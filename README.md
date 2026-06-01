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
- Xcode 15.0+

## Build

```bash
git clone https://github.com/likzq30-ship-it/clipflow.git
cd clipflow
xcodebuild -project ClipFlow.xcodeproj -scheme ClipFlow -configuration Release build
```

Or open `ClipFlow.xcodeproj` in Xcode and Cmd+B.

## Usage

ClipFlow lives in the menu bar. Click the icon or press ⌘⇧V to open the panel.

- Click any record to copy it back
- Search bar for full-text search
- Sidebar to filter by category
- Hover to show favorite & delete buttons
- Right-click icon → Settings / Quit

## Privacy

All data stored locally in `~/Library/Application Support/ClipFlow/clipflow.sqlite3`. Nothing uploaded.

## Screenshot

![Menu Bar](screenshots/menu-bar.png)

## License

MIT

## Author

[likzq](https://github.com/likzq30-ship-it)
