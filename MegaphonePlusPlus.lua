--[[
Megaphone Plus Plus
Warhammer Online: Age of Reckoning UI modification that announces the
messages from the group's leader.
Copyright (C) 2020  Tim Neill
kinghfb@gmail.com   timneill.net
Original by Richard Conner rkc@pacbell.net
]]--
----------------------------------------------------------------
Megaphone = {}
Megaphone.Windows = {}
Megaphone.Windows.Main = "MegaphoneMain"
Megaphone.Windows.Marker = "MegaphoneMarker"
local leaderId = nil                 -- The object ID of the leader
local chatNameFilter = ""            -- The player name to filter for in chat
local selfName = ""                  -- It's me!
local lastAnnouncedLeaderKey = nil  -- Lowercase std-string of last announced leader
local isUpdatePending = false      -- Flag to debounce group updates
local showLeaderName = true      -- Local checkbox setting for showing leader name in alert text
local highlightLeader = false      -- Local checkbox setting for highlighting leader
local highlightRealmLeader = false -- Local checkbox setting for highlighting the realm leader
local realmLeaderName_wstr = nil   -- Session-only: a realm leader's name (not saved)
local realmLeaderName_std_lower = nil -- Lowercase std-string version of RL name for fast comparisons
local realmLeaderObjectId = nil    -- Best-known world object id for the realm leader
local markerTargetId = nil         -- Tracks whichever world object currently has the marker attached
local isTargetEventRegistered = false -- Tracks whether we registered PLAYER_TARGET_UPDATED
-- Cached channel sets for fast filtering in Megaphone.FilterChat
local WB_CHANNELS = nil
local RL_CHANNELS = nil
-- Reusable scratch table to avoid per-message allocations when normalizing chat
local messageInfoScratch = {
    normalized_w = L"",
    normalized_std = "",
    normalized_std_lower = "",
    display_std = "",
    display_is_safe = true,
}
local normalizeScratchBuffer = {}
local sanitizeScratchBuffer = {}
-- Short-term cache of recent alert texts per sender to prevent rapid repeats
local recentMessageCache = nil       -- Tracks last alert timestamps per sender|message key
local recentMessageCleanupTime = 0   -- Last time the cache was pruned
local MESSAGE_SUPPRESS_WINDOW = 3    -- Seconds to block repeat alerts; keeps leader spam manageable
local PLAYER_LINK_DEFAULT_COLOR = "255,255,50" -- Match chat prefix tint unless overridden
local REALM_LEADER_RECHECK_SECONDS = 3 -- Throttle between auto reattachment passes
local nextRealmLeaderRecheckAt = nil
local realmLeaderNeedsForceUpdate = true -- Ensure the first recovery attempt refreshes target data
local MARKER_POLL_SECONDS = 1                -- Poll cadence in seconds
local MARKER_POLL_FALLBACK_UPDATES = 10      -- Poll cadence fallback when no time source is available
local MARKER_INACTIVE_SECONDS = 20           -- Idle duration before soft-hiding (seconds)
local MARKER_INACTIVE_FALLBACK_UPDATES = 20  -- Fallback update count for soft-hide threshold
local MARKER_REMOVE_SECONDS = 1200           -- Idle duration before we detach (seconds)
local MARKER_REMOVE_FALLBACK_UPDATES = 1200  -- Fallback update count for remove threshold
local MARKER_SOFT_HIDE_SCALE = 0.000001      -- Scale applied while soft-hidden; keeps attachment but removes visual
local markerLastScreenX = nil
local markerLastScreenY = nil
local markerLastMovementTime = nil
local markerStationaryUpdates = 0
local nextMarkerMotionCheckAt = nil
local markerMotionFallbackCounter = 0
local markerSoftHidden = false
local markerStoredScale = nil
local markerInactiveSince = nil
local markerSoftHideStartUpdate = nil
local TARGET_UNIT_IDS = { "selffriendlytarget", "mouseovertarget" }
local getCurrentTimeSeconds
local updateTargetEventRegistration

local function resetMarkerMovementTracking()
    markerLastScreenX = nil
    markerLastScreenY = nil
    markerLastMovementTime = nil
    markerStationaryUpdates = 0
    nextMarkerMotionCheckAt = nil
    markerMotionFallbackCounter = 0
    markerSoftHidden = false
    markerInactiveSince = nil
    markerSoftHideStartUpdate = nil
end

local function restoreMarkerScale()
    if not markerSoftHidden and markerStoredScale == nil then
        return
    end
    local scale = markerStoredScale
    if type(scale) ~= "number" or scale <= 0 then
        scale = 1
    end
    if type(WindowSetScale) == "function" then
        pcall(WindowSetScale, Megaphone.Windows.Marker, scale)
    end
end

local function cacheMarkerScaleIfNeeded()
    if markerStoredScale then
        return
    end
    if type(WindowGetScale) ~= "function" then
        return
    end
    local ok, scale = pcall(WindowGetScale, Megaphone.Windows.Marker)
    if ok and type(scale) == "number" and scale > 0 then
        markerStoredScale = scale
    end
end

local function ensureMarkerSoftShown()
    if not markerSoftHidden then
        return
    end
    cacheMarkerScaleIfNeeded()
    restoreMarkerScale()
    WindowSetShowing(Megaphone.Windows.Marker, true)
    markerSoftHidden = false
    markerInactiveSince = nil
    markerSoftHideStartUpdate = nil
end

local function applyMarkerSoftHide(nowSeconds)
    if markerSoftHidden then
        if markerInactiveSince == nil then
            markerInactiveSince = nowSeconds
        end
        if markerSoftHideStartUpdate == nil then
            markerSoftHideStartUpdate = markerStationaryUpdates
        end
        return
    end
    cacheMarkerScaleIfNeeded()
    if type(WindowSetScale) == "function" and type(markerStoredScale) == "number" and markerStoredScale > 0 then
        pcall(WindowSetScale, Megaphone.Windows.Marker, MARKER_SOFT_HIDE_SCALE)
    end
    WindowSetShowing(Megaphone.Windows.Marker, false)
    markerSoftHidden = true
    markerInactiveSince = nowSeconds
    markerSoftHideStartUpdate = markerStationaryUpdates
end

local function printMsg(str)
    EA_ChatWindow.Print(towstring("<LINK data=\"0\" text=\"[Megaphone++]\" color=\"255,255,50\"> " .. str))
end

-- Convert incoming strings to a CP-1252-safe narrow string so wide chars that
-- the client cannot render get folded into "?" instead of breaking alerts.
local function sanitizeToCp1252(str)
    if not str or str == "" then
        return ""
    end
    local buffer = sanitizeScratchBuffer
    local prevSize = #buffer
    local size = 0
    local i = 1
    local len = string.len(str)
    while i <= len do
        local byte = string.byte(str, i)
        local outChar
        if byte == nil then
            break
        end
        if byte == 9 or byte == 10 or byte == 13 then
            outChar = " "
            i = i + 1
        elseif byte >= 32 and byte <= 126 then
            outChar = string.char(byte)
            i = i + 1
        elseif byte == 0 or byte == 127 then
            outChar = "?"
            i = i + 1
        else
            local seqLen = nil
            if byte >= 0xC2 and byte <= 0xDF then
                seqLen = 2
            elseif byte >= 0xE0 and byte <= 0xEF then
                seqLen = 3
            elseif byte >= 0xF0 and byte <= 0xF4 then
                seqLen = 4
            end
            if seqLen then
                local validUtf8 = true
                if (i + seqLen - 1) > len then
                    validUtf8 = false
                else
                    for j = i + 1, i + seqLen - 1 do
                        local cbyte = string.byte(str, j)
                        if not cbyte or cbyte < 0x80 or cbyte > 0xBF then
                            validUtf8 = false
                            break
                        end
                    end
                end
                if validUtf8 then
                    outChar = "?"
                    i = i + seqLen
                else
                    outChar = string.char(byte)
                    i = i + 1
                end
            else
                outChar = string.char(byte)
                i = i + 1
            end
        end
        if outChar ~= nil then
            size = size + 1
            buffer[size] = outChar
        end
    end
    for j = size + 1, prevSize do
        buffer[j] = nil
    end
    return table.concat(buffer, "", 1, size)
end

local function toSafeNarrowString(value)
    if value == nil then
        return ""
    end
    local vType = type(value)
    if vType == "string" then
        return sanitizeToCp1252(value)
    end
    if vType == "wstring" then
        if type(WStringToString) == "function" then
            local ok, str = pcall(WStringToString, value)
            if ok and type(str) == "string" then
                return sanitizeToCp1252(str)
            end
        end
    end
    local ok, str = pcall(tostring, value)
    if ok and type(str) == "string" then
        return sanitizeToCp1252(str)
    end
    return ""
end

local function toWideString(value)
    if type(value) == "wstring" then
        return value
    end
    return towstring(value or "")
end

local function hasRealmLeader()
    return realmLeaderName_wstr ~= nil and realmLeaderName_wstr ~= L""
end

local function getRealmLeaderLower()
    return realmLeaderName_std_lower
end

local function setRealmLeaderLowerCache(std_name)
    if not std_name or std_name == "" then
        realmLeaderName_std_lower = nil
        return
    end
    realmLeaderName_std_lower = string.lower(std_name)
end

local function setRealmLeaderObjectId(objectId)
    local newObjectId = objectId
    if not newObjectId or newObjectId == 0 then
        newObjectId = nil
    end

    if realmLeaderObjectId == newObjectId then
        realmLeaderNeedsForceUpdate = (newObjectId == nil)
        return
    end

    realmLeaderObjectId = newObjectId
    realmLeaderNeedsForceUpdate = (newObjectId == nil)
    if newObjectId ~= nil then
        nextRealmLeaderRecheckAt = nil
    end
    if updateTargetEventRegistration then
        updateTargetEventRegistration()
    end
end

local function getRealmLeaderObjectId()
    return realmLeaderObjectId
end

local function canFallbackToWarbandLeader()
    if not IsWarBandActive() then
        return false
    end
    if not leaderId or leaderId == 0 then
        return false
    end
    if not chatNameFilter or chatNameFilter == "" or chatNameFilter == L"" then
        return false
    end
    if chatNameFilter == selfName then
        return false
    end
    return true
end

local function markerTargetIsRealmLeader()
    if not highlightRealmLeader or not hasRealmLeader() then
        return false
    end
    local rlId = getRealmLeaderObjectId()
    return rlId ~= nil and markerTargetId == rlId
end

