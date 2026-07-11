import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import ClipFlow

final class DatabaseMigratorTests: XCTestCase {
    private let canonicalColumns: Set<String> = [
        "id", "content", "content_hash", "builtin_category", "custom_category_id",
        "created_at", "last_copied_at", "copy_count", "is_favorite", "ai_summary",
        "deleted_at"
    ]

    private let legacyColumns: Set<String> = [
        "id", "content", "content_type", "category", "custom_category", "timestamp",
        "is_favorite", "ai_summary"
    ]

    func testCreatesFreshV2DatabaseAndPrepareIsIdempotent() throws {
        let fixture = try DatabaseFixture()

        let first = try DatabaseMigrator.prepare(
            database: fixture.database,
            databaseURL: fixture.url,
            legacyCategories: []
        )

        var rebuildCount = 0
        fixture.database.statementInterceptorForTesting = { sql in
            if sql.localizedCaseInsensitiveContains("clip_search") &&
                sql.localizedCaseInsensitiveContains("rebuild") {
                rebuildCount += 1
            }
        }
        let second = try DatabaseMigrator.prepare(
            database: fixture.database,
            databaseURL: fixture.url,
            legacyCategories: []
        )
        fixture.database.statementInterceptorForTesting = nil

        XCTAssertEqual(first.schemaVersion, 2)
        XCTAssertEqual(second.schemaVersion, 2)
        XCTAssertEqual(first.searchMode, second.searchMode)
        XCTAssertNil(first.backupURL)
        XCTAssertNil(second.backupURL)
        XCTAssertEqual(try fixture.columnNames(), canonicalColumns)
        XCTAssertEqual(try fixture.scalarInt("PRAGMA user_version"), 2)
        XCTAssertEqual(try fixture.scalarInt("PRAGMA foreign_keys"), 1)
        XCTAssertEqual(try fixture.scalarInt("SELECT COUNT(*) FROM clipboard_items"), 0)
        XCTAssertEqual(try fixture.scalarInt("SELECT COUNT(*) FROM custom_categories"), 0)
        XCTAssertEqual(try fixture.scalarInt("SELECT COUNT(*) FROM ai_usage"), 0)
        XCTAssertEqual(rebuildCount, 0, "Repeated prepare must not rebuild an existing FTS index")
    }

    func testMigratesLegacyRowsAndBackfillsV2Columns() throws {
        let fixture = try DatabaseFixture()
        try fixture.createLegacySchema()
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let knownID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        try fixture.insertLegacyClip(
            id: firstID,
            content: "hello\u{0}world",
            category: "english",
            customCategory: "Recovered",
            timestamp: 100,
            isFavorite: true,
            aiSummary: "summary"
        )
        try fixture.insertLegacyClip(
            id: secondID,
            content: "second",
            category: "code",
            customCategory: " recovered ",
            timestamp: 200
        )
        try fixture.insertLegacyClip(
            id: knownID,
            content: "known",
            category: "mixed",
            customCategory: " work ",
            timestamp: 300
        )

        let category = PersistedCustomCategory(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Work",
            prompt: "project",
            sortOrder: 0,
            isEnabled: true,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )

        let preparation = try DatabaseMigrator.prepare(
            database: fixture.database,
            databaseURL: fixture.url,
            legacyCategories: [category]
        )

        XCTAssertEqual(preparation.schemaVersion, 2)
        XCTAssertNotNil(preparation.backupURL)
        XCTAssertEqual(try fixture.columnNames(), canonicalColumns)
        XCTAssertEqual(try fixture.scalarInt("SELECT COUNT(*) FROM clipboard_items"), 3)
        XCTAssertEqual(try fixture.scalarInt("SELECT MIN(copy_count) FROM clipboard_items"), 1)
        XCTAssertEqual(
            try fixture.scalarText("SELECT content FROM clipboard_items WHERE id = '\(firstID.uuidString)'"),
            "hello\u{0}world"
        )
        XCTAssertEqual(
            try fixture.scalarText("SELECT content_hash FROM clipboard_items WHERE id = '\(firstID.uuidString)'"),
            sha256("hello\u{0}world")
        )
        XCTAssertEqual(
            try fixture.scalarText("SELECT builtin_category FROM clipboard_items WHERE id = '\(firstID.uuidString)'"),
            "english"
        )
        XCTAssertEqual(
            try fixture.scalarDouble("SELECT created_at FROM clipboard_items WHERE id = '\(firstID.uuidString)'"),
            100
        )
        XCTAssertEqual(
            try fixture.scalarDouble("SELECT last_copied_at FROM clipboard_items WHERE id = '\(firstID.uuidString)'"),
            100
        )
        XCTAssertEqual(
            try fixture.scalarInt("SELECT is_favorite FROM clipboard_items WHERE id = '\(firstID.uuidString)'"),
            1
        )
        XCTAssertEqual(
            try fixture.scalarText("SELECT ai_summary FROM clipboard_items WHERE id = '\(firstID.uuidString)'"),
            "summary"
        )

        XCTAssertEqual(preparation.recoveredCategories.count, 1)
        let recovered = try XCTUnwrap(preparation.recoveredCategories.first)
        XCTAssertEqual(recovered.name, "Recovered")
        XCTAssertFalse(recovered.isEnabled)
        XCTAssertEqual(try fixture.scalarInt("SELECT COUNT(*) FROM custom_categories"), 2)
        XCTAssertEqual(
            try fixture.scalarText("SELECT custom_category_id FROM clipboard_items WHERE id = '\(firstID.uuidString)'"),
            recovered.id.uuidString
        )
        XCTAssertEqual(
            try fixture.scalarText("SELECT custom_category_id FROM clipboard_items WHERE id = '\(secondID.uuidString)'"),
            recovered.id.uuidString,
            "Case-folded and trimmed recovered names must reuse one stable category"
        )
        XCTAssertEqual(
            try fixture.scalarText("SELECT custom_category_id FROM clipboard_items WHERE id = '\(knownID.uuidString)'"),
            category.id.uuidString
        )

        let backupURL = try XCTUnwrap(preparation.backupURL)
        let backup = try SQLiteDatabase(url: backupURL, readOnly: true)
        defer { backup.close() }
        XCTAssertEqual(try backup.columnNames(in: "clipboard_items"), legacyColumns)
        XCTAssertEqual(try scalarText(in: backup, sql: "PRAGMA integrity_check"), "ok")
        XCTAssertEqual(try scalarInt(in: backup, sql: "SELECT COUNT(*) FROM clipboard_items"), 3)
    }

