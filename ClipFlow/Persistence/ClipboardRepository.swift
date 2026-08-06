import CryptoKit
import Foundation
import SQLite3

enum RepositorySearchPlan: Equatable, Sendable {
    case unfiltered
    case fts(expression: String, phrases: [[String]])
    case parameterizedContains(text: String, escapedPattern: String)

    static func make(searchText: String, mode: SearchMode) -> RepositorySearchPlan {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unfiltered }
        guard mode == .fts5 else { return containsPlan(for: trimmed) }

        let components = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let phrases = components.map(searchableTerms)
        guard phrases.allSatisfy({ !$0.isEmpty }) else {
            return containsPlan(for: trimmed)
        }
        let expression = components.map { component in
            let escaped = component.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }.joined(separator: " AND ")
        return .fts(expression: expression, phrases: phrases)
    }

    func matches(_ content: String) -> Bool {
        switch self {
        case .unfiltered:
            return true
        case .parameterizedContains(let text, _):
            return content.range(of: text, options: .caseInsensitive) != nil
        case .fts(_, let phrases):
            let contentTerms = Self.searchableTerms(in: content)
            return phrases.allSatisfy { Self.contains($0, in: contentTerms) }
        }
    }

    private static func containsPlan(for text: String) -> RepositorySearchPlan {
        .parameterizedContains(
            text: text,
            escapedPattern: "%\(escapeLike(text))%"
        )
    }

    private static func searchableTerms(in value: String) -> [String] {
        value.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { term in
                String(term).folding(
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
            }
    }

    private static func contains(_ phrase: [String], in terms: [String]) -> Bool {
        guard !phrase.isEmpty, phrase.count <= terms.count else { return false }
        for start in 0...(terms.count - phrase.count) {
            if terms[start..<(start + phrase.count)].elementsEqual(phrase) {
                return true
            }
        }
        return false
    }

    private static func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

actor ClipboardRepository: ClipboardRepositoryProtocol {
    private static let canonicalColumns: Set<String> = [
        "id", "content", "content_hash", "builtin_category", "custom_category_id",
        "created_at", "last_copied_at", "copy_count", "is_favorite", "ai_summary",
        "deleted_at"
    ]
    private static let legacyRequiredColumns: Set<String> = [
        "id", "content", "content_type", "timestamp", "is_favorite"
    ]

    private let databaseURL: URL
    private var database: SQLiteDatabase?
    private var startup: RepositoryStartup?
    private var searchMode: SearchMode = .parameterizedContains
    private var recoveryLayout: RecoveryLayout?
    private var recoveryCategories: [PersistedCustomCategory] = []
    private var recoveryCategoryByNormalizedName: [String: PersistedCustomCategory] = [:]
    private var activeAIGenerations: [AIJobKey: UUID] = [:]
    private var conditionalMutationGate: (@Sendable () async -> Void)?
    private var preCommitPermissionHookForTesting: (@Sendable () throws -> Void)?

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    init(database: SQLiteDatabase, databaseURL: URL) {
        self.databaseURL = databaseURL
        self.database = database
    }

    func prepare(legacyCategories: [PersistedCustomCategory]) throws -> RepositoryStartup {
        if let startup { return startup }

        do {
            let preparation: DatabasePreparation
            if let database {
                preparation = try DatabaseMigrator.prepare(
                    database: database,
                    databaseURL: databaseURL,
                    legacyCategories: legacyCategories
                )
                try database.execute("PRAGMA foreign_keys = ON")
            } else {
                preparation = try DatabaseMigrator.prepare(
                    databaseURL: databaseURL,
                    legacyCategories: legacyCategories
                )
                let opened = try SQLiteDatabase(url: databaseURL)
                do {
                    try opened.execute("PRAGMA foreign_keys = ON")
                } catch {
                    opened.close()
                    throw error
                }
                database = opened
            }

            searchMode = preparation.searchMode
            try database?.applyPrivateFilePermissions()
            let state = RepositoryStartup.readWrite(preparation)
            startup = state
            return state
        } catch {
            let blockingError = error
            database?.close()
            database = nil

            do {
                let recoveryDatabase = try SQLiteDatabase(url: databaseURL, readOnly: true)
                do {
                    let recovery = try inspectRecovery(
                        database: recoveryDatabase,
                        legacyCategories: legacyCategories
                    )
                    database = recoveryDatabase
                    recoveryLayout = recovery.layout
                    recoveryCategories = recovery.categories
                    if case .legacy = recovery.layout {
                        recoveryCategoryByNormalizedName = recovery.categories.reduce(into: [:]) {
                            categories, category in
                            let name = Self.normalizeCategoryName(category.name)
                            if categories[name] == nil {
                                categories[name] = category
                            }
                        }
                    } else {
                        recoveryCategoryByNormalizedName = [:]
                    }
                    let state = RepositoryStartup.readOnlyRecovery(
                        databaseURL: databaseURL,
                        backupURL: Self.backupURL(from: blockingError),
                        errorCode: Self.errorCode(for: blockingError)
                    )
                    startup = state
                    return state
                } catch {
                    recoveryDatabase.close()
                    throw blockingError
                }
            } catch {
                throw blockingError
            }
        }
    }

    func startupState() -> RepositoryStartup? {
        startup
    }

    func fetchPage(_ query: ClipQuery) async throws -> ClipPage {
        let database = try readableDatabase()
        if case .legacy = recoveryLayout {
            return try fetchLegacyPage(query, database: database)
        }
        return try fetchCanonicalPage(query, database: database)
    }

    func item(id: UUID) async throws -> ClipboardItem? {
        let database = try readableDatabase()
        if case .legacy = recoveryLayout {
            return try loadLegacyItems(database: database)
                .first { $0.id == id && $0.deletedAt == nil }
        }
        return try canonicalItem(id: id, activeOnly: true, database: database)
    }

    func upsertCapturedText(_ capture: CapturedText) async throws -> ClipboardItem {
        let database = try writableDatabase()
        let hash = Self.contentHash(capture.content)

        return try withRepositoryTransaction(database) {
            let candidates = try matchingHashCandidates(hash, database: database)
            if let match = candidates.first(where: { $0.content == capture.content }) {
                let statement = try prepared(
                    """
                    UPDATE clipboard_items
                    SET last_copied_at = ?, copy_count = copy_count + 1
                    WHERE id = ? AND deleted_at IS NULL
                    """,
                    bindings: [
                        .double(capture.capturedAt.timeIntervalSince1970),
                        .string(match.id.uuidString)
                    ],
                    database: database
                )
                defer { sqlite3_finalize(statement) }
                try database.stepExpectingDone(statement)
                return try requireCanonicalItem(id: match.id, database: database)
            }

            let id = UUID()
            let statement = try prepared(
                """
                INSERT INTO clipboard_items (
                    id, content, content_hash, builtin_category, custom_category_id,
                    created_at, last_copied_at, copy_count, is_favorite, ai_summary, deleted_at
                ) VALUES (?, ?, ?, ?, NULL, ?, ?, 1, 0, NULL, NULL)
                """,
                bindings: [
                    .string(id.uuidString),
                    .string(capture.content),
                    .string(hash),
                    .string(capture.category.rawValue),
                    .double(capture.capturedAt.timeIntervalSince1970),
                    .double(capture.capturedAt.timeIntervalSince1970)
                ],
                database: database
            )
            defer { sqlite3_finalize(statement) }
            try database.stepExpectingDone(statement)
            return try requireCanonicalItem(id: id, database: database)
        }
    }

    func markCopied(id: UUID, at: Date) async throws -> ClipboardItem {
        let database = try writableDatabase()
        return try withRepositoryTransaction(database) {
            let statement = try prepared(
                """
                UPDATE clipboard_items
                SET last_copied_at = ?, copy_count = copy_count + 1
                WHERE id = ? AND deleted_at IS NULL
                """,
                bindings: [.double(at.timeIntervalSince1970), .string(id.uuidString)],
                database: database
            )
            defer { sqlite3_finalize(statement) }
            try database.stepExpectingDone(statement)
            return try requireCanonicalItem(id: id, database: database)
        }
    }

    func setContent(id: UUID, content: String) async throws -> ClipboardItem {
        let database = try writableDatabase()
        let hash = Self.contentHash(content)
        return try withRepositoryTransaction(database) {
            let statement = try prepared(
                """
                UPDATE clipboard_items
                SET content = ?, content_hash = ?
                WHERE id = ? AND deleted_at IS NULL
                """,
                bindings: [.string(content), .string(hash), .string(id.uuidString)],
                database: database
            )
            defer { sqlite3_finalize(statement) }
            try database.stepExpectingDone(statement)
            try requireChanged(id: id, database: database)
            return try requireCanonicalItem(id: id, database: database)
        }
    }

    func setFavorite(id: UUID, isFavorite: Bool) async throws -> ClipboardItem {
        let database = try writableDatabase()
        return try withRepositoryTransaction(database) {
            let statement = try prepared(
                "UPDATE clipboard_items SET is_favorite = ? WHERE id = ? AND deleted_at IS NULL",
                bindings: [.bool(isFavorite), .string(id.uuidString)],
                database: database
            )
            defer { sqlite3_finalize(statement) }
            try database.stepExpectingDone(statement)
            try requireChanged(id: id, database: database)
            return try requireCanonicalItem(id: id, database: database)
        }
    }

    func setSummary(id: UUID, summary: String?) async throws -> ClipboardItem {
        let database = try writableDatabase()
        return try withRepositoryTransaction(database) {
            try setSummarySynchronously(id: id, summary: summary, database: database)
        }
    }

    func setCustomCategory(id: UUID, categoryID: UUID?) async throws -> ClipboardItem {
        let database = try writableDatabase()
        return try withRepositoryTransaction(database) {
            try setCustomCategorySynchronously(
                id: id,
                categoryID: categoryID,
                database: database
            )
        }
    }

    func activateAIJob(_ key: AIJobKey, generation: UUID) async {
        activeAIGenerations[key] = generation
    }

    func cancelAIJob(_ key: AIJobKey, generation: UUID) async {
        guard activeAIGenerations[key] == generation else { return }
        activeAIGenerations.removeValue(forKey: key)
    }

    func setSummaryIfCurrent(
        id: UUID,
        summary: String?,
        key: AIJobKey,
        generation: UUID
    ) async throws -> ClipboardItem? {
        try requireWritableStartup()
        if let gate = conditionalMutationGate {
            conditionalMutationGate = nil
            await gate()
        }
        guard key.itemID == id,
              key.operation == .summarize,
              activeAIGenerations[key] == generation else { return nil }

        let database = try writableDatabase()
        return try withRepositoryTransaction(database) {
            try setSummarySynchronously(id: id, summary: summary, database: database)
        }
    }

    func setCustomCategoryIfCurrent(
        id: UUID,
        categoryID: UUID?,
        key: AIJobKey,
        generation: UUID
    ) async throws -> ClipboardItem? {
        try requireWritableStartup()
        if let gate = conditionalMutationGate {
            conditionalMutationGate = nil
            await gate()
        }
        guard key.itemID == id,
              key.operation == .categorize,
              activeAIGenerations[key] == generation else { return nil }

        let database = try writableDatabase()
        return try withRepositoryTransaction(database) {
            try setCustomCategorySynchronously(
                id: id,
                categoryID: categoryID,
                database: database
            )
        }
    }

    func setConditionalMutationGateForTesting(
        _ gate: (@Sendable () async -> Void)?
    ) {
        conditionalMutationGate = gate
    }

    func setPreCommitPermissionHookForTesting(
        _ hook: (@Sendable () throws -> Void)?
    ) {
        preCommitPermissionHookForTesting = hook
    }

    func setSearchModeForTesting(_ mode: SearchMode) {
        searchMode = mode
    }

    func failNextStatementForTesting(containing fragment: String) throws {
        let database = try readableDatabase()
        var didFail = false
        database.statementInterceptorForTesting = { sql in
            guard !didFail, sql.localizedCaseInsensitiveContains(fragment) else { return }
            didFail = true
            throw DatabaseError.stepFailed("injected repository statement failure")
        }
    }

    func softDelete(id: UUID, at: Date) async throws {
        let database = try writableDatabase()
        try withRepositoryTransaction(database) {
            let statement = try prepared(
                """
                UPDATE clipboard_items SET deleted_at = ?
                WHERE id = ? AND deleted_at IS NULL
                """,
                bindings: [.double(at.timeIntervalSince1970), .string(id.uuidString)],
                database: database
            )
            defer { sqlite3_finalize(statement) }
            try database.stepExpectingDone(statement)
            try requireChanged(id: id, database: database)
        }
    }

    func deletedTombstones(since: Date) async throws -> [DeletedClipTombstone] {
        let database = try readableDatabase()
        if case .legacy = recoveryLayout { return [] }
        let statement = try prepared(
            """
            SELECT id, deleted_at FROM clipboard_items
            WHERE deleted_at IS NOT NULL AND deleted_at >= ?
            ORDER BY deleted_at ASC, id ASC
            """,
            bindings: [.double(since.timeIntervalSince1970)],
            database: database
        )
        defer { sqlite3_finalize(statement) }

        var tombstones: [DeletedClipTombstone] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let idText = database.columnString(statement, at: 0),
                      let id = UUID(uuidString: idText) else {
                    throw DatabaseError.stepFailed("invalid deleted clipboard row")
                }
                tombstones.append(
                    DeletedClipTombstone(
                        itemID: id,
                        deletedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                    )
                )
            case SQLITE_DONE:
                return tombstones
            default:
                throw DatabaseError.stepFailed(database.lastError)
            }
        }
    }

    func restore(id: UUID) async throws {
        let database = try writableDatabase()
        try withRepositoryTransaction(database) {
            let statement = try prepared(
                """
                UPDATE clipboard_items SET deleted_at = NULL
                WHERE id = ? AND deleted_at IS NOT NULL
                """,
                bindings: [.string(id.uuidString)],
                database: database
            )
            defer { sqlite3_finalize(statement) }
            try database.stepExpectingDone(statement)
            try requireChanged(id: id, database: database)
        }
    }

    func purgeDeleted(id: UUID) async throws {
        let database = try writableDatabase()
        try withRepositoryTransaction(database) {
            let statement = try prepared(
                "DELETE FROM clipboard_items WHERE id = ? AND deleted_at IS NOT NULL",
                bindings: [.string(id.uuidString)],
                database: database
            )
            defer { sqlite3_finalize(statement) }
            try database.stepExpectingDone(statement)
            if try changes(database) == 0,
               try rowExists(id: id, database: database) == false {
                throw DatabaseError.itemNotFound(id)
            }
        }
    }

    func purgeDeleted(before: Date) async throws -> Int {
        let database = try writableDatabase()
        return try withRepositoryTransaction(database) {
            let statement = try prepared(
                "DELETE FROM clipboard_items WHERE deleted_at IS NOT NULL AND deleted_at < ?",
                bindings: [.double(before.timeIntervalSince1970)],
                database: database
            )
            defer { sqlite3_finalize(statement) }
            try database.stepExpectingDone(statement)
            return try changes(database)
        }
    }

    func countForCleanup(retention: RetentionPolicy, now: Date) async throws -> Int {
        let database = try readableDatabase()
        guard let cutoff = try cleanupCutoff(retention: retention, now: now) else { return 0 }
        if case .legacy = recoveryLayout {
            return try loadLegacyItems(database: database).filter {
                $0.deletedAt == nil && !$0.isFavorite && $0.lastCopiedAt < cutoff
            }.count
        }
        return try cleanupCount(cutoff: cutoff, database: database)
    }

    func cleanup(retention: RetentionPolicy, now: Date) async throws -> Int {
        let database = try writableDatabase()
        guard let cutoff = try cleanupCutoff(retention: retention, now: now) else { return 0 }
        return try withRepositoryTransaction(database) {
            let count = try cleanupCount(cutoff: cutoff, database: database)
            let statement = try prepared(
                """
                DELETE FROM clipboard_items
                WHERE deleted_at IS NULL AND is_favorite = 0 AND last_copied_at < ?
                """,
                bindings: [.double(cutoff.timeIntervalSince1970)],
                database: database
            )
            defer { sqlite3_finalize(statement) }
            try database.stepExpectingDone(statement)
            return count
        }
    }

    func countAllClips() async throws -> Int {
        let database = try readableDatabase()
        if case .legacy = recoveryLayout {
            return try loadLegacyItems(database: database).count
        }
        return try scalarInt("SELECT COUNT(*) FROM clipboard_items", database: database)
    }

    func deleteAllClipboardData() async throws -> Int {
        let database = try writableDatabase()
        return try withRepositoryTransaction(database) {
            let count = try scalarInt("SELECT COUNT(*) FROM clipboard_items", database: database)
            try database.execute("DELETE FROM clipboard_items")
            try database.execute("DELETE FROM ai_usage")
            return count
        }
    }

    func fetchCategories() async throws -> [PersistedCustomCategory] {
        let database = try readableDatabase()
        if case .legacy = recoveryLayout { return recoveryCategories }
        return try loadCanonicalCategories(database: database)
    }

    func saveCategory(_ category: PersistedCustomCategory) async throws {
        let database = try writableDatabase()
        guard let name = Self.nonemptyTrimmed(category.name) else {
            throw DatabaseError.stepFailed("custom category name must not be empty")
        }
        let normalizedName = Self.normalizeCategoryName(name)
        try withRepositoryTransaction(database) {
            if try categoryID(
                normalizedName: normalizedName,
                excluding: category.id,
                database: database
            ) != nil {
                throw DatabaseError.stepFailed("custom category name is already in use")
            }

            let statement = try prepared(
                """
                INSERT INTO custom_categories (
                    id, name, normalized_name, prompt, sort_order, is_enabled, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    normalized_name = excluded.normalized_name,
                    prompt = excluded.prompt,
                    sort_order = excluded.sort_order,
                    is_enabled = excluded.is_enabled,
                    created_at = excluded.created_at,
                    updated_at = excluded.updated_at
                """,
                bindings: [
                    .string(category.id.uuidString),
                    .string(name),
                    .string(normalizedName),
                    .string(category.prompt),
                    .int(category.sortOrder),
                    .bool(category.isEnabled),
                    .double(category.createdAt.timeIntervalSince1970),
                    .double(category.updatedAt.timeIntervalSince1970)
                ],
                database: database
            )
            defer { sqlite3_finalize(statement) }
            try database.stepExpectingDone(statement)
        }
    }

    func reorderCategories(ids: [UUID]) async throws {
        let database = try writableDatabase()
        try withRepositoryTransaction(database) {
            let existing = try Set(loadCanonicalCategories(database: database).map(\.id))
            if let missingID = ids.first(where: { !existing.contains($0) }) {
                throw DatabaseError.itemNotFound(missingID)
            }
            guard ids.count == existing.count,
                  Set(ids).count == ids.count,
                  Set(ids) == existing else {
                throw DatabaseError.stepFailed(
                    "category reorder must contain every category exactly once"
                )
            }

            for (sortOrder, id) in ids.enumerated() {
                let statement = try prepared(
                    "UPDATE custom_categories SET sort_order = ? WHERE id = ?",
                    bindings: [.int(sortOrder), .string(id.uuidString)],
                    database: database
                )
                defer { sqlite3_finalize(statement) }
                try database.stepExpectingDone(statement)
            }
        }
    }

    func deleteCategory(id: UUID, migrateTo replacementID: UUID?) async throws {
        let database = try writableDatabase()
        try withRepositoryTransaction(database) {
            guard try categoryExists(id: id, database: database) else {
                throw DatabaseError.itemNotFound(id)
            }
            if let replacementID {
                guard replacementID != id,
                      try categoryExists(id: replacementID, database: database) else {
                    throw DatabaseError.itemNotFound(replacementID)
                }
            }

            let update = try prepared(
                "UPDATE clipboard_items SET custom_category_id = ? WHERE custom_category_id = ?",
                bindings: [
                    .optionalString(replacementID?.uuidString),
                    .string(id.uuidString)
                ],
                database: database
            )
            defer { sqlite3_finalize(update) }
            try database.stepExpectingDone(update)

            let delete = try prepared(
                "DELETE FROM custom_categories WHERE id = ?",
                bindings: [.string(id.uuidString)],
                database: database
            )
            defer { sqlite3_finalize(delete) }
            try database.stepExpectingDone(delete)
        }
    }

    func addAIUsage(_ record: AIUsageRecord) async throws {
        let database = try writableDatabase()
        try withRepositoryTransaction(database) {
            let insert = try prepared(
                """
                INSERT INTO ai_usage (
                    id, operation, timestamp, provider, model, duration_ms, succeeded, error_code
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    operation = excluded.operation,
                    timestamp = excluded.timestamp,
                    provider = excluded.provider,
                    model = excluded.model,
                    duration_ms = excluded.duration_ms,
                    succeeded = excluded.succeeded,
                    error_code = excluded.error_code
                """,
                bindings: [
                    .string(record.id.uuidString),
                    .string(record.operation.rawValue),
                    .double(record.timestamp.timeIntervalSince1970),
                    .string(record.provider),
                    .string(record.model),
                    .int(record.durationMilliseconds),
                    .bool(record.succeeded),
                    .optionalString(record.errorCode)
                ],
                database: database
            )
            defer { sqlite3_finalize(insert) }
            try database.stepExpectingDone(insert)

            let trim = try prepared(
                """
                DELETE FROM ai_usage
                WHERE id NOT IN (
                    SELECT id FROM ai_usage
                    ORDER BY timestamp DESC, id DESC
                    LIMIT ?
                )
                """,
                bindings: [.int(200)],
                database: database
            )
            defer { sqlite3_finalize(trim) }
            try database.stepExpectingDone(trim)
        }
    }

    func fetchAIUsage(limit: Int) async throws -> [AIUsageRecord] {
        let database = try readableDatabase()
        let safeLimit = min(max(limit, 0), 200)
        guard safeLimit > 0 else { return [] }
        if case .legacy = recoveryLayout { return [] }
        let statement = try prepared(
            """
            SELECT id, operation, timestamp, provider, model, duration_ms, succeeded, error_code
            FROM ai_usage
            ORDER BY timestamp DESC, id DESC
            LIMIT ?
            """,
            bindings: [.int(safeLimit)],
            database: database
        )
        defer { sqlite3_finalize(statement) }

        var records: [AIUsageRecord] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                records.append(try mapUsage(statement, database: database))
            case SQLITE_DONE:
                return records
            default:
                throw DatabaseError.stepFailed(database.lastError)
            }
        }
    }

    func clearAIUsage() async throws {
        let database = try writableDatabase()
        try withRepositoryTransaction(database) {
            try database.execute("DELETE FROM ai_usage")
        }
    }
}

