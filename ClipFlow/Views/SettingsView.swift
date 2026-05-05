import SwiftUI
import Carbon

struct SettingsView: View {
    @ObservedObject var hotkeyService: HotkeyService
    @ObservedObject var ollamaService: OllamaService
    @Binding var isOpen: Bool

    @ObservedObject private var customCatStore = CustomCategoryStore.shared
    @ObservedObject private var apiUsageStore = APIUsageStore.shared

    @State private var selectedTab = 0
    @State private var apiURL: String = ""
    @State private var modelName: String = ""
    @State private var retentionDays: Double = 15
    @State private var newCatName: String = ""
    @State private var newCatPrompt: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            TabView(selection: $selectedTab) {
                generalTab
                    .tabItem { Label("通用", systemImage: "gearshape") }
                    .tag(0)

                shortcutTab
                    .tabItem { Label("快捷键", systemImage: "keyboard") }
                    .tag(1)

                categoryTab
                    .tabItem { Label("分类", systemImage: "folder") }
                    .tag(2)

                aiTab
                    .tabItem { Label("AI", systemImage: "brain") }
                    .tag(3)

                historyTab
                    .tabItem { Label("记录", systemImage: "clock.arrow.circlepath") }
                    .tag(4)
            }
            .padding(16)
        }
        .frame(width: 440, height: 420)
        .onAppear {
            apiURL = ollamaService.baseURL
            modelName = ollamaService.model
            retentionDays = Double(DatabaseService.shared.retentionDays)
        }
    }

    private var header: some View {
        HStack {
            Text("设置")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            Button(action: { isOpen = false }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    // MARK: - 通用 Tab

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("保存历史天数")
                    .font(.system(size: 13, weight: .medium))
                HStack {
                    Slider(value: $retentionDays, in: 1...30, step: 1) { Text("") }
                    Text("\(Int(retentionDays)) 天")
                        .font(.system(size: 13, design: .monospaced))
                        .frame(width: 40, alignment: .trailing)
                }
                Text("自动清理超过 \(Int(retentionDays)) 天的非收藏记录")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .onChange(of: retentionDays) { newVal in
                DatabaseService.shared.retentionDays = Int(newVal)
                DatabaseService.shared.cleanupOldRecords()
            }

            settingRow(title: "清空历史", description: "删除所有非收藏记录") {
                Button("清空") { ClipboardMonitor.shared.clearHistory() }
                    .buttonStyle(.bordered)
            }

            Spacer()

            HStack {
                Spacer()
                Text("ClipFlow v\(appVersion)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.6))
            }
        }
    }

    private var appVersion: String { "1.0" }

    // MARK: - 快捷键 Tab

    @State private var isRecording = false
    @State private var recordedModifiers: UInt32 = 0
    @State private var recordedKeyCode: UInt32 = 0
    @State private var recordingDisplay: String = ""

    private var shortcutTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("打开面板")
                    .font(.system(size: 13, weight: .medium))

                HStack {
                    if isRecording {
                        Text(recordingDisplay.isEmpty ? "按下组合键..." : recordingDisplay)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.accentColor.opacity(0.15))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.accentColor.opacity(0.4), lineWidth: 2)
                                    )
                            )
                            .onAppear { startRecording() }
                    } else {
                        Text(hotkeyService.shortcutManager.currentShortcut.displayString)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.1)))
                    }

                    Button(action: {
                        if isRecording {
                            saveRecording()
                        } else {
                            startRecordingUI()
                        }
                    }) {
                        Text(isRecording ? "保存" : "修改")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isRecording && recordingDisplay.isEmpty)

                    if isRecording {
                        Button("取消") {
                            stopRecording()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            Text("提示: 点击 修改 后按下组合键，如 ⌘⇧V")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Button("重置为默认 (⌘⇧V)") { hotkeyService.resetToDefault() }
                .buttonStyle(.bordered)

            Spacer()
        }
    }

    private func startRecordingUI() {
        recordedModifiers = 0
        recordedKeyCode = 0
        recordingDisplay = ""
        isRecording = true
    }

    private func startRecording() {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard isRecording else { return event }

            if event.type == .flagsChanged {
                recordedModifiers = 0
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags.contains(.control) { recordedModifiers |= UInt32(controlKey) }
                if flags.contains(.option) { recordedModifiers |= UInt32(optionKey) }
                if flags.contains(.shift) { recordedModifiers |= UInt32(shiftKey) }
                if flags.contains(.command) { recordedModifiers |= UInt32(cmdKey) }
                updateRecordingDisplay()
                return event
            }

            if event.type == .keyDown {
                recordedKeyCode = UInt32(event.keyCode)
                updateRecordingDisplay()
                return nil
            }

            return event
        }
    }

    private func updateRecordingDisplay() {
        let temp = ShortcutMapping(keyCode: recordedKeyCode, modifiers: recordedModifiers)
        recordingDisplay = temp.displayString
    }

    private func saveRecording() {
        guard recordedKeyCode > 0, recordedModifiers > 0 else { return }
        let shortcut = ShortcutMapping(keyCode: recordedKeyCode, modifiers: recordedModifiers)
        hotkeyService.updateShortcut(shortcut)
        stopRecording()
    }

    private func stopRecording() {
        isRecording = false
        recordedModifiers = 0
        recordedKeyCode = 0
        recordingDisplay = ""
    }

    // MARK: - 分类 Tab

    private var categoryTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("自定义分类 (AI 驱动)")
                .font(.system(size: 13, weight: .medium))

            Text("创建自定义分类并编写匹配提示词，AI 会根据提示词自动归类剪切板内容。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            // Add new
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("分类名称 (如: 工作)", text: $newCatName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .frame(width: 120)
                    TextField("提示词 (如: 包含工作、项目、会议)", text: $newCatPrompt)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    Button("添加") {
                        guard !newCatName.isEmpty, !newCatPrompt.isEmpty else { return }
                        customCatStore.add(name: newCatName, prompt: newCatPrompt)
                        newCatName = ""
                        newCatPrompt = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(newCatName.isEmpty || newCatPrompt.isEmpty)
                }
            }

            Divider()

            // List existing
            if customCatStore.categories.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("暂无自定义分类")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                    Spacer()
                }
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(customCatStore.categories) { cat in
                            HStack {
                                Image(systemName: "tag.fill")
                                    .foregroundColor(.green)
                                    .font(.system(size: 11))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(cat.name)
                                        .font(.system(size: 12, weight: .medium))
                                    Text("提示: \(cat.prompt)")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button(action: { customCatStore.delete(cat) }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
    }

    // MARK: - AI Tab

    private var aiTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("API 地址")
                    .font(.system(size: 12, weight: .medium))
                HStack {
                    TextField("http://localhost:11434", text: $apiURL)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12))
                    Button("应用") {
                        ollamaService.baseURL = apiURL
                        ollamaService.checkAvailability()
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("模型名称")
                    .font(.system(size: 12, weight: .medium))
                HStack {
                    TextField("qwen2.5:1.5b", text: $modelName)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12))
                    Button("应用") {
                        ollamaService.model = modelName
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }

            Divider()

            settingRow(title: "连接状态", description: ollamaService.isAvailable ? "✓ 已连接" : "✗ 未连接") {
                Button("检测") { ollamaService.checkAvailability() }
                    .buttonStyle(.bordered)
            }

            Spacer()
        }
    }

    // MARK: - API 历史记录 Tab

    private var historyTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("API 调用记录")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                if !apiUsageStore.records.isEmpty {
                    Button("清空全部") { apiUsageStore.clearAll() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            if apiUsageStore.records.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("暂无 API 调用记录")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(apiUsageStore.records) { record in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: record.type == "summarize" ? "sparkles" : "tag")
                                    .font(.system(size: 10))
                                    .foregroundColor(record.type == "summarize" ? .purple : .green)
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(record.type == "summarize" ? "汇总" : "分类")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(record.type == "summarize" ? .purple : .green)
                                        Text("· \(record.timestamp, style: .time)")
                                            .font(.system(size: 9))
                                            .foregroundColor(.secondary)
                                        Text("· \(record.model)")
                                            .font(.system(size: 9))
                                            .foregroundColor(.secondary)
                                    }

                                    Text(record.contentPreview)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)

                                    Text(record.result)
                                        .font(.system(size: 10))
                                        .foregroundColor(.primary)
                                        .lineLimit(2)
                                }

                                Spacer(minLength: 0)

                                Button(action: { apiUsageStore.delete(record) }) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))

                            if record.id != apiUsageStore.records.last?.id {
                                Divider().padding(.leading, 30)
                            }
                        }
                    }
                }
            }
        }
    }

    private func settingRow<Content: View>(title: String, description: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(description).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
            content()
        }
    }
}