local function clearMarkerTargetCacheIfNeeded()
    if markerTargetIsRealmLeader() then
        setRealmLeaderObjectId(nil)
    end
end

local captureRealmLeaderFromUnit
local captureRealmLeaderFromTargets

local function findRealmLeaderWorldObj()
    if not hasRealmLeader() then
        setRealmLeaderObjectId(nil)
        return nil
    end
    local lowerKey = getRealmLeaderLower()
    if not lowerKey or lowerKey == "" then
        setRealmLeaderObjectId(nil)
        return nil
    end

    local foundInWarband = false
    local resolvedFromWarband = nil
    if highlightRealmLeader and IsWarBandActive() then
        local wb = PartyUtils.GetWarbandData()
        if wb then
            for _, grp in ipairs(wb) do
                if grp and grp.players then
                    for _, player in ipairs(grp.players) do
                        if player and player.name then
                            local cleaned = Megaphone.CleanPlayerName(player.name)
                            if cleaned and cleaned ~= L"" then
                                local std = WStringToString(cleaned)
                                if std and string.lower(std) == lowerKey then
                                    foundInWarband = true
                                    if player.worldObjNum and player.worldObjNum ~= 0 then
                                        resolvedFromWarband = player.worldObjNum
                                    end
                                    break
                                end
                            end
                        end
                    end
                    if foundInWarband then
                        break
                    end
                end
            end
        end
    end

    if resolvedFromWarband then
        if getRealmLeaderObjectId() ~= resolvedFromWarband then
            setRealmLeaderObjectId(resolvedFromWarband)
        end
        return resolvedFromWarband
    end

    if foundInWarband then
        if getRealmLeaderObjectId() ~= nil then
            setRealmLeaderObjectId(nil)
        end
        return nil
    end

    local cached = getRealmLeaderObjectId()
    if not cached or cached == 0 then
        setRealmLeaderObjectId(nil)
        return nil
    end

    if TargetInfo and type(TargetInfo.UnitEntityId) == "function" and type(TargetInfo.UnitName) == "function" then
        for i = 1, #TARGET_UNIT_IDS do
            local unitId = TARGET_UNIT_IDS[i]
            local entityId = TargetInfo:UnitEntityId(unitId)
            if entityId and entityId ~= 0 then
                local name_w = TargetInfo:UnitName(unitId)
                if name_w then
                    local cleaned = Megaphone.CleanPlayerName(name_w)
                    if cleaned and cleaned ~= L"" then
                        local std = WStringToString(cleaned)
                        if std then
                            local stdLower = string.lower(std)
                            if entityId == cached and stdLower == lowerKey then
                                return cached
                            end
                            if stdLower == lowerKey then
                                setRealmLeaderObjectId(entityId)
                                return entityId
                            end
                        end
                    end
                end
            end
        end
    end

    setRealmLeaderObjectId(nil)
    return nil
end

local function resolveMarkerTargetId()
    if highlightRealmLeader then
        if hasRealmLeader() then
            local rlId = findRealmLeaderWorldObj()
            if rlId then
                return rlId
            end
            return nil
        end
        if canFallbackToWarbandLeader() then
            return leaderId
        end
        return nil
    end
    if highlightLeader then
        return leaderId
    end
    return nil
end

local function updateMarkerMotion()
    -- Poll sparingly: invalid positions detach, stationary markers soft-hide and eventually detach.
    if not markerTargetId then
        resetMarkerMovementTracking()
        return
    end
    local now = getCurrentTimeSeconds()
    if now then
        if MARKER_POLL_SECONDS > 0 then
            if nextMarkerMotionCheckAt ~= nil and now < nextMarkerMotionCheckAt then
                return
            end
            nextMarkerMotionCheckAt = now + MARKER_POLL_SECONDS
        end
        markerMotionFallbackCounter = 0
    else
        markerMotionFallbackCounter = markerMotionFallbackCounter + 1
        if markerMotionFallbackCounter < MARKER_POLL_FALLBACK_UPDATES then
            return
        end
        markerMotionFallbackCounter = 0
    end
    if type(WindowGetScreenPosition) ~= "function" then
        return
    end
    local ok, x, y = pcall(WindowGetScreenPosition, Megaphone.Windows.Marker)
    if not ok or type(x) ~= "number" or type(y) ~= "number" then
        clearMarkerTargetCacheIfNeeded()
        Megaphone.HideMarker()
        return
    end
    x = math.floor(x)
    y = math.floor(y)
    if markerLastScreenX == nil or markerLastScreenY == nil then
        markerLastScreenX = x
        markerLastScreenY = y
        markerStationaryUpdates = 0
        markerSoftHideStartUpdate = nil
        ensureMarkerSoftShown()
        if now then
            markerLastMovementTime = now
        else
            markerLastMovementTime = nil
        end
        markerInactiveSince = nil
        return
    end
    local deltaX = math.abs(x - markerLastScreenX)
    local deltaY = math.abs(y - markerLastScreenY)
    if deltaX ~= 0 or deltaY ~= 0 then
        markerLastScreenX = x
        markerLastScreenY = y
        markerStationaryUpdates = 0
        markerSoftHideStartUpdate = nil
        ensureMarkerSoftShown()
        if now then
            markerLastMovementTime = now
        else
            markerLastMovementTime = nil
        end
        markerInactiveSince = nil
        return
    end

    markerStationaryUpdates = markerStationaryUpdates + 1
    local timeSinceMove = nil
    if now and markerLastMovementTime then
        timeSinceMove = now - markerLastMovementTime
    end

    local reachedSoftHide = false
    if timeSinceMove then
        if timeSinceMove >= MARKER_INACTIVE_SECONDS then
            reachedSoftHide = true
        end
    elseif markerStationaryUpdates >= MARKER_INACTIVE_FALLBACK_UPDATES then
        reachedSoftHide = true
    end

    if reachedSoftHide then
        applyMarkerSoftHide(now)
        local removeDueToTime = false
        if now and markerInactiveSince then
            removeDueToTime = (now - markerInactiveSince) >= MARKER_REMOVE_SECONDS
        elseif markerSoftHideStartUpdate ~= nil then
            local updatesSinceSoftHide = markerStationaryUpdates - markerSoftHideStartUpdate
            if updatesSinceSoftHide >= MARKER_REMOVE_FALLBACK_UPDATES then
                removeDueToTime = true
            end
        end
        if removeDueToTime then
            clearMarkerTargetCacheIfNeeded()
            Megaphone.HideMarker()
        end
    end
end

local function realmLeaderNameMatches(candidate_w)
    if not candidate_w or candidate_w == L"" then
        return false
    end
    local cleaned = Megaphone.CleanPlayerName(candidate_w)
    if not cleaned or cleaned == L"" then
        return false
    end
    local std = WStringToString(cleaned)
    if not std or std == "" then
        return false
    end
    local lowerKey = getRealmLeaderLower()
    if not lowerKey or lowerKey == "" then
        return false
    end
    return string.lower(std) == lowerKey
end

captureRealmLeaderFromUnit = function(unitId)
    if not unitId or type(unitId) ~= "string" then
        return false
    end
    if not TargetInfo or type(TargetInfo.UnitName) ~= "function" then
        return false
    end
    if not hasRealmLeader() then
        return false
    end
    local lowerKey = getRealmLeaderLower()
    if not lowerKey or lowerKey == "" then
        return false
    end
    if type(TargetInfo.UnitType) == "function" and SystemData and SystemData.TargetObjectType then
        local unitType = TargetInfo:UnitType(unitId)
        local allyType = SystemData.TargetObjectType.ALLY_PLAYER
        if unitType and allyType and unitType ~= allyType then
            return false
        end
    end
    local name_w = TargetInfo:UnitName(unitId)
    if not realmLeaderNameMatches(name_w) then
        return false
    end
    local entityId = nil
    if type(TargetInfo.UnitEntityId) == "function" then
        entityId = TargetInfo:UnitEntityId(unitId)
    end
    if not entityId or entityId == 0 then
        return false
    end
    local cached = getRealmLeaderObjectId()
    if cached and cached == entityId then
        return true
    end
    setRealmLeaderObjectId(entityId)
    if highlightRealmLeader then
        Megaphone.AttachMarkerToPlayer()
    end
    return true
end

captureRealmLeaderFromTargets = function(forceUpdate)
    if not hasRealmLeader() then
        return false
    end
    if not TargetInfo or type(TargetInfo.UnitName) ~= "function" then
        return false
    end
    if forceUpdate and type(TargetInfo.UpdateFromClient) == "function" then
        TargetInfo:UpdateFromClient()
    end
    if captureRealmLeaderFromUnit("selffriendlytarget") then
        return true
    end
    if captureRealmLeaderFromUnit("mouseovertarget") then
        return true
    end
    return false
end

updateTargetEventRegistration = function()
    -- Listen only while RL highlighting still needs a world-object id.
    local shouldRegister = highlightRealmLeader and hasRealmLeader() and getRealmLeaderObjectId() == nil
    if shouldRegister and not isTargetEventRegistered then
        RegisterEventHandler(SystemData.Events.PLAYER_TARGET_UPDATED, "Megaphone.OnPlayerTargetUpdated")
        isTargetEventRegistered = true
    elseif (not shouldRegister) and isTargetEventRegistered then
        UnregisterEventHandler(SystemData.Events.PLAYER_TARGET_UPDATED, "Megaphone.OnPlayerTargetUpdated")
        isTargetEventRegistered = false
    end
end

-- Builds a clickable player link for chat output. Returns both the link
-- markup and a plain display name (capitalized) for fallback scenarios.
function Megaphone.FormatPlayerLink(name_input, colorOverride)
    local cleaned_w = Megaphone.CleanPlayerName(name_input)
    if not cleaned_w or cleaned_w == L"" then
        return "", ""
    end
    local base_std = WStringToString(cleaned_w)
    if not base_std or base_std == "" then
        return "", ""
    end
    local display_std = base_std
    if string.len(display_std) > 0 then
        display_std = string.upper(string.sub(display_std, 1, 1)) .. string.sub(display_std, 2)
    end
    local color = colorOverride or PLAYER_LINK_DEFAULT_COLOR
    local link_text = "@" .. display_std
    local link_markup = string.format(
        "<LINK data=\"PLAYER:%s\" color=\"%s\" text=\"%s\">",
        base_std,
        color,
        link_text
    )
    return link_markup, display_std
