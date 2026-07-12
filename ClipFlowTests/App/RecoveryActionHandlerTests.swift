import XCTest
@testable import ClipFlow

@MainActor
final class RecoveryActionHandlerTests: XCTestCase {
    func testRetryReloadsSurfaceAndClearsBannerAfterSuccessfulRecovery() async {
        let harness = await RecoveryHarness.make(contents: ["one"])
        harness.store.setSelection(harness.itemID, for: .quickPanel)
        await harness.repository.setFailFetch(true)
        await harness.store.reload(.quickPanel)
        XCTAssertEqual(harness.store.banner?.recoveryAction, .retry(surface: .quickPanel))

        await harness.repository.setFailFetch(false)
        await harness.handler.handle(.retry(surface: .quickPanel))

        XCTAssertNil(harness.store.banner)
        XCTAssertEqual(harness.store.session(for: .quickPanel).items.map(\.id), [harness.itemID])
    }

    func testRetryKeepsBannerWhenRecoveryFails() async {
        let harness = await RecoveryHarness.make(contents: ["one"])
        await harness.repository.setFailFetch(true)
        await harness.store.reload(.quickPanel)

        await harness.handler.handle(.retry(surface: .quickPanel))

        XCTAssertEqual(harness.store.banner?.recoveryAction, .retry(surface: .quickPanel))
    }

    func testOpenSettingsRoutesThroughCoordinator() async {
        let harness = await RecoveryHarness.make(contents: ["one"])

        await harness.handler.handle(.openSettings)

        XCTAssertEqual(harness.coordinator.settingsCount, 1)
    }

    func testRevealBackupUsesNarrowFileRevealerBoundary() async {
        let harness = await RecoveryHarness.make(contents: ["one"])
        let url = URL(fileURLWithPath: "/tmp/clipflow.sqlite3.backup")

        await harness.handler.handle(.revealBackup(url))

        XCTAssertEqual(harness.fileRevealer.revealedURLs, [url])
    }

    func testDeleteMigrationBackupsClearsBannerAfterSuccessfulRecovery() async {
        let backupManager = InMemoryMigrationBackupManager()
        let harness = await RecoveryHarness.make(contents: ["one"], backupManager: backupManager)
        harness.store.publishBannerForTesting(
            code: .migrationBackupDelete,
            recoveryAction: .deleteMigrationBackups
        )

        await harness.handler.handle(.deleteMigrationBackups)

        XCTAssertNil(harness.store.banner)
    }
}

@MainActor
private final class RecoveryHarness {
    let repository: FetchFailingRepository
    let store: ClipboardStore
    let coordinator: RecoveryRecordingCoordinator
    let fileRevealer: RecordingFileRevealer
    let handler: RecoveryActionHandler
    let itemID: UUID

    private init(
        repository: FetchFailingRepository,
        store: ClipboardStore,
        coordinator: RecoveryRecordingCoordinator,
        fileRevealer: RecordingFileRevealer,
        handler: RecoveryActionHandler,
        itemID: UUID
    ) {
        self.repository = repository
        self.store = store
        self.coordinator = coordinator
        self.fileRevealer = fileRevealer
        self.handler = handler
        self.itemID = itemID
    }

    static func make(
        contents: [String],
        backupManager: InMemoryMigrationBackupManager = InMemoryMigrationBackupManager()
    ) async -> RecoveryHarness {
        let repository = FetchFailingRepository()
        let pasteboard = FakePasteboardWriter(result: true)
        let settings = AppSettingsStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let store = ClipboardStore(
            repository: repository,
            captureService: pasteboard,
            capturePipeline: CapturePipeline(
                privacyGuard: PrivacyGuard(detector: SensitiveContentDetector()),
                classifier: TextClassifier(),
                repository: repository,
                configuration: settings.privacyConfiguration
            ),
            backupManager: backupManager,
            settings: settings,
            startup: .readWrite(DatabasePreparation(
                schemaVersion: 2,
                searchMode: .parameterizedContains,
                recoveredCategories: [],
                backupURL: nil
            )),
            logger: InMemoryAppLogger(),
            now: { Date(timeIntervalSince1970: 100) },
            sleeper: ManualSleeper()
        )
        let item = ClipboardItem(content: contents[0], timestamp: Date(timeIntervalSince1970: 100))
        await repository.seed(item)
        await store.start()
        let coordinator = RecoveryRecordingCoordinator()
        let fileRevealer = RecordingFileRevealer()
        let handler = RecoveryActionHandler(
            store: store,
            coordinator: coordinator,
            fileRevealer: fileRevealer
        )
        return RecoveryHarness(
            repository: repository,
            store: store,
            coordinator: coordinator,
            fileRevealer: fileRevealer,
            handler: handler,
            itemID: item.id
        )
    }
}

