import SwiftUI

struct ClipDetailView: View {
    let item: ClipboardItem
    let actions: any ClipDetailActions
    @ObservedObject var jobs: AIJobCoordinator
    let onExplicitDismiss: (UUID) async -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    content
                    aiActions
                    aiResults
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    Task {
                        await onExplicitDismiss(item.id)
                        dismiss()
                    }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }

                Spacer()

                Button {
                    Task { await actions.copy(itemID: item.id) }
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .controlSize(.large)
                .accessibilityIdentifier("library.copy")
            }
            .padding(12)
            .background(.regularMaterial)
        }
        .accessibilityIdentifier("library.detail")
    }
}

private extension ClipDetailView {
    var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.displayCategory)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item.lastCopiedAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await actions.toggleFavorite(itemID: item.id) }
            } label: {
                Label(
                    item.isFavorite ? "Unfavorite" : "Favorite",
                    systemImage: item.isFavorite ? "star.fill" : "star"
                )
            }
            .accessibilityIdentifier("library.favorite")

            Button(role: .destructive) {
                Task { await actions.delete(itemID: item.id) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("library.delete")
        }
    }

    var content: some View {
        Text(item.displayContent)
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    var aiActions: some View {
        HStack {
            Button("Summarize") {
                Task { await actions.summarize(itemID: item.id) }
            }
            Button("Categorize") {
                Task { await actions.categorize(itemID: item.id) }
            }
            Button("Rewrite") {
                Task { await actions.rewrite(itemID: item.id) }
            }
        }
    }

    var aiResults: some View {
        VStack(alignment: .leading, spacing: 12) {
            AIResultView(
                title: "Summary",
                persistedText: item.aiSummary,
                state: jobs.states[AIJobKey(itemID: item.id, operation: .summarize)]
            )
            AIResultView(
                title: "Rewrite",
                persistedText: nil,
                state: jobs.states[AIJobKey(itemID: item.id, operation: .rewrite)]
            )
            AIResultView(
                title: "Category",
                persistedText: nil,
                state: jobs.states[AIJobKey(itemID: item.id, operation: .categorize)]
            )
        }
    }
}