end
----------------------------------------------------------------
-- Helper: return clickable markup when possible, or a best-effort fallback.
function Megaphone.PlayerLinkText(name_input, colorOverride)
    local link_markup, display_std = Megaphone.FormatPlayerLink(name_input, colorOverride)
    if link_markup ~= "" then
        return link_markup
    end
    if display_std ~= "" then
        return "@" .. display_std
    end
    if not name_input then
        return ""
    end
    local cleaned_w = Megaphone.CleanPlayerName(name_input)
    if cleaned_w and cleaned_w ~= L"" then
        return WStringToString(cleaned_w)
    end
    return tostring(name_input)
end
----------------------------------------------------------------
-- Taken from GesConstants
Megaphone.AlertText = {
    { id = nil                                                   , name = "Do not alert" },
    { id = SystemData.AlertText.Types.DEFAULT                    , name = "Default" },
    { id = SystemData.AlertText.Types.COMBAT                     , name = "Combat" },
    { id = SystemData.AlertText.Types.QUEST_NAME                 , name = "Quest Name" },
    { id = SystemData.AlertText.Types.QUEST_CONDITION            , name = "Quest Condition" },
    { id = SystemData.AlertText.Types.QUEST_END                  , name = "Quest End" },
    { id = SystemData.AlertText.Types.OBJECTIVE                  , name = "Objective" },
    { id = SystemData.AlertText.Types.RVR                        , name = "RvR" },
    { id = SystemData.AlertText.Types.SCENARIO                   , name = "Scenario" },
    { id = SystemData.AlertText.Types.MOVEMENT_RVR               , name = "Movement RvR" },
    { id = SystemData.AlertText.Types.ENTERAREA                  , name = "Enter Area" },
    { id = SystemData.AlertText.Types.STATUS_ERRORS              , name = "Status Errors" },
    { id = SystemData.AlertText.Types.STATUS_ACHIEVEMENTS_GOLD   , name = "Status Achievements Gold"   },
    { id = SystemData.AlertText.Types.STATUS_ACHIEVEMENTS_PURPLE , name = "Status Achievements Purple" },
    { id = SystemData.AlertText.Types.STATUS_ACHIEVEMENTS_RANK   , name = "Status Achievements Rank"   },
    { id = SystemData.AlertText.Types.STATUS_ACHIEVEMENTS_RENOUN , name = "Status Achievements Renown" },
    { id = SystemData.AlertText.Types.PQ_ENTER                   , name = "PQ Enter" },
    { id = SystemData.AlertText.Types.PQ_NAME                    , name = "PQ Name" },
    { id = SystemData.AlertText.Types.PQ_DESCRIPTION             , name = "PQ Description" },
    { id = SystemData.AlertText.Types.ENTERZONE                  , name = "Enter Zone" },
    { id = SystemData.AlertText.Types.ORDER                      , name = "Order" },
    { id = SystemData.AlertText.Types.DESTRUCTION                , name = "Destruction" },
    { id = SystemData.AlertText.Types.NEUTRAL                    , name = "Neutral" },
    { id = SystemData.AlertText.Types.ABILITY                    , name = "Ability" },
    { id = SystemData.AlertText.Types.BO_ENTER                   , name = "BO Enter" },
    { id = SystemData.AlertText.Types.BO_NAME                    , name = "BO Name" },
    { id = SystemData.AlertText.Types.BO_DESCRIPTION             , name = "BO Description" },
    { id = SystemData.AlertText.Types.CITY_RATING                , name = "City Rating" },
    { id = SystemData.AlertText.Types.GUILD_RANK                 , name = "Guild Rank" },
    { id = SystemData.AlertText.Types.RRQ_UNPAUSED               , name = "RRQ Unpaused" },
    { id = SystemData.AlertText.Types.LARGE_ORDER                , name = "Large Order" },
    { id = SystemData.AlertText.Types.LARGE_DESTRUCTION          , name = "Large Destruction" },
    { id = SystemData.AlertText.Types.LARGE_NEUTRAL              , name = "Large Neutral" }
}
Megaphone.SoundTypes = {
    { id = nil                                           , name = "Do not play a sound"},
    { id = GameData.Sound.ACTION_FAILED                  , name = "Action Failed"},
    { id = GameData.Sound.ADVANCE_RANK                   , name = "Advance Rank"},
    { id = GameData.Sound.ADVANCE_TIER                   , name = "Advance Tier"},
    { id = GameData.Sound.APOTHECARY_ADD_FAILED          , name = "Apothecary Add Failed"},
    { id = GameData.Sound.APOTHECARY_BREW_STARTED        , name = "Apothecary Brew Started"},
    { id = GameData.Sound.APOTHECARY_CONTAINER_ADDED     , name = "Apothecary Container Added"},
    { id = GameData.Sound.APOTHECARY_DETERMINENT_ADDED   , name = "Apothecary Determinent Added"},
    { id = GameData.Sound.APOTHECARY_FAILED              , name = "Apothecary Failed"},
    { id = GameData.Sound.APOTHECARY_ITEM_REMOVED        , name = "Apothecary Item Removed"},
    { id = GameData.Sound.APOTHECARY_RESOURCE_ADDED      , name = "Apothecary Resource Added"},
    { id = GameData.Sound.BETA_WARNING                   , name = "Beta Warning"},
    { id = GameData.Sound.BUTTON_CLICK                   , name = "Button Click"},
    { id = GameData.Sound.BUTTON_OVER                    , name = "Button Over"},
    { id = GameData.Sound.CULTIVATING_HARVEST_CROP       , name = "Cultivating Harvest Crop"},
    { id = GameData.Sound.CULTIVATING_NUTRIENT_ADDED     , name = "Cultivating Nutrient Added"},
    { id = GameData.Sound.CULTIVATING_SEED_ADDED         , name = "Cultivating Seed Added"},
    { id = GameData.Sound.CULTIVATING_SOIL_ADDED         , name = "Cultivating Soil Added"},
    { id = GameData.Sound.CULTIVATING_WATER_ADDED        , name = "Cultivating Water Added"},
    { id = GameData.Sound.ICON_CLEAR                     , name = "Icon Clear"},
    { id = GameData.Sound.ICON_DROP                      , name = "Icon Drop"},
    { id = GameData.Sound.ICON_PICKUP                    , name = "Icon Pickup"},
    { id = GameData.Sound.LOOT_MONEY                     , name = "Loot Money"},
    { id = GameData.Sound.MONETARY_TRANSACTION           , name = "Monetary Transaction"},
    { id = GameData.Sound.OBJECTIVE_CAPTURE              , name = "Objective Capture"},
    { id = GameData.Sound.OBJECTIVE_LOSE                 , name = "Objective Lose"},
    { id = GameData.Sound.PREGAME_PLAY_GAME_BUTTON       , name = "Pregame Play Game Button"},
    { id = GameData.Sound.PUBLIC_TOME_UNLOCKED           , name = "Public Tome Unlocked"},
    { id = GameData.Sound.QUEST_ABANDONED                , name = "Quest Abandoned"},
    { id = GameData.Sound.QUEST_ACCEPTED                 , name = "Quest Accepted"},
    { id = GameData.Sound.QUEST_COMPLETED                , name = "Quest Completed"},
    { id = GameData.Sound.QUEST_OBJECTIVES_COMPLETED     , name = "Quest Objective Complete"},
    { id = GameData.Sound.RESPAWN                        , name = "Respawn"},
    { id = GameData.Sound.RVR_FLAG_OFF                   , name = "RvR Flag Off"},
    { id = GameData.Sound.RVR_FLAG_ON                    , name = "RvR Flag On"},
    { id = GameData.Sound.TARGET_DESELECT                , name = "Target Deselect"},
    { id = GameData.Sound.TARGET_SELECT                  , name = "Target Select"},
    { id = GameData.Sound.TOME_TURN_PAGE                 , name = "Tome Turn Page"},
    { id = GameData.Sound.WINDOW_CLOSE                   , name = "Window Close"},
    { id = GameData.Sound.WINDOW_OPEN                    , name = "Window Open"},
    { id = GameData.Sound.CLOSE_WORLD_MAP                , name = "World Map Close"},
    { id = GameData.Sound.OPEN_WORLD_MAP                 , name = "World Map Open"}
}

----------------------------------------------------------------
-- Configurable list of message prefixes to ignore.
-- Example: QueueQueuer messages start with "[QQ:".
Megaphone.IgnoredMessagePrefixes = {
    "[QQ:",
}
-- Configurable list of message substrings to ignore anywhere in the message.
-- Add plain substrings (no patterns).
Megaphone.IgnoredMessageSubstrings = {
    "discord.gg",
}
----------------------------------------------------------------
-- RealmLeader-specific ignore lists
-- Add more prefixes or substrings as needed.
Megaphone.RLIgnoredMessagePrefixes = {
    "<icon44> [",
    "<icon51> ",
    "<icon49> Warband Looking",
    "<icon49> Organized warband looking",
    "[AutoBand] Warband need",
}
Megaphone.RLIgnoredSubstrings = {
    -- Add plain substrings to ignore anywhere in the message (no patterns)
}
local function lowerListValues(list)
    if not list then return end
    for i = 1, #list do
        local v = list[i]
        if v and type(v) == "string" then
            list[i] = string.lower(v)
        end
    end
