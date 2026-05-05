import SwiftUI

struct ContentView: View {
    @ObservedObject var clipboardMonitor: ClipboardMonitor
    @ObservedObject var ollamaService: OllamaService
    @ObservedObject private var customCatStore = CustomCategoryStore.shared
    @State private var showClearConfirm = false
    @State private var selectedCategoryLabel: String? = nil
    @State private var categoryExpanded = true

    var filteredItems: [ClipboardItem] {
        guard let label = selectedCategoryLabel else { return clipboardMonitor.items }
        return clipboardMonitor.items.filter { $0.displayCategory == label }
    }

    var allCategoryCounts: [(String, Int, Color)] {
        var map: [String: Int] = [:]
        for item in clipboardMonitor.items {
            map[item.displayCategory, default: 0] += 1
        }
        return map.sorted { $0.value > $1.value }.map { label, count in
            (label, count, colorForCategory(label))
        }
    }

    private func colorForCategory(_ label: String) -> Color {
        if let cat = ClipboardItem.Category.allCases.first { $0.label == label } {
            switch cat {
            case .url: return .blue
            case .email: return .purple
            case .code: return .orange
            case .number: return .teal
            case .chinese: return .red
            case .english: return .indigo
            case .mixed: return .pink
            default: return .gray
            }
        }
        return .green // custom category color
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                HStack {
                    Text("ClipFlow")
                        .font(.system(size: 13, weight: .semibold))

                Text("· \(clipboardMonitor.items.count) 条记录")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: { showClearConfirm = true }) {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .help("一键清空")
                .popover(isPresented: $showClearConfirm, arrowEdge: .bottom) {
                    VStack(spacing: 12) {
                        Text("确认清空所有非收藏记录？")
                            .font(.system(size: 12))
                        HStack(spacing: 8) {
                            Button("取消") { showClearConfirm = false }
                                .buttonStyle(.bordered).controlSize(.small)
                            Button("清空") {
                                clipboardMonitor.clearHistory()
                                showClearConfirm = false
                            }
                            .buttonStyle(.borderedProminent).controlSize(.small).tint(.red)
                        }
                    }
                    .padding(12)
                }

                Button(action: { AppDelegate.shared?.openSettingsWindow() }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            HStack(spacing: 0) {
                if categoryExpanded {
                    categorySidebar
                    Divider()
                }

                ClipboardListView(
                    clipboardMonitor: clipboardMonitor,
                    selectedItem: $clipboardMonitor.selectedItem,
                    filteredItems: filteredItems
                )
                .frame(minWidth: 220, maxWidth: .infinity)

                Divider()

                DetailView(
                    item: clipboardMonitor.selectedItem,
                    ollamaService: ollamaService,
                    onUpdateSummary: { summary in
                        if let item = clipboardMonitor.selectedItem {
                            clipboardMonitor.updateAISummary(for: item, summary: summary ?? "")
                        }
                    },
                    onAICategorize: { result in
                        if let item = clipboardMonitor.selectedItem {
                            clipboardMonitor.updateCustomCategory(for: item, customCat: result)
                        }
                    }
                )
                .frame(minWidth: 260, maxWidth: .infinity)
            }
        }

            // Toast
            if let toast = clipboardMonitor.toastMessage {
                toastView(toast)
            }
        }
    }

    private func toastView(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            Text(text)
                .font(.system(size: 12))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .cornerRadius(20)
        .padding(.bottom, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.3), value: clipboardMonitor.toastMessage)
    }

    private var categorySidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                Text("分类")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button(action: { categoryExpanded = false }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(spacing: 2) {
                        categoryFolder(
                            label: "全部", count: clipboardMonitor.items.count,
                            isSelected: selectedCategoryLabel == nil,
                            color: .primary, icon: "tray.full"
                        ) { selectedCategoryLabel = nil }

                        if !allCategoryCounts.isEmpty {
                            Divider().padding(.horizontal, 10).padding(.vertical, 6)
                        }

                        ForEach(allCategoryCounts, id: \.0) { label, count, color in
                            categoryFolder(
                                label: label, count: count,
                                isSelected: selectedCategoryLabel == label,
                                color: color, icon: "circle.fill"
                            ) { selectedCategoryLabel = label }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(width: 120)
    }

    private func categoryFolder(label: String, count: Int, isSelected: Bool, color: Color, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 7))
                    .foregroundColor(isSelected ? color : .secondary.opacity(0.6))

                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? .primary : .secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text("\(count)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? color.opacity(0.1) : Color.clear)
            )
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
