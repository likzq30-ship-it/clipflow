import Foundation

enum RepositoryStartup: Equatable, Sendable {
    case readWrite(DatabasePreparation)
    case readOnlyRecovery(databaseURL: URL, backupURL: URL?, errorCode: String)

    var isReadOnly: Bool {
        if case .readOnlyRecovery = self { return true }
        return false
    }
}
