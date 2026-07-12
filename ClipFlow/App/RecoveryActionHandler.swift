import AppKit
import Foundation

@MainActor
protocol QuickPanelCoordinating: AnyObject {
    func closeQuickPanel()
    func openLibrary(selectedID: UUID?)
    func openSettings()
    func showCopyFeedback(_ outcome: CopyOutcome)
}

@MainActor
protocol FileRevealing: AnyObject {
    func reveal(_ url: URL)
}

@MainActor
final class SystemFileRevealer: FileRevealing {
    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

@MainActor
final class RecoveryActionHandler {
    private let store: ClipboardStore
    private weak var coordinator: (any QuickPanelCoordinating)?
    private let fileRevealer: any FileRevealing

    init(
        store: ClipboardStore,
        coordinator: any QuickPanelCoordinating,
        fileRevealer: any FileRevealing
    ) {
        self.store = store
        self.coordinator = coordinator
        self.fileRevealer = fileRevealer
    }

    func handle(_ action: RecoveryAction) async {
        switch action {
        case .retry(let surface):
            let previousBannerID = store.banner?.id
            await store.reload(surface)
            if store.banner?.id == previousBannerID {
                store.clearBanner(afterSuccessfulRecoveryOf: action)
            }
        case .openSettings:
            coordinator?.openSettings()
        case .revealBackup(let url):
            fileRevealer.reveal(url)
        case .deleteMigrationBackups:
            if await store.deleteMigrationBackups() {
                store.clearBanner(afterSuccessfulRecoveryOf: action)
            }
        }
    }
}
