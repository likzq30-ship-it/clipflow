# ClipFlow

macOS menu bar clipboard history manager.

macOS 菜单栏剪贴板历史管理工具。

## Features / 功能特性

- **Clipboard History** — Auto-record macOS text clipboard, 0.5s polling / 自动记录 macOS 文本剪贴板内容，0.5 秒轮询
- **Smart Classification** — Built-in categories: Link, Email, Code, Number, Chinese, English, Mixed, Other / 内置分类：链接、邮件、代码、数字、中文、英文、中英混合、其他
- **Search & Filter** — Full-text search + category sidebar / 全文搜索 + 分类侧边栏
- **Favorites** — Pin important records, favorites won't be auto-cleaned / 标记重要记录，收藏不会被自动清理
- **Auto Cleanup** — Configurable 1–30 day retention, auto-delete non-favorites / 可配置 1~30 天保留期，到期自动删除非收藏记录
- **Global Hotkey** — Custom hotkey to toggle panel, default ⌘⇧V / 自定义快捷键呼出面板，默认 ⌘⇧V
- **Privacy First** — Local SQLite storage / 数据本地 SQLite 存储

## Requirements / 系统要求

- macOS 13.0+
- Xcode 15.0+ (required for build / 构建需要)

## Build / 构建

```bash
git clone https://github.com/likzq30-ship-it/clipflow.git
cd clipflow
xcodebuild -project ClipFlow.xcodeproj -scheme ClipFlow -configuration Release build
```

Output is in Xcode DerivedData, or open `ClipFlow.xcodeproj` in Xcode and press Cmd+B.

产物位于 Xcode DerivedData 目录，或打开 `ClipFlow.xcodeproj` 用 Xcode 直接 Cmd+B。

## Usage / 使用方法

- ClipFlow runs in the menu bar / 运行后图标显示在菜单栏
- Click icon or press ⌘⇧V to open panel / 点击图标或按快捷键 ⌘⇧V 呼出面板
- Click any record to copy back to clipboard / 点击任意记录可复制回剪贴板
- Search bar supports full-text search / 搜索栏支持全文检索
- Left sidebar filters by category / 左侧分类栏可按类型筛选
- Hover to show favorite & delete buttons / 悬停显示收藏和删除按钮
- Right-click menu bar icon → Settings / Quit / 右键菜单栏图标 → 设置 / 退出

## Privacy / 隐私说明

- All clipboard data stored locally in SQLite: `~/Library/Application Support/ClipFlow/clipflow.sqlite3` / 所有剪贴板数据存储在本地 SQLite
- Data stays local, nothing is uploaded / 数据完全本地，不上传任何内容

## Screenshots / 截图

![Menu Bar / 菜单栏](screenshots/menu-bar.png)

## License

MIT License. See [LICENSE](LICENSE).

## Authors

- [likzq](https://github.com/likzq30-ship-it)