end
lowerListValues(Megaphone.IgnoredMessagePrefixes)
lowerListValues(Megaphone.IgnoredMessageSubstrings)
lowerListValues(Megaphone.RLIgnoredMessagePrefixes)
lowerListValues(Megaphone.RLIgnoredSubstrings)
----------------------------------------------------------------
-- Normalize chat text for matching:
-- - Remove color/style/link tags
-- - If a tag has a TEXT="..." attribute, keep its text
-- - Preserve icon tags like <icon49> as literal markers
-- Returns: normalized_wstr, normalized_std_str
function Megaphone.NormalizeForMatching(text_wstr)
    if not text_wstr then
        return L"", ""
    end
    local s = toSafeNarrowString(text_wstr)
    if s == "" then
        return L"", ""
    end
    local buffer = normalizeScratchBuffer
    local prevSize = #buffer
    local bufferSize = 0
    local pos = 1
    local slen = string.len(s)
    local strFind = string.find
    local strSub = string.sub
    local strMatch = string.match
    while pos <= slen do
        local lt = strFind(s, "<", pos, true)
        if not lt then
            local tail = strSub(s, pos)
            if tail ~= "" then
                bufferSize = bufferSize + 1
                buffer[bufferSize] = tail
            end
            break
        end
        -- copy text before tag
        if lt > pos then
            bufferSize = bufferSize + 1
            buffer[bufferSize] = strSub(s, pos, lt - 1)
        end
        -- find end of tag
        local gt = strFind(s, ">", lt + 1, true)
        if not gt then
            -- malformed tag; append rest and break
            bufferSize = bufferSize + 1
            buffer[bufferSize] = strSub(s, lt)
            break
        end
        local body = strSub(s, lt + 1, gt - 1)       -- inside <...>
        -- Preserve <iconNN> (case-insensitive)
        -- Allow optional whitespace: < icon 49 >
        local iconDigits = strMatch(body, "^%s*[Ii][Cc][Oo][Nn]%s*([0-9]+)%s*.*$")
        if iconDigits then
            bufferSize = bufferSize + 1
            buffer[bufferSize] = "<icon" .. iconDigits .. ">"
        else
            -- If the tag has a TEXT attribute, keep its value
            local _, _, txt = strFind(body, "[Tt][Ee][Xx][Tt]%s*=%s*\"([^\"]*)\"")
            if txt then
                if txt ~= "" then
                    bufferSize = bufferSize + 1
                    buffer[bufferSize] = txt
                end
            end
            -- else: drop tag entirely (colors/styles/closers)
        end
        pos = gt + 1
    end
    for i = bufferSize + 1, prevSize do
        buffer[i] = nil
    end
    local out = table.concat(buffer, "", 1, bufferSize)
    -- Trim leading whitespace introduced by tag removal
    out = string.gsub(out, "^%s+", "")
    out = sanitizeToCp1252(out)
    return towstring(out), out
end
----------------------------------------------------------------
getCurrentTimeSeconds = function()
    if type(GetGameTime) == "function" then
        local ok, t = pcall(GetGameTime)
        if ok and type(t) == "number" and t >= 0 then
            return t
        end
    end
    if GameData and GameData.Time and type(GameData.Time.seconds) == "number" then
        return GameData.Time.seconds
    end
    if GameData and GameData.ChatData and type(GameData.ChatData.time) == "number" then
        return GameData.ChatData.time
    end
    return nil
end

local function toLowerString(value)
    local s = toSafeNarrowString(value)
    if s == "" then
        return ""
    end
    return string.lower(s)
end

-- Prevents re-announcing the exact same leader text inside MESSAGE_SUPPRESS_WINDOW seconds.
-- Uses a normalized "sender|message" key so a leader repeating themselves triggers the block,
-- while different leaders or different messages still go through immediately.
local function shouldSuppressRepeatedMessage(message_std_str, sender_wstr)
    if not message_std_str or message_std_str == "" then
        return false
    end
    local now = getCurrentTimeSeconds()
    if not now then
        return false
    end
    recentMessageCache = recentMessageCache or {}
    local senderKey = toLowerString(sender_wstr)
    local cacheKey
    if senderKey ~= "" then
        cacheKey = senderKey .. "|" .. message_std_str
    else
        cacheKey = message_std_str
    end
    local last = recentMessageCache[cacheKey]
    if last and (now - last) < MESSAGE_SUPPRESS_WINDOW then
        return true
    end
    recentMessageCache[cacheKey] = now
    if (now - (recentMessageCleanupTime or 0)) >= MESSAGE_SUPPRESS_WINDOW then
        for key, timestamp in pairs(recentMessageCache) do
            if not timestamp or (now - timestamp) >= MESSAGE_SUPPRESS_WINDOW then
                recentMessageCache[key] = nil
            end
        end
        recentMessageCleanupTime = now
    end
    return false
end
----------------------------------------------------------------
-- Prepare reusable normalized/display forms of a chat message. Pass an
-- existing table to reuse it and keep GC pressure low.
function Megaphone.BuildMessageInfo(text_wstr, out)
    local normalized_w, normalized_std = Megaphone.NormalizeForMatching(text_wstr)
    local normalized_std_safe = normalized_std or ""
    local display_std = normalized_std_safe
    if display_std ~= "" then
        if string.find(display_std, "<icon", 1, true) then
            display_std = string.gsub(display_std, "<icon[0-9]+>", "")
        end
        if display_std ~= "" then
            display_std = string.gsub(display_std, "^%s+", "")
        end
    else
        display_std = ""
    end
    local info = out or {}
    info.normalized_w = normalized_w
    info.normalized_std = normalized_std_safe
    if normalized_std_safe ~= "" then
        info.normalized_std_lower = string.lower(normalized_std_safe)
    else
        info.normalized_std_lower = ""
    end
    info.display_std = display_std
    info.display_is_safe = true
    return info
end
----------------------------------------------------------------
-- Helper to check if a wstring starts with any prefix from a list
function Megaphone.MessageHasIgnoredPrefix(text_wstr, normalized_std_str, normalized_std_lower)
    if not text_wstr and normalized_std_str == nil then
        return false
    end
    -- Normalize to strip color/style while keeping icons
    local norm_s = normalized_std_str
    if norm_s == nil then
        local _, computed = Megaphone.NormalizeForMatching(text_wstr)
        norm_s = computed
    end
    if not norm_s then
        return false
    end
    -- Case-insensitive compare on plain string
    local norm_s_lc = normalized_std_lower
    if norm_s_lc == nil then
        norm_s_lc = string.lower(norm_s)
    end
    local prefixes = Megaphone.IgnoredMessagePrefixes
    if not prefixes then
        return false
    end
    for i = 1, #prefixes do
        local pref = prefixes[i]
        if pref then
            local plen = string.len(pref)
            if plen > 0 and string.sub(norm_s_lc, 1, plen) == pref then
                return true
            end
        end
    end
    return false
end
----------------------------------------------------------------
-- Helper to check if a wstring contains any ignored substring
function Megaphone.MessageHasIgnoredSubstring(text_wstr, normalized_std_str, normalized_std_lower)
    if not text_wstr and normalized_std_str == nil then
        return false
    end
    local norm_s = normalized_std_str
    if norm_s == nil then
        local _, computed = Megaphone.NormalizeForMatching(text_wstr)
        norm_s = computed
    end
    if not norm_s then
        return false
    end
    local norm_s_lc = normalized_std_lower
    if norm_s_lc == nil then
        norm_s_lc = string.lower(norm_s)
    end
    local subs = Megaphone.IgnoredMessageSubstrings
    if not subs then
        return false
    end
    for i = 1, #subs do
        local sub = subs[i]
        if sub and string.len(sub) > 0 then
            if string.find(norm_s_lc, sub, 1, true) then
                return true
            end
        end
    end
    return false
end
----------------------------------------------------------------
-- RL helper: ignore message if it matches RL-specific prefixes/substrings
function Megaphone.RLMessageShouldIgnore(text_wstr, normalized_std_str, normalized_std_lower)
    if not text_wstr and normalized_std_str == nil then
        return false
    end
    local s = normalized_std_str
    if s == nil then
        local _, computed = Megaphone.NormalizeForMatching(text_wstr)
        s = computed
    end
    if not s then return false end
    local s_lc = normalized_std_lower
    if s_lc == nil then
        s_lc = string.lower(s)
    end
    -- Check RL prefixes (case-insensitive startswith)
    local pfx = Megaphone.RLIgnoredMessagePrefixes
    if pfx then
        for i = 1, #pfx do
            local pref = pfx[i]
            if pref then
                local plen = string.len(pref)
                if plen > 0 and string.sub(s_lc, 1, plen) == pref then
                    return true
                end
            end
        end
    end
    -- Check RL substrings (plain contains on std string)
    local subs = Megaphone.RLIgnoredSubstrings
    if subs then
        for i = 1, #subs do
            local sub = subs[i]
            if sub and string.len(sub) > 0 then
                if string.find(s_lc, sub, 1, true) then
                    return true
                end
            end
        end
    end
    -- Drop icon-tagged realm recruitment spam that includes an LFM ask
    if string.find(s_lc, "lfm", 1, true) then
        if string.sub(s_lc, 1, string.len("<icon44> [")) == "<icon44> [" then
            return true
        end
        if string.sub(s_lc, 1, string.len("<icon51> ")) == "<icon51> " then
            return true
        end
    end
    return false
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.OnFrameUpdate()
    if isUpdatePending then
        isUpdatePending = false
        Megaphone.GroupUpdate()
    end
    local shouldCheckRealmLeader = highlightRealmLeader and hasRealmLeader() and getRealmLeaderObjectId() == nil
    if shouldCheckRealmLeader then
        local now = getCurrentTimeSeconds()
        if now and (nextRealmLeaderRecheckAt == nil or now >= nextRealmLeaderRecheckAt) then
            nextRealmLeaderRecheckAt = now + REALM_LEADER_RECHECK_SECONDS
            local forced = realmLeaderNeedsForceUpdate
            realmLeaderNeedsForceUpdate = false
            captureRealmLeaderFromTargets(forced)
            local refreshedId = getRealmLeaderObjectId()
            if refreshedId ~= nil then
                Megaphone.AttachMarkerToPlayer()
                nextRealmLeaderRecheckAt = nil
            end
        end
    else
        if nextRealmLeaderRecheckAt ~= nil then
            nextRealmLeaderRecheckAt = nil
        end
        if not realmLeaderNeedsForceUpdate then
            realmLeaderNeedsForceUpdate = true
        end
        if not markerTargetId then
            return
        end
    end

    if markerTargetId then
        updateMarkerMotion()
    end
end
----------------------------------------------------------------
function Megaphone.RequestUpdate()
    isUpdatePending = true
