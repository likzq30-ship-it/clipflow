import Foundation

enum DatabaseError: LocalizedError, Equatable, Sendable {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case migrationFailed(message: String, databaseURL: URL, backupURL: URL?)
    case itemNotFound(UUID)
    case readOnlyRecovery(databaseURL: URL, backupURL: URL?)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            return "无法打开剪贴板数据库：\(message)"
        case .prepareFailed(let message):
            return "无法准备数据库操作：\(message)"
        case .stepFailed(let message):
            return "无法写入剪贴板数据库：\(message)"
        case .migrationFailed(let message, _, _):
            return "数据库升级失败：\(message)"
        case .itemNotFound:
            return "剪贴板记录已不存在"
        case .readOnlyRecovery:
            return "数据库已进入只读恢复模式"
        }
    }
}
