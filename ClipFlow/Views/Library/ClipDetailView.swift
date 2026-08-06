import SwiftUI

struct ClipDetailView: View {
    let item: ClipboardItem
    let isReadOnly: Bool
    let actions: any ClipDetailActions
    @ObservedObject var jobs: AIJobCoordinator
    let onExplicitDismiss: (UUID) async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var editedContent: String = ""
    @State private var lastItemID: UUID?
    @FocusState private var isEditing: Bool

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
        .onAppear {
            editedContent = item.content
            lastItemID = item.id
        }
        .onChange(of: item.id) { newID in
            saveIfNeeded()
            editedContent = item.content
            lastItemID = newID
            isEditing = false
        }
        .onChange(of: isEditing) { editing in
            if !editing {
                saveIfNeeded()
            }
        }
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
            .disabled(isReadOnly)

            Button(role: .destructive) {
                Task { await actions.delete(itemID: item.id) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("library.delete")
            .disabled(isReadOnly)
        }
    }

    var content: some View {
        TextEditor(text: $editedContent)
            .font(.body)
            .focused($isEditing)
            .frame(minHeight: 120)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            .disabled(isReadOnly)
            .accessibilityIdentifier("library.detail.text.\(item.content)")
    }

    func saveIfNeeded() {
        guard let lastID = lastItemID,
              editedContent != item.content,
              !editedContent.isEmpty else { return }
        Task { await actions.updateContent(itemID: lastID, content: editedContent) }
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