private extension ClipboardRepository {
    enum RecoveryLayout {
        case canonical
        case legacy(columns: Set<String>)
    }

    struct RecoveryInspection {
        var layout: RecoveryLayout
        var categories: [PersistedCustomCategory]
    }

    enum SQLBinding {
        case string(String)
        case optionalString(String?)
        case double(Double)
        case int(Int)
        case bool(Bool)
    }

    struct HashCandidate {
        var id: UUID
        var content: String
    }

    struct QueryPredicate {
        var sql: String
        var bindings: [SQLBinding]
    }

    func readableDatabase() throws -> SQLiteDatabase {
        guard startup != nil else {
            throw DatabaseError.openFailed("clipboard repository is not prepared")
        }
        guard let database else {
            throw DatabaseError.openFailed("clipboard repository connection is unavailable")
        }
        return database
    }

    func requireWritableStartup() throws {
        switch startup {
        case .readWrite:
            return
        case .readOnlyRecovery(let databaseURL, let backupURL, _):
            throw DatabaseError.readOnlyRecovery(
                databaseURL: databaseURL,
                backupURL: backupURL
            )
        case nil:
            throw DatabaseError.openFailed("clipboard repository is not prepared")
        }
    }

    func writableDatabase() throws -> SQLiteDatabase {
        try requireWritableStartup()
        guard let database else {
            throw DatabaseError.openFailed("clipboard repository connection is unavailable")
        }
        return database
    }

