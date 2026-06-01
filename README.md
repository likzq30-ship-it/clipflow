# ClipFlow

macOS clipboard history in the menu bar.

**[中文](README_CN.md)** | English

## Features

- Records everything you copy (polls every 0.5s)
- Auto-classifies clips: links, emails, code, numbers, Chinese/English/mixed
- Full-text search with category sidebar
- Pin items to keep them from auto-cleanup
- Auto-cleanup after 1–30 days (configurable)
- Global hotkey ⌘⇧V (customizable)
- All data stored locally in SQLite

## Requirements

- macOS 13.0+
- Xcode 15.0+

## Build

```bash
git clone https://github.com/likzq30-ship-it/clipflow.git
cd clipflow
xcodebuild -project ClipFlow.xcodeproj -scheme ClipFlow -configuration Release build
```

Or open `ClipFlow.xcodeproj` and Cmd+B.

## Usage

- Menu bar icon — click or ⌘⇧V to open
- Click a clip to copy it back
- Search bar for text search
- Sidebar filters by category
- Hover for pin/delete buttons
- Right-click icon for settings

## Privacy

Local SQLite at `~/Library/Application Support/ClipFlow/clipflow.sqlite3`. No network, no uploads.

## Screenshot

![Menu Bar](screenshots/menu-bar.png)

## License

MIT — [likzq](https://github.com/likzq30-ship-it)
