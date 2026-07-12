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
    private var libraryDelegate: WindowRetainerDelegate?
    private var settingsDelegate: WindowRetainerDelegate?
    private var copyFeedbackTask: Task<Void, Never>?
    private var readyContinuation: CheckedContinuation<Void, Never>?
    private var simulatedQuickPanelShownForTesting = false

    #if DEBUG
    private(set) var openSettingsCountForTesting = 0
    private(set) var quitRequestCountForTesting = 0
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
        if let statusItem {
            MainActor.assumeIsolated {
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
            environment.store.setSelection(selectedID, for: .library)
        }

        if let libraryWindow {
            libraryWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ClipFlow History"
        window.center()
        window.contentViewController = NSHostingController(
            rootView: HistoryWindowView(
                store: environment.store,
                selectedID: selectedID,
                onSettings: { [weak self] in self?.openSettings() }
            )
        )
        window.isReleasedWhenClosed = false
        libraryDelegate = WindowRetainerDelegate { [weak self] in
            self?.libraryWindow = nil
            self?.libraryDelegate = nil
        }
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
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ClipFlow Settings"
        window.center()
        window.contentViewController = NSHostingController(
            rootView: SettingsView(
                hotkeyService: environment.hotkeyService,
                ollamaService: OllamaService.shared,
                isOpen: Binding(
                    get: { true },
                    set: { [weak window] isOpen in
                        if !isOpen { window?.close() }
                    }
                )
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
        button.setAccessibilityLabel("ClipFlow")
        button.setAccessibilityHelp("Open ClipFlow clipboard history")
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
                title: "About ClipFlow",
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                keyEquivalent: ""
            )
        )
        appMenu.addItem(NSMenuItem.separator())

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsMenuItem(_:)),
            keyEquivalent: ","
        )
        settings.target = self
        appMenu.addItem(settings)

        appMenu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(
            title: "Quit ClipFlow",
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
            title: "Open History",
            action: #selector(openLibraryMenuItem(_:)),
            keyEquivalent: ""
        )
        history.target = self
        menu.addItem(history)

        let settings = NSMenuItem(
            title: "Settings",
            action: #selector(openSettingsMenuItem(_:)),
            keyEquivalent: ""
        )
        settings.target = self
        menu.addItem(settings)

        let monitoringTitle: String
        if case .active = environment?.store.monitoringPause ?? .active {
            monitoringTitle = "Pause Monitoring"
        } else {
            monitoringTitle = "Resume Monitoring"
        }
        let monitoring = NSMenuItem(
            title: monitoringTitle,
            action: #selector(toggleMonitoringMenuItem(_:)),
            keyEquivalent: ""
        )
        monitoring.target = self
        menu.addItem(monitoring)

        let about = NSMenuItem(
            title: "About ClipFlow",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        menu.addItem(about)

        let quit = NSMenuItem(
            title: "Quit ClipFlow",
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
        installQuickPanelContent()
        guard let button = statusItem?.button else {
            simulatedQuickPanelShownForTesting = true
            return
        }
        popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
                    onReady: { [weak self] in self?.resumeReadyProbeIfNeeded() }
                )
            )
        }

        if let bootstrapError {
            return AnyView(
                StartupQuickPanelView(
                    title: "ClipFlow could not start",
                    message: String(describing: bootstrapError)
                )
                .frame(width: 440, height: 520)
            )
        }

        return AnyView(
            StartupQuickPanelView(
                title: "Starting ClipFlow…",
                message: "Preparing the clipboard database."
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

    func resumeReadyProbeIfNeeded() {
        readyContinuation?.resume()
        readyContinuation = nil
    }
}

#if DEBUG
extension AppCoordinator {
    static func performanceFixture() async throws -> AppCoordinator {
        let environment = try await AppEnvironment.performanceFixture()
        return AppCoordinator(
            environmentFactory: { environment },
            terminateApplication: {}
        )
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

    func closeQuickPanelForTesting() {
        closeQuickPanel()
    }
}
#endif

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

private struct HistoryWindowView: View {
    @ObservedObject var store: ClipboardStore
    let selectedID: UUID?
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ClipFlow History")
                    .font(.headline)
                Spacer()
                Button("Settings", action: onSettings)
            }
            .padding()
            Divider()
            List(selection: Binding(
                get: { store.session(for: .library).selectedItemID },
                set: { store.setSelection($0, for: .library) }
            )) {
                ForEach(store.session(for: .library).items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.displayContent)
                            .lineLimit(2)
                        Text(item.displayCategory)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(item.id)
                }
            }
        }
        .onAppear {
            if let selectedID {
                store.setSelection(selectedID, for: .library)
            }
        }
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
