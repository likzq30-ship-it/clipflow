# ClipFlow

A clipboard history tool for macOS. Lives in your menu bar.

**[中文](README_CN.md)** | English

## What it does

Keeps track of everything you copy. Text gets auto-saved every half second.

Classifies clips into categories — links, emails, code, numbers, Chinese, English, mixed, whatever. You can search through them, filter by type, and pin stuff you want to keep.

Pinned items survive auto-cleanup. You set how many days to keep stuff (1–30), the rest gets deleted automatically.

Hit ⌘⇧V (customizable) to pop open the panel. Click anything to copy it back.

Everything stays local in a SQLite file. Nothing leaves your machine.

## Build

Requires macOS 13+ and Xcode 15+.

```bash
git clone https://github.com/likzq30-ship-it/clipflow.git
cd clipflow
xcodebuild -project ClipFlow.xcodeproj -scheme ClipFlow -configuration Release build
```

Or just open the `.xcodeproj` and hit Cmd+B.

## How to use

Icon sits in the menu bar. Click it or use the hotkey.

- Click a clip to copy it
- Type in the search bar to filter
- Sidebar has category filters
- Hover over items for pin/delete buttons
- Right-click the icon for settings or to quit

## Where's my data

`~/Library/Application Support/ClipFlow/clipflow.sqlite3`

That's it. Local only.

## Screenshot

![Menu Bar](screenshots/menu-bar.png)

## License

MIT — [likzq](https://github.com/likzq30-ship-it)