    func withRepositoryTransaction<T>(
        _ database: SQLiteDatabase,
        operation: () throws -> T
    ) throws -> T {
        try database.execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let result = try operation()
            if let hook = preCommitPermissionHookForTesting {
                preCommitPermissionHookForTesting = nil
                try hook()
            }
            try database.execute("COMMIT")
            return result
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    func verifyPrivateDatabaseFilePermissions(_ database: SQLiteDatabase) throws {
        let fileManager = FileManager.default
        let candidates = [
            database.url,
            URL(fileURLWithPath: database.url.path + "-wal"),
            URL(fileURLWithPath: database.url.path + "-shm")
        ]

        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            let attributes = try fileManager.attributesOfItem(atPath: candidate.path)
            guard let permissions = attributes[.posixPermissions] as? NSNumber,
                  permissions.intValue & 0o777 == 0o600 else {
                throw DatabaseError.stepFailed("database file permissions are not private")
            }
        }
    }

    func prepared(
        _ sql: String,
        bindings: [SQLBinding] = [],
        database: SQLiteDatabase
    ) throws -> OpaquePointer? {
        let statement = try database.prepare(sql)
        do {
            for (offset, binding) in bindings.enumerated() {
                let index = Int32(offset + 1)
                switch binding {
                case .string(let value):
                    try database.bind(value, at: index, to: statement)
                case .optionalString(let value):
                    try database.bind(value, at: index, to: statement)
                case .double(let value):
                    try database.bind(value, at: index, to: statement)
                case .int(let value):
                    try database.bind(value, at: index, to: statement)
                case .bool(let value):
                    try database.bind(value, at: index, to: statement)
                }
            }
            return statement
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
    }

    func scalarInt(
        _ sql: String,
        bindings: [SQLBinding] = [],
        database: SQLiteDatabase
    ) throws -> Int {
        let statement = try prepared(sql, bindings: bindings, database: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.stepFailed(database.lastError)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func scalarText(_ sql: String, database: SQLiteDatabase) throws -> String? {
        let statement = try prepared(sql, database: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.stepFailed(database.lastError)
        }
        return database.columnString(statement, at: 0)
    }

    func changes(_ database: SQLiteDatabase) throws -> Int {
        try scalarInt("SELECT changes()", database: database)
    }

    func requireChanged(id: UUID, database: SQLiteDatabase) throws {
        guard try changes(database) > 0 else {
            throw DatabaseError.itemNotFound(id)
        }
    }

    func mapCanonicalItem(
        _ statement: OpaquePointer?,
        database: SQLiteDatabase
    ) throws -> ClipboardItem {
        guard let idText = database.columnString(statement, at: 0),
              let id = UUID(uuidString: idText),
              let content = database.columnString(statement, at: 1),
              let categoryText = database.columnString(statement, at: 2) else {
            throw DatabaseError.stepFailed("invalid clipboard row")
        }

        let customCategoryID: UUID?
        if let customIDText = database.columnString(statement, at: 3) {
            guard let parsed = UUID(uuidString: customIDText) else {
                throw DatabaseError.stepFailed("invalid clipboard category reference")
            }
            customCategoryID = parsed
        } else {
            customCategoryID = nil
        }

        let deletedAt: Date?
        if sqlite3_column_type(statement, 10) == SQLITE_NULL {
            deletedAt = nil
        } else {
            deletedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 10))
        }

        return ClipboardItem(
            id: id,
            content: content,
            category: ClipboardItem.Category(rawValue: categoryText) ?? .other,
            customCategoryID: customCategoryID,
            customCategory: database.columnString(statement, at: 4),
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            copyCount: Int(sqlite3_column_int64(statement, 7)),
            isFavorite: sqlite3_column_int(statement, 8) != 0,
            aiSummary: database.columnString(statement, at: 9),
            deletedAt: deletedAt
        )
    }

    func canonicalItem(
        id: UUID,
        activeOnly: Bool,
        database: SQLiteDatabase
    ) throws -> ClipboardItem? {
        let activePredicate = activeOnly ? "AND i.deleted_at IS NULL" : ""
        let statement = try prepared(
            """
            SELECT i.id, i.content, i.builtin_category, i.custom_category_id, c.name,
                   i.created_at, i.last_copied_at, i.copy_count, i.is_favorite,
                   i.ai_summary, i.deleted_at
            FROM clipboard_items i
            LEFT JOIN custom_categories c ON c.id = i.custom_category_id
            WHERE i.id = ? \(activePredicate)
            LIMIT 1
            """,
            bindings: [.string(id.uuidString)],
            database: database
        )
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try mapCanonicalItem(statement, database: database)
        case SQLITE_DONE:
            return nil
        default:
            throw DatabaseError.stepFailed(database.lastError)
        }
    }

