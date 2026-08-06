import SwiftUI

struct ClipListView: View {
    @ObservedObject var store: ClipboardStore
    let actions: any ClipDetailActions

    var body: some View {
        VStack(spacing: 0) {
            pendingUndoBar

            List(selection: selectionBinding) {
                ForEach(session.items) { item in
                    clipRow(item)
                        .tag(item.id)
                        .onAppear {
                            if item.id == session.items.last?.id {
                                Task { await store.loadNextPage(.library) }
                            }
                        }
                }
            }
            .accessibilityIdentifier("library.list")
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task {
                        if let selectedID {
                            await actions.copy(itemID: selectedID)
                        }
                    }
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .accessibilityIdentifier("library.copy")
                .disabled(selectedID == nil)

                Button {
                    Task {
                        if let selectedID {
                            await actions.toggleFavorite(itemID: selectedID)
                        }
                    }
                } label: {
                    Label("Favorite", systemImage: "star")
                }
                .accessibilityIdentifier("library.favorite")
                .disabled(selectedID == nil || store.isReadOnlyRecovery)

                Button(role: .destructive) {
                    Task {
                        if let selectedID {
                            await actions.delete(itemID: selectedID)
                        }
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .accessibilityIdentifier("library.delete")
                .disabled(selectedID == nil || store.isReadOnlyRecovery)
            }
        }
    }
}

private extension ClipListView {
    var session: ClipQuerySession {
        store.session(for: .library)
    }

    var selectedID: UUID? {
        session.selectedItemID
    }

    var oldestPendingDelete: PendingDelete? {
        store.pendingDeletes.values.sorted {
            if $0.deletedAt != $1.deletedAt { return $0.deletedAt < $1.deletedAt }
            return $0.itemID.uuidString < $1.itemID.uuidString
        }.first
    }

    var selectionBinding: Binding<UUID?> {
        Binding(
            get: { session.selectedItemID },
            set: { store.setSelection($0, for: .library) }
        )
    }

    @ViewBuilder
    var pendingUndoBar: some View {
        if let pendingDelete = oldestPendingDelete {
            HStack {
                Text("Clip deleted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Undo") {
                    Task { await store.undoDelete(id: pendingDelete.itemID) }
                }
                .accessibilityIdentifier("library.undo")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial)
        }
    }

    func clipRow(_ item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.displayContent)
                .font(.body)
                .lineLimit(2)

            HStack(spacing: 8) {
                Text(item.displayCategory)
                Text(String(localized: "Copied \(item.copyCount)x"))
                if item.isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            store.setSelection(item.id, for: .library)
        }
        .onTapGesture(count: 2) {
            store.setSelection(item.id, for: .library)
            Task { await actions.copy(itemID: item.id) }
        }
        .contextMenu {
            Button("Copy") {
                Task { await actions.copy(itemID: item.id) }
            }
            Button(item.isFavorite ? "Unfavorite" : "Favorite") {
                Task { await actions.toggleFavorite(itemID: item.id) }
            }
            Button("Delete", role: .destructive) {
                Task { await actions.delete(itemID: item.id) }
            }
            if store.pendingDeletes[item.id] != nil {
                Button("Undo Delete") {
                    Task { await store.undoDelete(id: item.id) }
                }
                .accessibilityIdentifier("library.undo")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.displayContent)
        .accessibilityIdentifier("library.row.text.\(item.content)")
    }
}
