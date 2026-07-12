import Foundation
@testable import ClipFlow

@MainActor
func makeStore(
    repository: InMemoryRepository,
    pasteboard: FakePasteboardWriter = FakePasteboardWriter(result: true),
    captureService: (any ClipboardCaptureServiceProtocol)? = nil,
    capturePipeline: CapturePipeline? = nil,
    backupManager: InMemoryMigrationBackupManager = InMemoryMigrationBackupManager(),
    settings: AppSettingsStore? = nil,
    startup: RepositoryStartup = .readWrite(DatabasePreparation(
        schemaVersion: 2,
        searchMode: .parameterizedContains,
        recoveredCategories: [],
        backupURL: nil
    )),
    logger: InMemoryAppLogger = InMemoryAppLogger(),
    now: @escaping () -> Date = { Date(timeIntervalSince1970: 100) },
    sleeper: any SleepProviding = ContinuousSleeper()
) -> ClipboardStore {
    ClipboardStore(
        repository: repository,
        captureService: captureService ?? pasteboard,
        capturePipeline: capturePipeline ?? CapturePipeline(
            privacyGuard: PrivacyGuard(detector: SensitiveContentDetector()),
            classifier: TextClassifier(),
            repository: repository,
            configuration: .standard
        ),
        backupManager: backupManager,
        settings: settings ?? AppSettingsStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!
        ),
        startup: startup,
        logger: logger,
        now: now,
        sleeper: sleeper
    )
}
