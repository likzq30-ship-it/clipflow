# ClipFlow Agent README

## 0. 当前事实

- 路径：`/Users/likzq/Desktop/项目/ClipFlow`
- 不是 git 仓库；不要用 git 状态判断工作区。
- macOS 菜单栏 App：Swift + SwiftUI + AppKit + SQLite.swift + HotKey + 本地 Ollama。
- 当前 checkout 没有 `PrivacyFilter`、`TestModeController.swift`、测试 target；旧记忆里的 `27 tests` 不适用于这里。
- 隐私红线：不要打印、上传、复述真实剪贴板内容；验证只用假文本。

## 1. 先跑什么

```bash
cd /Users/likzq/Desktop/项目/ClipFlow
xcodebuild -project ClipFlow.xcodeproj -scheme ClipFlow -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

当前阻塞：本机未同意 Xcode license，`xcodebuild -list -project ClipFlow.xcodeproj` 会报：

```text
You have not agreed to the Xcode license agreements.
```

改 `project.yml` 后才需要：

```bash
xcodegen generate
```

## 2. 最小架构图

```text
main.swift
  -> AppDelegate
      -> NSStatusItem / NSPopover / SettingsWindow
      -> HotkeyService
      -> ClipboardMonitor
          -> NSPasteboard
          -> DatabaseService
          -> ClipboardItem.categorize
      -> OllamaService
          -> http://localhost:11434/api/generate
```

## 3. 关键文件

| 文件 | 作用 |
| --- | --- |
| `ClipFlow/main.swift` | AppKit 启动入口 |
| `ClipFlow/App/AppDelegate.swift` | 状态栏、popover、右键菜单、设置窗口、快捷键回调 |
| `ClipFlow/Models/ClipboardItem.swift` | 剪贴板模型、分类规则、AI 记录、自定义分类 |
| `ClipFlow/Models/ShortcutMapping.swift` | Carbon 快捷键编码和显示 |
| `ClipFlow/Services/ClipboardMonitor.swift` | 0.5 秒轮询剪贴板、去重、复制、收藏、删除 |
| `ClipFlow/Services/DatabaseService.swift` | SQLite 建表、迁移、CRUD、过期清理 |
| `ClipFlow/Services/HotkeyService.swift` | 注册全局快捷键，默认 `⌘⇧V` |
| `ClipFlow/Services/OllamaService.swift` | 检查/启动 Ollama，摘要、AI 分类、调用记录 |
| `ClipFlow/Views/ContentView.swift` | 主面板：分类、列表、详情 |
| `ClipFlow/Views/ClipboardListView.swift` | 搜索和列表 |
| `ClipFlow/Views/DetailView.swift` | 详情、复制、AI 摘要、AI 分类 |
| `ClipFlow/Views/SettingsView.swift` | 设置、快捷键录制、自定义分类、AI 历史 |

## 4. 数据位置

- SQLite：`~/Library/Application Support/ClipFlow/clipflow.sqlite3`
- 表：`clipboard_items`
- 字段：`id`、`content`、`content_type`、`category`、`custom_category`、`timestamp`、`is_favorite`、`ai_summary`
- `UserDefaults`：`retention_days`、`clipflow_shortcut`、`ollama_base_url`、`ollama_model`、`custom_categories`、`api_usage_records`

## 5. 真实运行流

1. 启动后 `AppDelegate` 创建菜单栏图标和服务单例。
2. `ClipboardMonitor.shared` 读取数据库，然后启动 0.5 秒 timer。
3. `checkClipboard()` 发现 `NSPasteboard.changeCount` 变化后读取文本。
4. 新文本经 `ClipboardItem.categorize()` 分类，写入 SQLite，插到列表顶部。
5. 当前列表点击会调用 `selectItem()`，同时选中并复制回系统剪贴板。
6. 详情页 AI 摘要和分类调用本地 Ollama，结果写回 `ClipboardMonitor`/SQLite。

## 6. 已修这些

| 优先级 | 问题 | 位置 | 最小修法 |
| --- | --- | --- | --- |
| P0 | 详情页“删除”按钮不删除，只保存摘要 | `DetailView.actionButtons` | 已改为 `onDelete` -> `ClipboardMonitor.deleteItem` |
| P0 | 单击列表就复制，不符合“单击选中，双击复制” | `ClipboardItemRow` + `ClipboardListView` | 已拆成 `onSelect` 和 `onCopy` |
| P1 | 快捷键录制监听不移除，会堆 local monitor | `SettingsView.startRecording` | 已保存 monitor token，停止/消失时 remove |
| P1 | A 键不能作为快捷键 | `SettingsView.saveRecording` | 已用 `hasRecordedKey` 代替 `keyCode > 0` |
| P1 | 老库缺 `ai_summary` 可能炸 | `DatabaseService.migrate` | 已补 `ai_summary` 迁移 |
| P1 | DB 初始化失败后 `fetchAll()` 强解包会崩 | `DatabaseService.fetchAll` | 已改 `guard let db else { return [] }` |
| P2 | 分类空状态文案永远拿不到分类名 | `ClipboardListView.emptyState` | 从父视图传入当前分类名 |
| P2 | AI 调用历史保存真实内容前 100 字 | `OllamaService.logUsage` | 存固定占位或脱敏预览 |

回归检查：

```bash
./script/check_bugfixes.sh
```

## 7. 别先做这些

- 别重写架构；单例 + SwiftUI observable 够用。
- 别先加图片/文件剪贴板；模型有枚举，采集没实现。
- 别先做导入导出、自动更新、DMG、公证；当前先把核心 bug 修干净。
- 别手改大段 `.pbxproj`；改工程配置优先改 `project.yml` 后生成。
- 别覆盖 `doex.md`；它是旧项目说明，不是接手入口。

## 8. 改完检查

```bash
xcodebuild -project ClipFlow.xcodeproj -scheme ClipFlow -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

没有测试 target。非平凡逻辑至少留一个最小可运行检查，或者在最终说明里写清楚没法自动测的原因。
