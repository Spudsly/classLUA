# EZChat

Modern chat replacement for MyChat, with one dockable window per channel.

## Run

```text
/lua run EZChat
```

## Core Features

- Independent channel windows with unread counts in titles.
- Tell conversations can spawn per-player windows alongside the aggregate `Tells` view.
- Windows can be shown/hidden and docked next to each other.
- Built-in channels: `All`, `Tells`, `Loot`, `Group`, `Guild`, `Raid`, `Say`, `OOC`, `Auction`, `Combat`, `System`, `Other`.
- Built-in channels include `MQ` for MacroQuest/plugin lines.
- `All` feed category filters (including `MQ`) are configurable.
- Incoming chat display only (no text-entry input bar).
- Font scaling via `ImGui.SetWindowFontScale`.
- Timestamp toggle, auto-scroll toggle, lock-window toggle.
- Configurable max line history per window.
- Compatibility hook for scripts that publish through `MyUI_MyChatHandler`.

## Commands

```text
/ezchat
/ezchat show [all|manager|channel]
/ezchat hide [all|manager|channel]
/ezchat toggle [all|manager|channel]
/ezchat manager [on|off|toggle]
/ezchat help
/ezchat lock [on|off]
/ezchat timestamps [on|off]
/ezchat autoscroll [on|off]
/ezchat scale <0.75-2.25>
/ezchat lines <250-10000>
/ezchat allinclude <channel|external> [on|off|toggle]
/ezchat clear [all|channel]
/ezchat reset
/ezchat exit
```

## Config File

Saved to:

```text
<MQ Config Dir>/EZChat_<Server>_<Character>.lua
```
