import Foundation
import XCTest
@testable import ClipFlow

final class MigrationBackupManagerTests: XCTestCase {
    func testBackupURLsMatchOnlyManagedSentinelNames() async throws {
        let location = try TemporaryDatabaseLocation()
        let managedA = try makeFile(named: "clipflow.sqlite3.backup-20260711T000000Z", in: location.directory)
        let managedB = try makeFile(named: "clipflow.sqlite3.backup-manual", in: location.directory)
        let unrelated = [
            try makeFile(named: "clipflow.sqlite3", in: location.directory),
            try makeFile(named: "clipflow.sqlite3.backup", in: location.directory),
            try makeFile(named: "other.sqlite3.backup-20260711", in: location.directory),
            try makeFile(named: "notes.txt", in: location.directory)
        ]
        let manager = MigrationBackupManager(databaseDirectory: location.directory)

        let urls = try await manager.backupURLs()

        XCTAssertEqual(
            Set(urls.map { $0.resolvingSymlinksInPath() }),
            Set([managedA, managedB].map { $0.resolvingSymlinksInPath() })
        )
        XCTAssertTrue(unrelated.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testPurgeExpiredKeepsYoungerThan24HoursAndRemovesAtOrOver24Hours() async throws {
        let location = try TemporaryDatabaseLocation()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let young = try makeFile(named: "clipflow.sqlite3.backup-young", in: location.directory)
        let boundary = try makeFile(named: "clipflow.sqlite3.backup-boundary", in: location.directory)
        let old = try makeFile(named: "clipflow.sqlite3.backup-old", in: location.directory)
        let unrelated = try makeFile(named: "unrelated.backup-old", in: location.directory)
        try setModificationDate(now.addingTimeInterval(-MigrationBackupManager.maximumAge + 60), at: young)
        try setModificationDate(now.addingTimeInterval(-MigrationBackupManager.maximumAge), at: boundary)
        try setModificationDate(now.addingTimeInterval(-MigrationBackupManager.maximumAge - 60), at: old)
        try setModificationDate(now.addingTimeInterval(-MigrationBackupManager.maximumAge * 2), at: unrelated)
        let manager = MigrationBackupManager(databaseDirectory: location.directory)

        let removed = try await manager.purgeExpired(now: now)

        XCTAssertEqual(removed, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: young.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: boundary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testDeleteAllRemovesEveryManagedBackupAndLeavesUnrelatedFiles() async throws {
        let location = try TemporaryDatabaseLocation()
        let managed = [
            try makeFile(named: "clipflow.sqlite3.backup-one", in: location.directory),
            try makeFile(named: "clipflow.sqlite3.backup-two", in: location.directory),
            try makeFile(named: "clipflow.sqlite3.backup-three", in: location.directory)
        ]
        let unrelated = try makeFile(named: "clipflow.sqlite3", in: location.directory)
        let manager = MigrationBackupManager(databaseDirectory: location.directory)

        try await manager.deleteAll()

        XCTAssertTrue(managed.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        let remainingBackups = try await manager.backupURLs()
        XCTAssertEqual(remainingBackups, [])
    }

    func testDeletionFailureThrowsInsteadOfReportingSuccess() async throws {
        let location = try TemporaryDatabaseLocation()
        let sentinel = location.directory.appendingPathComponent("clipflow.sqlite3.backup-fails")
        let fileSystem = FailingMigrationBackupFileSystem(urls: [sentinel])
        let manager = MigrationBackupManager(
            databaseDirectory: location.directory,
            fileSystem: fileSystem
        )

        do {
            try await manager.deleteAll()
            XCTFail("Expected the injected deletion failure")
        } catch let error as FailingMigrationBackupFileSystem.Failure {
            XCTAssertEqual(error, .remove)
        }
        let removeAttempts = await fileSystem.removeAttempts()
        XCTAssertEqual(removeAttempts, [sentinel])
    }
}

private extension MigrationBackupManagerTests {
    func makeFile(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(name.utf8)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    func setModificationDate(_ date: Date, at url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
    }
}

private actor FailingMigrationBackupFileSystem: MigrationBackupFileSystem {
    enum Failure: Error, Equatable {
        case remove
    }

    private let urls: [URL]
    private var attemptedURLs: [URL] = []

    init(urls: [URL]) {
        self.urls = urls
    }

    func matchingBackupURLs(in directory: URL) async throws -> [URL] {
        urls
    }

    func modificationDate(at url: URL) async throws -> Date {
        .distantPast
    }

    func removeItem(at url: URL) async throws {
        attemptedURLs.append(url)
        throw Failure.remove
    }

    func removeAttempts() -> [URL] {
        attemptedURLs
    }
}
