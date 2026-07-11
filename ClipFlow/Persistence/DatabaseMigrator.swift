import CryptoKit
import Foundation
import SQLite3

enum SearchMode: Equatable, Sendable {
    case fts5
    case parameterizedContains
}

struct LegacyCustomCategoryV1: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var prompt: String
}

struct LegacySettingsSnapshot: Equatable, Sendable {
    var categories: [LegacyCustomCategoryV1]
    var hadAIEnabled: Bool
    var hadOllamaURL: Bool
    var hadAPIUsageRecords: Bool

    func migratedCategories(now: Date) -> [PersistedCustomCategory] {
        categories.enumerated().map { index, category in
            PersistedCustomCategory(
                id: category.id,
                name: category.name.trimmingCharacters(in: .whitespacesAndNewlines),
                prompt: category.prompt,
                sortOrder: index,
                isEnabled: true,
                createdAt: now,
                updatedAt: now
            )
        }
    }
}

struct DatabasePreparation: Equatable, Sendable {
    var schemaVersion: Int
    var searchMode: SearchMode
    var recoveredCategories: [PersistedCustomCategory]
    var backupURL: URL?
}

enum DatabaseMigrator {
    static let schemaVersion = 2

    private static let canonicalClipboardColumns: Set<String> = [
        "id", "content", "content_hash", "builtin_category", "custom_category_id",
        "created_at", "last_copied_at", "copy_count", "is_favorite", "ai_summary",
        "deleted_at"
    ]

    private static let requiredLegacyColumns: Set<String> = [
        "id", "content", "content_type", "timestamp", "is_favorite"
    ]

    static func prepare(
        databaseURL: URL,
        legacyCategories: [PersistedCustomCategory]
    ) throws -> DatabasePreparation {
        do {
            try configureDatabaseDirectory(for: databaseURL)
            try validateExistingFilesBeforeOpen(databaseURL: databaseURL)
            try secureWritableExistingFiles(at: databaseURL)

            if FileManager.default.fileExists(atPath: databaseURL.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
                let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                if mode & 0o200 == 0 {
                    try throwReadOnlyRecovery(databaseURL: databaseURL)
                }
            } else {
                guard FileManager.default.createFile(atPath: databaseURL.path, contents: Data()) else {
                    throw DatabaseError.openFailed("unable to create database file")
                }
                try setMode(0o600, at: databaseURL)
            }

            let database: SQLiteDatabase
            do {
                database = try SQLiteDatabase(url: databaseURL)
            } catch {
                if FileManager.default.fileExists(atPath: databaseURL.path),
                   let recovery = try? makeReadOnlyRecovery(databaseURL: databaseURL) {
                    throw recovery
                }
                throw error
            }
            defer { database.close() }
            return try prepare(
                database: database,
                databaseURL: databaseURL,
                legacyCategories: legacyCategories
            )
        } catch let error as DatabaseError {
            switch error {
            case .migrationFailed, .readOnlyRecovery:
                throw error
            default:
                throw DatabaseError.migrationFailed(
                    message: message(for: error),
                    databaseURL: databaseURL,
                    backupURL: nil
                )
            }
        } catch {
            throw DatabaseError.migrationFailed(
                message: message(for: error),
                databaseURL: databaseURL,
                backupURL: nil
            )
        }
    }

