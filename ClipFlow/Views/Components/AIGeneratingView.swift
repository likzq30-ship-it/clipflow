import SwiftUI

struct AIGeneratingView: View {
    @Binding var summary: String?
    let isGenerating: Bool
    let onGenerate: () -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundColor(.purple)
                Text("AI 智能汇总")
                    .font(.system(size: 14, weight: .semibold))

                Spacer()

                if summary == nil && !isGenerating {
                    Button(action: onGenerate) {
                        Label("生成汇总", systemImage: "wand.and.stars")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                if isGenerating {
                    ProgressView()
                        .controlSize(.small)
                    Text("生成中...")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                if summary != nil {
                    Button(action: onClear) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .help("清除汇总")
                }
            }

            if let summary = summary {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "quote.opening")
                        .font(.system(size: 12))
                        .foregroundColor(.purple.opacity(0.6))

                    Text(summary)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.purple.opacity(0.1))
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}