end
----------------------------------------------------------------
function Megaphone.Initialize()
    local DEFAULT_MAX_MSG_LENGTH = 100
    if not Megaphone.Settings then
        Megaphone.Settings = {}
        Megaphone.Settings.Font = SystemData.AlertText.Types.QUEST_END
        Megaphone.Settings.Sound = GameData.Sound.QUEST_COMPLETED
        Megaphone.Settings.ShowName = true
        Megaphone.Settings.Highlight = false
        Megaphone.Settings.HighlightRealmLeader = false
        Megaphone.Settings.MaxMsgLength = DEFAULT_MAX_MSG_LENGTH
    end
    -- Cast to bool in case the settings are empty for this
    Megaphone.Settings.ShowName = not not Megaphone.Settings.ShowName
    Megaphone.Settings.Highlight = not not Megaphone.Settings.Highlight
    Megaphone.Settings.HighlightRealmLeader = not not Megaphone.Settings.HighlightRealmLeader
    Megaphone.Settings.MaxMsgLength = tonumber(Megaphone.Settings.MaxMsgLength)
    if Megaphone.Settings.MaxMsgLength == nil or Megaphone.Settings.MaxMsgLength < 0 then
        Megaphone.Settings.MaxMsgLength = DEFAULT_MAX_MSG_LENGTH
    end
    -- Default: add the context menu item to mark RL
    if Megaphone.Settings.AddContextMarkRL == nil then
        Megaphone.Settings.AddContextMarkRL = true
    end
    Megaphone.Settings.AddContextMarkRL = not not Megaphone.Settings.AddContextMarkRL
    showLeaderName = Megaphone.Settings.ShowName
    highlightLeader = Megaphone.Settings.Highlight
    highlightRealmLeader = Megaphone.Settings.HighlightRealmLeader
    if highlightRealmLeader and highlightLeader then
        highlightLeader = false
        Megaphone.Settings.Highlight = false
    end
    Megaphone.CreateWindows()
    RegisterEventHandler(SystemData.Events.CHAT_TEXT_ARRIVED, "Megaphone.FilterChat")
    RegisterEventHandler(SystemData.Events.BATTLEGROUP_UPDATED, "Megaphone.RequestUpdate")
    RegisterEventHandler(SystemData.Events.BATTLEGROUP_MEMBER_UPDATED, "Megaphone.RequestUpdate")
    RegisterEventHandler(SystemData.Events.INTERFACE_RELOADED, "Megaphone.RequestUpdate")
    RegisterEventHandler(SystemData.Events.LOADING_END, "Megaphone.Refresh")
    RegisterEventHandler(SystemData.Events.PLAYER_ZONE_CHANGED, "Megaphone.Refresh")
    Megaphone.EnsureChannelSets()
    LibSlash.RegisterSlashCmd("megaphonepp", Megaphone.SlashHandler)
    LibSlash.RegisterSlashCmd("mppp", Megaphone.SlashHandler)
    selfName = Megaphone.CleanPlayerName(GameData.Player.name)
    printMsg("Type /megaphonepp or /mppp to show config.")
    printMsg("Session cmd: /mppp rl <name> | /mppp rloff")
    printMsg("Help: /mppp help")
    Megaphone.HookPlayerContextMenu()
    updateTargetEventRegistration()
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.EnsureChannelSets()
    if WB_CHANNELS and RL_CHANNELS then return end
    WB_CHANNELS = WB_CHANNELS or {}
    RL_CHANNELS = RL_CHANNELS or {}
    local f = SystemData.ChatLogFilters
    if f then
        if f.GROUP then WB_CHANNELS[f.GROUP] = true end
        if f.BATTLEGROUP then WB_CHANNELS[f.BATTLEGROUP] = true end
        if f.SCENARIO_GROUPS then WB_CHANNELS[f.SCENARIO_GROUPS] = true end
        if f.REGION then RL_CHANNELS[f.REGION] = true end
        if f.REGIONAL then RL_CHANNELS[f.REGIONAL] = true end
        if f.CHANNEL_1 then RL_CHANNELS[f.CHANNEL_1] = true end
        if f.CHANNEL1 then RL_CHANNELS[f.CHANNEL1] = true end
        if f.CHANNEL_2 then RL_CHANNELS[f.CHANNEL_2] = true end
        if f.CHANNEL2 then RL_CHANNELS[f.CHANNEL2] = true end
        if f.GENERAL then RL_CHANNELS[f.GENERAL] = true end
        if f.ZONE then RL_CHANNELS[f.ZONE] = true end
    end
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.OnShutdown()
    UnregisterEventHandler(SystemData.Events.CHAT_TEXT_ARRIVED, "Megaphone.FilterChat")
    UnregisterEventHandler(SystemData.Events.BATTLEGROUP_UPDATED, "Megaphone.RequestUpdate")
    UnregisterEventHandler(SystemData.Events.BATTLEGROUP_MEMBER_UPDATED, "Megaphone.RequestUpdate")
    UnregisterEventHandler(SystemData.Events.INTERFACE_RELOADED, "Megaphone.RequestUpdate")
    UnregisterEventHandler(SystemData.Events.LOADING_END, "Megaphone.Refresh")
    UnregisterEventHandler(SystemData.Events.PLAYER_ZONE_CHANGED, "Megaphone.Refresh")
    if isTargetEventRegistered then
        UnregisterEventHandler(SystemData.Events.PLAYER_TARGET_UPDATED, "Megaphone.OnPlayerTargetUpdated")
        isTargetEventRegistered = false
    end
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.CreateWindows()
    CreateWindow(Megaphone.Windows.Main, true)
    Megaphone.HideWindow()
    CreateWindow(Megaphone.Windows.Marker, true)
    Megaphone.HideMarker()
    LabelSetText(Megaphone.Windows.Main.."TitleBarText", L"Megaphone++")
    ButtonSetText(Megaphone.Windows.Main.."CloseButton", L"Close")
    ButtonSetText(Megaphone.Windows.Main.."TestButton", L"Test")
    ButtonSetText(Megaphone.Windows.Main.."RLTestButton", L"Test RL")
    Megaphone.OptionsInitExtra()
    Megaphone.OptionsInitSounds()
    Megaphone.OptionsInitFonts()
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.HookPlayerContextMenu()
    if not PlayerMenuWindow then return end
    if Megaphone._origAddInteractionMenuItems then return end
    Megaphone._origAddInteractionMenuItems = PlayerMenuWindow.AddInteractionMenuItems
    PlayerMenuWindow.AddInteractionMenuItems = function(targetSelf)
        Megaphone._origAddInteractionMenuItems(targetSelf)
        if Megaphone.Settings and Megaphone.Settings.AddContextMarkRL then
            local label = L"Set as Realm Leader"
            local callback = Megaphone.OnContextMarkRealmLeader
            if realmLeaderName_wstr and realmLeaderName_wstr ~= L"" and PlayerMenuWindow and PlayerMenuWindow.curPlayer and PlayerMenuWindow.curPlayer.name then
                local curName_w = Megaphone.CleanPlayerName(PlayerMenuWindow.curPlayer.name)
                if curName_w and curName_w ~= L"" then
                    local currentLower = toLowerString(curName_w)
                    local realmLower = getRealmLeaderLower()
                    if realmLower and currentLower == realmLower then
                        label = L"Unset as Realm Leader"
                        callback = Megaphone.OnContextUnmarkRealmLeader
                    end
                end
            end
            EA_Window_ContextMenu.AddMenuItem(label, callback, false, true, EA_Window_ContextMenu.CONTEXT_MENU_1)
        end
    end
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.OnContextMarkRealmLeader()
    if ButtonGetDisabledFlag(SystemData.ActiveWindow.name) == true then
        return
    end
    local name = nil
    local worldObj = nil
    if PlayerMenuWindow and PlayerMenuWindow.curPlayer then
        name = PlayerMenuWindow.curPlayer.name
        worldObj = PlayerMenuWindow.curPlayer.worldObjNum
    end
    if not name or name == L"" then
        return
    end
    Megaphone.SetRealmLeader(name, nil, worldObj)
    if PlayerMenuWindow and PlayerMenuWindow.Done then
        PlayerMenuWindow.Done()
    end
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.OptionsInitExtra()
    ButtonSetPressedFlag(Megaphone.Windows.Main.."ShowLeaderCheckbox", showLeaderName)
    LabelSetText(Megaphone.Windows.Main.."ShowLeaderLabel", L"Show Leader Name")
    ButtonSetPressedFlag(Megaphone.Windows.Main.."HighlightLeaderCheckbox", highlightLeader)
    LabelSetText(Megaphone.Windows.Main.."HighlightLeaderLabel", L"Highlight Leader")
    ButtonSetPressedFlag(Megaphone.Windows.Main.."HighlightRealmLeaderCheckbox", highlightRealmLeader)
    LabelSetText(Megaphone.Windows.Main.."HighlightRealmLeaderLabel", L"Highlight Realm Leader")
    LabelSetText(Megaphone.Windows.Main.."RealmLeaderLabel", L"Realm Leader (RL)")
    -- Context menu option for marking RL from right-click menu
    LabelSetText(Megaphone.Windows.Main.."ContextMarkRLLabel", L"Context Menu: Set as RL")
    ButtonSetPressedFlag(Megaphone.Windows.Main.."ContextMarkRLCheckbox", Megaphone.Settings.AddContextMarkRL)
    -- Initialize the RL edit box with current session value (or empty)
    if realmLeaderName_wstr and realmLeaderName_wstr ~= L"" then
        TextEditBoxSetText(Megaphone.Windows.Main.."RealmLeaderEditBox", realmLeaderName_wstr)
    else
        TextEditBoxSetText(Megaphone.Windows.Main.."RealmLeaderEditBox", L"")
    end
    LabelSetText(Megaphone.Windows.Main.."MaxLengthLabel", L"Max Length (0=no limit)")
    Megaphone.RefreshHighlightControls()
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.RefreshHighlightControls()
    local base = Megaphone.Windows.Main
    local leaderCheckbox = base.."HighlightLeaderCheckbox"
    local rlCheckbox = base.."HighlightRealmLeaderCheckbox"
    if not DoesWindowExist(leaderCheckbox) or not DoesWindowExist(rlCheckbox) then
        return
    end
    ButtonSetPressedFlag(leaderCheckbox, highlightLeader)
    ButtonSetPressedFlag(rlCheckbox, highlightRealmLeader)
    local hasRL = hasRealmLeader()
    ButtonSetDisabledFlag(rlCheckbox, false)
    ButtonSetDisabledFlag(leaderCheckbox, highlightRealmLeader and hasRL)
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.OptionsInitSounds()
    LabelSetText(Megaphone.Windows.Main.."SFXTitleLabel", L"Alert Sound")
    LabelSetText(Megaphone.Windows.Main.."RLSFXTitleLabel", L"RL Alert Sound")
    for _, snd in ipairs(Megaphone.SoundTypes) do
        ComboBoxAddMenuItem(Megaphone.Windows.Main.."SFXComboBox", towstring(snd.name))
        ComboBoxAddMenuItem(Megaphone.Windows.Main.."RLSFXComboBox", towstring(snd.name))
    end
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.OptionsInitFonts()
    LabelSetText(Megaphone.Windows.Main.."FontTitleLabel", L"Alert Text Style")
    for _, fnt in ipairs(Megaphone.AlertText) do
        ComboBoxAddMenuItem(Megaphone.Windows.Main.."FontComboBox", towstring(fnt.name))
    end
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.ShowConfig()
    local sfxIndex =
        Megaphone.IndexFromId(
            Megaphone.SoundTypes,
            Megaphone.Settings.Sound
        )
    ComboBoxSetSelectedMenuItem(
        Megaphone.Windows.Main.."SFXComboBox",
        sfxIndex
    )
    local fontIndex =
        Megaphone.IndexFromId(
            Megaphone.AlertText,
            Megaphone.Settings.Font
        )
    ComboBoxSetSelectedMenuItem(
        Megaphone.Windows.Main.."FontComboBox",
        fontIndex
    )
    TextEditBoxSetText(
        Megaphone.Windows.Main.."MaxLengthEditBox",
        towstring(tostring(Megaphone.Settings.MaxMsgLength))
    )
    -- RL Sound selection (default to the same as general when unset)
    local rlsfxIndex
    if Megaphone.Settings.RLSound == nil then
        rlsfxIndex = sfxIndex
    else
        rlsfxIndex = Megaphone.IndexFromId(
            Megaphone.SoundTypes,
            Megaphone.Settings.RLSound
        )
    end
    ComboBoxSetSelectedMenuItem(
        Megaphone.Windows.Main.."RLSFXComboBox",
        rlsfxIndex
    )
    -- Sync the RealmLeader edit field when opening config
    if realmLeaderName_wstr and realmLeaderName_wstr ~= L"" then
        TextEditBoxSetText(Megaphone.Windows.Main.."RealmLeaderEditBox", realmLeaderName_wstr)
    else
        TextEditBoxSetText(Megaphone.Windows.Main.."RealmLeaderEditBox", L"")
    end
    -- Sync context menu checkbox to current setting on open
    ButtonSetPressedFlag(Megaphone.Windows.Main.."ContextMarkRLCheckbox", Megaphone.Settings.AddContextMarkRL)
    Megaphone.RefreshHighlightControls()
    WindowSetShowing(Megaphone.Windows.Main, true)
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.HighlightLeaderToggle()
    if ButtonGetDisabledFlag(Megaphone.Windows.Main.."HighlightLeaderCheckbox") then
        return
    end
    highlightLeader = not highlightLeader
    if highlightLeader and highlightRealmLeader then
        highlightRealmLeader = false
        ButtonSetPressedFlag(Megaphone.Windows.Main.."HighlightRealmLeaderCheckbox", highlightRealmLeader)
    end
    ButtonSetPressedFlag(Megaphone.Windows.Main.."HighlightLeaderCheckbox", highlightLeader)
    Megaphone.RefreshHighlightControls()
    Megaphone.SaveSettings()
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.HighlightRealmLeaderToggle()
    if ButtonGetDisabledFlag(Megaphone.Windows.Main.."HighlightRealmLeaderCheckbox") then
        return
    end
    highlightRealmLeader = not highlightRealmLeader
    if highlightRealmLeader and highlightLeader then
        highlightLeader = false
        ButtonSetPressedFlag(Megaphone.Windows.Main.."HighlightLeaderCheckbox", highlightLeader)
    end
    ButtonSetPressedFlag(Megaphone.Windows.Main.."HighlightRealmLeaderCheckbox", highlightRealmLeader)
    Megaphone.RefreshHighlightControls()
    Megaphone.SaveSettings()
