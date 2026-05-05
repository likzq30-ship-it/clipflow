import Foundation
import SQLite

class DatabaseService: ObservableObject {
    static let shared = DatabaseService()

    private var db: Connection?
    private let clipboardItems = Table("clipboard_items")

    private let id = Expression<String>("id")
    private let content = Expression<String>("content")
    private let contentType = Expression<String>("content_type")
    private let category = Expression<String>("category")
    private let customCategory = Expression<String?>("custom_category")
    private let timestamp = Expression<Double>("timestamp")
    private let isFavorite = Expression<Bool>("is_favorite")
    private let aiSummary = Expression<String?>("ai_summary")

    var retentionDays: Int {
        get { UserDefaults.standard.integer(forKey: "retention_days") == 0 ? 15 : UserDefaults.standard.integer(forKey: "retention_days") }
        set { UserDefaults.standard.set(newValue, forKey: "retention_days") }
    }

    private init() {
        setupDatabase()
    }

    private func setupDatabase() {
        do {
            let path = getDatabasePath()
            db = try Connection(path)
            try createTable()
            try migrate()
            cleanupOldRecords()
        } catch {
            print("Database setup error: \(error)")
        }
    }

    private func getDatabasePath() -> String {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("ClipFlow", isDirectory: true)
        if !fm.fileExists(atPath: appFolder.path) {
            try? fm.createDirectory(at: appFolder, withIntermediateDirectories: true)
        }
        return appFolder.appendingPathComponent("clipflow.sqlite3").path
    }

    private func createTable() throws {
        try db?.run(clipboardItems.create(ifNotExists: true) { t in
            t.column(id, primaryKey: true)
            t.column(content)
            t.column(contentType)
            t.column(category, defaultValue: ClipboardItem.Category.other.rawValue)
            t.column(customCategory)
            t.column(timestamp)
            t.column(isFavorite, defaultValue: false)
            t.column(aiSummary)
        })
    }

    private func migrate() throws {
        let columns = try db?.prepare("PRAGMA table_info(clipboard_items)")
        let names = columns?.compactMap { $0[1] as? String } ?? []
        if !names.contains("category") {
            try db?.run(clipboardItems.addColumn(category, defaultValue: "other"))
        }
        if !names.contains("custom_category") {
            try db?.run(clipboardItems.addColumn(self.customCategory, defaultValue: nil))
        }
    }

    func cleanupOldRecords() {
        let days = retentionDays
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60).timeIntervalSince1970
        do {
            let old = clipboardItems.filter(timestamp < cutoff && isFavorite == false)
            try db?.run(old.delete())
        } catch {
            print("Cleanup error: \(error)")
        }
    }

    func save(_ item: ClipboardItem) {
        do {
            try db?.run(clipboardItems.insert(
                id <- item.id.uuidString,
                content <- item.content,
                contentType <- item.contentType.rawValue,
                category <- item.category.rawValue,
                customCategory <- item.customCategory,
                timestamp <- item.timestamp.timeIntervalSince1970,
                isFavorite <- item.isFavorite,
                aiSummary <- item.aiSummary
            ))
        } catch {
            print("Save error: \(error)")
        }
    }

    func fetchAll() -> [ClipboardItem] {
        var items: [ClipboardItem] = []
        do {
            for row in try db!.prepare(clipboardItems.order(timestamp.desc)) {
                if let item = rowToItem(row) { items.append(item) }
            }
        } catch {
            print("Fetch error: \(error)")
        }
        return items
    }

    func update(_ item: ClipboardItem) {
        do {
            let record = clipboardItems.filter(id == item.id.uuidString)
            try db?.run(record.update(
                category <- item.category.rawValue,
                customCategory <- item.customCategory,
                isFavorite <- item.isFavorite,
                aiSummary <- item.aiSummary
            ))
        } catch {
            print("Update error: \(error)")
        }
    }

    func delete(_ item: ClipboardItem) {
        do {
            try db?.run(clipboardItems.filter(id == item.id.uuidString).delete())
        } catch {
            print("Delete error: \(error)")
        }
    }

    func exists(content: String) -> Bool {
        do {
            return try db?.pluck(clipboardItems.filter(self.content == content)) != nil
        } catch {
            return false
        }
    }

    private func rowToItem(_ row: Row) -> ClipboardItem? {
        guard let uuid = UUID(uuidString: row[id]),
              let cType = ClipboardItem.ContentType(rawValue: row[contentType]) else { return nil }

        let cat = ClipboardItem.Category(rawValue: row[category]) ?? .other

        return ClipboardItem(
            id: uuid,
            content: row[content],
            contentType: cType,
            category: cat,
            customCategory: row[customCategory],
            timestamp: Date(timeIntervalSince1970: row[timestamp]),
            isFavorite: row[isFavorite],
            aiSummary: row[aiSummary]
        )
    }
}