    static func prepare(
        database: SQLiteDatabase,
        databaseURL: URL,
        legacyCategories: [PersistedCustomCategory]
    ) throws -> DatabasePreparation {
        try configureDatabaseDirectory(for: databaseURL)

        if database.readOnly {
            let backupURL = try? createVerifiedBackup(database: database, databaseURL: databaseURL)
            throw DatabaseError.readOnlyRecovery(databaseURL: databaseURL, backupURL: backupURL)
        }

        try database.applyPrivateFilePermissions()
        try database.execute("PRAGMA foreign_keys = ON")
        do {
            try requireIntegrity(database)
        } catch {
            throw DatabaseError.migrationFailed(
                message: message(for: error),
                databaseURL: databaseURL,
                backupURL: nil
            )
        }

        let currentVersion: Int
        let hasClipboardTable: Bool
        let existingColumns: Set<String>
        do {
            currentVersion = try scalarInt(database, sql: "PRAGMA user_version")
            hasClipboardTable = try objectExists(
                database,
                type: "table",
                name: "clipboard_items"
            )
            existingColumns = hasClipboardTable
                ? try database.columnNames(in: "clipboard_items")
                : []
        } catch {
            throw DatabaseError.migrationFailed(
                message: message(for: error),
                databaseURL: databaseURL,
                backupURL: nil
            )
        }

        guard currentVersion <= schemaVersion else {
            throw DatabaseError.migrationFailed(
                message: "database schema version \(currentVersion) is newer than supported version \(schemaVersion)",
                databaseURL: databaseURL,
                backupURL: nil
            )
        }

        let supportsFTS5 = detectFTS5(in: database)
        var backupURL: URL?
        var recoveredCategories: [PersistedCustomCategory] = []

        do {
            if !hasClipboardTable {
                try database.withTransaction {
                    try createCanonicalTables(in: database)
                    try importKnownCategories(legacyCategories, into: database)
                    try createCanonicalIndexes(in: database)
                    if supportsFTS5 {
                        try ensureFTSSchema(in: database)
                    }
                    try database.execute("PRAGMA user_version = \(schemaVersion)")
                    try validateCanonicalState(in: database, expectedRowCount: 0)
                }
            } else if currentVersion < schemaVersion {
                guard requiredLegacyColumns.isSubset(of: existingColumns) else {
                    throw DatabaseError.prepareFailed(
                        "legacy clipboard_items schema is missing required columns"
                    )
                }
                backupURL = try createVerifiedBackup(database: database, databaseURL: databaseURL)
                recoveredCategories = try migrateLegacyDatabase(
                    database,
                    legacyColumns: existingColumns,
                    legacyCategories: legacyCategories,
                    supportsFTS5: supportsFTS5
                )
            } else {
                try validateCanonicalState(in: database, expectedRowCount: nil)
                try validateAuxiliarySchema(in: database)
                if supportsFTS5 {
                    if try objectExists(database, type: "table", name: "clip_search") {
                        try validateFTSSchema(in: database)
                    } else {
                        backupURL = try createVerifiedBackup(
                            database: database,
                            databaseURL: databaseURL
                        )
                        try database.withTransaction {
                            try ensureFTSSchema(in: database)
                        }
                    }
                }
            }

            try database.applyPrivateFilePermissions()
            return DatabasePreparation(
                schemaVersion: schemaVersion,
                searchMode: supportsFTS5 ? .fts5 : .parameterizedContains,
                recoveredCategories: recoveredCategories,
                backupURL: backupURL
            )
        } catch let error as DatabaseError {
            if case .migrationFailed = error {
                throw error
            }
            throw DatabaseError.migrationFailed(
                message: message(for: error),
                databaseURL: databaseURL,
                backupURL: backupURL
            )
        } catch {
            throw DatabaseError.migrationFailed(
                message: message(for: error),
                databaseURL: databaseURL,
                backupURL: backupURL
            )
        }
    }
}

private extension DatabaseMigrator {
    struct LegacyClipboardRow {
        var id: String
        var content: String
        var category: String
        var customCategory: String?
        var timestamp: Double
        var isFavorite: Bool
        var aiSummary: String?
    }

