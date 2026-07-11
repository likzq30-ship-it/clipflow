import Foundation
import SQLite3

final class SQLiteDatabase {
    let url: URL
    let readOnly: Bool

    var statementInterceptorForTesting: ((String) throws -> Void)?

    private var handle: OpaquePointer?

    init(url: URL, readOnly: Bool = false) throws {
        self.url = url
        self.readOnly = readOnly

        let flags: Int32
        if readOnly {
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        } else {
            flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        }

        var connection: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &connection, flags, nil)
        guard result == SQLITE_OK, let connection else {
            let message = connection.flatMap(sqlite3_errmsg).map(String.init(cString:))
                ?? "SQLite error \(result)"
            if let connection {
                sqlite3_close_v2(connection)
            }
            throw DatabaseError.openFailed(message)
        }

        handle = connection
        sqlite3_extended_result_codes(connection, 1)
        sqlite3_busy_timeout(connection, 5_000)
    }

    deinit {
        close()
    }

    func close() {
        guard let handle else { return }
        sqlite3_close_v2(handle)
        self.handle = nil
    }

    var lastError: String {
        guard let handle, let message = sqlite3_errmsg(handle) else { return "unknown SQLite error" }
        return String(cString: message)
    }

    func execute(_ sql: String) throws {
        try statementInterceptorForTesting?(sql)
        let connection = try requireHandle()
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? lastError
            sqlite3_free(errorMessage)
            throw DatabaseError.stepFailed(message)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer? {
        try statementInterceptorForTesting?(sql)
        let connection = try requireHandle()
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard result == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw DatabaseError.prepareFailed(lastError)
        }
        return statement
    }

    func stepExpectingDone(_ statement: OpaquePointer?) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw DatabaseError.stepFailed(lastError)
        }
    }

    func bind(_ value: String, at index: Int32, to statement: OpaquePointer?) throws {
        let bytes = value.utf8CString
        let result = bytes.withUnsafeBufferPointer { buffer in
            sqlite3_bind_text(
                statement,
                index,
                buffer.baseAddress,
                Int32(bytes.count - 1),
                sqliteTransient
            )
        }
        try requireSuccessfulBind(result)
    }

    func bind(_ value: String?, at index: Int32, to statement: OpaquePointer?) throws {
        guard let value else {
            try requireSuccessfulBind(sqlite3_bind_null(statement, index))
            return
        }
        try bind(value, at: index, to: statement)
    }

    func bind(_ value: Double, at index: Int32, to statement: OpaquePointer?) throws {
        try requireSuccessfulBind(sqlite3_bind_double(statement, index, value))
    }

    func bind(_ value: Double?, at index: Int32, to statement: OpaquePointer?) throws {
        guard let value else {
            try requireSuccessfulBind(sqlite3_bind_null(statement, index))
            return
        }
        try bind(value, at: index, to: statement)
    }

    func bind(_ value: Int, at index: Int32, to statement: OpaquePointer?) throws {
        try requireSuccessfulBind(sqlite3_bind_int64(statement, index, sqlite3_int64(value)))
    }

    func bind(_ value: Bool, at index: Int32, to statement: OpaquePointer?) throws {
        try bind(value ? 1 : 0, at: index, to: statement)
    }

    func columnString(_ statement: OpaquePointer?, at index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let byteCount = Int(sqlite3_column_bytes(statement, index))
        guard byteCount > 0 else { return "" }
        guard let bytes = sqlite3_column_text(statement, index) else { return nil }
        return String(
            decoding: UnsafeBufferPointer(start: bytes, count: byteCount),
            as: UTF8.self
        )
    }

    func columnNames(in table: String) throws -> Set<String> {
        let quotedTable = table.replacingOccurrences(of: "\"", with: "\"\"")
        let statement = try prepare("PRAGMA table_info(\"\(quotedTable)\")")
        defer { sqlite3_finalize(statement) }

        var names = Set<String>()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let name = columnString(statement, at: 1) {
                    names.insert(name)
                }
            case SQLITE_DONE:
                return names
            default:
                throw DatabaseError.stepFailed(lastError)
            }
        }
    }

    func withTransaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let result = try operation()
            try execute("COMMIT")
            try applyPrivateFilePermissions()
            return result
        } catch {
            try? execute("ROLLBACK")
            try? applyPrivateFilePermissions()
            throw error
        }
    }

    func applyPrivateFilePermissions() throws {
        let fileManager = FileManager.default
        for candidate in [
            url,
            URL(fileURLWithPath: url.path + "-wal"),
            URL(fileURLWithPath: url.path + "-shm")
        ] where fileManager.fileExists(atPath: candidate.path) {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: candidate.path
            )
        }
    }

    func onlineBackup(to destinationURL: URL) throws {
        let source = try requireHandle()
        var destination: OpaquePointer?
        let openResult = sqlite3_open_v2(
            destinationURL.path,
            &destination,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let destination else {
            let message = destination.flatMap(sqlite3_errmsg).map(String.init(cString:))
                ?? "SQLite error \(openResult)"
            if let destination {
                sqlite3_close_v2(destination)
            }
            throw DatabaseError.openFailed(message)
        }
        defer {
            sqlite3_close_v2(destination)
            let fileManager = FileManager.default
            for sidecar in [
                URL(fileURLWithPath: destinationURL.path + "-wal"),
                URL(fileURLWithPath: destinationURL.path + "-shm")
            ] where fileManager.fileExists(atPath: sidecar.path) {
                try? fileManager.removeItem(at: sidecar)
            }
        }

        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(destination)))
        }

        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(destination))
            throw DatabaseError.stepFailed(message)
        }

        var errorMessage: UnsafeMutablePointer<CChar>?
        let journalResult = sqlite3_exec(
            destination,
            "PRAGMA journal_mode = DELETE",
            nil,
            nil,
            &errorMessage
        )
        guard journalResult == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(destination))
            sqlite3_free(errorMessage)
            throw DatabaseError.stepFailed(message)
        }
    }

    private func requireHandle() throws -> OpaquePointer {
        guard let handle else {
            throw DatabaseError.openFailed("database connection is closed")
        }
        return handle
    }

    private func requireSuccessfulBind(_ result: Int32) throws {
        guard result == SQLITE_OK else {
            throw DatabaseError.stepFailed(lastError)
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
