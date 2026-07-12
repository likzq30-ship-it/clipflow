import AppKit
import Foundation

@MainActor
struct AppEnvironment {
    let store: ClipboardStore
    let settings: AppSettingsStore
    let captureService: any ClipboardCaptureServiceProtocol
    let hotkeyService: HotkeyService
    let aiJobCoordinator: AIJobCoordinator
    let startup: RepositoryStartup

    static func live() async throws -> AppEnvironment {
        let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        let databaseURL = try productionDatabaseURL(
            isUITesting: isUITesting,
            environment: ProcessInfo.processInfo.environment
        )
        let userDefaults = isUITesting
            ? UserDefaults(suiteName: "com.clipflow.v12.ui-testing.\(UUID().uuidString)")!
            : .standard
        let settings = AppSettingsStore(userDefaults: userDefaults)
        let legacyCategories = isUITesting
            ? []
            : settings.pendingLegacySettingsSnapshot?.migratedCategories(now: Date()) ?? []

        let repository = ClipboardRepository(databaseURL: databaseURL)
        let startup = try await repository.prepare(legacyCategories: legacyCategories)
        let backupManager = MigrationBackupManager(
            databaseDirectory: databaseURL.deletingLastPathComponent()
        )

        let captureService = ClipboardCaptureService(
            pasteboard: SystemPasteboardClient(),
            sourceBundleID: {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            }
        )
        let capturePipeline = CapturePipeline(
            privacyGuard: PrivacyGuard(detector: SensitiveContentDetector()),
            classifier: TextClassifier(),
            repository: repository,
            configuration: settings.privacyConfiguration
        )
        let logger = AppLogger()
        let store = ClipboardStore(
            repository: repository,
            captureService: captureService,
            capturePipeline: capturePipeline,
            backupManager: backupManager,
            settings: settings,
            startup: startup,
            logger: logger
        )
        let ai = AIService(
            http: URLSessionHTTPClient(),
            keychain: KeychainCredentialStore(),
            localRules: LocalRulesService()
        )
        let aiJobCoordinator = AIJobCoordinator(ai: ai, store: store)
        let hotkeyService = HotkeyService(
            registrar: CarbonHotKeyRegistrar(),
            settings: settings
        )
        return AppEnvironment(
            store: store,
            settings: settings,
            captureService: captureService,
            hotkeyService: hotkeyService,
            aiJobCoordinator: aiJobCoordinator,
            startup: startup
        )
    }

    static func performanceFixture(startup startupOverride: RepositoryStartup? = nil) async throws -> AppEnvironment {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipFlow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let databaseURL = directory.appendingPathComponent("clipflow.sqlite3")
        let settings = AppSettingsStore(
            userDefaults: UserDefaults(suiteName: "com.clipflow.v12.tests.\(UUID().uuidString)")!
        )
        let repository = ClipboardRepository(databaseURL: databaseURL)
        let preparedStartup = try await repository.prepare(legacyCategories: [])
        let startup = startupOverride ?? preparedStartup
        let captureService = NoopClipboardCaptureService()
        let store = ClipboardStore(
            repository: repository,
            captureService: captureService,
            capturePipeline: CapturePipeline(
                privacyGuard: PrivacyGuard(detector: SensitiveContentDetector()),
                classifier: TextClassifier(),
                repository: repository,
                configuration: settings.privacyConfiguration
            ),
            backupManager: MigrationBackupManager(databaseDirectory: directory),
            settings: settings,
            startup: startup,
            logger: AppLogger()
        )
        let ai = AIService(
            http: URLSessionHTTPClient(),
            keychain: KeychainCredentialStore(),
            localRules: LocalRulesService()
        )
        return AppEnvironment(
            store: store,
            settings: settings,
            captureService: captureService,
            hotkeyService: HotkeyService(
                registrar: NoopHotKeyRegistrar(),
                settings: settings
            ),
            aiJobCoordinator: AIJobCoordinator(ai: ai, store: store),
            startup: startup
        )
    }
}

private extension AppEnvironment {
    static func productionDatabaseURL(
        isUITesting: Bool,
        environment: [String: String]
    ) throws -> URL {
        if isUITesting {
            if let path = environment["CLIPFLOW_TEST_DATABASE"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return URL(fileURLWithPath: path)
            }

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipFlowUITesting-\(UUID().uuidString)", isDirectory: true)
            return directory.appendingPathComponent("clipflow.sqlite3")
        }

        let supportDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return supportDirectory
            .appendingPathComponent("ClipFlow", isDirectory: true)
            .appendingPathComponent("clipflow.sqlite3")
    }
}

#if DEBUG
extension AppEnvironment {
    static func databaseURLForTesting(
        isUITesting: Bool,
        environment: [String: String]
    ) throws -> URL {
        try productionDatabaseURL(isUITesting: isUITesting, environment: environment)
    }
}
#endif

@MainActor
private final class NoopHotKeyRegistrar: HotKeyRegistrar {
    private var handlers: [HotKeyToken: @MainActor () -> Void] = [:]

    func register(
        _ shortcut: ShortcutMapping,
        id: UInt32,
        handler: @escaping @MainActor () -> Void
    ) throws -> HotKeyToken {
        let token = HotKeyToken(rawID: id)
        handlers[token] = handler
        return token
    }

    func unregister(_ token: HotKeyToken) {
        handlers.removeValue(forKey: token)
    }
}

@MainActor
private final class NoopClipboardCaptureService: ClipboardCaptureServiceProtocol {
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
        true
    }
}
