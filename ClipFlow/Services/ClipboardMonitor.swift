import Foundation
import AppKit
import Combine

class ClipboardMonitor: ObservableObject {
    static let shared = ClipboardMonitor()

    @Published var items: [ClipboardItem] = []
    @Published var selectedItem: ClipboardItem?
    @Published var toastMessage: String?

    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private var lastContent: String = ""
    private let database = DatabaseService.shared

    private init() {
        loadItems()
        startMonitoring()
    }

    private func loadItems() {
        items = database.fetchAll()
        for i in 0..<items.count where items[i].category == .other && items[i].contentType == .text {
            let newCat = ClipboardItem.categorize(items[i].content)
            if newCat != .other {
                items[i] = ClipboardItem(id: items[i].id, content: items[i].content, contentType: items[i].contentType, category: newCat, timestamp: items[i].timestamp, isFavorite: items[i].isFavorite, aiSummary: items[i].aiSummary)
                database.update(items[i])
            }
        }
        if let first = items.first {
            lastContent = first.content
        }
    }

    func startMonitoring() {
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func checkClipboard() {
        let pasteboard = NSPasteboard.general
        let currentChangeCount = pasteboard.changeCount

        guard currentChangeCount != lastChangeCount else { return }
        lastChangeCount = currentChangeCount

        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            if string != lastContent {
                addItem(content: string, type: .text)
                lastContent = string
            }
        }
    }

    private func addItem(content: String, type: ClipboardItem.ContentType) {
        if database.exists(content: content) { return }

        let cat = ClipboardItem.categorize(content)
        let item = ClipboardItem(content: content, contentType: type, category: cat)
        database.save(item)
        items.insert(item, at: 0)
    }

    func selectItem(_ item: ClipboardItem) {
        selectedItem = item
        copyToPasteboard(item)
        toastMessage = "已复制: \(String(item.content.prefix(40)))"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.toastMessage = nil
        }
    }

    func copyToPasteboard(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.content, forType: .string)
        lastContent = item.content
        lastChangeCount = pasteboard.changeCount
    }

    func toggleFavorite(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isFavorite.toggle()
        database.update(items[index])
    }

    func deleteItem(_ item: ClipboardItem) {
        database.delete(item)
        items.removeAll { $0.id == item.id }
        if selectedItem?.id == item.id {
            selectedItem = nil
        }
    }

    func clearHistory() {
        for item in items where !item.isFavorite {
            database.delete(item)
        }
        items.removeAll { !$0.isFavorite }
    }

    func updateAISummary(for item: ClipboardItem, summary: String) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].aiSummary = summary
        database.update(items[index])
    }

    func updateCustomCategory(for item: ClipboardItem, customCat: String) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].customCategory = customCat
        database.update(items[index])
    }
}