    func testMigrationFailureRollsBackLegacySchemaAndPropagatesBackupURL() throws {
        let fixture = try DatabaseFixture()
        try fixture.createLegacySchema()
        try fixture.insertLegacyClip(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            content: "preserve me",
            category: "english",
            customCategory: nil,
            timestamp: 100
        )
        let originalInode = try fixture.inode(at: fixture.url)
        fixture.failNextStatement(containing: "ALTER TABLE")

        var capturedError: DatabaseError?
        do {
            _ = try DatabaseMigrator.prepare(
                database: fixture.database,
                databaseURL: fixture.url,
                legacyCategories: []
            )
            XCTFail("Expected injected migration failure")
        } catch let error as DatabaseError {
            capturedError = error
        }

        guard let capturedError,
              case let .migrationFailed(message, databaseURL, backupURL) = capturedError else {
            return XCTFail("Expected typed migrationFailed, got \(String(describing: capturedError))")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(databaseURL, fixture.url)
        let propagatedBackupURL = try XCTUnwrap(backupURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: propagatedBackupURL.path))
        XCTAssertEqual(try fixture.inode(at: fixture.url), originalInode, "Migration must not replace the source DB")
        XCTAssertEqual(try fixture.columnNames(), legacyColumns)
        XCTAssertEqual(try fixture.scalarInt("PRAGMA user_version"), 0)
        XCTAssertEqual(try fixture.scalarInt("SELECT COUNT(*) FROM clipboard_items"), 1)
        XCTAssertEqual(try fixture.scalarText("PRAGMA integrity_check"), "ok")

        let retry = try DatabaseMigrator.prepare(
            database: fixture.database,
            databaseURL: fixture.url,
            legacyCategories: []
        )
        XCTAssertEqual(retry.schemaVersion, 2, "A rolled-back source must remain migratable")
    }

    func testAppliesPrivateFilePermissionsAndExcludesUTF8DirectoryFromBackup() throws {
        let fixture = try DatabaseFixture(
            directoryName: "数据库目录",
            databaseName: "剪贴板.sqlite3"
        )
        try fixture.setMode(0o777, at: fixture.directory)
        try fixture.setMode(0o666, at: fixture.url)
        try fixture.execute("PRAGMA journal_mode = WAL")
        try fixture.execute("PRAGMA wal_autocheckpoint = 0")

        _ = try DatabaseMigrator.prepare(
            database: fixture.database,
            databaseURL: fixture.url,
            legacyCategories: []
        )

        XCTAssertEqual(try fixture.posixMode(at: fixture.url) & 0o777, 0o600)
        XCTAssertEqual(try fixture.posixMode(at: fixture.directory) & 0o777, 0o700)
        XCTAssertTrue(try fixture.isExcludedFromBackup(fixture.directory))
        try assertPrivateModesForExistingSQLiteFiles(at: fixture.url)
    }

