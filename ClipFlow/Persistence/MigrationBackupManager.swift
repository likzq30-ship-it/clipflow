import Foundation

protocol MigrationBackupManaging: Sendable {
    func backupURLs() async throws -> [URL]
    func purgeExpired(now: Date) async throws -> Int
    func deleteAll() async throws
}

protocol MigrationBackupFileSystem: Sendable {
    func matchingBackupURLs(in directory: URL) async throws -> [URL]
    func modificationDate(at url: URL) async throws -> Date
    func removeItem(at url: URL) async throws
}

actor LocalMigrationBackupFileSystem: MigrationBackupFileSystem {
    func matchingBackupURLs(in directory: URL) async throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        return try FileManager.default
            .contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
            .filter { url in
                guard url.lastPathComponent.hasPrefix("clipflow.sqlite3.backup-") else {
                    return false
                }
                return (try? url.resourceValues(forKeys: keys).isRegularFile) == true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func modificationDate(at url: URL) async throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let date = attributes[.modificationDate] as? Date else {
            throw CocoaError(.fileReadUnknown)
        }
        return date
    }

    func removeItem(at url: URL) async throws {
        try FileManager.default.removeItem(at: url)
    }
}

actor MigrationBackupManager: MigrationBackupManaging {
    static let maximumAge: TimeInterval = 24 * 60 * 60

    private let databaseDirectory: URL
    private let fileSystem: any MigrationBackupFileSystem

    init(
        databaseDirectory: URL,
        fileSystem: any MigrationBackupFileSystem = LocalMigrationBackupFileSystem()
    ) {
        self.databaseDirectory = databaseDirectory
        self.fileSystem = fileSystem
    }

    func backupURLs() async throws -> [URL] {
        try await fileSystem.matchingBackupURLs(in: databaseDirectory)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func purgeExpired(now: Date) async throws -> Int {
        var removedCount = 0
        for url in try await backupURLs() {
            let modificationDate = try await fileSystem.modificationDate(at: url)
            guard now.timeIntervalSince(modificationDate) >= Self.maximumAge else { continue }
            try await fileSystem.removeItem(at: url)
            removedCount += 1
        }
        return removedCount
    }

    func deleteAll() async throws {
        for url in try await backupURLs() {
            try await fileSystem.removeItem(at: url)
        }
    }
}
