# EZQuests

A peer-to-peer quest tracking tool for EverQuest. Monitor task progress across your entire group or raid in real-time from a single screen.

<img align="center" width="882" height="585" alt="EQZQuests main" src="https://github.com/user-attachments/assets/912c58dd-c6ac-4dff-b10b-203e6214118a" />

## Features

- **Real-time Task Sync**: Automatically shares quest data with all peers running EZQuests
- **Peer Overview**: See which quests your group members have and their progress
- **Task Coverage Indicators**: Quickly identify which peers are missing specific tasks (`[OK]` = all have it, `[X]` = some missing)
- **Detailed Task View**: Click any task to see detailed objective progress across all peers
- **Advanced View**: Browse all tasks across all peers in a split-pane interface

<img align="center" width="1028" height="685" alt="EZQuests Advanced View" src="https://github.com/user-attachments/assets/8d095652-c805-4e81-a256-39f6158b3db8" />

## Installation

1. Copy the `EZQuests` folder to your MacroQuest `/lua` directory.  (Be sure to delete the -main off the folder, if downloading from GiTHub)
2. Launch with: `/lua run ezquests`

## Usage

### Basic Commands

| Command | Description |
|---------|-------------|
| `/lua run ezquests` | Launch EZQuests with GUI |
| `/lua run ezquests nohud` | Launch in background mode (for alts) |
| `/ezq show` | Show the UI |
| `/ezq hide` | Hide the UI |
| `/ezq refresh` | Request fresh task data from all peers |
| `/ezq debug` | Toggle debug mode |
| `/ezq exit` | Stop the script |

### Understanding the UI

**Simple View** (default):
- Shows your current tasks
- `[OK]` / `[X]` indicators show peer coverage
- Click indicators to see which peers have each task

**Advanced View**:
- Left pane: All tasks across all peers
- Right pane: Detailed objective progress
- Filter by specific peers

**Peer Task View**:
- Click any peer name to view their specific tasks

## How It Works

EZQuests uses MacroQuest's actor system to communicate between characters:

1. When you launch EZQuests, it automatically broadcasts to all connected peers (via DanNet/EQBC)
2. All running instances share task data via a shared mailbox
3. The primary character displays the GUI; background instances (`nohud` mode) just share data

## Requirements

- MacroQuest
- DanNet or EQBC (for peer discovery))

## Configuration

No configuration required! EZQuests automatically:
- Discovers peers via DanNet or EQBC
- Syncs task data in real-time
- Saves no data to disk (all ephemeral)

## Troubleshooting

**"Number of Peers reporting: 1" but I have peers connected**
- Peers may be running different script cases - check that all used the same case when launching
- Try `/ezq refresh` to re-request data

**Peers not showing up**
- Ensure DanNet or EQBC is loaded and connected
- Check that peers are in the same zone or properly networked

**UI not appearing**
- Run `/ezq show` to toggle visibility
- Check that mq2imgui is loaded

## License

Open source - feel free to modify and share.
