import SwiftUI

struct QuickClipRow: View {
    let item: ClipboardItem
    let isSelected: Bool
    let isReadOnly: Bool
    let onSelect: () -> Void
    let onCopy: () -> Void
    let onToggleFavorite: () -> Void
    let onOpenInHistory: () -> Void
    let onDelete: () -> Void
    let onUndo: () -> Void
    let canUndoDelete: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displayContent)
                        .font(.callout)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        Label(item.displayCategory, systemImage: iconName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(item.timeAgo)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 8)

                Button {
                    onToggleFavorite()
                } label: {
                    Image(systemName: item.isFavorite ? "star.fill" : "star")
                }
                .buttonStyle(.plain)
                .disabled(isReadOnly)
                .help(item.isFavorite ? "Remove Favorite" : "Favorite")

                Button {
                    onCopy()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy")
            }

            if canUndoDelete {
                Button("Undo Delete", action: onUndo)
                    .font(.caption)
                    .accessibilityIdentifier("quick.undo.\(item.id.uuidString)")
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onCopy)
        .simultaneousGesture(TapGesture().onEnded(onSelect))
        .contextMenu {
            Button("Copy", action: onCopy)
            Button(item.isFavorite ? "Remove Favorite" : "Favorite", action: onToggleFavorite)
                .disabled(isReadOnly)
            Button("Open in History", action: onOpenInHistory)
            Divider()
            Button("Delete", action: onDelete)
                .disabled(isReadOnly)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.displayContent)
        .accessibilityIdentifier("quick.row.text.\(item.content)")
    }
}

private extension QuickClipRow {
    var iconName: String {
        switch item.category {
        case .url: return "link"
        case .email: return "envelope"
        case .code: return "curlybraces"
        case .number: return "number"
        case .chinese, .english, .mixed: return "textformat"
        case .other: return "doc.text"
        }
    }
}