private actor FetchFailingRepository: ClipboardRepositoryProtocol {
    private let base = InMemoryRepository()
    private var failFetch = false

    func setFailFetch(_ value: Bool) {
        failFetch = value
    }

    @discardableResult
    func seed(_ item: ClipboardItem) async -> ClipboardItem {
        await base.seed(item)
    }

    func fetchPage(_ query: ClipQuery) async throws -> ClipPage {
        if failFetch { throw DatabaseError.openFailed("requested") }
        return try await base.fetchPage(query)
    }

    func item(id: UUID) async throws -> ClipboardItem? { try await base.item(id: id) }
    func upsertCapturedText(_ capture: CapturedText) async throws -> ClipboardItem { try await base.upsertCapturedText(capture) }
    func markCopied(id: UUID, at: Date) async throws -> ClipboardItem { try await base.markCopied(id: id, at: at) }
    func setFavorite(id: UUID, isFavorite: Bool) async throws -> ClipboardItem { try await base.setFavorite(id: id, isFavorite: isFavorite) }
    func setSummary(id: UUID, summary: String?) async throws -> ClipboardItem { try await base.setSummary(id: id, summary: summary) }
    func setCustomCategory(id: UUID, categoryID: UUID?) async throws -> ClipboardItem { try await base.setCustomCategory(id: id, categoryID: categoryID) }
    func activateAIJob(_ key: AIJobKey, generation: UUID) async { await base.activateAIJob(key, generation: generation) }
    func cancelAIJob(_ key: AIJobKey, generation: UUID) async { await base.cancelAIJob(key, generation: generation) }
    func setSummaryIfCurrent(id: UUID, summary: String?, key: AIJobKey, generation: UUID) async throws -> ClipboardItem? { try await base.setSummaryIfCurrent(id: id, summary: summary, key: key, generation: generation) }
    func setCustomCategoryIfCurrent(id: UUID, categoryID: UUID?, key: AIJobKey, generation: UUID) async throws -> ClipboardItem? { try await base.setCustomCategoryIfCurrent(id: id, categoryID: categoryID, key: key, generation: generation) }
    func softDelete(id: UUID, at: Date) async throws { try await base.softDelete(id: id, at: at) }
    func deletedTombstones(since: Date) async throws -> [DeletedClipTombstone] { try await base.deletedTombstones(since: since) }
    func restore(id: UUID) async throws { try await base.restore(id: id) }
    func purgeDeleted(id: UUID) async throws { try await base.purgeDeleted(id: id) }
    func purgeDeleted(before: Date) async throws -> Int { try await base.purgeDeleted(before: before) }
    func countForCleanup(retention: RetentionPolicy, now: Date) async throws -> Int { try await base.countForCleanup(retention: retention, now: now) }
    func cleanup(retention: RetentionPolicy, now: Date) async throws -> Int { try await base.cleanup(retention: retention, now: now) }
    func countAllClips() async throws -> Int { try await base.countAllClips() }
    func deleteAllClipboardData() async throws -> Int { try await base.deleteAllClipboardData() }
    func fetchCategories() async throws -> [PersistedCustomCategory] { try await base.fetchCategories() }
    func saveCategory(_ category: PersistedCustomCategory) async throws { try await base.saveCategory(category) }
    func reorderCategories(ids: [UUID]) async throws { try await base.reorderCategories(ids: ids) }
    func deleteCategory(id: UUID, migrateTo replacementID: UUID?) async throws { try await base.deleteCategory(id: id, migrateTo: replacementID) }
    func addAIUsage(_ record: AIUsageRecord) async throws { try await base.addAIUsage(record) }
    func fetchAIUsage(limit: Int) async throws -> [AIUsageRecord] { try await base.fetchAIUsage(limit: limit) }
    func clearAIUsage() async throws { try await base.clearAIUsage() }
}

@MainActor
private final class RecoveryRecordingCoordinator: QuickPanelCoordinating {
    private(set) var settingsCount = 0
    func closeQuickPanel() {}
    func openLibrary(selectedID: UUID?) {}
    func openSettings() { settingsCount += 1 }
    func showCopyFeedback(_ outcome: CopyOutcome) {}
}

@MainActor
private final class RecordingFileRevealer: FileRevealing {
    private(set) var revealedURLs: [URL] = []
    func reveal(_ url: URL) {
        revealedURLs.append(url)
    }
}
