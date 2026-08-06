import AppKit
import SwiftUI

@MainActor
final class AppCoordinator: NSObject, QuickPanelCoordinating {
    private let environmentFactory: () async throws -> AppEnvironment
    private let terminateApplication: @MainActor () -> Void
    private var didStart = false
    private var bootstrapTask: Task<Void, Never>?

    private(set) var environment: AppEnvironment?
    private var bootstrapError: Error?
    private var recoveryHandler: RecoveryActionHandler?
    private var quickPanelCommandHandler: QuickPanelCommandHandler?

    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var popover: NSPopover?
    private var libraryWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var libraryDelegate: LibraryWindowDelegate?
    private var settingsDelegate: WindowRetainerDelegate?
    private var libraryConsentPresenter: RemoteConsentSheetPresenter?
    private var libraryAIActionCoordinator: AIActionCoordinator?
    private var copyFeedbackTask: Task<Void, Never>?
    private var readyContinuation: CheckedContinuation<Void, Never>?
    private var readyProbeState = QuickPanelReadyProbeState()
    private var isReadyProbeActive = false
    private var simulatedQuickPanelShownForTesting = false

    #if DEBUG
    private(set) var openSettingsCountForTesting = 0
    private(set) var quitRequestCountForTesting = 0
    private var settingsStoreForTestingStorage: ClipboardStore?
    private var libraryRecoveryPresentationForTestingStorage: AppErrorPresentation?
    private var libraryRecoveryBannerIsUndismissableForTestingStorage = false
    #endif

    init(
        environmentFactory: @escaping () async throws -> AppEnvironment = AppEnvironment.live,
        terminateApplication: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }
    ) {
        self.environmentFactory = environmentFactory
        self.terminateApplication = terminateApplication
        super.init()
    }

    deinit {
        copyFeedbackTask?.cancel()
        bootstrapTask?.cancel()
        MainActor.assumeIsolated {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        configureActivationPolicy()
        setupMainMenu()
        setupStatusItem()
        startBootstrap()
    }

    func toggleQuickPanel() {
        if popover?.isShown == true {
            closeQuickPanel()
        } else {
            presentQuickPanel()
        }
    }

    func closeQuickPanel() {
        popover?.performClose(nil)
        simulatedQuickPanelShownForTesting = false
    }

    func openLibrary(selectedID: UUID?) {
        guard let environment else { return }
        if let selectedID {
            Task { @MainActor [weak self, environment] in
                await environment.store.loadItem(id: selectedID)
                environment.store.setSelection(selectedID, for: .library)
                self?.presentLibraryWindow(environment: environment)
            }
        } else {
            presentLibraryWindow(environment: environment)
        }
    }

    private func presentLibraryWindow(environment: AppEnvironment) {
        let recoveryPresentation = readOnlyRecoveryPresentation(for: environment.store.repositoryStartup)
        #if DEBUG
        libraryRecoveryPresentationForTestingStorage = recoveryPresentation
        libraryRecoveryBannerIsUndismissableForTestingStorage = recoveryPresentation != nil
        #endif

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
        window.title = String(localized: "ClipFlow Library")
        window.minSize = NSSize(width: 760, height: 520)
        window.setFrameAutosaveName("ClipFlow.LibraryWindow")
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
        window.isReleasedWhenClosed = false
        libraryDelegate = LibraryWindowDelegate(
            onPrepareClose: { [jobs = environment.aiJobCoordinator] in
                await jobs.cancelAll()
                jobs.clearAllTransientResults()
            },
            onClose: { [weak self] in
                self?.libraryWindow = nil
                self?.libraryDelegate = nil
                self?.libraryConsentPresenter = nil
                self?.libraryAIActionCoordinator = nil
            }
        )
        window.delegate = libraryDelegate
        libraryWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openSettings() {
        #if DEBUG
        openSettingsCountForTesting += 1
        #endif

        guard let environment else { return }
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "ClipFlow Settings")
        window.center()
        #if DEBUG
        settingsStoreForTestingStorage = environment.store
        #endif
        let settingsActions = SettingsActionAdapter(
            settings: environment.settings,
            store: environment.store,
            aiJobs: environment.aiJobCoordinator,
            aiService: environment.aiService,
            keychain: environment.keychain,
            launchAtLogin: environment.launchAtLogin,
            logger: environment.logger
        )
        window.contentViewController = NSHostingController(
            rootView: SettingsRootView(
                settings: environment.settings,
                store: environment.store,
                hotkeyService: environment.hotkeyService,
                launchAtLogin: environment.launchAtLogin,
                actions: settingsActions
            )
        )
        window.isReleasedWhenClosed = false
        settingsDelegate = WindowRetainerDelegate { [weak self] in
            self?.settingsWindow = nil
            self?.settingsDelegate = nil
        }
        window.delegate = settingsDelegate
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showCopyFeedback(_ outcome: CopyOutcome) {
        copyFeedbackTask?.cancel()
        setStatusItemFeedback(for: outcome)
        copyFeedbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.refreshStatusItemState()
            }
        }
    }
}