    func testOnlineBackupIncludesCommittedWALRows() throws {
        let fixture = try DatabaseFixture()
        try fixture.createLegacySchema()
        try fixture.execute("PRAGMA journal_mode = WAL")
        try fixture.execute("PRAGMA wal_autocheckpoint = 0")
        try fixture.insertLegacyClip(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
            content: "wal\u{0}row",
            category: "english",
            customCategory: nil,
            timestamp: 123
        )
        let sourceWAL = URL(fileURLWithPath: fixture.url.path + "-wal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceWAL.path))

        let preparation = try DatabaseMigrator.prepare(
            database: fixture.database,
            databaseURL: fixture.url,
            legacyCategories: []
        )
        let backupURL = try XCTUnwrap(preparation.backupURL)

        let backup = try SQLiteDatabase(url: backupURL, readOnly: true)
        defer { backup.close() }
        XCTAssertEqual(try scalarText(in: backup, sql: "PRAGMA integrity_check"), "ok")
        XCTAssertEqual(try backup.columnNames(in: "clipboard_items"), legacyColumns)
        XCTAssertEqual(try scalarInt(in: backup, sql: "SELECT COUNT(*) FROM clipboard_items"), 1)
        XCTAssertEqual(try scalarText(in: backup, sql: "SELECT content FROM clipboard_items"), "wal\u{0}row")
        XCTAssertEqual(try posixMode(at: backupURL) & 0o777, 0o600)
        try assertPrivateModesForExistingSQLiteFiles(at: fixture.url)
    }

    func testProductionBinderRoundTripsEmptyNULAndEmoji() throws {
        let fixture = try DatabaseFixture()
        try fixture.execute("CREATE TABLE samples (value TEXT NOT NULL)")
        let values = ["", "a\u{0}b", "👍🏽"]
        let insert = try fixture.database.prepare("INSERT INTO samples(value) VALUES (?)")
        defer { sqlite3_finalize(insert) }

        for value in values {
            sqlite3_reset(insert)
            sqlite3_clear_bindings(insert)
            try fixture.database.bind(value, at: 1, to: insert)
            try fixture.database.stepExpectingDone(insert)
        }

        let query = try fixture.database.prepare("SELECT value FROM samples ORDER BY rowid")
        defer { sqlite3_finalize(query) }
        var roundTripped: [String] = []
        while sqlite3_step(query) == SQLITE_ROW {
            roundTripped.append(try XCTUnwrap(fixture.database.columnString(query, at: 0)))
        }
        XCTAssertEqual(roundTripped, values)
    }

    func testReadOnlyV1DatabaseProducesReadableRecoveryAndRejectsMutation() throws {
        let fixture = try DatabaseFixture()
        try fixture.createLegacySchema()
        try fixture.insertLegacyClip(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!,
            content: "read only\u{0}row",
            category: "english",
            customCategory: nil,
            timestamp: 50
        )
        fixture.close()
        let originalData = try Data(contentsOf: fixture.url)
        let originalInode = try fixture.inode(at: fixture.url)
        try fixture.setMode(0o400, at: fixture.url)
        defer { try? fixture.setMode(0o600, at: fixture.url) }

        var capturedError: DatabaseError?
        do {
            _ = try DatabaseMigrator.prepare(databaseURL: fixture.url, legacyCategories: [])
            XCTFail("Expected read-only recovery")
        } catch let error as DatabaseError {
            capturedError = error
        }

        guard let capturedError,
              case let .readOnlyRecovery(databaseURL, backupURL) = capturedError else {
            return XCTFail("Expected readOnlyRecovery, got \(String(describing: capturedError))")
        }
        XCTAssertEqual(databaseURL, fixture.url)
        XCTAssertEqual(try Data(contentsOf: fixture.url), originalData)
        XCTAssertEqual(try fixture.inode(at: fixture.url), originalInode)

        let recoveryURL = try XCTUnwrap(backupURL)
        let recovery = try SQLiteDatabase(url: recoveryURL, readOnly: true)
        defer { recovery.close() }
        XCTAssertEqual(try scalarText(in: recovery, sql: "SELECT content FROM clipboard_items"), "read only\u{0}row")
        XCTAssertEqual(try scalarText(in: recovery, sql: "PRAGMA integrity_check"), "ok")
        XCTAssertEqual(try posixMode(at: recoveryURL) & 0o777, 0o600)

        let source = try SQLiteDatabase(url: fixture.url, readOnly: true)
        defer { source.close() }
        XCTAssertEqual(try scalarText(in: source, sql: "SELECT content FROM clipboard_items"), "read only\u{0}row")
        XCTAssertThrowsError(try source.execute("DELETE FROM clipboard_items"))
        XCTAssertEqual(try source.columnNames(in: "clipboard_items"), legacyColumns)
    }

    func testNonSQLiteMainFileIsBlockedWithoutChangingOrReplacingIt() throws {
        let location = try TemporaryDatabaseLocation()
        let original = Data("not a sqlite database\u{0}with bytes".utf8)
        try original.write(to: location.url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: location.url.path
        )
        let originalInode = try inode(at: location.url)
        let originalDigest = SHA256.hash(data: original)

        var capturedError: DatabaseError?
        do {
            _ = try DatabaseMigrator.prepare(databaseURL: location.url, legacyCategories: [])
            XCTFail("Expected corrupt database to block preparation")
        } catch let error as DatabaseError {
            capturedError = error
        }

        guard let capturedError,
              case let .migrationFailed(_, databaseURL, _) = capturedError else {
            return XCTFail("Expected migrationFailed, got \(String(describing: capturedError))")
        }
        XCTAssertEqual(databaseURL, location.url)
        let after = try Data(contentsOf: location.url)
        XCTAssertEqual(after.count, original.count)
        XCTAssertEqual(SHA256.hash(data: after), originalDigest)
        XCTAssertEqual(try inode(at: location.url), originalInode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.url.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.url.path + "-shm"))
    }

    func testDamagedWALAndSHMAreBlockedWithOriginalFilesUnchanged() throws {
        let fixture = try DatabaseFixture()
        try fixture.createLegacySchema()
        try fixture.insertLegacyClip(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000041")!,
            content: "main remains valid",
            category: "english",
            customCategory: nil,
            timestamp: 10
        )
        fixture.close()

        let walURL = URL(fileURLWithPath: fixture.url.path + "-wal")
        let shmURL = URL(fileURLWithPath: fixture.url.path + "-shm")
        let damagedWAL = Data([0x00, 0x01, 0x02, 0x03, 0x04])
        let damagedSHM = Data([0x05, 0x06, 0x07])
        try damagedWAL.write(to: walURL)
        try damagedSHM.write(to: shmURL)
        for url in [fixture.url, walURL, shmURL] {
            try fixture.setMode(0o644, at: url)
        }
        let originalMain = try Data(contentsOf: fixture.url)
        let originalInode = try fixture.inode(at: fixture.url)
        let originalModes = try [fixture.url, walURL, shmURL].map {
            try fixture.posixMode(at: $0)
        }

        var capturedError: DatabaseError?
        do {
            _ = try DatabaseMigrator.prepare(databaseURL: fixture.url, legacyCategories: [])
            XCTFail("Expected damaged sidecars to block preparation")
        } catch let error as DatabaseError {
            capturedError = error
        }

        guard let capturedError,
              case let .migrationFailed(_, databaseURL, _) = capturedError else {
            return XCTFail("Expected migrationFailed, got \(String(describing: capturedError))")
        }
        XCTAssertEqual(databaseURL, fixture.url)
        XCTAssertEqual(try Data(contentsOf: fixture.url), originalMain)
        XCTAssertEqual(try Data(contentsOf: walURL), damagedWAL)
        XCTAssertEqual(try Data(contentsOf: shmURL), damagedSHM)
        XCTAssertEqual(try fixture.inode(at: fixture.url), originalInode)
        XCTAssertEqual(
            try [fixture.url, walURL, shmURL].map { try fixture.posixMode(at: $0) },
            originalModes
        )
    }

