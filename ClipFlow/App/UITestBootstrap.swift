import AppKit
import SwiftUI

@MainActor
final class UITestBootstrap {
    private var coordinator: UITestCoordinator?

    func start() {
        NSApp.setActivationPolicy(.regular)
        let coordinator = UITestCoordinator()
        self.coordinator = coordinator
        coordinator.start()
    }
}

@MainActor
private final class UITestCoordinator: NSObject, QuickPanelCoordinating {
    private var environment: AppEnvironment?
    private var recoveryHandler: RecoveryActionHandler?
    private var quickWindow: NSWindow?
    private var libraryWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var commandHandler: QuickPanelCommandHandler?
    private var libraryConsentPresenter: RemoteConsentSheetPresenter?
    private var libraryAIActionCoordinator: AIActionCoordinator?

    func start() {
        setupMainMenu()
        Task { @MainActor in
            do {
                let environment = try await makeEnvironment()
                let recoveryHandler = RecoveryActionHandler(
                    store: environment.store,
                    coordinator: self,
                    fileRevealer: UITestFileRevealer()
                )
                await environment.store.start()
                self.environment = environment
                self.recoveryHandler = recoveryHandler
                showQuickPanelWindow()
                NSApp.activate(ignoringOtherApps: true)
            } catch {
                showStartupFailure(error)
            }
        }
    }

    func closeQuickPanel() {
        quickWindow?.orderOut(nil)
    }

    func openLibrary(selectedID: UUID?) {
        guard let environment else { return }
        Task { @MainActor in
            let librarySelection = selectedID
                ?? environment.store.session(for: .quickPanel).selectedItemID
                ?? environment.store.session(for: .quickPanel).items.first?.id
            if let librarySelection {
                await environment.store.loadItem(id: librarySelection)
                environment.store.setSelection(librarySelection, for: .library)
            }
            showLibraryWindow(environment: environment)
        }
    }