private extension AppCoordinator {
    func configureActivationPolicy() {
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func startBootstrap() {
        bootstrapTask = Task { [weak self] in
            guard let self else { return }
            do {
                let environment = try await environmentFactory()
                environment.hotkeyService.onHotkeyPressed = { [weak self] in
                    self?.toggleQuickPanel()
                }
                let recoveryHandler = RecoveryActionHandler(
                    store: environment.store,
                    coordinator: self,
                    fileRevealer: SystemFileRevealer()
                )
                await environment.store.start()
                self.environment = environment
                self.recoveryHandler = recoveryHandler
                self.bootstrapError = nil
            } catch {
                self.bootstrapError = error
            }
            self.refreshStatusItemState()
            if self.popover?.isShown == true || self.simulatedQuickPanelShownForTesting {
                self.installQuickPanelContent()
            }
        }
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        button.image?.isTemplate = true
        button.title = ""
        button.target = self
        button.action = #selector(statusButtonClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel(String(localized: "ClipFlow"))
        button.setAccessibilityHelp(String(localized: "Open ClipFlow clipboard history"))
        button.setAccessibilityValue("active")
    }

    func setupMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        appMenu.addItem(
            NSMenuItem(
                title: String(localized: "About ClipFlow"),
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                keyEquivalent: ""
            )
        )
        appMenu.addItem(NSMenuItem.separator())

        let settings = NSMenuItem(
            title: String(localized: "Settings…"),
            action: #selector(openSettingsMenuItem(_:)),
            keyEquivalent: ","
        )
        settings.target = self
        appMenu.addItem(settings)

        appMenu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(
            title: String(localized: "Quit ClipFlow"),
            action: #selector(quitMenuItem(_:)),
            keyEquivalent: "q"
        )
        quit.target = self
        appMenu.addItem(quit)

        NSApp.mainMenu = mainMenu
    }

    @objc func statusButtonClicked(_ sender: NSStatusBarButton?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else {
            toggleQuickPanel()
        }
    }

    @objc func openLibraryMenuItem(_ sender: Any?) {
        openLibrary(selectedID: nil)
    }

    @objc func openSettingsMenuItem(_ sender: Any?) {
        openSettings()
    }

    @objc func toggleMonitoringMenuItem(_ sender: Any?) {
        guard let store = environment?.store else { return }
        switch store.monitoringPause {
        case .active:
            store.pauseMonitoring(.indefinitely)
        case .until, .indefinitely:
            store.resumeMonitoring()
        }
        refreshStatusItemState()
    }

    @objc func quitMenuItem(_ sender: Any?) {
        #if DEBUG
        quitRequestCountForTesting += 1
        #endif
        terminateApplication()
    }

    func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()

        let history = NSMenuItem(
            title: String(localized: "Open History"),
            action: #selector(openLibraryMenuItem(_:)),
            keyEquivalent: ""
        )
        history.target = self
        menu.addItem(history)

        let settings = NSMenuItem(
            title: String(localized: "Settings"),
            action: #selector(openSettingsMenuItem(_:)),
            keyEquivalent: ""
        )
        settings.target = self
        menu.addItem(settings)

        let monitoringTitle: String
        if case .active = environment?.store.monitoringPause ?? .active {
            monitoringTitle = String(localized: "Pause Monitoring")
        } else {
            monitoringTitle = String(localized: "Resume Monitoring")
        }
        let monitoring = NSMenuItem(
            title: monitoringTitle,
            action: #selector(toggleMonitoringMenuItem(_:)),
            keyEquivalent: ""
        )
        monitoring.target = self
        menu.addItem(monitoring)

