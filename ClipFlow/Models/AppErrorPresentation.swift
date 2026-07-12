import Foundation

enum AppBannerSeverity: Equatable, Sendable {
    case information
    case warning
    case error
}

enum ClipSurface: Hashable, Sendable {
    case quickPanel
    case library
}

enum RecoveryAction: Equatable, Sendable {
    case retry(surface: ClipSurface)
    case openSettings
    case revealBackup(URL)
    case deleteMigrationBackups
}

struct AppErrorPresentation: Identifiable, Equatable, Sendable {
    let id: UUID
    let code: AppErrorCode
    let message: String
    let severity: AppBannerSeverity
    let recoveryTitle: String?
    let recoveryAction: RecoveryAction?

    init(
        id: UUID = UUID(),
        code: AppErrorCode,
        message: String,
        severity: AppBannerSeverity,
        recoveryTitle: String? = nil,
        recoveryAction: RecoveryAction? = nil
    ) {
        self.id = id
        self.code = code
        self.message = message
        self.severity = severity
        self.recoveryTitle = recoveryTitle
        self.recoveryAction = recoveryAction
    }
}

struct ClipQuerySession: Equatable, Sendable {
    var query: ClipQuery
    var items: [ClipboardItem]
    var selectedItemID: UUID?
    var totalCount: Int
    var nextOffset: Int?
    var isLoading: Bool
}

struct PendingDelete: Equatable, Sendable {
    let itemID: UUID
    let deletedAt: Date
    let expiresAt: Date
}

enum AIResultApplication: Equatable, Sendable {
    case applied(ClipboardItem)
    case staleGeneration
    case targetMissing
    case failed(AppErrorCode)
}

enum ClearClipboardDataOutcome: Equatable, Sendable {
    case complete(removedClipCount: Int)
    case partial(removedClipCount: Int, code: AppErrorCode)
    case failed(AppErrorCode)
}

enum CopyOutcome: Equatable, Sendable {
    case copied
    case copiedWithMetadataWarning
    case clipboardWriteFailed
}

struct DiagnosticEvent: Equatable, Sendable {
    let code: AppErrorCode
    let timestamp: Date
}

protocol AppLogging: Sendable {
    func record(_ event: DiagnosticEvent) async
    func recentEvents(limit: Int) async -> [DiagnosticEvent]
}
