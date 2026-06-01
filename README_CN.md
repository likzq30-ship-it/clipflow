# ClipFlow

macOS 菜单栏剪贴板历史工具。

English | **[中文](README_CN.md)**

## 功能

- 自动记录剪贴板内容（0.5秒轮询）
- 自动分类：链接、邮件、代码、数字、中文、英文、中英混合
- 全文搜索 + 分类侧边栏
- 收藏重要记录，不被自动清理
- 自动清理：1~30天可配
- 全局快捷键 ⌘⇧V，可自定义
- 本地 SQLite 存储

## 环境要求

- macOS 13.0+
- Xcode 15.0+

## 构建

```bash
git clone https://github.com/likzq30-ship-it/clipflow.git
cd clipflow
xcodebuild -project ClipFlow.xcodeproj -scheme ClipFlow -configuration Release build
```

或者 Xcode 打开 `ClipFlow.xcodeproj` 直接 Cmd+B。

## 使用

- 菜单栏常驻，点击或 ⌘⇧V 打开
- 点击记录复制回剪贴板
- 搜索栏全文检索
- 侧边栏按分类筛选
- 悬停出现收藏和删除
- 右键图标进设置

## 隐私

本地存储在 `~/Library/Application Support/ClipFlow/clipflow.sqlite3`，不联网不上传。

## 截图

![菜单栏](screenshots/menu-bar.png)

## License

MIT — [likzq](https://github.com/likzq30-ship-it)
