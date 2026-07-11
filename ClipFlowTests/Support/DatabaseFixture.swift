import Foundation
import SQLite3
@testable import ClipFlow

enum DatabaseFixtureError: Error {
    case injectedStatementFailure(String)
    case missingScalarRow(String)
}

final class TemporaryDatabaseLocation {
    let directory: URL
    let url: URL

    init(
        directoryName: String = "Database",
        databaseName: String = "clipflow.sqlite3"
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipFlowTests-\(UUID().uuidString)", isDirectory: true)
        directory = root.appendingPathComponent(directoryName, isDirectory: true)
        url = directory.appendingPathComponent(databaseName, isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }
}

final class DatabaseFixture {
    let location: TemporaryDatabaseLocation
    var database: SQLiteDatabase

    var url: URL { location.url }
    var directory: URL { location.directory }

    init(
        directoryName: String = "Database",
        databaseName: String = "clipflow.sqlite3"
    ) throws {
        let location = try TemporaryDatabaseLocation(
            directoryName: directoryName,
            databaseName: databaseName
        )
        self.location = location
        database = try SQLiteDatabase(url: location.url)
    }

    deinit {
        database.close()
    }

    func close() {
        database.close()
    }

    func reopen(readOnly: Bool = false) throws {
        database.close()
        database = try SQLiteDatabase(url: url, readOnly: readOnly)
    }

    func createLegacySchema() throws {
        try database.execute("""
            CREATE TABLE clipboard_items (
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

    func insertLegacyClip(
        id: UUID,
        content: String,
        contentType: String = "text",
        category: String,
        customCategory: String?,
        timestamp: TimeInterval,
        isFavorite: Bool = false,
        aiSummary: String? = nil
    ) throws {
        let statement = try database.prepare("""
            INSERT INTO clipboard_items
                (id, content, content_type, category, custom_category, timestamp, is_favorite, ai_summary)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(statement) }

        try database.bind(id.uuidString, at: 1, to: statement)
        try database.bind(content, at: 2, to: statement)
        try database.bind(contentType, at: 3, to: statement)
        try database.bind(category, at: 4, to: statement)
        try database.bind(customCategory, at: 5, to: statement)
        try database.bind(timestamp, at: 6, to: statement)
        try database.bind(isFavorite, at: 7, to: statement)
        try database.bind(aiSummary, at: 8, to: statement)
        try database.stepExpectingDone(statement)
    }

    func execute(_ sql: String) throws {
        try database.execute(sql)
    }

    func scalarInt(_ sql: String) throws -> Int {
        let statement = try database.prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseFixtureError.missingScalarRow(sql)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func scalarDouble(_ sql: String) throws -> Double {
        let statement = try database.prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseFixtureError.missingScalarRow(sql)
        }
        return sqlite3_column_double(statement, 0)
    }

    func scalarText(_ sql: String) throws -> String? {
        let statement = try database.prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseFixtureError.missingScalarRow(sql)
        }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }

        let byteCount = Int(sqlite3_column_bytes(statement, 0))
        guard let bytes = sqlite3_column_text(statement, 0) else {
            return byteCount == 0 ? "" : nil
        }
        return String(
            decoding: UnsafeBufferPointer(start: bytes, count: byteCount),
            as: UTF8.self
        )
    }

    func columnNames(_ table: String = "clipboard_items") throws -> Set<String> {
        try database.columnNames(in: table)
    }

    func failNextStatement(containing fragment: String) {
        var didFail = false
        database.statementInterceptorForTesting = { sql in
            guard !didFail, sql.localizedCaseInsensitiveContains(fragment) else { return }
            didFail = true
            throw DatabaseFixtureError.injectedStatementFailure(sql)
        }
    }

    func posixMode(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    func inode(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    func isExcludedFromBackup(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
    }

    func setMode(_ mode: Int, at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode)],
            ofItemAtPath: url.path
        )
    }
}
