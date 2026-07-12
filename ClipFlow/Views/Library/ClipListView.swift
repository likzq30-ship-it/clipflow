import SwiftUI

struct ClipListView: View {
    @ObservedObject var store: ClipboardStore
    let actions: any ClipDetailActions

    var body: some View {
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
                .disabled(selectedID == nil)

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
                .disabled(selectedID == nil)
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

    var selectionBinding: Binding<UUID?> {
        Binding(
            get: { session.selectedItemID },
            set: { store.setSelection($0, for: .library) }
        )
    }

    func clipRow(_ item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.displayContent)
                .font(.body)
                .lineLimit(2)

            HStack(spacing: 8) {
                Text(item.displayCategory)
                Text("Copied \(item.copyCount)x")
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
    }
}