    func testProductionPrepareMigratesCommittedHotWALRowAndCreatesVerifiedBackup() throws {
        let location = try TemporaryDatabaseLocation()
        let walURL = URL(fileURLWithPath: location.url.path + "-wal")
        let shmURL = URL(fileURLWithPath: location.url.path + "-shm")
        let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000048")!
        let content = "valid\u{0}committed"

        let setup = try SQLiteDatabase(url: location.url)
        try setup.execute("""
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
        setup.close()

        let writer = try SQLiteDatabase(url: location.url)
        try writer.execute("PRAGMA journal_mode = WAL")
        try writer.execute("PRAGMA wal_autocheckpoint = 0")
        try writer.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        let insert = try writer.prepare("""
            INSERT INTO clipboard_items
                (id, content, content_type, category, custom_category, timestamp, is_favorite, ai_summary)
            VALUES (?, ?, 'text', 'english', NULL, 122, 0, NULL)
            """)
        try writer.bind(itemID.uuidString, at: 1, to: insert)
        try writer.bind(content, at: 2, to: insert)
        try writer.stepExpectingDone(insert)
        sqlite3_finalize(insert)

        let committedMain = try Data(contentsOf: location.url)
        let committedWAL = try Data(contentsOf: walURL)
        let committedSHM = try Data(contentsOf: shmURL)
        XCTAssertEqual(committedSHM.count, 32_768)
        writer.close()

        try committedMain.write(to: location.url)
        try committedWAL.write(to: walURL)
        try committedSHM.write(to: shmURL)

        let preparation = try DatabaseMigrator.prepare(
            databaseURL: location.url,
            legacyCategories: []
        )
        let backupURL = try XCTUnwrap(preparation.backupURL)
        let backup = try SQLiteDatabase(url: backupURL, readOnly: true)
        defer { backup.close() }
        XCTAssertEqual(try scalarText(in: backup, sql: "PRAGMA integrity_check"), "ok")
        XCTAssertEqual(
            try scalarText(
                in: backup,
                sql: "SELECT content FROM clipboard_items WHERE id = '\(itemID.uuidString)'"
            ),
            content
        )

        let migrated = try SQLiteDatabase(url: location.url, readOnly: true)
        defer { migrated.close() }
        XCTAssertEqual(
            try scalarText(
                in: migrated,
                sql: "SELECT content FROM clipboard_items WHERE id = '\(itemID.uuidString)'"
            ),
            content
        )
    }

    func testProductionPrepareAcceptsReusedWALWithStalePhysicalSuffix() throws {
        let fixture = try DatabaseFixture()
        try fixture.execute("PRAGMA journal_mode = WAL")
        try fixture.execute("PRAGMA wal_autocheckpoint = 0")
        try fixture.createLegacySchema()
        try fixture.execute("""
            WITH RECURSIVE seq(x) AS (
                VALUES(1)
                UNION ALL
                SELECT x + 1 FROM seq WHERE x < 200
            )
            INSERT INTO clipboard_items
                (id, content, content_type, category, custom_category, timestamp, is_favorite, ai_summary)
            SELECT
                printf('10000000-0000-0000-0000-%012d', x),
                hex(randomblob(2000)),
                'text',
                'english',
                NULL,
                x,
                0,
                NULL
            FROM seq
            """)
        try fixture.execute("PRAGMA wal_checkpoint(RESTART)")

        let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000061")!
        let content = "reused\u{0}wal"
        try fixture.insertLegacyClip(
            id: itemID,
            content: content,
            category: "english",
            customCategory: nil,
            timestamp: 124
        )

        let walURL = URL(fileURLWithPath: fixture.url.path + "-wal")
        let shmURL = URL(fileURLWithPath: fixture.url.path + "-shm")
        let committedMain = try Data(contentsOf: fixture.url)
        let committedWAL = try Data(contentsOf: walURL)
        let committedSHM = try Data(contentsOf: shmURL)
        XCTAssertTrue(
            walContainsStaleGenerationSuffix(committedWAL),
            "Fixture must exercise WAL reuse rather than a truncated WAL"
        )
        fixture.close()

        try committedMain.write(to: fixture.url)
        try committedWAL.write(to: walURL)
        try committedSHM.write(to: shmURL)

        try assertProductionPreparationRetainsLegacyRow(
            at: fixture.url,
            itemID: itemID,
            content: content
        )
    }

    func testProductionPrepareAcceptsEmptyWALWithInitializedSharedMemory() throws {
        let fixture = try DatabaseFixture()
        try fixture.createLegacySchema()
        let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000062")!
        let content = "checkpointed"
        try fixture.insertLegacyClip(
            id: itemID,
            content: content,
            category: "english",
            customCategory: nil,
            timestamp: 125
        )
        try fixture.execute("PRAGMA journal_mode = WAL")
        try fixture.execute("PRAGMA wal_autocheckpoint = 0")
        try fixture.execute("PRAGMA wal_checkpoint(TRUNCATE)")

        let walURL = URL(fileURLWithPath: fixture.url.path + "-wal")
        let shmURL = URL(fileURLWithPath: fixture.url.path + "-shm")
        let checkpointedMain = try Data(contentsOf: fixture.url)
        let emptyWAL = try Data(contentsOf: walURL)
        let initializedSHM = try Data(contentsOf: shmURL)
        XCTAssertTrue(emptyWAL.isEmpty)
        XCTAssertEqual(initializedSHM.count, 32_768)
        XCTAssertFalse(initializedSHM.prefix(96).allSatisfy { $0 == 0 })
        fixture.close()

        try checkpointedMain.write(to: fixture.url)
        try emptyWAL.write(to: walURL)
        try initializedSHM.write(to: shmURL)

        try assertProductionPreparationRetainsLegacyRow(
            at: fixture.url,
            itemID: itemID,
            content: content
        )
    }

    func testProductionPrepareRebuildsStaleSharedMemoryFromValidatedWAL() throws {
        let fixture = try DatabaseFixture()
        try fixture.createLegacySchema()
        try fixture.execute("PRAGMA journal_mode = WAL")
        try fixture.execute("PRAGMA wal_autocheckpoint = 0")
        try fixture.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000063")!
        let content = "rebuild\u{0}shm"
        try fixture.insertLegacyClip(
            id: itemID,
            content: content,
            category: "english",
            customCategory: nil,
            timestamp: 126
        )

        let walURL = URL(fileURLWithPath: fixture.url.path + "-wal")
        let shmURL = URL(fileURLWithPath: fixture.url.path + "-shm")
        let committedMain = try Data(contentsOf: fixture.url)
        let committedWAL = try Data(contentsOf: walURL)
        var staleSHM = try Data(contentsOf: shmURL)
        XCTAssertEqual(staleSHM.count, 32_768)
        staleSHM[40] ^= 0x01
        staleSHM[88] ^= 0x01
        fixture.close()

        try committedMain.write(to: fixture.url)
        try committedWAL.write(to: walURL)
        try staleSHM.write(to: shmURL)

        try assertProductionPreparationRetainsLegacyRow(
            at: fixture.url,
            itemID: itemID,
            content: content
        )
    }

    func testProductionPrepareBlocksCurrentGenerationCommitWithCorruptSalt() throws {
        let fixture = try DatabaseFixture()
        try fixture.createLegacySchema()
        try fixture.execute("PRAGMA journal_mode = WAL")
        try fixture.execute("PRAGMA wal_autocheckpoint = 0")
        try fixture.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try fixture.insertLegacyClip(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000064")!,
            content: "earlier commit",
            category: "english",
            customCategory: nil,
            timestamp: 127
        )
        let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000065")!
        let content = "salt\u{0}committed"
        try fixture.insertLegacyClip(
            id: itemID,
            content: content,
            category: "english",
            customCategory: nil,
            timestamp: 128
        )

        let walURL = URL(fileURLWithPath: fixture.url.path + "-wal")
        let shmURL = URL(fileURLWithPath: fixture.url.path + "-shm")
        let committedMain = try Data(contentsOf: fixture.url)
        let committedWAL = try Data(contentsOf: walURL)
        let committedSHM = try Data(contentsOf: shmURL)
        let corruption = try corruptSaltOfLastCommitFrame(in: committedWAL)
        let corruptWAL = corruption.wal
        XCTAssertEqual(corruptWAL.count, committedWAL.count)
        XCTAssertEqual(corruptWAL.prefix(4), committedWAL.prefix(4))
        XCTAssertEqual(
            committedWAL.indices.filter { committedWAL[$0] != corruptWAL[$0] },
            [corruption.frameOffset + 8],
            "Only one salt byte may change; the stored rolling checksum must remain intact"
        )
        fixture.close()

        try committedMain.write(to: fixture.url)
        try corruptWAL.write(to: walURL)
        try committedSHM.write(to: shmURL)
        let sourceURLs = [fixture.url, walURL, shmURL]
        for url in sourceURLs {
            try fixture.setMode(0o644, at: url)
        }
        let originalBytes = try sourceURLs.map { try Data(contentsOf: $0) }
        let originalInodes = try sourceURLs.map { try fixture.inode(at: $0) }
        let originalModes = try sourceURLs.map { try fixture.posixMode(at: $0) }

        do {
            let preparation = try DatabaseMigrator.prepare(
                databaseURL: fixture.url,
                legacyCategories: []
            )
            let backupURL = try XCTUnwrap(preparation.backupURL)
            let backup = try SQLiteDatabase(url: backupURL, readOnly: true)
            defer { backup.close() }
            XCTAssertEqual(
                try scalarText(
                    in: backup,
                    sql: "SELECT content FROM clipboard_items WHERE id = '\(itemID.uuidString)'"
                ),
                content,
                "A successful recovery must not silently omit the committed salt-corrupt frame"
            )

            let migrated = try SQLiteDatabase(url: fixture.url, readOnly: true)
            defer { migrated.close() }
            XCTAssertEqual(
                try scalarText(
                    in: migrated,
                    sql: "SELECT content FROM clipboard_items WHERE id = '\(itemID.uuidString)'"
                ),
                content,
                "A successful migration must not silently omit the committed salt-corrupt frame"
            )
            XCTFail("A current-generation frame with corrupt salt must block before SQLite opens it")
        } catch let error as DatabaseError {
            guard case let .migrationFailed(_, databaseURL, backupURL) = error else {
                return XCTFail("Expected migrationFailed blocking error, got \(error)")
            }
            XCTAssertEqual(databaseURL, fixture.url)
            XCTAssertNil(backupURL)
            XCTAssertEqual(try sourceURLs.map { try Data(contentsOf: $0) }, originalBytes)
            XCTAssertEqual(try sourceURLs.map { try fixture.inode(at: $0) }, originalInodes)
            XCTAssertEqual(try sourceURLs.map { try fixture.posixMode(at: $0) }, originalModes)
        }
    }

    func testProductionPreparePreservesCommittedRowWhenWALFrameChecksumIsCorrupt() throws {
        let location = try TemporaryDatabaseLocation()
        let walURL = URL(fileURLWithPath: location.url.path + "-wal")
        let shmURL = URL(fileURLWithPath: location.url.path + "-shm")
        let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000049")!
        let content = "checksum\u{0}committed"

        let setup = try SQLiteDatabase(url: location.url)
        try setup.execute("""
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
        setup.close()

        let writer = try SQLiteDatabase(url: location.url)
        try writer.execute("PRAGMA journal_mode = WAL")
        try writer.execute("PRAGMA wal_autocheckpoint = 0")
        try writer.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        let insert = try writer.prepare("""
            INSERT INTO clipboard_items
                (id, content, content_type, category, custom_category, timestamp, is_favorite, ai_summary)
            VALUES (?, ?, 'text', 'english', NULL, 123, 0, NULL)
            """)
        try writer.bind(itemID.uuidString, at: 1, to: insert)
        try writer.bind(content, at: 2, to: insert)
        try writer.stepExpectingDone(insert)
        sqlite3_finalize(insert)

        let committedMain = try Data(contentsOf: location.url)
        let committedWAL = try Data(contentsOf: walURL)
        let committedSHM = try Data(contentsOf: shmURL)
        XCTAssertEqual(committedSHM.count, 32_768)
        writer.close()

        let corruptWAL = try corruptChecksumOfLastCommitFrame(in: committedWAL)
        let plausibleUninitializedSHM = Data(repeating: 0, count: 32_768)
        try committedMain.write(to: location.url)
        try corruptWAL.write(to: walURL)
        try plausibleUninitializedSHM.write(to: shmURL)
        for url in [location.url, walURL, shmURL] {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o644)],
                ofItemAtPath: url.path
            )
        }

        let originalMain = try Data(contentsOf: location.url)
        let originalWAL = try Data(contentsOf: walURL)
        let originalSHM = try Data(contentsOf: shmURL)
        let originalInode = try inode(at: location.url)
        let originalModes = try [location.url, walURL, shmURL].map {
            try posixMode(at: $0)
        }

        do {
            let preparation = try DatabaseMigrator.prepare(
                databaseURL: location.url,
                legacyCategories: []
            )
            let backupURL = try XCTUnwrap(preparation.backupURL)
            let backup = try SQLiteDatabase(url: backupURL, readOnly: true)
            defer { backup.close() }
            XCTAssertEqual(try scalarText(in: backup, sql: "PRAGMA integrity_check"), "ok")
            XCTAssertEqual(
                try scalarText(
                    in: backup,
                    sql: "SELECT content FROM clipboard_items WHERE id = '\(itemID.uuidString)'"
                ),
                content,
                "A successful recovery must retain the committed hot-WAL row in its verified backup"
            )

            let migrated = try SQLiteDatabase(url: location.url, readOnly: true)
            defer { migrated.close() }
            XCTAssertEqual(
                try scalarText(
                    in: migrated,
                    sql: "SELECT content FROM clipboard_items WHERE id = '\(itemID.uuidString)'"
                ),
                content,
                "A successful migration must retain the committed hot-WAL row"
            )
        } catch let error as DatabaseError {
            guard case .migrationFailed = error else {
                return XCTFail("Expected migrationFailed blocking error, got \(error)")
            }
            XCTAssertEqual(try Data(contentsOf: location.url), originalMain)
            XCTAssertEqual(try Data(contentsOf: walURL), originalWAL)
            XCTAssertEqual(try Data(contentsOf: shmURL), originalSHM)
            XCTAssertEqual(try inode(at: location.url), originalInode)
            XCTAssertEqual(
                try [location.url, walURL, shmURL].map { try posixMode(at: $0) },
                originalModes,
                "A blocking preflight must not chmod source files"
            )
        }
    }

    func testRealV1MigrationSupportsAllV2MutationsAndReopen() throws {
        let fixture = try DatabaseFixture()
        try fixture.createLegacySchema()
        let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000051")!
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000052")!
        try fixture.insertLegacyClip(
            id: itemID,
            content: "legacy",
            contentType: "text",
            category: "english",
            customCategory: nil,
            timestamp: 1
        )
        let category = PersistedCustomCategory(
            id: categoryID,
            name: "Projects",
            prompt: "project material",
            sortOrder: 0,
            isEnabled: true,
            createdAt: Date(timeIntervalSince1970: 2),
            updatedAt: Date(timeIntervalSince1970: 2)
        )

        _ = try DatabaseMigrator.prepare(
            database: fixture.database,
            databaseURL: fixture.url,
            legacyCategories: [category]
        )
        XCTAssertEqual(try fixture.columnNames(), canonicalColumns)
        XCTAssertTrue(legacyColumns.subtracting(canonicalColumns).isDisjoint(with: try fixture.columnNames()))

        let updatedContent = "updated\u{0}👍🏽"
        do {
            let upsert = try fixture.database.prepare("""
                INSERT INTO clipboard_items (
                    id, content, content_hash, builtin_category, custom_category_id,
                    created_at, last_copied_at, copy_count, is_favorite, ai_summary, deleted_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    content = excluded.content,
                    content_hash = excluded.content_hash,
                    builtin_category = excluded.builtin_category,
                    custom_category_id = excluded.custom_category_id,
                    created_at = excluded.created_at,
                    last_copied_at = excluded.last_copied_at,
                    copy_count = excluded.copy_count,
                    is_favorite = excluded.is_favorite,
                    ai_summary = excluded.ai_summary,
                    deleted_at = excluded.deleted_at
                """)
            defer { sqlite3_finalize(upsert) }
            try fixture.database.bind(itemID.uuidString, at: 1, to: upsert)
            try fixture.database.bind(updatedContent, at: 2, to: upsert)
            try fixture.database.bind(sha256(updatedContent), at: 3, to: upsert)
            try fixture.database.bind("code", at: 4, to: upsert)
            try fixture.database.bind(nil as String?, at: 5, to: upsert)
            try fixture.database.bind(10.0, at: 6, to: upsert)
            try fixture.database.bind(20.0, at: 7, to: upsert)
            try fixture.database.bind(3, at: 8, to: upsert)
            try fixture.database.bind(true, at: 9, to: upsert)
            try fixture.database.bind("kept summary", at: 10, to: upsert)
            try fixture.database.bind(nil as Double?, at: 11, to: upsert)
            try fixture.database.stepExpectingDone(upsert)
        }

        try executeBoundUpdate(
            database: fixture.database,
            sql: "UPDATE clipboard_items SET last_copied_at = ?, copy_count = copy_count + 1 WHERE id = ?",
            doubles: [30],
            strings: [itemID.uuidString]
        )
        try executeBoundUpdate(
            database: fixture.database,
            sql: "UPDATE clipboard_items SET custom_category_id = ? WHERE id = ?",
            strings: [categoryID.uuidString, itemID.uuidString]
        )
        try executeBoundUpdate(
            database: fixture.database,
            sql: "UPDATE clipboard_items SET deleted_at = ? WHERE id = ?",
            doubles: [40],
            strings: [itemID.uuidString]
        )
        try executeBoundUpdate(
            database: fixture.database,
            sql: "UPDATE clipboard_items SET deleted_at = NULL WHERE id = ?",
            strings: [itemID.uuidString]
        )

        try fixture.reopen()
        XCTAssertEqual(try fixture.scalarInt("PRAGMA user_version"), 2)
        XCTAssertEqual(try fixture.columnNames(), canonicalColumns)
        XCTAssertEqual(try fixture.scalarText("SELECT content FROM clipboard_items"), updatedContent)
        XCTAssertEqual(try fixture.scalarText("SELECT content_hash FROM clipboard_items"), sha256(updatedContent))
        XCTAssertEqual(try fixture.scalarText("SELECT builtin_category FROM clipboard_items"), "code")
        XCTAssertEqual(try fixture.scalarText("SELECT custom_category_id FROM clipboard_items"), categoryID.uuidString)
        XCTAssertEqual(try fixture.scalarDouble("SELECT created_at FROM clipboard_items"), 10)
        XCTAssertEqual(try fixture.scalarDouble("SELECT last_copied_at FROM clipboard_items"), 30)
        XCTAssertEqual(try fixture.scalarInt("SELECT copy_count FROM clipboard_items"), 4)
        XCTAssertEqual(try fixture.scalarInt("SELECT is_favorite FROM clipboard_items"), 1)
        XCTAssertEqual(try fixture.scalarText("SELECT ai_summary FROM clipboard_items"), "kept summary")
        XCTAssertEqual(try fixture.scalarInt("SELECT deleted_at IS NULL FROM clipboard_items"), 1)
        XCTAssertEqual(try fixture.scalarText("PRAGMA integrity_check"), "ok")
    }

    func testFTS5IsDetectedBuiltOnceAndMaintainedWhenAvailable() throws {
        let fixture = try DatabaseFixture()
        let preparation = try DatabaseMigrator.prepare(
            database: fixture.database,
            databaseURL: fixture.url,
            legacyCategories: []
        )

        guard preparation.searchMode == .fts5 else {
            XCTAssertEqual(preparation.searchMode, .parameterizedContains)
            XCTAssertEqual(
                try fixture.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE name = 'clip_search'"),
                0
            )
            return
        }

        XCTAssertEqual(
            try fixture.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'clip_search'"),
            1
        )
        XCTAssertEqual(
            try fixture.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'clips_fts_%'"),
            3
        )
        try insertCanonicalClip(
            into: fixture.database,
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000061")!,
            content: "searchable alpha"
        )
        XCTAssertEqual(try fixture.scalarInt("SELECT COUNT(*) FROM clip_search WHERE clip_search MATCH 'alpha'"), 1)
        try fixture.execute("UPDATE clipboard_items SET content = 'searchable beta' WHERE content = 'searchable alpha'")
        XCTAssertEqual(try fixture.scalarInt("SELECT COUNT(*) FROM clip_search WHERE clip_search MATCH 'alpha'"), 0)
        XCTAssertEqual(try fixture.scalarInt("SELECT COUNT(*) FROM clip_search WHERE clip_search MATCH 'beta'"), 1)

        var rebuildCount = 0
        fixture.database.statementInterceptorForTesting = { sql in
            if sql.localizedCaseInsensitiveContains("clip_search") &&
                sql.localizedCaseInsensitiveContains("rebuild") {
                rebuildCount += 1
            }
        }
        _ = try DatabaseMigrator.prepare(
            database: fixture.database,
            databaseURL: fixture.url,
            legacyCategories: []
        )
        fixture.database.statementInterceptorForTesting = nil
        XCTAssertEqual(rebuildCount, 0)
        XCTAssertEqual(try fixture.scalarInt("SELECT COUNT(*) FROM clip_search WHERE clip_search MATCH 'beta'"), 1)

        try fixture.execute("DELETE FROM clipboard_items")
        XCTAssertEqual(try fixture.scalarInt("SELECT COUNT(*) FROM clip_search WHERE clip_search MATCH 'beta'"), 0)
    }

    func testLegacySettingsSnapshotPreservesStableIDsAndMigratesFlagsOutOfClipStorage() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000071")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000072")!
        let snapshot = LegacySettingsSnapshot(
            categories: [
                .init(id: firstID, name: " First ", prompt: "one"),
                .init(id: secondID, name: "Second", prompt: "two")
            ],
            hadAIEnabled: true,
            hadOllamaURL: true,
            hadAPIUsageRecords: true
        )
        let now = Date(timeIntervalSince1970: 999)

        let migrated = snapshot.migratedCategories(now: now)

        XCTAssertEqual(migrated.map(\.id), [firstID, secondID])
        XCTAssertEqual(migrated.map(\.name), ["First", "Second"])
        XCTAssertEqual(migrated.map(\.prompt), ["one", "two"])
        XCTAssertEqual(migrated.map(\.sortOrder), [0, 1])
        XCTAssertTrue(migrated.allSatisfy(\.isEnabled))
        XCTAssertTrue(migrated.allSatisfy { $0.createdAt == now && $0.updatedAt == now })
    }
}

