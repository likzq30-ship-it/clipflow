import Foundation
@testable import ClipFlow

actor InMemoryMigrationBackupManager: MigrationBackupManaging {
    enum InjectedFailure: Error {
        case requested
    }

    private(set) var urls: [URL]
    private(set) var purgeExpiredCount = 0
    private(set) var deleteAllCount = 0
    var failPurgeExpired = false
    var failDeleteAll = false

    init(urls: [URL] = []) {
        self.urls = urls
    }

    func backupURLs() async throws -> [URL] {
        urls
    }

    func purgeExpired(now: Date) async throws -> Int {
        purgeExpiredCount += 1
        if failPurgeExpired {
            failPurgeExpired = false
            throw InjectedFailure.requested
        }
        let count = urls.count
        urls.removeAll()
        return count
    }

    func deleteAll() async throws {
        deleteAllCount += 1
        if failDeleteAll {
            failDeleteAll = false
            throw InjectedFailure.requested
        }
        urls.removeAll()
    }

    func setFailPurgeExpired(_ value: Bool) {
        failPurgeExpired = value
    }

    func setFailDeleteAll(_ value: Bool) {
        failDeleteAll = value
    }
}