        let about = NSMenuItem(
            title: String(localized: "About ClipFlow"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        menu.addItem(about)

        let quit = NSMenuItem(
            title: String(localized: "Quit ClipFlow"),
            action: #selector(quitMenuItem(_:)),
            keyEquivalent: ""
        )
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    func showStatusMenu() {
        let menu = makeStatusMenu()
        statusMenu = menu
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    func presentQuickPanel() {
        startQuickPanelReadyProbe()
        installQuickPanelContent()
        guard let button = statusItem?.button else {
            simulatedQuickPanelShownForTesting = true
            markQuickPanelPopoverShownForReadyProbe()
            return
        }
        popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if popover?.isShown == true {
            markQuickPanelPopoverShownForReadyProbe()
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.popover?.isShown == true else { return }
                self.markQuickPanelPopoverShownForReadyProbe()
            }
        }
    }

    func installQuickPanelContent() {
        if popover == nil {
            let popover = NSPopover()
            popover.contentSize = NSSize(width: 440, height: 520)
            popover.behavior = .transient
            popover.animates = true
            self.popover = popover
        }
        popover?.contentViewController = NSHostingController(rootView: quickPanelRootView())
    }

    func quickPanelRootView() -> AnyView {
        if let environment {
            let commandHandler = QuickPanelCommandHandler(
                store: environment.store,
                coordinator: self
            )
            quickPanelCommandHandler = commandHandler
            return AnyView(
                QuickPanelView(
                    store: environment.store,
                    commandHandler: commandHandler,
                    recoveryHandler: recoveryHandler,
                    shortcutDisplay: environment.hotkeyService.currentShortcut.displayString,
                    onReady: { [weak self] in self?.markQuickPanelViewReadyForReadyProbe() },
                    onOpenSettings: { [weak self] in self?.openSettings() }
                )
            )
        }

        if let bootstrapError {
            return AnyView(
                StartupQuickPanelView(
                    title: String(localized: "ClipFlow could not start"),
                    message: String(describing: bootstrapError)
                )
                .frame(width: 440, height: 520)
            )
        }

        return AnyView(
            StartupQuickPanelView(
                title: String(localized: "Starting ClipFlow…"),
                message: String(localized: "Preparing the clipboard database.")
            )
            .frame(width: 440, height: 520)
        )
    }

    func refreshStatusItemState() {
        let value: String
        if environment?.store.banner?.severity == .error || bootstrapError != nil {
            value = "error"
        } else if let pause = environment?.store.monitoringPause, pause != .active {
            value = "paused"
        } else {
            value = "active"
        }
        statusItem?.button?.setAccessibilityValue(value)
        let symbolName = value == "error"
            ? "exclamationmark.triangle"
            : (value == "paused" ? "pause.circle" : "doc.on.clipboard")
        statusItem?.button?.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        statusItem?.button?.image?.isTemplate = true
    }

    func setStatusItemFeedback(for outcome: CopyOutcome) {
        let value = outcome == .copied ? "copied" : "copiedWithMetadataWarning"
        statusItem?.button?.setAccessibilityValue(value)
        let symbolName = outcome == .copied ? "checkmark.circle" : "exclamationmark.circle"
        statusItem?.button?.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        statusItem?.button?.image?.isTemplate = true
    }

    func startQuickPanelReadyProbe() {
        readyProbeState = QuickPanelReadyProbeState()
        isReadyProbeActive = true
    }

    func markQuickPanelPopoverShownForReadyProbe() {
        readyProbeState.popoverShown = true
        resumeReadyProbeIfNeeded()
    }

    func markQuickPanelViewReadyForReadyProbe() {
        readyProbeState.viewReady = true
        resumeReadyProbeIfNeeded()
    }

    func resumeReadyProbeIfNeeded() {
        guard isReadyProbeActive, readyProbeState.isReady else { return }
        readyContinuation?.resume()
        readyContinuation = nil
        isReadyProbeActive = false
        readyProbeState = QuickPanelReadyProbeState()
    }
}

#if DEBUG
extension AppCoordinator {
    static func performanceFixture(startup: RepositoryStartup? = nil) async throws -> AppCoordinator {
        let environment = try await AppEnvironment.performanceFixture(startup: startup)
        return AppCoordinator(
            environmentFactory: { environment },
            terminateApplication: {}
        )
    }

    var environmentStoreForTesting: ClipboardStore? {
        environment?.store
    }

    var settingsStoreForTesting: ClipboardStore? {
        settingsStoreForTestingStorage
    }

    var libraryRecoveryPresentationForTesting: AppErrorPresentation? {
        libraryRecoveryPresentationForTestingStorage
    }

    var libraryRecoveryBannerIsUndismissableForTesting: Bool {
        libraryRecoveryBannerIsUndismissableForTestingStorage
    }

    var hasLibraryWindowForTesting: Bool {
        libraryWindow != nil
    }

    var hasPendingQuickPanelReadyProbeForTesting: Bool {
        isReadyProbeActive
    }

    func waitForEnvironmentForTesting() async {
        await bootstrapTask?.value
    }

    var statusButtonForTesting: NSStatusBarButton? {
        statusItem?.button
    }

    var isQuickPanelShownForTesting: Bool {
        simulatedQuickPanelShownForTesting || popover?.isShown == true
    }

    var statusMenuTitlesForTesting: [String] {
        (statusMenu ?? makeStatusMenu()).items
            .filter { !$0.isSeparatorItem }
            .map(\.title)
    }

    func simulateStatusButtonClickForTesting(type: NSEvent.EventType) {
        switch type {
        case .rightMouseUp:
            statusMenu = makeStatusMenu()
        default:
            simulatedQuickPanelShownForTesting.toggle()
            if simulatedQuickPanelShownForTesting {
                installQuickPanelContent()
            } else {
                closeQuickPanel()
            }
        }
    }

    func simulateGlobalHotkeyForTesting() {
        simulateStatusButtonClickForTesting(type: .leftMouseUp)
    }

    func performSettingsMenuItemForTesting() {
        openSettingsMenuItem(nil)
    }

    func performQuitMenuItemForTesting() {
        quitMenuItem(nil)
    }

    func presentQuickPanelAndWaitUntilReadyForTesting() async {
        await withCheckedContinuation { continuation in
            readyContinuation = continuation
            presentQuickPanel()
        }
    }

    func beginQuickPanelReadyProbeForTesting() {
        startQuickPanelReadyProbe()
    }

    func markQuickPanelViewReadyForTesting() {
        markQuickPanelViewReadyForReadyProbe()
    }

    func markQuickPanelPopoverShownForTesting() {
        markQuickPanelPopoverShownForReadyProbe()
    }

    func closeQuickPanelForTesting() {
        closeQuickPanel()
    }
}
#endif

private struct QuickPanelReadyProbeState {
    var popoverShown = false
    var viewReady = false

    var isReady: Bool {
        popoverShown && viewReady
    }
}

private struct StartupQuickPanelView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }
}

