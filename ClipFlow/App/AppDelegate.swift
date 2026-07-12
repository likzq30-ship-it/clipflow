import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?
    private var uiTestBootstrap: UITestBootstrap?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            let uiTestBootstrap = UITestBootstrap()
            self.uiTestBootstrap = uiTestBootstrap
            uiTestBootstrap.start()
            return
        }

        let coordinator = AppCoordinator()
        self.coordinator = coordinator
        coordinator.start()
    }
}