    static func migrateLegacyDatabase(
        _ database: SQLiteDatabase,
        legacyColumns: Set<String>,
        legacyCategories: [PersistedCustomCategory],
        supportsFTS5: Bool
    ) throws -> [PersistedCustomCategory] {
        let now = Date()
        var recoveredCategories: [PersistedCustomCategory] = []

        try database.withTransaction {
            try database.execute("ALTER TABLE clipboard_items RENAME TO clipboard_items_v1")
            try createCanonicalTables(in: database)
            try importKnownCategories(legacyCategories, into: database)

            let legacyRows = try readLegacyRows(database, columns: legacyColumns)
            var categoryByNormalizedName = try loadCategories(in: database)
            var nextSortOrder = (categoryByNormalizedName.values.map(\.sortOrder).max() ?? -1) + 1

            for row in legacyRows {
                let customCategoryID: UUID?
                if let rawName = row.customCategory,
                   let displayName = nonemptyTrimmed(rawName) {
                    let normalizedName = normalizeCategoryName(displayName)
                    if let category = categoryByNormalizedName[normalizedName] {
                        customCategoryID = category.id
                    } else {
                        let category = PersistedCustomCategory(
                            id: stableRecoveredCategoryID(normalizedName: normalizedName),
                            name: displayName,
                            prompt: "",
                            sortOrder: nextSortOrder,
                            isEnabled: false,
                            createdAt: now,
                            updatedAt: now
                        )
                        try insertCategory(
                            category,
                            normalizedName: normalizedName,
                            into: database
                        )
                        categoryByNormalizedName[normalizedName] = category
                        recoveredCategories.append(category)
                        nextSortOrder += 1
                        customCategoryID = category.id
                    }
                } else {
                    customCategoryID = nil
                }

                try insertCanonicalRow(
                    row,
                    customCategoryID: customCategoryID,
                    into: database
                )
            }

            try validateCopiedRows(in: database, expectedCount: legacyRows.count)
            try database.execute("DROP TABLE clipboard_items_v1")
            try createCanonicalIndexes(in: database)
            if supportsFTS5 {
                try ensureFTSSchema(in: database)
            }
            try database.execute("PRAGMA user_version = \(schemaVersion)")
            try validateCanonicalState(in: database, expectedRowCount: legacyRows.count)
        }

        return recoveredCategories
    }