func readOnlyRecoveryPresentation(for startup: RepositoryStartup) -> AppErrorPresentation? {
    guard case .readOnlyRecovery(_, let backupURL, _) = startup else { return nil }
    return AppErrorPresentation(
        code: .databaseReadOnly,
        message: backupURL.map {
            String(localized: "ClipFlow is browsing a read-only database. Backup: \($0.lastPathComponent)")
        } ?? String(localized: "ClipFlow is browsing a read-only database."),
        severity: .warning,
        recoveryTitle: backupURL == nil ? nil : String(localized: "Reveal Backup"),
        recoveryAction: backupURL.map(RecoveryAction.revealBackup)
    )
}

@MainActor
private final class LibraryWindowDelegate: NSObject, NSWindowDelegate {
    private let onPrepareClose: @MainActor () async -> Void
    private let onClose: @MainActor () -> Void
    private var isPerformingClose = false

    init(
        onPrepareClose: @escaping @MainActor () async -> Void,
        onClose: @escaping @MainActor () -> Void
    ) {
        self.onPrepareClose = onPrepareClose
        self.onClose = onClose
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isPerformingClose else { return true }
        isPerformingClose = true
        Task { @MainActor in
            await onPrepareClose()
            sender.performClose(nil)
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

private final class WindowRetainerDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
