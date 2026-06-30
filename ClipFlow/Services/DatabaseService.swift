import Foundation
import SQLite3

class DatabaseService: ObservableObject {
    static let shared = DatabaseService()

    private var db: OpaquePointer?

    var retentionDays: Int {
        get { UserDefaults.standard.integer(forKey: "retention_days") == 0 ? 15 : UserDefaults.standard.integer(forKey: "retention_days") }
        set { UserDefaults.standard.set(newValue, forKey: "retention_days") }
    }

    private init() {
        setupDatabase()
    }

    deinit {
        sqlite3_close(db)
    }

    private func setupDatabase() {
        let path = getDatabasePath()
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            print("Database open error: \(lastError)")
            return
        }
        createTable()
        migrate()
        cleanupOldRecords()
    }

    private var lastError: String {
        guard let db, let message = sqlite3_errmsg(db) else { return "unknown" }
        return String(cString: message)
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

    private func createTable() {
        execute("""
            CREATE TABLE IF NOT EXISTS clipboard_items (
                id TEXT PRIMARY KEY,
                content TEXT NOT NULL,
                content_type TEXT NOT NULL,
                category TEXT NOT NULL DEFAULT 'other',
                custom_category TEXT,
                timestamp REAL NOT NULL,
                is_favorite INTEGER NOT NULL DEFAULT 0,
                ai_summary TEXT
            )
            """)
    }

    private func migrate() {
        let names = columnNames()
        if !names.contains("category") {
            execute("ALTER TABLE clipboard_items ADD COLUMN category TEXT NOT NULL DEFAULT 'other'")
        }
        if !names.contains("custom_category") {
            execute("ALTER TABLE clipboard_items ADD COLUMN custom_category TEXT")
        }
        if !names.contains("ai_summary") {
            execute("ALTER TABLE clipboard_items ADD COLUMN ai_summary TEXT")
        }
    }

    private func columnNames() -> Set<String> {
        guard let db else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(clipboard_items)", -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 1) {
                names.insert(String(cString: text))
            }
        }
        return names
    }

    func cleanupOldRecords() {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60).timeIntervalSince1970
        run("DELETE FROM clipboard_items WHERE timestamp < ? AND is_favorite = 0") { statement in
            sqlite3_bind_double(statement, 1, cutoff)
        }
    }

    func save(_ item: ClipboardItem) {
        run("""
            INSERT INTO clipboard_items
            (id, content, content_type, category, custom_category, timestamp, is_favorite, ai_summary)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """) { statement in
            bind(item.id.uuidString, to: 1, in: statement)
            bind(item.content, to: 2, in: statement)
            bind(item.contentType.rawValue, to: 3, in: statement)
            bind(item.category.rawValue, to: 4, in: statement)
            bind(item.customCategory, to: 5, in: statement)
            sqlite3_bind_double(statement, 6, item.timestamp.timeIntervalSince1970)
            sqlite3_bind_int(statement, 7, item.isFavorite ? 1 : 0)
            bind(item.aiSummary, to: 8, in: statement)
        }
    }

    func fetchAll() -> [ClipboardItem] {
        guard let db else { return [] }
        let sql = """
            SELECT id, content, content_type, category, custom_category, timestamp, is_favorite, ai_summary
            FROM clipboard_items
            ORDER BY timestamp DESC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            print("Fetch error: \(lastError)")
            return []
        }
        defer { sqlite3_finalize(statement) }

        var items: [ClipboardItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let item = rowToItem(statement) {
                items.append(item)
            }
        }
        return items
    }

    func update(_ item: ClipboardItem) {
        run("""
            UPDATE clipboard_items
            SET category = ?, custom_category = ?, is_favorite = ?, ai_summary = ?
            WHERE id = ?
            """) { statement in
            bind(item.category.rawValue, to: 1, in: statement)
            bind(item.customCategory, to: 2, in: statement)
            sqlite3_bind_int(statement, 3, item.isFavorite ? 1 : 0)
            bind(item.aiSummary, to: 4, in: statement)
            bind(item.id.uuidString, to: 5, in: statement)
        }
    }

    func delete(_ item: ClipboardItem) {
        run("DELETE FROM clipboard_items WHERE id = ?") { statement in
            bind(item.id.uuidString, to: 1, in: statement)
        }
    }

    func exists(content: String) -> Bool {
        guard let db else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM clipboard_items WHERE content = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        bind(content, to: 1, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func execute(_ sql: String) {
        guard let db else { return }
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            print("SQLite error: \(lastError)")
        }
    }

    private func run(_ sql: String, bindValues: (OpaquePointer?) -> Void) {
        guard let db else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            print("SQLite prepare error: \(lastError)")
            return
        }
        defer { sqlite3_finalize(statement) }

        bindValues(statement)
        if sqlite3_step(statement) != SQLITE_DONE {
            print("SQLite step error: \(lastError)")
        }
    }

    private func rowToItem(_ statement: OpaquePointer?) -> ClipboardItem? {
        guard let idText = sqlite3_column_text(statement, 0),
              let uuid = UUID(uuidString: String(cString: idText)),
              let contentText = sqlite3_column_text(statement, 1),
              let contentTypeText = sqlite3_column_text(statement, 2),
              let cType = ClipboardItem.ContentType(rawValue: String(cString: contentTypeText)) else {
            return nil
        }

        let categoryText = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? ClipboardItem.Category.other.rawValue
        let cat = ClipboardItem.Category(rawValue: categoryText) ?? .other

        return ClipboardItem(
            id: uuid,
            content: String(cString: contentText),
            contentType: cType,
            category: cat,
            customCategory: optionalText(statement, 4),
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            isFavorite: sqlite3_column_int(statement, 6) != 0,
            aiSummary: optionalText(statement, 7)
        )
    }

    private func optionalText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func bind(_ value: String?, to index: Int32, in statement: OpaquePointer?) {
    guard let value else {
        sqlite3_bind_null(statement, index)
        return
    }
    sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
}
