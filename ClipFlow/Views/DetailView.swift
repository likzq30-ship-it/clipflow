import SwiftUI

struct DetailView: View {
    let item: ClipboardItem?
    @ObservedObject var ollamaService: OllamaService
    let onUpdateSummary: (String?) -> Void
    let onAICategorize: (String) -> Void

    @State private var summary: String?
    @State private var isGenerating = false
    @State private var isCategorizing = false
    @State private var copied = false

    var body: some View {
        if let item = item {
            VStack(alignment: .leading, spacing: 16) {
                header(for: item)

                Divider()

                contentArea(for: item)

                Divider()

                aiCategorizeArea(for: item)

                Divider()

                aiSummaryArea

                Spacer()

                actionButtons(for: item)
            }
            .padding(16)
        } else {
            emptyState
        }
    }

    private func header(for item: ClipboardItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(item.isFavorite ? "已收藏" : "普通记录")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("·")
                        .foregroundColor(.secondary)
                    Text(item.displayCategory)
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                }
                Text(formatDate(item.timestamp))
                    .font(.system(size: 13, weight: .medium))
            }

            Spacer()

            Text(item.timeAgo)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    private func contentArea(for item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("内容")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            ScrollView {
                Text(item.content)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .frame(maxHeight: 150)
        }
    }

    private func aiCategorizeArea(for item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "tag")
                    .foregroundColor(.green)
                Text("AI 智能分类")
                    .font(.system(size: 14, weight: .semibold))

                Spacer()

                if isCategorizing {
                    ProgressView().controlSize(.small)
                    Text("分类中...")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else if CustomCategoryStore.shared.categories.isEmpty {
                    Text("无自定义分类")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    Button(action: { categorize(item) }) {
                        Label("AI分类", systemImage: "wand.and.stars")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.green)
                }
            }

            if let custom = item.customCategory {
                HStack(spacing: 6) {
                    Image(systemName: "tag.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                    Text("当前分类: \(custom)")
                        .font(.system(size: 12))
                        .foregroundColor(.green)
                    Spacer()
                    Button(action: { onAICategorize("") }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.1)))
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var aiSummaryArea: some View {
        AIGeneratingView(
            summary: $summary,
            isGenerating: isGenerating,
            onGenerate: generateSummary,
            onClear: { summary = nil }
        )
    }

    private func actionButtons(for item: ClipboardItem) -> some View {
        HStack(spacing: 12) {
            Button(action: { copyContent(item) }) {
                Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(copied)

            Button(action: { onUpdateSummary(summary) }) {
                Label("删除", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "text.alignleft")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))
            Text("选择一条记录查看详情")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private func generateSummary() {
        guard let item = item else { return }
        isGenerating = true
        Task {
            if let result = await ollamaService.summarize(item.content) {
                await MainActor.run {
                    summary = result
                    isGenerating = false
                }
            } else {
                await MainActor.run { isGenerating = false }
            }
        }
    }

    private func categorize(_ item: ClipboardItem) {
        let cats = CustomCategoryStore.shared.categories
        guard !cats.isEmpty else { return }
        isCategorizing = true
        Task {
            if let result = await ollamaService.categorizeContent(item.content, customCategories: cats) {
                await MainActor.run {
                    onAICategorize(result)
                    isCategorizing = false
                }
            } else {
                await MainActor.run { isCategorizing = false }
            }
        }
    }

    private func copyContent(_ item: ClipboardItem) {
        ClipboardMonitor.shared.copyToPasteboard(item)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
