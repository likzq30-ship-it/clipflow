import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        let coordinator = AppCoordinator()
        self.coordinator = coordinator
        coordinator.start()
    }

    func openSettingsWindow() {
        coordinator?.openSettings()
    }
}
