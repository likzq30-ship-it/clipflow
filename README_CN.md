# ClipFlow

macOS 剪贴板历史工具，常驻菜单栏。

English | **[中文](README_CN.md)**

## 功能

你复制过的东西都会自动存下来，每半秒检查一次。

剪贴内容会自动分类：链接、邮件、代码、数字、中文、英文、中英混合等等。可以搜索，可以按分类筛选，重要的可以收藏。

收藏的内容不会被自动清理。保留天数自己设（1~30天），到期的自动删。

按 ⌘⇧V（可改）呼出面板，点一下就复制回去。

数据全在本地 SQLite，不联网不上传。

## 构建

需要 macOS 13+ 和 Xcode 15+。

```bash
git clone https://github.com/likzq30-ship-it/clipflow.git
cd clipflow
xcodebuild -project ClipFlow.xcodeproj -scheme ClipFlow -configuration Release build
```

或者 Xcode 打开 `.xcodeproj` 直接 Cmd+B。

## 使用

菜单栏常驻，点图标或快捷键打开。

- 点击记录复制
- 搜索栏全文检索
- 侧边栏按类型筛选
- 悬停出现收藏和删除
- 右键图标进设置或退出

## 数据在哪

`~/Library/Application Support/ClipFlow/clipflow.sqlite3`

仅本地，不上传。

## 截图

![菜单栏](screenshots/menu-bar.png)

## License

MIT — [likzq](https://github.com/likzq30-ship-it)
