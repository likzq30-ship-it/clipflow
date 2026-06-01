# ClipFlow

macOS menu bar clipboard history manager.

**[中文](README_CN.md)** | English

## Features

- **Clipboard History** — Auto-record macOS text clipboard, 0.5s polling
- **Smart Classification** — Built-in categories: Link, Email, Code, Number, Chinese, English, Mixed, Other
- **Search & Filter** — Full-text search + category sidebar
- **Favorites** — Pin important records, favorites won't be auto-cleaned
- **Auto Cleanup** — Configurable 1–30 day retention, auto-delete non-favorites
- **Global Hotkey** — Custom hotkey to toggle panel, default ⌘⇧V
- **Privacy First** — Local SQLite storage

## Requirements

- macOS 13.0+
- Xcode 15.0+ (required for build)

## Build

```bash
git clone https://github.com/likzq30-ship-it/clipflow.git
cd clipflow
xcodebuild -project ClipFlow.xcodeproj -scheme ClipFlow -configuration Release build
```

Output is in Xcode DerivedData, or open `ClipFlow.xcodeproj` in Xcode and press Cmd+B.

## Usage

- ClipFlow runs in the menu bar
- Click icon or press ⌘⇧V to open panel
- Click any record to copy back to clipboard
- Search bar supports full-text search
- Left sidebar filters by category
- Hover to show favorite & delete buttons
- Right-click menu bar icon → Settings / Quit

## Privacy

- All clipboard data stored locally in SQLite: `~/Library/Application Support/ClipFlow/clipflow.sqlite3`
- Data stays local, nothing is uploaded

## Screenshots

![Menu Bar](screenshots/menu-bar.png)

## License

MIT License. See [LICENSE](LICENSE).

## Authors

- [likzq](https://github.com/likzq30-ship-it)
