import SwiftUI

struct ClipboardListView: View {
    @ObservedObject var clipboardMonitor: ClipboardMonitor
    @Binding var selectedItem: ClipboardItem?
    var filteredItems: [ClipboardItem]
    @State private var searchText = ""

    var searchedItems: [ClipboardItem] {
        if searchText.isEmpty {
            return filteredItems
        }
        return filteredItems.filter { $0.content.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar

            Divider()

            if searchedItems.isEmpty {
                emptyState
            } else {
                listContent
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)

            TextField("搜索剪切板历史...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))
            Text(selectedCategoryLabel.isEmpty ? "暂无剪切板记录" : "「\(selectedCategoryLabel)」分类为空")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private var selectedCategoryLabel: String {
        ""
    }

    private var listContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(searchedItems) { item in
                        ClipboardItemRow(
                            item: item,
                            isSelected: selectedItem?.id == item.id,
                            onSelect: {
                                selectedItem = item
                                clipboardMonitor.selectItem(item)
                            },
                            onToggleFavorite: {
                                clipboardMonitor.toggleFavorite(item)
                            },
                            onDelete: {
                                clipboardMonitor.deleteItem(item)
                            }
                        )
                    }
                }
                .padding(8)
            }
            .onChange(of: selectedItem?.id) { newValue in
                if let id = newValue {
                    withAnimation {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }
}