    func requireCanonicalItem(id: UUID, database: SQLiteDatabase) throws -> ClipboardItem {
        guard let item = try canonicalItem(id: id, activeOnly: true, database: database) else {
            throw DatabaseError.itemNotFound(id)
        }
        return item
    }

    func matchingHashCandidates(
        _ hash: String,
        database: SQLiteDatabase
    ) throws -> [HashCandidate] {
        let statement = try prepared(
            """
            SELECT id, content FROM clipboard_items
            WHERE content_hash = ? AND deleted_at IS NULL
            """,
            bindings: [.string(hash)],
            database: database
        )
        defer { sqlite3_finalize(statement) }

        var candidates: [HashCandidate] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let idText = database.columnString(statement, at: 0),
                      let id = UUID(uuidString: idText),
                      let content = database.columnString(statement, at: 1) else {
                    throw DatabaseError.stepFailed("invalid clipboard hash candidate")
                }
                candidates.append(HashCandidate(id: id, content: content))
            case SQLITE_DONE:
                return candidates
            default:
                throw DatabaseError.stepFailed(database.lastError)
            }
        }
    }

    func rowExists(id: UUID, database: SQLiteDatabase) throws -> Bool {
        try scalarInt(
            "SELECT COUNT(*) FROM clipboard_items WHERE id = ?",
            bindings: [.string(id.uuidString)],
            database: database
        ) > 0
    }

    func setSummarySynchronously(
        id: UUID,
        summary: String?,
        database: SQLiteDatabase
    ) throws -> ClipboardItem {
        let statement = try prepared(
            """
            UPDATE clipboard_items SET ai_summary = ?
            WHERE id = ? AND deleted_at IS NULL
            """,
            bindings: [.optionalString(summary), .string(id.uuidString)],
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try database.stepExpectingDone(statement)
        try requireChanged(id: id, database: database)
        return try requireCanonicalItem(id: id, database: database)
    }

    func setCustomCategorySynchronously(
        id: UUID,
        categoryID: UUID?,
        database: SQLiteDatabase
    ) throws -> ClipboardItem {
        guard try canonicalItem(id: id, activeOnly: true, database: database) != nil else {
            throw DatabaseError.itemNotFound(id)
        }
        if let categoryID,
           try categoryExists(id: categoryID, database: database) == false {
            throw DatabaseError.itemNotFound(categoryID)
        }
        let statement = try prepared(
            """
            UPDATE clipboard_items SET custom_category_id = ?
            WHERE id = ? AND deleted_at IS NULL
            """,
            bindings: [
                .optionalString(categoryID?.uuidString),
                .string(id.uuidString)
            ],
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try database.stepExpectingDone(statement)
        try requireChanged(id: id, database: database)
        return try requireCanonicalItem(id: id, database: database)
    }

    func cleanupCutoff(retention: RetentionPolicy, now: Date) throws -> Date? {
        switch retention {
        case .forever:
            return nil
        case .days(let days):
            guard (1...365).contains(days) else {
                throw ValidationError.invalidRetentionDays(days)
            }
            return now.addingTimeInterval(-Double(days) * 86_400)
        }
    }

    func cleanupCount(cutoff: Date, database: SQLiteDatabase) throws -> Int {
        try scalarInt(
            """
            SELECT COUNT(*) FROM clipboard_items
            WHERE deleted_at IS NULL AND is_favorite = 0 AND last_copied_at < ?
            """,
            bindings: [.double(cutoff.timeIntervalSince1970)],
            database: database
        )
    }

    func loadCanonicalCategories(
        database: SQLiteDatabase
    ) throws -> [PersistedCustomCategory] {
        let statement = try prepared(
            """
            SELECT id, name, prompt, sort_order, is_enabled, created_at, updated_at
            FROM custom_categories
            ORDER BY sort_order ASC, id ASC
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }

        var categories: [PersistedCustomCategory] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let idText = database.columnString(statement, at: 0),
                      let id = UUID(uuidString: idText),
                      let name = database.columnString(statement, at: 1),
                      let prompt = database.columnString(statement, at: 2) else {
                    throw DatabaseError.stepFailed("invalid custom category row")
                }
                categories.append(
                    PersistedCustomCategory(
                        id: id,
                        name: name,
                        prompt: prompt,
                        sortOrder: Int(sqlite3_column_int64(statement, 3)),
                        isEnabled: sqlite3_column_int(statement, 4) != 0,
                        createdAt: Date(
                            timeIntervalSince1970: sqlite3_column_double(statement, 5)
                        ),
                        updatedAt: Date(
                            timeIntervalSince1970: sqlite3_column_double(statement, 6)
                        )
                    )
                )
            case SQLITE_DONE:
                return categories
            default:
                throw DatabaseError.stepFailed(database.lastError)
            }
        }
    }

    func categoryExists(id: UUID, database: SQLiteDatabase) throws -> Bool {
        try scalarInt(
            "SELECT COUNT(*) FROM custom_categories WHERE id = ?",
            bindings: [.string(id.uuidString)],
            database: database
        ) > 0
    }

    func categoryID(
        normalizedName: String,
        excluding excludedID: UUID,
        database: SQLiteDatabase
    ) throws -> UUID? {
        let statement = try prepared(
            """
            SELECT id FROM custom_categories
            WHERE normalized_name = ? AND id <> ?
            LIMIT 1
            """,
            bindings: [.string(normalizedName), .string(excludedID.uuidString)],
            database: database
        )
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard let idText = database.columnString(statement, at: 0),
                  let id = UUID(uuidString: idText) else {
                throw DatabaseError.stepFailed("invalid custom category row")
            }
            return id
        case SQLITE_DONE:
            return nil
        default:
            throw DatabaseError.stepFailed(database.lastError)
        }
    }

    func mapUsage(
        _ statement: OpaquePointer?,
        database: SQLiteDatabase
    ) throws -> AIUsageRecord {
        guard let idText = database.columnString(statement, at: 0),
              let id = UUID(uuidString: idText),
              let operationText = database.columnString(statement, at: 1),
              let operation = AIOperation(rawValue: operationText),
              let provider = database.columnString(statement, at: 3),
              let model = database.columnString(statement, at: 4) else {
            throw DatabaseError.stepFailed("invalid AI usage row")
        }
        return AIUsageRecord(
            id: id,
            operation: operation,
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            provider: provider,
            model: model,
            durationMilliseconds: Int(sqlite3_column_int64(statement, 5)),
            succeeded: sqlite3_column_int(statement, 6) != 0,
            errorCode: database.columnString(statement, at: 7)
        )
    }
}

private extension ClipboardRepository {
    func fetchCanonicalPage(
        _ query: ClipQuery,
        database: SQLiteDatabase
    ) throws -> ClipPage {
        let search = RepositorySearchPlan.make(searchText: query.searchText, mode: searchMode)
        guard case .fts = search else {
            return try runCanonicalPage(query, search: search, database: database)
        }

        do {
            return try runCanonicalPage(query, search: search, database: database)
        } catch let error as DatabaseError where Self.isFTSQueryError(error) {
            let fallback = RepositorySearchPlan.make(
                searchText: query.searchText,
                mode: .parameterizedContains
            )
            return try runCanonicalPage(query, search: fallback, database: database)
        }
    }

    func runCanonicalPage(
        _ query: ClipQuery,
        search: RepositorySearchPlan,
        database: SQLiteDatabase
    ) throws -> ClipPage {
        let predicate = canonicalPredicate(query, search: search)
        let totalCount = try scalarInt(
            """
            SELECT COUNT(*)
            FROM clipboard_items i
            LEFT JOIN custom_categories c ON c.id = i.custom_category_id
            WHERE \(predicate.sql)
            """,
            bindings: predicate.bindings,
            database: database
        )
        let limit = min(max(query.limit, 0), 100)
        let offset = max(query.offset, 0)
        guard limit > 0 else {
            return ClipPage(items: [], nextOffset: nil, totalCount: totalCount)
        }

        let statement = try prepared(
            """
            SELECT i.id, i.content, i.builtin_category, i.custom_category_id, c.name,
                   i.created_at, i.last_copied_at, i.copy_count, i.is_favorite,
                   i.ai_summary, i.deleted_at
            FROM clipboard_items i
            LEFT JOIN custom_categories c ON c.id = i.custom_category_id
            WHERE \(predicate.sql)
            ORDER BY i.last_copied_at DESC, i.id DESC
            LIMIT ? OFFSET ?
            """,
            bindings: predicate.bindings + [.int(limit), .int(offset)],
            database: database
        )
        defer { sqlite3_finalize(statement) }

        var items: [ClipboardItem] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                items.append(try mapCanonicalItem(statement, database: database))
            case SQLITE_DONE:
                let consumed = offset + items.count
                return ClipPage(
                    items: items,
                    nextOffset: consumed < totalCount ? consumed : nil,
                    totalCount: totalCount
                )
            default:
                throw DatabaseError.stepFailed(database.lastError)
            }
        }
    }

    func canonicalPredicate(
        _ query: ClipQuery,
        search: RepositorySearchPlan
    ) -> QueryPredicate {
        var clauses = ["i.deleted_at IS NULL"]
        var bindings: [SQLBinding] = []

        switch search {
        case .unfiltered:
            break
        case .fts(let expression, _):
            clauses.append(
                "i.rowid IN (SELECT rowid FROM clip_search WHERE clip_search MATCH ?)"
            )
            bindings.append(.string(expression))
        case .parameterizedContains(let text, let escapedPattern):
            clauses.append("(? = '' OR lower(i.content) LIKE lower(?) ESCAPE '\\')")
            bindings.append(.string(text))
            bindings.append(.string(escapedPattern))
        }

        switch query.scope {
        case .all:
            break
        case .favorites:
            clauses.append("i.is_favorite = 1")
        case .today:
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: Date())
            let end = calendar.date(byAdding: .day, value: 1, to: start)
                ?? start.addingTimeInterval(86_400)
            clauses.append("i.last_copied_at >= ? AND i.last_copied_at < ?")
            bindings.append(.double(start.timeIntervalSince1970))
            bindings.append(.double(end.timeIntervalSince1970))
        case .builtIn(let category):
            clauses.append("i.builtin_category = ?")
            bindings.append(.string(category.rawValue))
        case .custom(let id):
            clauses.append("i.custom_category_id = ?")
            bindings.append(.string(id.uuidString))
        }

        return QueryPredicate(sql: clauses.joined(separator: " AND "), bindings: bindings)
    }

    func inspectRecovery(
        database: SQLiteDatabase,
        legacyCategories: [PersistedCustomCategory]
    ) throws -> RecoveryInspection {
        guard try scalarText("PRAGMA integrity_check", database: database) == "ok" else {
            throw DatabaseError.prepareFailed("database integrity check failed")
        }
        let columns = try database.columnNames(in: "clipboard_items")
        if columns == Self.canonicalColumns {
            guard try objectExists(type: "table", name: "custom_categories", database: database),
                  try objectExists(type: "table", name: "ai_usage", database: database) else {
                throw DatabaseError.prepareFailed("canonical recovery schema is incomplete")
            }
            return RecoveryInspection(
                layout: .canonical,
                categories: try loadCanonicalCategories(database: database)
            )
        }

        guard Self.legacyRequiredColumns.isSubset(of: columns) else {
            throw DatabaseError.prepareFailed("legacy recovery schema is unreadable")
        }
        let categories = try recoveryCategoryList(
            database: database,
            columns: columns,
            legacyCategories: legacyCategories
        )
        return RecoveryInspection(layout: .legacy(columns: columns), categories: categories)
    }

    func objectExists(
        type: String,
        name: String,
        database: SQLiteDatabase
    ) throws -> Bool {
        try scalarInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = ? AND name = ?",
            bindings: [.string(type), .string(name)],
            database: database
        ) > 0
    }

    func recoveryCategoryList(
        database: SQLiteDatabase,
        columns: Set<String>,
        legacyCategories: [PersistedCustomCategory]
    ) throws -> [PersistedCustomCategory] {
        var byName: [String: PersistedCustomCategory] = [:]
        for category in legacyCategories.sorted(by: Self.categoryOrder) {
            guard let name = Self.nonemptyTrimmed(category.name) else { continue }
            let normalized = Self.normalizeCategoryName(name)
            guard byName[normalized] == nil else { continue }
            var sanitized = category
            sanitized.name = name
            byName[normalized] = sanitized
        }

        guard columns.contains("custom_category") else {
            return byName.values.sorted(by: Self.categoryOrder)
        }
        let statement = try prepared(
            """
            SELECT DISTINCT custom_category FROM clipboard_items
            WHERE custom_category IS NOT NULL
            ORDER BY custom_category ASC
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        var nextSortOrder = (byName.values.map(\.sortOrder).max() ?? -1) + 1
        let recoveredAt = Date(timeIntervalSince1970: 0)

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let raw = database.columnString(statement, at: 0),
                      let name = Self.nonemptyTrimmed(raw) else { continue }
                let normalized = Self.normalizeCategoryName(name)
                guard byName[normalized] == nil else { continue }
                byName[normalized] = PersistedCustomCategory(
                    id: Self.stableRecoveredCategoryID(normalizedName: normalized),
                    name: name,
                    prompt: "",
                    sortOrder: nextSortOrder,
                    isEnabled: false,
                    createdAt: recoveredAt,
                    updatedAt: recoveredAt
                )
                nextSortOrder += 1
            case SQLITE_DONE:
                return byName.values.sorted(by: Self.categoryOrder)
            default:
                throw DatabaseError.stepFailed(database.lastError)
            }
        }
    }

    func loadLegacyItems(database: SQLiteDatabase) throws -> [ClipboardItem] {
        guard case .legacy(let columns) = recoveryLayout else { return [] }
        let category = columns.contains("category") ? "category" : "'other'"
        let custom = columns.contains("custom_category") ? "custom_category" : "NULL"
        let summary = columns.contains("ai_summary") ? "ai_summary" : "NULL"
        let created = columns.contains("created_at") ? "created_at" : "timestamp"
        let lastCopied = columns.contains("last_copied_at") ? "last_copied_at" : "timestamp"
        let copyCount = columns.contains("copy_count") ? "copy_count" : "1"
        let deleted = columns.contains("deleted_at") ? "deleted_at" : "NULL"
        let statement = try prepared(
            """
            SELECT id, content, \(category), \(custom), \(created), \(lastCopied),
                   \(copyCount), is_favorite, \(summary), \(deleted)
            FROM clipboard_items
            ORDER BY rowid ASC
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }

        var items: [ClipboardItem] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let idText = database.columnString(statement, at: 0),
                      let id = UUID(uuidString: idText),
                      let content = database.columnString(statement, at: 1),
                      let categoryText = database.columnString(statement, at: 2) else {
                    throw DatabaseError.stepFailed("invalid legacy clipboard row")
                }
                let rawCustomName = database.columnString(statement, at: 3)
                    .flatMap(Self.nonemptyTrimmed)
                let customCategory = rawCustomName.flatMap {
                    recoveryCategoryByNormalizedName[Self.normalizeCategoryName($0)]
                }
                let deletedAt: Date?
                if sqlite3_column_type(statement, 9) == SQLITE_NULL {
                    deletedAt = nil
                } else {
                    deletedAt = Date(
                        timeIntervalSince1970: sqlite3_column_double(statement, 9)
                    )
                }
                items.append(
                    ClipboardItem(
                        id: id,
                        content: content,
                        category: ClipboardItem.Category(rawValue: categoryText) ?? .other,
                        customCategoryID: customCategory?.id,
                        customCategory: customCategory?.name ?? rawCustomName,
                        timestamp: Date(
                            timeIntervalSince1970: sqlite3_column_double(statement, 5)
                        ),
                        createdAt: Date(
                            timeIntervalSince1970: sqlite3_column_double(statement, 4)
                        ),
                        copyCount: max(Int(sqlite3_column_int64(statement, 6)), 1),
                        isFavorite: sqlite3_column_int(statement, 7) != 0,
                        aiSummary: database.columnString(statement, at: 8),
                        deletedAt: deletedAt
                    )
                )
            case SQLITE_DONE:
                return items
            default:
                throw DatabaseError.stepFailed(database.lastError)
            }
        }
    }

    func fetchLegacyPage(
        _ query: ClipQuery,
        database: SQLiteDatabase
    ) throws -> ClipPage {
        let search = query.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let todayEnd = calendar.date(byAdding: .day, value: 1, to: todayStart)
            ?? todayStart.addingTimeInterval(86_400)
        let filtered = try loadLegacyItems(database: database).filter { item in
            guard item.deletedAt == nil else { return false }
            if !search.isEmpty,
               item.content.range(
                   of: search,
                   options: [.caseInsensitive, .diacriticInsensitive]
               ) == nil {
                return false
            }
            switch query.scope {
            case .all:
                return true
            case .favorites:
                return item.isFavorite
            case .today:
                return item.lastCopiedAt >= todayStart && item.lastCopiedAt < todayEnd
            case .builtIn(let category):
                return item.category == category
            case .custom(let id):
                return item.customCategoryID == id
            }
        }.sorted {
            if $0.lastCopiedAt != $1.lastCopiedAt {
                return $0.lastCopiedAt > $1.lastCopiedAt
            }
            return $0.id.uuidString > $1.id.uuidString
        }

        let totalCount = filtered.count
        let limit = min(max(query.limit, 0), 100)
        let offset = min(max(query.offset, 0), totalCount)
        guard limit > 0 else {
            return ClipPage(items: [], nextOffset: nil, totalCount: totalCount)
        }
        let end = min(offset + limit, totalCount)
        let items = Array(filtered[offset..<end])
        return ClipPage(
            items: items,
            nextOffset: end < totalCount ? end : nil,
            totalCount: totalCount
        )
    }
}

private extension ClipboardRepository {
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

    static func categoryOrder(
        _ lhs: PersistedCustomCategory,
        _ rhs: PersistedCustomCategory
    ) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    static func backupURL(from error: Error) -> URL? {
        switch error {
        case DatabaseError.migrationFailed(_, _, let backupURL):
            return backupURL
        case DatabaseError.readOnlyRecovery(_, let backupURL):
            return backupURL
        default:
            return nil
        }
    }

    static func errorCode(for error: Error) -> String {
        switch error {
        case DatabaseError.migrationFailed:
            return "migration_failed"
        case DatabaseError.readOnlyRecovery:
            return "read_only_recovery"
        case DatabaseError.openFailed:
            return "open_failed"
        case DatabaseError.prepareFailed:
            return "prepare_failed"
        case DatabaseError.stepFailed:
            return "step_failed"
        case DatabaseError.itemNotFound:
            return "item_not_found"
        default:
            return "database_failed"
        }
    }

    static func isFTSQueryError(_ error: DatabaseError) -> Bool {
        let message: String
        switch error {
        case .prepareFailed(let value), .stepFailed(let value):
            message = value.lowercased()
        default:
            return false
        }
        return message.contains("fts5")
            || message.contains("malformed match")
            || message.contains("syntax error")
    }
}