    static func createCanonicalTables(in database: SQLiteDatabase) throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS custom_categories (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                normalized_name TEXT NOT NULL UNIQUE,
                prompt TEXT NOT NULL,
                sort_order INTEGER NOT NULL,
                is_enabled INTEGER NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS clipboard_items (
                id TEXT PRIMARY KEY NOT NULL,
                content TEXT NOT NULL,
                content_hash TEXT NOT NULL,
                builtin_category TEXT NOT NULL,
                custom_category_id TEXT REFERENCES custom_categories(id) ON DELETE SET NULL,
                created_at REAL NOT NULL,
                last_copied_at REAL NOT NULL,
                copy_count INTEGER NOT NULL DEFAULT 1 CHECK(copy_count >= 1),
                is_favorite INTEGER NOT NULL DEFAULT 0 CHECK(is_favorite IN (0, 1)),
                ai_summary TEXT,
                deleted_at REAL
            )
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS ai_usage (
                id TEXT PRIMARY KEY,
                operation TEXT NOT NULL,
                timestamp REAL NOT NULL,
                provider TEXT NOT NULL,
                model TEXT NOT NULL,
                duration_ms INTEGER NOT NULL,
                succeeded INTEGER NOT NULL,
                error_code TEXT
            )
            """)
    }

    static func createCanonicalIndexes(in database: SQLiteDatabase) throws {
        try database.execute("""
            CREATE INDEX IF NOT EXISTS idx_clips_last_copied
            ON clipboard_items(deleted_at, last_copied_at DESC)
            """)
        try database.execute("""
            CREATE INDEX IF NOT EXISTS idx_clips_hash
            ON clipboard_items(content_hash, deleted_at)
            """)
        try database.execute("""
            CREATE INDEX IF NOT EXISTS idx_clips_category
            ON clipboard_items(deleted_at, builtin_category, custom_category_id)
            """)
    }

    static func importKnownCategories(
        _ categories: [PersistedCustomCategory],
        into database: SQLiteDatabase
    ) throws {
        for category in categories {
            guard let name = nonemptyTrimmed(category.name) else { continue }
            let normalizedName = normalizeCategoryName(name)
            let statement = try database.prepare("""
                INSERT INTO custom_categories (
                    id, name, normalized_name, prompt, sort_order, is_enabled, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(normalized_name) DO NOTHING
                """)
            defer { sqlite3_finalize(statement) }
            try database.bind(category.id.uuidString, at: 1, to: statement)
            try database.bind(name, at: 2, to: statement)
            try database.bind(normalizedName, at: 3, to: statement)
            try database.bind(category.prompt, at: 4, to: statement)
            try database.bind(category.sortOrder, at: 5, to: statement)
            try database.bind(category.isEnabled, at: 6, to: statement)
            try database.bind(category.createdAt.timeIntervalSince1970, at: 7, to: statement)
            try database.bind(category.updatedAt.timeIntervalSince1970, at: 8, to: statement)
            try database.stepExpectingDone(statement)
        }
    }

    static func insertCategory(
        _ category: PersistedCustomCategory,
        normalizedName: String,
        into database: SQLiteDatabase
    ) throws {
        let statement = try database.prepare("""
            INSERT INTO custom_categories (
                id, name, normalized_name, prompt, sort_order, is_enabled, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(statement) }
        try database.bind(category.id.uuidString, at: 1, to: statement)
        try database.bind(category.name, at: 2, to: statement)
        try database.bind(normalizedName, at: 3, to: statement)
        try database.bind(category.prompt, at: 4, to: statement)
        try database.bind(category.sortOrder, at: 5, to: statement)
        try database.bind(category.isEnabled, at: 6, to: statement)
        try database.bind(category.createdAt.timeIntervalSince1970, at: 7, to: statement)
        try database.bind(category.updatedAt.timeIntervalSince1970, at: 8, to: statement)
        try database.stepExpectingDone(statement)
    }

    static func loadCategories(
        in database: SQLiteDatabase
    ) throws -> [String: PersistedCustomCategory] {
        let statement = try database.prepare("""
            SELECT id, name, normalized_name, prompt, sort_order, is_enabled, created_at, updated_at
            FROM custom_categories
            """)
        defer { sqlite3_finalize(statement) }

        var result: [String: PersistedCustomCategory] = [:]
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let idText = database.columnString(statement, at: 0),
                      let id = UUID(uuidString: idText),
                      let name = database.columnString(statement, at: 1),
                      let normalizedName = database.columnString(statement, at: 2),
                      let prompt = database.columnString(statement, at: 3) else {
                    throw DatabaseError.stepFailed("invalid custom category row")
                }
                result[normalizedName] = PersistedCustomCategory(
                    id: id,
                    name: name,
                    prompt: prompt,
                    sortOrder: Int(sqlite3_column_int64(statement, 4)),
                    isEnabled: sqlite3_column_int(statement, 5) != 0,
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
                )
            case SQLITE_DONE:
                return result
            default:
                throw DatabaseError.stepFailed(database.lastError)
            }
        }
    }

    static func readLegacyRows(
        _ database: SQLiteDatabase,
        columns: Set<String>
    ) throws -> [LegacyClipboardRow] {
        let categoryExpression = columns.contains("category") ? "category" : "'other'"
        let customExpression = columns.contains("custom_category") ? "custom_category" : "NULL"
        let summaryExpression = columns.contains("ai_summary") ? "ai_summary" : "NULL"
        let statement = try database.prepare("""
            SELECT id, content, \(categoryExpression), \(customExpression), timestamp,
                   is_favorite, \(summaryExpression)
            FROM clipboard_items_v1
            ORDER BY rowid
            """)
        defer { sqlite3_finalize(statement) }

        var rows: [LegacyClipboardRow] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let id = database.columnString(statement, at: 0),
                      let content = database.columnString(statement, at: 1),
                      let category = database.columnString(statement, at: 2) else {
                    throw DatabaseError.stepFailed("invalid legacy clipboard row")
                }
                rows.append(
                    LegacyClipboardRow(
                        id: id,
                        content: content,
                        category: category,
                        customCategory: database.columnString(statement, at: 3),
                        timestamp: sqlite3_column_double(statement, 4),
                        isFavorite: sqlite3_column_int(statement, 5) != 0,
                        aiSummary: database.columnString(statement, at: 6)
                    )
                )
            case SQLITE_DONE:
                return rows
            default:
                throw DatabaseError.stepFailed(database.lastError)
            }
        }
    }

    static func insertCanonicalRow(
        _ row: LegacyClipboardRow,
        customCategoryID: UUID?,
        into database: SQLiteDatabase
    ) throws {
        let statement = try database.prepare("""
            INSERT INTO clipboard_items (
                id, content, content_hash, builtin_category, custom_category_id,
                created_at, last_copied_at, copy_count, is_favorite, ai_summary, deleted_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?, NULL)
            """)
        defer { sqlite3_finalize(statement) }

        let builtinCategory = ClipboardItem.Category(rawValue: row.category)?.rawValue
            ?? ClipboardItem.Category.other.rawValue
        try database.bind(row.id, at: 1, to: statement)
        try database.bind(row.content, at: 2, to: statement)
        try database.bind(contentHash(row.content), at: 3, to: statement)
        try database.bind(builtinCategory, at: 4, to: statement)
        try database.bind(customCategoryID?.uuidString, at: 5, to: statement)
        try database.bind(row.timestamp, at: 6, to: statement)
        try database.bind(row.timestamp, at: 7, to: statement)
        try database.bind(row.isFavorite, at: 8, to: statement)
        try database.bind(row.aiSummary, at: 9, to: statement)
        try database.stepExpectingDone(statement)
    }

    static func validateCopiedRows(
        in database: SQLiteDatabase,
        expectedCount: Int
    ) throws {
        guard try scalarInt(database, sql: "SELECT COUNT(*) FROM clipboard_items") == expectedCount else {
            throw DatabaseError.stepFailed("legacy row count validation failed")
        }

        let statement = try database.prepare("SELECT content, content_hash FROM clipboard_items")
        defer { sqlite3_finalize(statement) }
        var validatedCount = 0
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let content = database.columnString(statement, at: 0),
                      let storedHash = database.columnString(statement, at: 1),
                      storedHash == contentHash(content) else {
                    throw DatabaseError.stepFailed("legacy content hash validation failed")
                }
                validatedCount += 1
            case SQLITE_DONE:
                guard validatedCount == expectedCount else {
                    throw DatabaseError.stepFailed("legacy row validation count failed")
                }
                return
            default:
                throw DatabaseError.stepFailed(database.lastError)
            }
        }
    }

    static func validateCanonicalState(
        in database: SQLiteDatabase,
        expectedRowCount: Int?
    ) throws {
        guard try database.columnNames(in: "clipboard_items") == canonicalClipboardColumns else {
            throw DatabaseError.prepareFailed("clipboard_items does not match the canonical v2 schema")
        }
        guard try scalarInt(database, sql: "PRAGMA user_version") == schemaVersion else {
            throw DatabaseError.prepareFailed("database schema version was not committed")
        }
        if let expectedRowCount {
            guard try scalarInt(database, sql: "SELECT COUNT(*) FROM clipboard_items") == expectedRowCount else {
                throw DatabaseError.stepFailed("canonical row count validation failed")
            }
        }
        try requireNoRows(database, sql: "PRAGMA foreign_key_check")
        try requireIntegrity(database)
    }

    static func validateAuxiliarySchema(in database: SQLiteDatabase) throws {
        guard try objectExists(database, type: "table", name: "custom_categories"),
              try objectExists(database, type: "table", name: "ai_usage") else {
            throw DatabaseError.prepareFailed("canonical auxiliary tables are missing")
        }
        for index in ["idx_clips_last_copied", "idx_clips_hash", "idx_clips_category"] {
            guard try objectExists(database, type: "index", name: index) else {
                throw DatabaseError.prepareFailed("canonical index \(index) is missing")
            }
        }
    }

    static func detectFTS5(in database: SQLiteDatabase) -> Bool {
        do {
            try database.execute("CREATE VIRTUAL TABLE temp.clipflow_fts_probe USING fts5(content)")
            try database.execute("DROP TABLE temp.clipflow_fts_probe")
            return true
        } catch {
            try? database.execute("DROP TABLE IF EXISTS temp.clipflow_fts_probe")
            return false
        }
    }

    static func ensureFTSSchema(in database: SQLiteDatabase) throws {
        if try objectExists(database, type: "table", name: "clip_search") {
            try validateFTSSchema(in: database)
            return
        }

        try database.execute("""
            CREATE VIRTUAL TABLE clip_search
            USING fts5(content, content='clipboard_items', content_rowid='rowid')
            """)
        try database.execute("""
            CREATE TRIGGER clips_fts_insert AFTER INSERT ON clipboard_items BEGIN
              INSERT INTO clip_search(rowid, content) VALUES (new.rowid, new.content);
            END
            """)
        try database.execute("""
            CREATE TRIGGER clips_fts_delete AFTER DELETE ON clipboard_items BEGIN
              INSERT INTO clip_search(clip_search, rowid, content)
              VALUES ('delete', old.rowid, old.content);
            END
            """)
        try database.execute("""
            CREATE TRIGGER clips_fts_update AFTER UPDATE OF content ON clipboard_items BEGIN
              INSERT INTO clip_search(clip_search, rowid, content)
              VALUES ('delete', old.rowid, old.content);
              INSERT INTO clip_search(rowid, content) VALUES (new.rowid, new.content);
            END
            """)
        try database.execute("INSERT INTO clip_search(clip_search) VALUES ('rebuild')")
        try validateFTSSchema(in: database)
    }

    static func validateFTSSchema(in database: SQLiteDatabase) throws {
        let expected: Set<String> = [
            "clips_fts_insert", "clips_fts_delete", "clips_fts_update"
        ]
        let statement = try database.prepare("""
            SELECT name FROM sqlite_master
            WHERE type = 'trigger' AND name LIKE 'clips_fts_%'
            """)
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let name = database.columnString(statement, at: 0) {
                    names.insert(name)
                }
            case SQLITE_DONE:
                guard names == expected else {
                    throw DatabaseError.prepareFailed("FTS trigger schema is incomplete")
                }
                return
            default:
                throw DatabaseError.stepFailed(database.lastError)
            }
        }
    }
}

