# ClipFlow

macOS 菜单栏剪贴板历史管理工具。

English | **[中文](README_CN.md)**

## 功能

- **剪贴板历史** — 自动记录文本剪贴板，0.5 秒轮询
- **智能分类** — 链接、邮件、代码、数字、中文、英文、中英混合、其他
- **搜索与筛选** — 全文搜索 + 分类侧边栏
- **收藏** — 标记重要记录，不会被自动清理
- **自动清理** — 1~30 天保留期可配，到期删除非收藏记录
- **全局快捷键** — 默认 ⌘⇧V，可自定义
- **本地存储** — SQLite，数据不上传

## 环境要求

- macOS 13.0+
- Xcode 15.0+

## 构建

```bash
git clone https://github.com/likzq30-ship-it/clipflow.git
cd clipflow
xcodebuild -project ClipFlow.xcodeproj -scheme ClipFlow -configuration Release build
```

或者 Xcode 里打开 `ClipFlow.xcodeproj` 直接 Cmd+B。

## 使用

运行后常驻菜单栏，点图标或按 ⌘⇧V 呼出面板。

- 点击记录复制回剪贴板
- 搜索栏支持全文检索
- 侧边栏按分类筛选
- 悬停显示收藏和删除
- 右键图标 → 设置 / 退出

## 隐私

数据存在本地 `~/Library/Application Support/ClipFlow/clipflow.sqlite3`，不上传。

## 截图

![菜单栏](screenshots/menu-bar.png)

## License

MIT

## 作者

[likzq](https://github.com/likzq30-ship-it)