private extension DatabaseMigratorTests {
    func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func scalarInt(in database: SQLiteDatabase, sql: String) throws -> Int {
        let statement = try database.prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseFixtureError.missingScalarRow(sql)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func scalarText(in database: SQLiteDatabase, sql: String) throws -> String? {
        let statement = try database.prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseFixtureError.missingScalarRow(sql)
        }
        return database.columnString(statement, at: 0)
    }

    func posixMode(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    func inode(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    func assertProductionPreparationRetainsLegacyRow(
        at databaseURL: URL,
        itemID: UUID,
        content: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let preparation = try DatabaseMigrator.prepare(
            databaseURL: databaseURL,
            legacyCategories: []
        )
        let backupURL = try XCTUnwrap(preparation.backupURL, file: file, line: line)
        let backup = try SQLiteDatabase(url: backupURL, readOnly: true)
        defer { backup.close() }
        XCTAssertEqual(
            try scalarText(in: backup, sql: "PRAGMA integrity_check"),
            "ok",
            file: file,
            line: line
        )
        XCTAssertEqual(
            try scalarText(
                in: backup,
                sql: "SELECT content FROM clipboard_items WHERE id = '\(itemID.uuidString)'"
            ),
            content,
            file: file,
            line: line
        )

        let migrated = try SQLiteDatabase(url: databaseURL, readOnly: true)
        defer { migrated.close() }
        XCTAssertEqual(
            try scalarText(
                in: migrated,
                sql: "SELECT content FROM clipboard_items WHERE id = '\(itemID.uuidString)'"
            ),
            content,
            file: file,
            line: line
        )
    }

    func walContainsStaleGenerationSuffix(_ wal: Data) -> Bool {
        guard wal.count >= 32 else { return false }
        let pageSize = Int(readBigEndianUInt32(in: wal, at: 8))
        guard pageSize >= 512 else { return false }
        let frameSize = 24 + pageSize
        let salt = wal[16..<24]
        var sawCurrentFrame = false
        var frameOffset = 32
        while frameOffset + frameSize <= wal.count {
            let frameSalt = wal[(frameOffset + 8)..<(frameOffset + 16)]
            if frameSalt.elementsEqual(salt) {
                sawCurrentFrame = true
            } else if sawCurrentFrame {
                return true
            }
            frameOffset += frameSize
        }
        return false
    }

    func corruptChecksumOfLastCommitFrame(in wal: Data) throws -> Data {
        guard wal.count >= 32 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let pageSize = Int(readBigEndianUInt32(in: wal, at: 8))
        let frameSize = 24 + pageSize
        guard pageSize >= 512,
              (pageSize & (pageSize - 1)) == 0,
              (wal.count - 32).isMultiple(of: frameSize) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var lastCommitOffset: Int?
        var frameOffset = 32
        while frameOffset < wal.count {
            if readBigEndianUInt32(in: wal, at: frameOffset + 4) != 0 {
                lastCommitOffset = frameOffset
            }
            frameOffset += frameSize
        }
        guard let lastCommitOffset else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var corrupt = wal
        corrupt[lastCommitOffset + 16] ^= 0x01
        return corrupt
    }

    func corruptSaltOfLastCommitFrame(in wal: Data) throws -> (wal: Data, frameOffset: Int) {
        guard wal.count >= 32 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let pageSize = Int(readBigEndianUInt32(in: wal, at: 8))
        let frameSize = 24 + pageSize
        guard pageSize >= 512,
              (pageSize & (pageSize - 1)) == 0,
              (wal.count - 32).isMultiple(of: frameSize) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let headerSalt = wal[16..<24]
        var commitOffsets: [Int] = []
        var frameOffset = 32
        while frameOffset < wal.count {
            guard wal[(frameOffset + 8)..<(frameOffset + 16)].elementsEqual(headerSalt) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if readBigEndianUInt32(in: wal, at: frameOffset + 4) != 0 {
                commitOffsets.append(frameOffset)
            }
            frameOffset += frameSize
        }
        guard commitOffsets.count >= 2, let lastCommitOffset = commitOffsets.last else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var corrupt = wal
        corrupt[lastCommitOffset + 8] ^= 0x01
        return (corrupt, lastCommitOffset)
    }

    func readBigEndianUInt32(in data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    func assertPrivateModesForExistingSQLiteFiles(at databaseURL: URL) throws {
        for url in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ] where FileManager.default.fileExists(atPath: url.path) {
            XCTAssertEqual(try posixMode(at: url) & 0o777, 0o600, "Unexpected mode at \(url.path)")
        }
    }

    func executeBoundUpdate(
        database: SQLiteDatabase,
        sql: String,
        doubles: [Double] = [],
        strings: [String] = []
    ) throws {
        let statement = try database.prepare(sql)
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        for value in doubles {
            try database.bind(value, at: index, to: statement)
            index += 1
        }
        for value in strings {
            try database.bind(value, at: index, to: statement)
            index += 1
        }
        try database.stepExpectingDone(statement)
    }

    func insertCanonicalClip(into database: SQLiteDatabase, id: UUID, content: String) throws {
        let statement = try database.prepare("""
            INSERT INTO clipboard_items (
                id, content, content_hash, builtin_category, custom_category_id,
                created_at, last_copied_at, copy_count, is_favorite, ai_summary, deleted_at
            ) VALUES (?, ?, ?, ?, NULL, ?, ?, 1, 0, NULL, NULL)
            """)
        defer { sqlite3_finalize(statement) }
        try database.bind(id.uuidString, at: 1, to: statement)
        try database.bind(content, at: 2, to: statement)
        try database.bind(sha256(content), at: 3, to: statement)
        try database.bind("english", at: 4, to: statement)
        try database.bind(1.0, at: 5, to: statement)
        try database.bind(1.0, at: 6, to: statement)
        try database.stepExpectingDone(statement)
    }
}