private extension DatabaseMigrator {
    static func configureDatabaseDirectory(for databaseURL: URL) throws {
        let directory = databaseURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        }
        try setMode(0o700, at: directory)
        var mutableDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableDirectory.setResourceValues(values)
    }

    static func validateExistingFilesBeforeOpen(databaseURL: URL) throws {
        let fileManager = FileManager.default
        var expectedDatabasePageSize: Int?
        if fileManager.fileExists(atPath: databaseURL.path) {
            let attributes = try fileManager.attributesOfItem(atPath: databaseURL.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            if size > 0 {
                let header = try readPrefix(of: databaseURL, count: 100)
                guard header.count >= 100,
                      header.prefix(16) == Data("SQLite format 3\u{0}".utf8),
                      let pageSize = databasePageSize(from: header) else {
                    throw DatabaseError.migrationFailed(
                        message: "database header is not valid SQLite",
                        databaseURL: databaseURL,
                        backupURL: nil
                    )
                }
                expectedDatabasePageSize = pageSize
            }
        }

        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        if fileManager.fileExists(atPath: walURL.path) {
            do {
                let wal = try Data(contentsOf: walURL, options: .mappedIfSafe)
                if !wal.isEmpty {
                    try validateWAL(
                        wal,
                        expectedPageSize: expectedDatabasePageSize
                    )
                }
            } catch {
                throw DatabaseError.migrationFailed(
                    message: "database WAL is damaged: \(message(for: error))",
                    databaseURL: databaseURL,
                    backupURL: nil
                )
            }
        }

        // The WAL-index (-shm) contains no database content and SQLite rebuilds it
        // from the durable WAL after a crash. Persisted SHM bytes can legitimately
        // be stale, torn, or initialized beside an empty WAL, so they are never
        // used as preflight recovery evidence.
    }

    static func validateWAL(
        _ wal: Data,
        expectedPageSize: Int?
    ) throws {
        guard wal.count >= 32 else {
            throw DatabaseError.prepareFailed("WAL header is truncated")
        }

        let magic = readBigEndianUInt32(in: wal, at: 0)
        guard magic == 0x377f0682 || magic == 0x377f0683 else {
            throw DatabaseError.prepareFailed("WAL magic is invalid")
        }
        guard readBigEndianUInt32(in: wal, at: 4) == 3_007_000 else {
            throw DatabaseError.prepareFailed("WAL format version is unsupported")
        }

        let pageSize = Int(readBigEndianUInt32(in: wal, at: 8))
        guard isValidSQLitePageSize(pageSize),
              expectedPageSize == nil || expectedPageSize == pageSize else {
            throw DatabaseError.prepareFailed("WAL page size is invalid")
        }

        let usesBigEndianChecksums = magic == 0x377f0683
        var checksum = updateChecksum(
            in: wal,
            offset: 0,
            byteCount: 24,
            usesBigEndianWords: usesBigEndianChecksums,
            initial: (0, 0)
        )
        guard checksum.0 == readBigEndianUInt32(in: wal, at: 24),
              checksum.1 == readBigEndianUInt32(in: wal, at: 28) else {
            throw DatabaseError.prepareFailed("WAL header checksum is invalid")
        }

        let frameSize = 24 + pageSize
        let salt = Data(wal[16..<24])
        let frameCount = (wal.count - 32) / frameSize

        for frameIndex in 0..<frameCount {
            let frameOffset = 32 + frameIndex * frameSize
            guard readBigEndianUInt32(in: wal, at: frameOffset) > 0 else {
                throw DatabaseError.prepareFailed("WAL frame page number is invalid")
            }

            var candidateChecksum = updateChecksum(
                in: wal,
                offset: frameOffset,
                byteCount: 8,
                usesBigEndianWords: usesBigEndianChecksums,
                initial: checksum
            )
            candidateChecksum = updateChecksum(
                in: wal,
                offset: frameOffset + 24,
                byteCount: pageSize,
                usesBigEndianWords: usesBigEndianChecksums,
                initial: candidateChecksum
            )
            let storedChecksum = (
                readBigEndianUInt32(in: wal, at: frameOffset + 16),
                readBigEndianUInt32(in: wal, at: frameOffset + 20)
            )

            if !wal[(frameOffset + 8)..<(frameOffset + 16)].elementsEqual(salt) {
                guard frameIndex > 0 else {
                    throw DatabaseError.prepareFailed(
                        "first WAL frame salt does not match its header"
                    )
                }
                guard candidateChecksum != storedChecksum else {
                    throw DatabaseError.prepareFailed(
                        "WAL frame \(frameIndex + 1) salt is corrupt within the current checksum chain"
                    )
                }
                // A RESTART checkpoint rewinds the logical WAL without truncating
                // its physical file. The first old-salt frame is the end of the
                // current generation; everything after it is a stale suffix.
                break
            }

            checksum = candidateChecksum
            guard checksum == storedChecksum else {
                throw DatabaseError.prepareFailed(
                    "WAL frame \(frameIndex + 1) checksum is invalid"
                )
            }
        }
    }

    static func updateChecksum(
        in data: Data,
        offset: Int,
        byteCount: Int,
        usesBigEndianWords: Bool,
        initial: (UInt32, UInt32)
    ) -> (UInt32, UInt32) {
        precondition(byteCount.isMultiple(of: 8))
        var state = initial
        var position = offset
        let end = offset + byteCount
        while position < end {
            let first = readUInt32(
                in: data,
                at: position,
                bigEndian: usesBigEndianWords
            )
            let second = readUInt32(
                in: data,
                at: position + 4,
                bigEndian: usesBigEndianWords
            )
            state.0 = state.0 &+ first &+ state.1
            state.1 = state.1 &+ second &+ state.0
            position += 8
        }
        return state
    }

    static func databasePageSize(from header: Data) -> Int? {
        let rawValue = Int(readBigEndianUInt16(in: header, at: 16))
        let pageSize = rawValue == 1 ? 65_536 : rawValue
        return isValidSQLitePageSize(pageSize) ? pageSize : nil
    }

    static func isValidSQLitePageSize(_ pageSize: Int) -> Bool {
        pageSize >= 512 && pageSize <= 65_536 && (pageSize & (pageSize - 1)) == 0
    }

    static func readUInt32(in data: Data, at offset: Int, bigEndian: Bool) -> UInt32 {
        bigEndian
            ? readBigEndianUInt32(in: data, at: offset)
            : readLittleEndianUInt32(in: data, at: offset)
    }

    static func readBigEndianUInt16(in data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    static func readBigEndianUInt32(in data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    static func readLittleEndianUInt32(in data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) |
            (UInt32(data[offset + 1]) << 8) |
            (UInt32(data[offset + 2]) << 16) |
            (UInt32(data[offset + 3]) << 24)
    }

    static func secureWritableExistingFiles(at databaseURL: URL) throws {
        let fileManager = FileManager.default
        for url in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ] where fileManager.fileExists(atPath: url.path) {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            guard mode & 0o200 != 0 else { continue }
            try setMode(0o600, at: url)
        }
    }

    static func throwReadOnlyRecovery(databaseURL: URL) throws -> Never {
        throw try makeReadOnlyRecovery(databaseURL: databaseURL)
    }

    static func makeReadOnlyRecovery(databaseURL: URL) throws -> DatabaseError {
        let database = try SQLiteDatabase(url: databaseURL, readOnly: true)
        defer { database.close() }
        try requireIntegrity(database)
        let backupURL = try createVerifiedBackup(database: database, databaseURL: databaseURL)
        return .readOnlyRecovery(databaseURL: databaseURL, backupURL: backupURL)
    }

    static func createVerifiedBackup(
        database: SQLiteDatabase,
        databaseURL: URL
    ) throws -> URL {
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000_000)
        let name = "\(databaseURL.lastPathComponent).backup-\(timestamp)-\(UUID().uuidString)"
        let backupURL = databaseURL.deletingLastPathComponent()
            .appendingPathComponent(name, isDirectory: false)
        let fileManager = FileManager.default

        guard fileManager.createFile(atPath: backupURL.path, contents: Data()) else {
            throw DatabaseError.openFailed("unable to create migration backup")
        }

        do {
            try setMode(0o600, at: backupURL)
            try database.onlineBackup(to: backupURL)
            try setMode(0o600, at: backupURL)
            let verification = try SQLiteDatabase(url: backupURL, readOnly: true)
            defer { verification.close() }
            try requireIntegrity(verification)
            return backupURL
        } catch {
            try? fileManager.removeItem(at: backupURL)
            throw error
        }
    }

    static func requireIntegrity(_ database: SQLiteDatabase) throws {
        guard try scalarText(database, sql: "PRAGMA integrity_check") == "ok" else {
            throw DatabaseError.prepareFailed("database integrity check failed")
        }
    }

    static func requireNoRows(_ database: SQLiteDatabase, sql: String) throws {
        let statement = try database.prepare(sql)
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_DONE:
            return
        case SQLITE_ROW:
            throw DatabaseError.stepFailed("database validation returned unexpected rows")
        default:
            throw DatabaseError.stepFailed(database.lastError)
        }
    }

    static func scalarInt(_ database: SQLiteDatabase, sql: String) throws -> Int {
        let statement = try database.prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.stepFailed(database.lastError)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    static func scalarText(_ database: SQLiteDatabase, sql: String) throws -> String? {
        let statement = try database.prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.stepFailed(database.lastError)
        }
        return database.columnString(statement, at: 0)
    }

    static func objectExists(
        _ database: SQLiteDatabase,
        type: String,
        name: String
    ) throws -> Bool {
        let statement = try database.prepare("""
            SELECT 1 FROM sqlite_master WHERE type = ? AND name = ? LIMIT 1
            """)
        defer { sqlite3_finalize(statement) }
        try database.bind(type, at: 1, to: statement)
        try database.bind(name, at: 2, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else {
            throw DatabaseError.stepFailed(database.lastError)
        }
        return result == SQLITE_ROW
    }

    static func setMode(_ mode: Int, at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode)],
            ofItemAtPath: url.path
        )
    }

    static func readPrefix(of url: URL, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: count) ?? Data()
    }

    static func contentHash(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func nonemptyTrimmed(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizeCategoryName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    static func stableRecoveredCategoryID(normalizedName: String) -> UUID {
        var bytes = Array(
            SHA256.hash(data: Data("clipflow-recovered:\(normalizedName)".utf8)).prefix(16)
        )
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static func message(for error: Error) -> String {
        switch error {
        case DatabaseError.openFailed(let message),
             DatabaseError.prepareFailed(let message),
             DatabaseError.stepFailed(let message):
            return message
        case DatabaseError.migrationFailed(let message, _, _):
            return message
        case DatabaseError.itemNotFound:
            return "clipboard item was not found"
        case DatabaseError.readOnlyRecovery:
            return "database is read-only"
        default:
            return String(describing: error)
        }
    }
}