    func openSettings() {
        guard let environment else { return }
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let actions = SettingsActionAdapter(
            settings: environment.settings,
            store: environment.store,
            aiJobs: environment.aiJobCoordinator,
            aiService: environment.aiService,
            keychain: environment.keychain,
            launchAtLogin: environment.launchAtLogin,
            logger: environment.logger
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = String(localized: "ClipFlow Settings")
        window.center()
        window.contentViewController = NSHostingController(
            rootView: SettingsRootView(
                settings: environment.settings,
                store: environment.store,
                hotkeyService: environment.hotkeyService,
                launchAtLogin: environment.launchAtLogin,
                actions: actions
            )
        )
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showCopyFeedback(_ outcome: CopyOutcome) {
        _ = outcome
    }

    @objc private func openSettingsMenuItem(_ sender: Any?) {
        openSettings()
    }
}

private extension UITestCoordinator {
    func setupMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let settings = NSMenuItem(
            title: String(localized: "Settings…"),
            action: #selector(openSettingsMenuItem(_:)),
            keyEquivalent: ","
        )
        settings.target = self
        appMenu.addItem(settings)

        NSApp.mainMenu = mainMenu
    }

    func showQuickPanelWindow() {
        guard let environment else { return }
        if let quickWindow {
            quickWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let commandHandler = QuickPanelCommandHandler(
            store: environment.store,
            coordinator: self
        )
        self.commandHandler = commandHandler
        if environment.store.session(for: .quickPanel).selectedItemID == nil {
            environment.store.setSelection(
                environment.store.session(for: .quickPanel).items.first?.id,
                for: .quickPanel
            )
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = String(localized: "ClipFlow Quick Panel")
        window.center()
        window.contentViewController = NSHostingController(
            rootView: QuickPanelView(
                store: environment.store,
                commandHandler: commandHandler,
                recoveryHandler: recoveryHandler,
                shortcutDisplay: environment.hotkeyService.currentShortcut.displayString,
                onReady: nil,
                onOpenSettings: { }
            )
        )
        quickWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showLibraryWindow(environment: AppEnvironment) {
        if let libraryWindow {
            libraryWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let consentPresenter = RemoteConsentSheetPresenter()
        libraryConsentPresenter = consentPresenter
        let aiActionCoordinator = AIActionCoordinator(
            settings: environment.settings,
            jobs: environment.aiJobCoordinator,
            consentPresenter: consentPresenter
        )
        libraryAIActionCoordinator = aiActionCoordinator

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = String(localized: "ClipFlow Library")
        window.minSize = NSSize(width: 760, height: 520)
        window.center()
        consentPresenter.window = window
        window.contentViewController = NSHostingController(
            rootView: LibraryView(
                store: environment.store,
                aiActions: aiActionCoordinator,
                jobs: environment.aiJobCoordinator,
                recoveryHandler: recoveryHandler
            )
        )
        libraryWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showStartupFailure(_ error: Error) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = String(localized: "ClipFlow UI Test Startup Failed")
        window.contentViewController = NSHostingController(
            rootView: VStack(spacing: 12) {
                Text("ClipFlow UI test bootstrap failed")
                    .font(.headline)
                Text(String(describing: error))
                    .font(.caption)
                    .textSelection(.enabled)
            }
            .padding()
        )
        quickWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func makeEnvironment() async throws -> AppEnvironment {
        let environment = ProcessInfo.processInfo.environment
        let databaseURL = databaseURL(environment: environment)
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let settings = AppSettingsStore(
            userDefaults: UserDefaults(suiteName: "com.clipflow.v12.ui-testing.\(UUID().uuidString)")!
        )
        let repository = ClipboardRepository(databaseURL: databaseURL)
        let preparedStartup = try await repository.prepare(legacyCategories: [])
        try await seedFixtureClips(repository)
        let startup = environment["CLIPFLOW_UI_READ_ONLY"] == "1"
            ? RepositoryStartup.readOnlyRecovery(
                databaseURL: databaseURL,
                backupURL: databaseURL.deletingPathExtension().appendingPathExtension("backup.sqlite3"),
                errorCode: AppErrorCode.databaseReadOnly.rawValue
            )
            : preparedStartup
        let captureService = UITestClipboardCaptureService()
        let logger = AppLogger()
        let store = ClipboardStore(
            repository: repository,
            captureService: captureService,
            capturePipeline: CapturePipeline(
                privacyGuard: PrivacyGuard(detector: SensitiveContentDetector()),
                classifier: TextClassifier(),
                repository: repository,
                configuration: settings.privacyConfiguration
            ),
            backupManager: MigrationBackupManager(databaseDirectory: databaseURL.deletingLastPathComponent()),
            settings: settings,
            startup: startup,
            logger: logger
        )
        let keychain = KeychainCredentialStore()
        let ai = AIService(
            http: URLSessionHTTPClient(),
            keychain: keychain,
            localRules: LocalRulesService()
        )

        return AppEnvironment(
            store: store,
            settings: settings,
            captureService: captureService,
            hotkeyService: HotkeyService(
                registrar: UITestHotKeyRegistrar(),
                settings: settings
            ),
            aiService: ai,
            aiJobCoordinator: AIJobCoordinator(ai: ai, store: store),
            keychain: keychain,
            launchAtLogin: LaunchAtLoginService(registrar: UITestLoginItemRegistrar()),
            logger: logger,
            startup: startup
        )
    }

    func seedFixtureClips(_ repository: ClipboardRepository) async throws {
        let base = Date().addingTimeInterval(-2)
        let captures = [
            CapturedText(
                content: "Meeting notes",
                category: .english,
                capturedAt: base,
                sourceBundleID: nil
            ),
            CapturedText(
                content: "https://example.com",
                category: .url,
                capturedAt: base.addingTimeInterval(1),
                sourceBundleID: nil
            ),
            CapturedText(
                content: "Project roadmap",
                category: .english,
                capturedAt: base.addingTimeInterval(2),
                sourceBundleID: nil
            )
        ]
        for capture in captures {
            _ = try await repository.upsertCapturedText(capture)
        }
    }

    func databaseURL(environment: [String: String]) -> URL {
        if let path = environment["CLIPFLOW_TEST_DATABASE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return URL(fileURLWithPath: path)
        }

        return FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipFlowUITesting-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("clipflow.sqlite3")
    }
}

@MainActor
private final class UITestClipboardCaptureService: ClipboardCaptureServiceProtocol {
    private(set) var pauseState: MonitoringPause = .active
    private var handler: (@MainActor (RawClipboardCapture) -> Void)?

    func start(handler: @escaping @MainActor (RawClipboardCapture) -> Void) {
        self.handler = handler
    }

    func stop() {
        handler = nil
    }

    func pause(_ state: MonitoringPause) {
        pauseState = state
    }

    func resume() {
        pauseState = .active
    }

    func write(_ text: String) -> Bool {
        _ = text
        return true
    }
}

@MainActor
private final class UITestHotKeyRegistrar: HotKeyRegistrar {
    func register(
        _ shortcut: ShortcutMapping,
        id: UInt32,
        handler: @escaping @MainActor () -> Void
    ) throws -> HotKeyToken {
        _ = shortcut
        _ = handler
        return HotKeyToken(rawID: id)
    }

    func unregister(_ token: HotKeyToken) {
        _ = token
    }
}

@MainActor
private final class UITestLoginItemRegistrar: LoginItemRegistering {
    private(set) var isRegistered = false

    func register() throws {
        isRegistered = true
    }

    func unregister() throws {
        isRegistered = false
    }
}

@MainActor
private final class UITestFileRevealer: FileRevealing {
    func reveal(_ url: URL) {
        _ = url
    }
}