end
----------------------------------------------------------------
function Megaphone.OnPlayerTargetUpdated(targetClassification, _targetId, targetType)
    if not highlightRealmLeader then
        return
    end
    if not hasRealmLeader() then
        return
    end
    if type(TargetInfo) ~= "table" then
        return
    end
    if type(TargetInfo.UpdateFromClient) == "function" then
        TargetInfo:UpdateFromClient()
    end
    local captured = false
    if type(targetClassification) == "string" then
        local isAlly = false
        if SystemData and SystemData.TargetObjectType and targetType then
            isAlly = (targetType == SystemData.TargetObjectType.ALLY_PLAYER)
        end
        if isAlly or targetClassification == "selffriendlytarget" or targetClassification == "mouseovertarget" then
            captured = captureRealmLeaderFromUnit(targetClassification)
        end
    end
    if not captured then
        captured = captureRealmLeaderFromTargets(false)
    end
    if captured then
        updateTargetEventRegistration()
    end
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.ShowLeaderToggle()
    showLeaderName = not showLeaderName
    ButtonSetPressedFlag(Megaphone.Windows.Main.."ShowLeaderCheckbox", showLeaderName)
    Megaphone.SaveSettings()
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.OnContextUnmarkRealmLeader()
    if ButtonGetDisabledFlag(SystemData.ActiveWindow.name) == true then
        return
    end
    local name = nil
    if PlayerMenuWindow and PlayerMenuWindow.curPlayer then
        name = PlayerMenuWindow.curPlayer.name
    end
    if not name or name == L"" then
        return
    end
    local isSame = false
    if realmLeaderName_wstr and realmLeaderName_wstr ~= L"" then
        local curName_w = Megaphone.CleanPlayerName(name)
        if curName_w and curName_w ~= L"" then
            local currentLower = toLowerString(curName_w)
            local realmLower = getRealmLeaderLower()
            if realmLower and currentLower == realmLower then
                isSame = true
            end
        end
    end
    if isSame then
        Megaphone.ClearRealmLeader()
    else
        -- Fallback: if mismatch, treat as mark action
        local worldObj = nil
        if PlayerMenuWindow and PlayerMenuWindow.curPlayer then
            worldObj = PlayerMenuWindow.curPlayer.worldObjNum
        end
        Megaphone.SetRealmLeader(name, nil, worldObj)
    end
    if PlayerMenuWindow and PlayerMenuWindow.Done then
        PlayerMenuWindow.Done()
    end
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.ContextMarkRLToggle()
    local cur = ButtonGetPressedFlag(Megaphone.Windows.Main.."ContextMarkRLCheckbox")
    ButtonSetPressedFlag(Megaphone.Windows.Main.."ContextMarkRLCheckbox", not cur)
    Megaphone.SaveSettings()
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.TestAlert()
    Megaphone.SaveSettings()
    Megaphone.ShowNotification(
        L"Sigmar",
        L"It is on the anvil of pain that the gods forge heroes, and sometimes those heroes talk for a very, very, very, very, very, very, very long time indeed, so long that their words might need to be cut off to fit on the screen properly."
    )
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.TestRLAlert()
    Megaphone.SaveSettings()
    local baseName = nil
    -- Prefer the current content of the edit box (even if not committed yet)
    local box = Megaphone.Windows.Main.."RealmLeaderEditBox"
    local typed_w = TextEditBoxGetText(box)
    if typed_w and typed_w ~= L"" then
        local cleaned_w = Megaphone.CleanPlayerName(typed_w)
        if cleaned_w and cleaned_w ~= L"" then
            local s_std = WStringToString(cleaned_w)
            if string.len(s_std) > 0 then
                local first = string.sub(s_std, 1, 1)
                local rest = string.sub(s_std, 2)
                s_std = string.upper(first) .. rest
            end
            baseName = towstring(s_std)
        end
    end
    if not baseName or baseName == L"" then
        baseName = realmLeaderName_wstr
    end
    if not baseName or baseName == L"" then
        baseName = L"Sigmar"
    end
    local displayLeader = baseName
    if IsWarBandActive() then
        displayLeader = displayLeader .. L" (RL)"
    end
    local testMsg = L"It is on the anvil of pain that the gods forge heroes, and sometimes those heroes talk for a very, very, very, very, very, very, very long time indeed, so long that their words might need to be cut off to fit on the screen properly."
    local override = Megaphone.Settings and Megaphone.Settings.RLSound or nil
    Megaphone.ShowNotification(displayLeader, testMsg, override)
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.SlashHandler(args)
    -- Handles:
    --   /mppp                      -> show config
    --   /mppp help                 -> show command help
    --   /mppp truncate <n|off>     -> set/show truncation limit (0/off = no limit)
    --   /mppp maxlen <n|off>       -> alias for truncate
    --   /mppp rl <name>            -> set realm leader for this session
    --   /mppp rloff                -> clear realm leader
    --   /mppp setrl on|off|toggle  -> enable/disable context menu item
    local s = ""
    if args ~= nil then
        s = tostring(args)
    end
    -- trim
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    local lower = string.lower(s)
    if lower == "help" or lower == "?" or lower == "h" then
        Megaphone.PrintHelp()
        return
    end
    -- Truncate/maxlen commands
    if lower == "truncate" or lower == "maxlen" or lower == "maxlength" then
        Megaphone.TruncateStatus()
        return
    end
    if string.sub(lower, 1, 9) == "truncate " then
        local val = string.sub(s, 10)
        Megaphone.SetTruncate(val)
        return
    end
    if string.sub(lower, 1, 7) == "maxlen " then
        local val = string.sub(s, 8)
        Megaphone.SetTruncate(val)
        return
    end
    if string.sub(lower, 1, 10) == "maxlength " then
        local val = string.sub(s, 11)
        Megaphone.SetTruncate(val)
        return
    end
    if lower == "" then
        Megaphone.ShowConfig()
        return
    end
    if lower == "rloff" or lower == "rl off" or lower == "realmleader off" then
        Megaphone.ClearRealmLeader()
        return
    end
    -- Toggle context menu item for marking RL
    if lower == "setrl" then
        local state = (Megaphone.Settings.AddContextMarkRL and "ON" or "OFF")
        printMsg("Context menu 'Set as RL' is " .. state)
        return
    end
    if string.sub(lower, 1, 6) == "setrl " then
        local val = string.sub(lower, 7)
        if val == "on" or val == "1" or val == "true" or val == "yes" then
            Megaphone.Settings.AddContextMarkRL = true
        elseif val == "off" or val == "0" or val == "false" or val == "no" then
            Megaphone.Settings.AddContextMarkRL = false
        elseif val == "toggle" or val == "tog" then
            Megaphone.Settings.AddContextMarkRL = not Megaphone.Settings.AddContextMarkRL
        else
            printMsg("Usage: /mppp setrl on|off|toggle")
            return
        end
        ButtonSetPressedFlag(Megaphone.Windows.Main.."ContextMarkRLCheckbox", Megaphone.Settings.AddContextMarkRL)
        local state = (Megaphone.Settings.AddContextMarkRL and "ON" or "OFF")
        printMsg("Context menu 'Set as RL' is " .. state)
        return
    end
    if string.sub(lower, 1, 3) == "rl " then
        local name = string.sub(s, 4)
        name = string.gsub(name, "^%s+", "")
        name = string.gsub(name, "%s+$", "")
        if name == "" then
            Megaphone.ShowRealmLeaderStatus()
        else
            Megaphone.SetRealmLeader(name)
        end
        return
    end
    if lower == "rl" then
        Megaphone.ShowRealmLeaderStatus()
        return
    end
    if string.sub(lower, 1, 12) == "realmleader " then
        local name = string.sub(s, 13)
        Megaphone.SetRealmLeader(name)
        return
    end
    -- Fallback: show config for unknown args
    Megaphone.ShowConfig()
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.PrintHelp()
    -- Pretty, link-styled help output using wstring LINK markup
    local function prefix_w()
        return L"<LINK data=\"0\" text=\"[Megaphone++]\" color=\"255,255,50\">"
    end
    local function print_line_w(w)
        EA_ChatWindow.Print(prefix_w() .. L" " .. w)
    end
    local function link_w(text_s, color_s)
        local c = color_s or "150,200,255"
        return L"<LINK data=\"\" text=\"" .. towstring(text_s) .. L"\" color=\"" .. towstring(c) .. L"\">"
    end

    print_line_w(L"<LINK data=\"\" text=\"--- [Megaphone++] Help ---\" color=\"150,200,255\">")
    local function helpLine(cmd_s, desc_s)
        local line = link_w(cmd_s, "150,200,255") .. L" - " .. towstring(desc_s)
        print_line_w(line)
    end
    helpLine("/mppp or /megaphonepp", "Open settings window")
    helpLine("/mppp help",              "Show this help")
    helpLine("/mppp truncate n|off",    "Set/show truncation (0/off=no limit)")
    helpLine("/mppp maxlen n|off",      "Alias for truncate")
    helpLine("/mppp rl name",           "Set Realm Leader (session)")
    helpLine("/mppp rl",                 "Show current Realm Leader")
    helpLine("/mppp rloff",              "Clear Realm Leader (session)")
    helpLine("/mppp setrl on|off|toggle", "Add 'Set as RL' to right-click menu")
    print_line_w(L"<LINK data=\"\" text=\"--- End of Help ---\" color=\"150,200,255\">")
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.TruncateStatus()
    local cur = Megaphone.Settings and Megaphone.Settings.MaxMsgLength or 0
    if not cur or cur == 0 then
        printMsg("Truncation is OFF (no limit)")
    else
        printMsg("Truncation limit is " .. tostring(cur) .. " characters")
    end
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.SetTruncate(val_str)
    if not val_str then
        Megaphone.TruncateStatus()
        return
    end
    -- trim
    local s = tostring(val_str)
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    local l = string.lower(s)
    local newMax
    if l == "off" or l == "none" or l == "no" or l == "0" then
        newMax = 0
    else
        local n = tonumber(s)
        if n == nil then
            printMsg("Usage: /mppp truncate <n|off>")
            return
        end
        if n < 0 then n = 0 end
        newMax = n
    end
    Megaphone.Settings = Megaphone.Settings or {}
    Megaphone.Settings.MaxMsgLength = newMax
    -- Reflect in the UI edit box
    local text = towstring(tostring(newMax))
    TextEditBoxSetText(Megaphone.Windows.Main.."MaxLengthEditBox", text)
    if newMax == 0 then
        printMsg("Truncation disabled (no limit)")
    else
        printMsg("Truncation set to " .. tostring(newMax) .. " characters")
    end
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.SetRealmLeader(name_str, quiet, objectId)
    if not name_str then
        printMsg("Usage: /mppp rl <playername>")
        return
    end
    local cleaned = Megaphone.CleanPlayerName(name_str)
    if cleaned == L"" then
        printMsg("Usage: /mppp rl <playername>")
        return
    end
    -- Capitalize first letter; leave the rest unchanged
    local s_std = WStringToString(cleaned)
    if string.len(s_std) > 0 then
        local first = string.sub(s_std, 1, 1)
        local rest = string.sub(s_std, 2)
        s_std = string.upper(first) .. rest
    end
    local new_w = towstring(s_std)
    local rlChatText = Megaphone.PlayerLinkText(s_std)
    if rlChatText == "" then
        rlChatText = s_std
    end
    if realmLeaderName_wstr and realmLeaderName_wstr == new_w then
        -- No change; optionally suppress feedback when called from GUI
        if not quiet then
            printMsg("RealmLeader is already set to " .. rlChatText)
        end
        return
    end
    local hadPreviousRL = realmLeaderName_wstr and realmLeaderName_wstr ~= L""
    if highlightRealmLeader and hadPreviousRL then
        local previousRealmObjectId = getRealmLeaderObjectId()
        Megaphone.HideMarker(previousRealmObjectId)
    end
    realmLeaderName_wstr = new_w
    setRealmLeaderLowerCache(s_std)
    setRealmLeaderObjectId(objectId)
    printMsg("RealmLeader set to " .. rlChatText)
    Megaphone.UpdateRealmLeaderEditBox()
    Megaphone.RefreshHighlightControls()
    local captured = false
    if not objectId or objectId == 0 then
        captured = captureRealmLeaderFromTargets(true)
    end
    if (not captured) and (highlightRealmLeader or highlightLeader) then
        Megaphone.AttachMarkerToPlayer()
    end
    updateTargetEventRegistration()
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.ClearRealmLeader()
    if not realmLeaderName_wstr or realmLeaderName_wstr == L"" then
        return
    end
    realmLeaderName_wstr = nil
    setRealmLeaderLowerCache(nil)
    setRealmLeaderObjectId(nil)
    printMsg("RealmLeader cleared.")
    Megaphone.UpdateRealmLeaderEditBox()
    Megaphone.RefreshHighlightControls()
    if highlightRealmLeader or highlightLeader then
        Megaphone.AttachMarkerToPlayer()
    else
        Megaphone.HideMarker()
    end
    updateTargetEventRegistration()
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.ShowRealmLeaderStatus()
    if realmLeaderName_wstr and realmLeaderName_wstr ~= L"" then
        local rlChatText = Megaphone.PlayerLinkText(realmLeaderName_wstr)
        if rlChatText == "" then
            rlChatText = WStringToString(realmLeaderName_wstr)
        end
        printMsg("RealmLeader is " .. rlChatText)
    else
        printMsg("RealmLeader is not set")
    end
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.RealmLeaderEditCommit()
    -- Read text, trim, and set/clear RL accordingly (session only)
    local box = Megaphone.Windows.Main.."RealmLeaderEditBox"
    local txt_w = TextEditBoxGetText(box)
    local s = WStringToString(txt_w)
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    if s == "" then
        Megaphone.ClearRealmLeader()
        return
    end
    -- Suppress "already set" feedback when committing from GUI
    Megaphone.SetRealmLeader(s, true)
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.UpdateRealmLeaderEditBox()
    local value = realmLeaderName_wstr or L""
    TextEditBoxSetText(Megaphone.Windows.Main.."RealmLeaderEditBox", value)
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.CloseAndSave()
    -- Commit RL edit value before hiding
    Megaphone.RealmLeaderEditCommit()
    Megaphone.HideWindow()
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.HideWindow()
    WindowSetShowing(Megaphone.Windows.Main, false)
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.SaveSettings()
    Megaphone.Settings.Font = Megaphone.AlertText[ComboBoxGetSelectedMenuItem(Megaphone.Windows.Main.."FontComboBox")].id
    Megaphone.Settings.Sound = Megaphone.SoundTypes[ComboBoxGetSelectedMenuItem(Megaphone.Windows.Main.."SFXComboBox")].id
    Megaphone.Settings.RLSound = Megaphone.SoundTypes[ComboBoxGetSelectedMenuItem(Megaphone.Windows.Main.."RLSFXComboBox")].id
    local leaderCheckbox = Megaphone.Windows.Main.."HighlightLeaderCheckbox"
    local rlCheckbox = Megaphone.Windows.Main.."HighlightRealmLeaderCheckbox"
    Megaphone.Settings.ShowName = ButtonGetPressedFlag(Megaphone.Windows.Main.."ShowLeaderCheckbox")
    local highlightLeaderState = ButtonGetPressedFlag(leaderCheckbox)
    local highlightRLState = ButtonGetPressedFlag(rlCheckbox)
    if highlightRLState and highlightLeaderState then
        highlightLeaderState = false
        ButtonSetPressedFlag(leaderCheckbox, false)
    end
    Megaphone.Settings.Highlight = highlightLeaderState
    Megaphone.Settings.HighlightRealmLeader = highlightRLState
    Megaphone.Settings.AddContextMarkRL = ButtonGetPressedFlag(Megaphone.Windows.Main.."ContextMarkRLCheckbox")
    local maxLengthText = TextEditBoxGetText(Megaphone.Windows.Main.."MaxLengthEditBox")
    local newMaxLength = tonumber(WStringToString(maxLengthText)) -- Convert wstring to string, then to number
    if newMaxLength == nil or newMaxLength < 0 then
        newMaxLength = 0 -- Default to 0 (no limit) if input is invalid or negative
    end
    Megaphone.Settings.MaxMsgLength = newMaxLength
    highlightLeader = Megaphone.Settings.Highlight
    highlightRealmLeader = Megaphone.Settings.HighlightRealmLeader
    Megaphone.RefreshHighlightControls()
    -- Update to refresh marker if applicable
    if highlightRealmLeader and getRealmLeaderObjectId() == nil then
        captureRealmLeaderFromTargets(true)
    end
    Megaphone.Refresh()
    updateTargetEventRegistration()
    if highlightRealmLeader or highlightLeader then
        Megaphone.AttachMarkerToPlayer()
    else
        Megaphone.HideMarker()
    end
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.GroupUpdate()
    -- Despite the name, leaving a group using a slash command only triggers
    -- the group UPDATE event, so we need to double check the status here
    if not IsWarBandActive() then
        Megaphone.Reset()
        if highlightRealmLeader and hasRealmLeader() then
            captureRealmLeaderFromTargets(true)
            Megaphone.AttachMarkerToPlayer()
        elseif highlightLeader then
            Megaphone.AttachMarkerToPlayer()
        end
        return
    end
    Megaphone.AssignLeader()
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.IndexFromId(list, id)
    -- Given an ID, find the index of that item in a list
    for k, item in ipairs(list) do
        if (item.id == id) then
            return k
        end
    end
    return 0
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.AssignLeader()
    local leader = Megaphone.FindLeader()
    if leader ~= nil then
        -- A leader was successfully found.
        local newLeaderName = Megaphone.CleanPlayerName(leader.name)
        local newLeaderId = leader.worldObjNum
        -- Detach marker if it differs from our stored leader
        if leaderId ~= newLeaderId then
            Megaphone.HideMarker()
        end
        -- Assign new leader information for chat filtering and marker attachment
        chatNameFilter = newLeaderName
        leaderId = newLeaderId
        -- Attach or hide the marker based on current availability and settings.
        if leaderId and (highlightLeader or highlightRealmLeader) then
            Megaphone.AttachMarkerToPlayer()
        else
            Megaphone.HideMarker()
        end
        -- Announce only if the leader identity has changed since the last announcement.
        local hasLeaderName = newLeaderName and newLeaderName ~= L""
        if hasLeaderName then
            local leaderKey = toLowerString(newLeaderName)
            if leaderKey == "" then
                leaderKey = nil -- Do not treat "no key" as a new leader
            end
            if leaderKey == nil then
                return
            end
            local keyChanged = leaderKey ~= lastAnnouncedLeaderKey
            if keyChanged then
                local leaderChatText = Megaphone.PlayerLinkText(newLeaderName)
                if leaderChatText == "" then
                    leaderChatText = WStringToString(newLeaderName)
                end
                printMsg("Found leader - " .. leaderChatText)
                lastAnnouncedLeaderKey = leaderKey
            end
        end
    else
        Megaphone.HideMarker()
        leaderId = nil
        chatNameFilter = ""
    end
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.FindLeader()
    -- If in a warband, use the API-provided leader name, then map to the
    -- corresponding player entry so we can get worldObjNum for marking.
    if IsWarBandActive() then
        local leaderInfo = PartyUtils.GetWarbandLeader()
        local desiredLeaderName = nil
        if leaderInfo and leaderInfo.name then
            local candidate = Megaphone.CleanPlayerName(leaderInfo.name)
            if candidate ~= L"" and candidate ~= selfName then
                desiredLeaderName = candidate
            end
        end

        local wb = PartyUtils.GetWarbandData()
        if desiredLeaderName then
            for _, grp in ipairs(wb) do
                for _, player in ipairs(grp.players) do
                    if Megaphone.CleanPlayerName(player.name) == desiredLeaderName then
                        return player
                    end
                end
            end
            -- Could not map the name to a player entry; avoid incorrect fallbacks
            return nil
        else
            -- Legacy fallback when leader API is unavailable: first subgroup leader
            for _, grp in ipairs(wb) do
                for _, player in ipairs(grp.players) do
                    if player.isGroupLeader then
                        return player
                    end
                end
            end
            return nil
        end
    end
    return nil
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.FilterChat()
    if not WB_CHANNELS or not RL_CHANNELS then
        Megaphone.EnsureChannelSets()
    end
    local chatData = GameData.ChatData
    local chatType = chatData.type
    local isWBType = WB_CHANNELS and WB_CHANNELS[chatType]
    local isRLType = RL_CHANNELS and RL_CHANNELS[chatType]
    if not isWBType and not isRLType then
        return
    end

    local wantsRealmLeader = isRLType and realmLeaderName_wstr and realmLeaderName_wstr ~= L""
    local wantsWarbandLeader = isWBType and chatNameFilter and chatNameFilter ~= "" and chatNameFilter ~= L"" and chatNameFilter ~= selfName
    if not wantsRealmLeader and not wantsWarbandLeader then
        return
    end

    local chatText = chatData.text
    local chatSender = Megaphone.CleanPlayerName(chatData.name)
    -- RealmLeader: mirror realm/channel announcements from the designated player
    if wantsRealmLeader and chatSender == realmLeaderName_wstr then
        local messageInfo = Megaphone.BuildMessageInfo(chatText, messageInfoScratch)
        if Megaphone.RLMessageShouldIgnore(chatText, messageInfo.normalized_std, messageInfo.normalized_std_lower) then return end
        if chatData.objectId and chatData.objectId ~= 0 then
            setRealmLeaderObjectId(chatData.objectId)
        end
        -- Always echo realm leader alerts, even if the warband leader matches, so
        -- their /1 and /2 calls still surface alongside warband chat.
        local displayLeader = realmLeaderName_wstr
        if IsWarBandActive() then
            displayLeader = displayLeader .. L" (RL)"
        end
        local override = Megaphone.Settings and Megaphone.Settings.RLSound or nil
        Megaphone.ShowNotification(displayLeader, chatText, override, messageInfo)
        if highlightRealmLeader then
            Megaphone.AttachMarkerToPlayer()
        end
        return
    end
    -- Warband leader: include only group-type chats and avoid echoing self
    if wantsWarbandLeader and chatSender == chatNameFilter then
        local messageInfo = Megaphone.BuildMessageInfo(chatText, messageInfoScratch)
        Megaphone.ShowNotification(chatSender, chatText, nil, messageInfo)
    end
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.ShowNotification(leaderName_wstr, originalMessage_wstr, overrideSoundId, messageInfo)
    -- Ensure originalMessage_wstr is not nil before processing
    if not originalMessage_wstr then
        return
    end
    local info = messageInfo
    if not info then
        info = Megaphone.BuildMessageInfo(originalMessage_wstr)
    end
    -- Filter out messages with known ignored prefixes
    if Megaphone.MessageHasIgnoredPrefix(originalMessage_wstr, info.normalized_std, info.normalized_std_lower) then
        return
    end
    if Megaphone.MessageHasIgnoredSubstring(originalMessage_wstr, info.normalized_std, info.normalized_std_lower) then
        return
    end
    local processed_message_std_str = info.display_std or ""
    if not info.display_is_safe then
        processed_message_std_str = sanitizeToCp1252(processed_message_std_str)
    end
    -- Early exit for truly empty string
    if processed_message_std_str == "" then
        return
    end
    -- Truncate message if MaxMsgLength is set and message is too long
    if Megaphone.Settings.MaxMsgLength and Megaphone.Settings.MaxMsgLength > 0 then
        if string.len(processed_message_std_str) > Megaphone.Settings.MaxMsgLength then
            processed_message_std_str = string.sub(
                processed_message_std_str,
                1,
                Megaphone.Settings.MaxMsgLength
            ) .. "..."
        end
    end
    -- Guard against messages that normalize down to pure whitespace
    if not string.match(processed_message_std_str, "%S") then
        return
    end
    if shouldSuppressRepeatedMessage(processed_message_std_str, leaderName_wstr) then
        return
    end
    -- Play sound if configured
    local sid = overrideSoundId
    if sid == nil then
        sid = Megaphone.Settings.Sound
    end
    if sid ~= nil then
        PlaySound(sid)
    end
    -- Return if font is not set (no alert will be shown)
    if (Megaphone.Settings.Font == nil) then
        return
    end
    local final_display_text_wstr
    if Megaphone.Settings.ShowName then
        local leaderName_std_str = toSafeNarrowString(leaderName_wstr)
        local combined_std_str = leaderName_std_str .. ": " .. processed_message_std_str
        final_display_text_wstr = towstring(combined_std_str)
    else
        final_display_text_wstr = towstring(processed_message_std_str)
    end
    AlertTextWindow.AddLine(Megaphone.Settings.Font, final_display_text_wstr)
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.CleanPlayerName(playerName_input)
    -- Normalize to wstring and strip server/channel markers from names.
    if not playerName_input then
        return L""
    end
    local work_wstring
    if type(playerName_input) == "wstring" then
        work_wstring = playerName_input
    else
        work_wstring = towstring(playerName_input)
    end
    if type(work_wstring) ~= "wstring" then
        -- Ensure we always operate on a wstring; fall back to string manipulation then reconvert.
        local work_string = tostring(work_wstring or "")
        work_string = string.gsub(work_string, "%^%a,in", "")
        work_string = string.gsub(work_string, "%^%a", "")
        return towstring(work_string)
    end
    work_wstring = toWideString(wstring.gsub(work_wstring, L"%^%a,in", L""))
    work_wstring = toWideString(wstring.gsub(work_wstring, L"%^%a", L""))
    return work_wstring
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.AttachMarkerToPlayer()
    if not highlightRealmLeader and not highlightLeader then
        Megaphone.HideMarker()
        return
    end
    local targetId = resolveMarkerTargetId()
    if not targetId then
        Megaphone.HideMarker()
        return
    end
    local previousTargetId = markerTargetId
    local switchingTarget = previousTargetId and previousTargetId ~= targetId
    if (not switchingTarget) and previousTargetId == targetId then
        if markerSoftHidden then
            WindowSetShowing(Megaphone.Windows.Marker, false)
        else
            cacheMarkerScaleIfNeeded()
            restoreMarkerScale()
            WindowSetShowing(Megaphone.Windows.Marker, true)
            markerSoftHidden = false
            markerInactiveSince = nil
            markerSoftHideStartUpdate = nil
        end
        return
    end
    if switchingTarget then
        DetachWindowFromWorldObject(Megaphone.Windows.Marker, previousTargetId)
        resetMarkerMovementTracking()
    end
    markerTargetId = targetId
    AttachWindowToWorldObject(Megaphone.Windows.Marker, markerTargetId)
    if markerSoftHidden and not switchingTarget then
        WindowSetShowing(Megaphone.Windows.Marker, false)
    else
        cacheMarkerScaleIfNeeded()
        restoreMarkerScale()
        WindowSetShowing(Megaphone.Windows.Marker, true)
        markerSoftHidden = false
        markerInactiveSince = nil
        markerSoftHideStartUpdate = nil
    end
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.HideMarker(fallbackTargetId)
    cacheMarkerScaleIfNeeded()
    restoreMarkerScale()
    resetMarkerMovementTracking()
    WindowSetShowing(Megaphone.Windows.Marker, false)
    -- There is a case where the Window manager kept showing an attached window. Stop that
    if markerTargetId ~= nil then
        DetachWindowFromWorldObject(Megaphone.Windows.Marker, markerTargetId)
        markerTargetId = nil
        return
    end
    if fallbackTargetId ~= nil and fallbackTargetId ~= 0 then
        DetachWindowFromWorldObject(Megaphone.Windows.Marker, fallbackTargetId)
        markerTargetId = nil
        return
    end
    if leaderId ~= nil then
        DetachWindowFromWorldObject(Megaphone.Windows.Marker, leaderId)
    end
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.Reset()
    Megaphone.HideMarker()
    leaderId = nil
    markerTargetId = nil
    chatNameFilter = ""
    nextRealmLeaderRecheckAt = nil
    realmLeaderNeedsForceUpdate = true
end
----------------------------------------------------------------
----------------------------------------------------------------
function Megaphone.Refresh()
    Megaphone.Reset()
    Megaphone.RequestUpdate()
end
----------------------------------------------------------------
