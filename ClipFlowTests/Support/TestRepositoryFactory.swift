import Foundation
@testable import ClipFlow

// Test fixtures deliberately transfer one FULLMUTEX connection into the repository actor.
#if compiler(>=6.0)
extension SQLiteDatabase: @unchecked @retroactive Sendable {}
#else
extension SQLiteDatabase: @unchecked Sendable {}
#endif

func makeRepository() async throws -> ClipboardRepository {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let url = directory.appendingPathComponent("clipflow.sqlite3")
    let repository = ClipboardRepository(databaseURL: url)
    let startup = try await repository.prepare(legacyCategories: [])
    guard case .readWrite = startup else {
        throw DatabaseError.readOnlyRecovery(databaseURL: url, backupURL: nil)
    }
    return repository
}
