# Megaphone++

Megaphone++ is a Return of Reckoning addon that puts important leader messages in the on-screen alert area so you do not have to keep scanning chat during a warband.

It watches the current warband leader and shows their group, warband, and scenario-group messages as alerts. You can also set a temporary Realm Leader for the current session, and Megaphone++ will show that player's general, region, zone, or channel 1/2 calls separately.

## Installation

Unzip the addon so the `MegaphonePlusPlus` folder is in your addon directory:

```text
<RoR Install Dir>/Interface/AddOns/
```

Then enable it from the in-game mods menu.

## What It Does

- Shows warband leader messages in the alert area.
- Optionally plays a sound for those alerts.
- Optionally includes the leader name before the message.
- Can shorten long messages so they do not fill the middle of the screen.
- Can place a marker over the warband leader.
- Can set a session-only Realm Leader and show their general, region, zone, or channel 1/2 calls as alerts.
- Can use a separate sound for Realm Leader alerts.
- Can place a marker over the Realm Leader when the game client can identify their character.

## Configuration

Open the settings window with:

```text
/mppp
```

or:

```text
/megaphonepp
```

From the settings window you can choose the alert sound, alert text style, maximum message length, leader-name display, leader marker, Realm Leader marker, and Realm Leader sound.

![Configuration window](docs/mppp-config.jpg?raw=true "Configuration window")

The Realm Leader name is not saved. It is only kept for the current session.

### Alert

Choose the alert sound and text style from the settings window. Use the test button to check the current combination, and enable leader-name display if you want each alert to show who sent it.

The maximum message length setting can shorten long calls before they fill the middle of the screen.

![Alert example](docs/mppp-alert.jpg?raw=true "Alert example")

### Highlight Leader

Megaphone++ can place a marker over the warband leader so they are easier to find in a crowd. This is useful for calls like `follow me`, or when you suddenly need to find the person leading the group.

![Highlight leader example](docs/mppp-highlight.jpg?raw=true "Highlight leader example")

### Realm Leader

Realm Leader support is session-only. Set a player as Realm Leader when you want their broader calls to stand out separately from normal warband leader alerts.

When leader-name display is enabled, Realm Leader alerts are labeled as `(RL)` while you are in a warband, for example:

```text
Sigmar (RL): push north
```

## Slash Commands

- `/mppp` opens the settings window.
- `/megaphonepp` opens the settings window.
- `/mppp help` shows the command list.
- `/mppp truncate <number|off>` sets the maximum alert length.
- `/mppp maxlen <number|off>` is another name for the truncate command.
- `/mppp rl <name>` sets the Realm Leader for this session.
- `/mppp rl` shows the current Realm Leader.
- `/mppp rloff` clears the current Realm Leader.
- `/mppp setrl on|off|toggle` controls whether the right-click player menu includes `Set as Realm Leader`.

## Known Issues and Notes

- The leader marker depends on the game client reporting a valid world object. If the client stops reporting a usable position, Megaphone++ hides or detaches the marker instead of leaving it in the wrong place.
- Realm Leader highlighting can also use your current friendly target or mouseover target to identify the player.
- Some automated recruitment messages are ignored so Realm Leader alerts stay focused on actual calls.
- The game alert area keeps a limited number of recent lines. If repeated test messages stop appearing, wait a few seconds and try again.
- Maintained public source: https://github.com/jmaartenson/MegaphonePlusPlus.
- Original GitHub source: https://github.com/timneill/megaphoneplusplus/. That repository's latest commit is from 2020-07-07, so this version is maintained separately.

## Changelog

### 1.1.5 - 2026-05-15

- Added session-only Realm Leader alerts for general, region, zone, and channel 1/2 calls.
- Added `/mppp rl`, `/mppp rloff`, `/mppp setrl`, and `/mppp help`.
- Added a Realm Leader field, Realm Leader marker option, right-click `Set as Realm Leader`, and separate Realm Leader alert sound.
- Changed Realm Leader alerts to show the leader name as `(RL)` while you are in a warband and leader-name display is enabled.
- Improved leader markers so stale or stuck positions hide or detach instead of drifting.
- Improved chat cleanup, ignored-message handling, and short repeat suppression.
- Improved warband leader detection and reduced repeated `Found leader` messages.
- Reduced background work when no matching leader alert or marker update is active.

### 1.1.4 - 2025-05-11

- Added the maximum message length setting.
- Defaulted alerts to 100 characters so very long leader messages do not become a wall of text.
- Added the max-length field to the settings window.

### 1.1.3 - 2025-05-10

- Fixed more cases where heavily formatted leader messages could fail to show.
- Tightened player-name cleanup used when matching the leader.

### 1.1.2 - 2025-04-14

- Improved formatted-message cleanup before alerts are shown.
- Kept visible message text while stripping chat formatting tags.
- Continued from the `1.1.0` line after the `1.1.1` revert, so the self-alert guard remained.
- The `1.1.0` leader-change notification refresh was not present in this package.

### 1.1.1

- Reverted to the earlier `1.0.1` package contents.

### 1.1.0 - 2024-06-22

- Added support for leader messages with colored or styled chat text.
- Ignored your own leader messages so you do not alert yourself.
- Watched leader-change chat notifications to refresh the detected warband leader.

### 1.0.1 - 2020-05-26

- First public Idrinth package.
- Showed warband leader messages as on-screen alerts.
- Added the optional leader marker.
