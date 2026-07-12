import XCTest
@testable import ClipFlow

@MainActor
final class ClipboardStoreTests: XCTestCase {
    func testSelectedItemIsDerivedFromItems() async {
        let repository = InMemoryRepository()
        let item = await repository.seed(.fixture(content: "selected"))
        let store = makeStore(repository: repository)

        await store.start()
        store.setSelection(item.id, for: .library)
        await store.toggleFavorite(id: item.id)

        XCTAssertTrue(store.selectedItem(for: .library)?.isFavorite == true)
    }

    func testFailedFavoriteWriteDoesNotMutateUI() async {
        let repository = InMemoryRepository()
        let item = await repository.seed(.fixture(content: "stable"))
        let store = makeStore(repository: repository)
        await store.start()
        await repository.setFailNextMutation(true)

        await store.toggleFavorite(id: item.id)

        XCTAssertFalse(store.session(for: .library).items.first?.isFavorite == true)
        XCTAssertEqual(store.banner?.code, .databaseWrite)
    }

    func testCleanupRefreshesItemsAndSelectionAtomically() async {
        let repository = InMemoryRepository()
        let old = await repository.seed(.fixture(content: "old", at: 0))
        let store = makeStore(repository: repository)
        await store.start()
        store.setSelection(old.id, for: .library)

        await store.updateRetention(.days(15), now: Date(timeIntervalSince1970: 20 * 86_400))

        XCTAssertTrue(store.session(for: .library).items.isEmpty)
        XCTAssertNil(store.session(for: .library).selectedItemID)
    }

    func testMetadataFailureDoesNotUndoSuccessfulPasteboardCopy() async {
        let repository = InMemoryRepository()
        let item = await repository.seed(.fixture(content: "copy"))
        let pasteboard = FakePasteboardWriter(result: true)
        let store = makeStore(repository: repository, pasteboard: pasteboard)
        await store.start()
        await repository.setFailNextMutation(true)

        let outcome = await store.copy(id: item.id)

        XCTAssertEqual(outcome, .copiedWithMetadataWarning)
        XCTAssertEqual(pasteboard.writtenText, "copy")
        XCTAssertEqual(store.banner?.code, .databaseCopyMetadata)
    }

    func testCopyFailureDoesNotWriteMetadata() async {
        let repository = InMemoryRepository()
        let item = await repository.seed(.fixture(content: "copy fail"))
        let pasteboard = FakePasteboardWriter(result: false)
        let store = makeStore(repository: repository, pasteboard: pasteboard)
        await store.start()

        let outcome = await store.copy(id: item.id)
        let reloaded = try? await repository.item(id: item.id)

        XCTAssertEqual(outcome, .clipboardWriteFailed)
        XCTAssertEqual(reloaded?.copyCount, 1)
        XCTAssertEqual(store.banner?.code, .clipboardWrite)
    }

    func testSoftDeleteUndoAndFinalizeAffectOnlyThatItem() async {
        let repository = InMemoryRepository()
        let first = await repository.seed(.fixture(content: "first"))
        let second = await repository.seed(.fixture(content: "second"))
        var currentDate = Date(timeIntervalSince1970: 0)
        let store = makeStore(repository: repository, now: { currentDate })
        await store.start()

        await store.delete(id: first.id)
        currentDate = Date(timeIntervalSince1970: 1)
        await store.delete(id: second.id)

        XCTAssertEqual(Set(store.pendingDeletes.keys), [first.id, second.id])
        XCTAssertFalse(store.session(for: .library).items.contains(first))
        XCTAssertFalse(store.session(for: .library).items.contains(second))

        await store.undoDelete(id: first.id)
        XCTAssertNil(store.pendingDeletes[first.id])
        let restoredFirst = try? await repository.item(id: first.id)
        let deletedSecond = try? await repository.item(id: second.id)
        XCTAssertNotNil(restoredFirst)
        XCTAssertNil(deletedSecond)

        await store.finalizePendingDelete(id: second.id)
        XCTAssertNil(store.pendingDeletes[second.id])
        let purgedSecond = try? await repository.item(id: second.id)
        XCTAssertNil(purgedSecond)
    }

    func testUndoFailureKeepsPendingDeleteAndAllowsTimerToFinalize() async {
        let repository = InMemoryRepository()
        let item = await repository.seed(.fixture(content: "undo failure"))
        var currentDate = Date(timeIntervalSince1970: 0)
        let sleeper = ManualSleeper()
        let store = makeStore(
            repository: repository,
            now: { currentDate },
            sleeper: sleeper
        )
        await store.start()
        await store.delete(id: item.id)
        await repository.setFailNextMutation(true)

        await store.undoDelete(id: item.id)
        currentDate = Date(timeIntervalSince1970: 8)
        await waitForPendingSleeps(2, sleeper: sleeper)
        await sleeper.resumeAll()
        await waitForPendingDeleteCleared(item.id, store: store)

        let remainingClipCount = try? await repository.countAllClips()
        XCTAssertNil(store.pendingDeletes[item.id])
        XCTAssertEqual(remainingClipCount, 0)
    }

    func testFinalizeFailureKeepsPendingDeleteAndAllowsRetryTimer() async {
        let repository = InMemoryRepository()
        let item = await repository.seed(.fixture(content: "purge failure"))
        var currentDate = Date(timeIntervalSince1970: 0)
        let sleeper = ManualSleeper()
        let store = makeStore(
            repository: repository,
            now: { currentDate },
            sleeper: sleeper
        )
        await store.start()
        await store.delete(id: item.id)
        await repository.setFailNextMutation(true)

        await store.finalizePendingDelete(id: item.id)
        currentDate = Date(timeIntervalSince1970: 8)
        await waitForPendingSleeps(2, sleeper: sleeper)
        await sleeper.resumeAll()
        await waitForPendingDeleteCleared(item.id, store: store)

        let remainingClipCount = try? await repository.countAllClips()
        XCTAssertNil(store.pendingDeletes[item.id])
        XCTAssertEqual(remainingClipCount, 0)
    }

    func testRestartRebuildsPendingDeletesFromRepositoryTombstones() async {
        let repository = InMemoryRepository()
        let item = await repository.seed(.fixture(content: "restart purge"))
        var currentDate = Date(timeIntervalSince1970: 0)
        let store = makeStore(repository: repository, now: { currentDate })
        await store.start()
        await store.delete(id: item.id)
        XCTAssertNotNil(store.pendingDeletes[item.id])

        store.stop()
        currentDate = Date(timeIntervalSince1970: 9)
        await store.start()

        let remainingClipCount = try? await repository.countAllClips()
        XCTAssertNil(store.pendingDeletes[item.id])
        XCTAssertEqual(remainingClipCount, 0)
    }

    func testPaginationLoadsNextPageWithoutDuplicates() async {
        let repository = InMemoryRepository()
        for index in 0..<120 {
            _ = await repository.seed(.fixture(content: "item-\(index)", at: TimeInterval(index)))
        }
        let store = makeStore(repository: repository)

        await store.start()
        await store.loadNextPage(.library)

        let ids = store.session(for: .library).items.map(\.id)
        XCTAssertEqual(ids.count, 120)
        XCTAssertEqual(Set(ids).count, 120)
        XCTAssertNil(store.session(for: .library).nextOffset)
    }

    func testReadOnlyRecoveryAllowsReadsAndPasteboardCopyButRejectsPersistentWrites() async {
        let repository = InMemoryRepository()
        let item = await repository.seed(.fixture(content: "read only"))
        let pasteboard = FakePasteboardWriter(result: true)
        let store = makeStore(
            repository: repository,
            pasteboard: pasteboard,
            startup: .readOnlyRecovery(
                databaseURL: URL(fileURLWithPath: "/tmp/clipflow.sqlite3"),
                backupURL: URL(fileURLWithPath: "/tmp/clipflow.sqlite3.backup"),
                errorCode: "database.readOnly"
            )
        )

        await store.start()
        XCTAssertEqual(store.session(for: .library).items.map(\.id), [item.id])
        let copyOutcome = await store.copy(id: item.id)
        XCTAssertEqual(copyOutcome, .copiedWithMetadataWarning)
        XCTAssertEqual(pasteboard.writtenText, "read only")

        await store.toggleFavorite(id: item.id)
        XCTAssertFalse(store.session(for: .library).items.first?.isFavorite == true)
        XCTAssertEqual(store.banner?.code, .databaseReadOnly)
        XCTAssertEqual(
            store.banner?.recoveryAction,
            .revealBackup(URL(fileURLWithPath: "/tmp/clipflow.sqlite3.backup"))
        )
    }

    func testReadWriteStartupConsumesLegacySettingsAfterSuccessfulMigration() async throws {
        let repository = InMemoryRepository()
        let category = LegacyCustomCategoryV1(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000601")!,
            name: " Projects ",
            prompt: "project material"
        )
        let defaults = legacyDefaults(categories: [category])
        let settings = AppSettingsStore(userDefaults: defaults)
        let now = Date(timeIntervalSince1970: 123)
        let migratedCategories = try XCTUnwrap(
            settings.pendingLegacySettingsSnapshot?.migratedCategories(now: now)
        )
        for migratedCategory in migratedCategories {
            try await repository.saveCategory(migratedCategory)
        }
        let store = makeStore(repository: repository, settings: settings, now: { now })

        await store.start()

        XCTAssertNil(defaults.object(forKey: "ai_integration_enabled"))
        XCTAssertNil(defaults.object(forKey: "ollama_base_url"))
        XCTAssertNil(defaults.object(forKey: "api_usage_records"))
        XCTAssertNil(defaults.object(forKey: "custom_categories"))
        XCTAssertEqual(settings.aiProviderKind, .disabled)
        XCTAssertNil(settings.aiConsentOrigin)
    }

    func testReadWriteStartupKeepsLegacySettingsUntilMigratedCategoriesArePresent() async {
        let repository = InMemoryRepository()
        let defaults = legacyDefaults(categories: [
            LegacyCustomCategoryV1(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000602")!,
                name: "Invoices",
                prompt: "billing"
            )
        ])
        let settings = AppSettingsStore(userDefaults: defaults)
        let store = makeStore(repository: repository, settings: settings)

        await store.start()

        XCTAssertNotNil(defaults.object(forKey: "ai_integration_enabled"))
        XCTAssertNotNil(defaults.object(forKey: "ollama_base_url"))
        XCTAssertNotNil(defaults.object(forKey: "api_usage_records"))
        XCTAssertNotNil(defaults.object(forKey: "custom_categories"))
        XCTAssertNotNil(settings.pendingLegacySettingsSnapshot)
        XCTAssertEqual(store.banner?.code, .migrationFailed)
    }

    func testReadOnlyStartupDoesNotConsumeLegacySettings() async {
        let repository = InMemoryRepository()
        let defaults = legacyDefaults()
        let settings = AppSettingsStore(userDefaults: defaults)
        let store = makeStore(
            repository: repository,
            settings: settings,
            startup: .readOnlyRecovery(
                databaseURL: URL(fileURLWithPath: "/tmp/clipflow.sqlite3"),
                backupURL: URL(fileURLWithPath: "/tmp/clipflow.sqlite3.backup"),
                errorCode: "database.readOnly"
            )
        )

        await store.start()

        XCTAssertNotNil(defaults.object(forKey: "ai_integration_enabled"))
        XCTAssertNotNil(defaults.object(forKey: "ollama_base_url"))
        XCTAssertNotNil(defaults.object(forKey: "api_usage_records"))
        XCTAssertNotNil(defaults.object(forKey: "custom_categories"))
    }

    func testQuickPanelAndLibraryMaintainIndependentQueriesAndSelections() async {
        let repository = InMemoryRepository()
        var favorite = ClipboardItem.fixture(content: "favorite", at: 2)
        favorite.isFavorite = true
        let favoriteItem = await repository.seed(favorite)
        let ordinary = await repository.seed(.fixture(content: "ordinary", at: 1))
        let store = makeStore(repository: repository)

        await store.start()
        await store.updateQuery(.quickPanel(searchText: "", favoritesOnly: true), for: .quickPanel)
        store.setSelection(favoriteItem.id, for: .quickPanel)
        store.setSelection(ordinary.id, for: .library)

        XCTAssertEqual(store.session(for: .quickPanel).items.map(\.id), [favoriteItem.id])
        XCTAssertEqual(store.session(for: .library).items.map(\.id), [favoriteItem.id, ordinary.id])
        XCTAssertEqual(store.session(for: .quickPanel).selectedItemID, favoriteItem.id)
        XCTAssertEqual(store.session(for: .library).selectedItemID, ordinary.id)
    }

    func testDeleteAllFailureLeavesVisibleStateUnchanged() async {
        let repository = InMemoryRepository()
        let item = await repository.seed(.fixture(content: "keep"))
        let store = makeStore(repository: repository)
        await store.start()
        await repository.setFailNextMutation(true)

        let outcome = await store.deleteAllClipboardDataConfirmed()

        XCTAssertEqual(outcome, .failed(.databaseWrite))
        XCTAssertEqual(store.session(for: .library).items.map(\.id), [item.id])
        XCTAssertEqual(store.banner?.code, .databaseWrite)
    }

    func testDeleteAllBackupFailureClearsRowsButReportsPartial() async {
        let repository = InMemoryRepository()
        let item = await repository.seed(.fixture(content: "delete"))
        let backups = InMemoryMigrationBackupManager(
            urls: [URL(fileURLWithPath: "/tmp/clipflow.sqlite3.backup")]
        )
        await backups.setFailDeleteAll(true)
        let store = makeStore(repository: repository, backupManager: backups)
        await store.start()

        let outcome = await store.deleteAllClipboardDataConfirmed()

        XCTAssertEqual(outcome, .partial(removedClipCount: 1, code: .migrationBackupDelete))
        XCTAssertTrue(store.session(for: .library).items.isEmpty)
        let deletedItem = try? await repository.item(id: item.id)
        XCTAssertNil(deletedItem)
        XCTAssertEqual(store.banner?.code, .migrationBackupDelete)
    }

    func testCategoryOperationsAndAIUsageDelegateToRepository() async {
        let repository = InMemoryRepository()
        let store = makeStore(repository: repository)
        let category = PersistedCustomCategory.fixture(name: "Saved", sortOrder: 0)
        let usage = AIUsageRecord(
            id: UUID(),
            operation: .summarize,
            timestamp: Date(timeIntervalSince1970: 1),
            provider: "local",
            model: "fixture",
            durationMilliseconds: 42,
            succeeded: true,
            errorCode: nil
        )

        await store.saveCategory(category)
        await store.reorderCategories(ids: [category.id])
        await store.addAIUsage(usage)
        let savedCategoryIDs = try? await repository.fetchCategories().map(\.id)
        let savedUsageIDs = try? await repository.fetchAIUsage(limit: 10).map(\.id)
        XCTAssertEqual(savedCategoryIDs, [category.id])
        XCTAssertEqual(savedUsageIDs, [usage.id])

        await store.clearAIUsage()
        await store.deleteCategory(id: category.id, migrateTo: nil)

        let clearedUsage = try? await repository.fetchAIUsage(limit: 10)
        let clearedCategories = try? await repository.fetchCategories()
        XCTAssertEqual(clearedUsage, [])
        XCTAssertEqual(clearedCategories, [])
    }

    func testLifecycleStartStopAndRestartOwnsOneCaptureLoop() async {
        let repository = InMemoryRepository()
        let pasteboard = FakePasteboardWriter(result: true)
        let store = makeStore(repository: repository, pasteboard: pasteboard)

        await store.start()
        await store.start()
        store.stop()
        await store.start()

        XCTAssertEqual(pasteboard.startCount, 2)
        XCTAssertEqual(pasteboard.stopCount, 1)
    }

    func testCaptureEventsReconcileOrPublishContentFreeErrors() async {
        let repository = InMemoryRepository()
        let store = makeStore(repository: repository)
        let item = try! await repository.upsertCapturedText(CapturedText(
            content: "captured",
            category: .english,
            capturedAt: Date(timeIntervalSince1970: 2),
            sourceBundleID: nil
        ))
        await store.start()

        await store.applyCaptureEvent(.persisted(item))
        XCTAssertEqual(store.session(for: .library).items.map(\.id), [item.id])

        await store.applyCaptureEvent(.skipped(.sensitive(.apiToken)))
        XCTAssertEqual(store.banner?.code, .privacySensitive)

        await store.applyCaptureEvent(.failed(code: .databaseWrite))
        XCTAssertEqual(store.banner?.code, .databaseWrite)
    }

    func testFabricatedPersistedCaptureEventCannotCreatePhantomVisibleItem() async {
        let repository = InMemoryRepository()
        let store = makeStore(repository: repository)
        let phantom = ClipboardItem.fixture(content: "phantom", at: 2)
        await store.start()

        await store.applyCaptureEvent(.persisted(phantom))

        XCTAssertFalse(store.session(for: .library).items.contains { $0.id == phantom.id })
        XCTAssertNil(store.itemCache[phantom.id])
    }

    func testAIResultApplicationHandlesAppliedStaleMissingAndFailed() async {
        let repository = InMemoryRepository()
        let item = await repository.seed(.fixture(content: "ai"))
        let store = makeStore(repository: repository)
        let key = AIJobKey(itemID: item.id, operation: .summarize)
        let generation = UUID()
        await store.start()

        await store.activateAIJob(key, generation: generation)
        let applied = await store.applyAISummary(
            itemID: item.id,
            summary: "short",
            key: key,
            generation: generation
        )
        XCTAssertEqual(applied, .applied(ClipboardItem(
            id: item.id,
            content: item.content,
            category: item.category,
            timestamp: item.timestamp,
            copyCount: item.copyCount,
            isFavorite: item.isFavorite,
            aiSummary: "short"
        )))

        let stale = await store.applyAISummary(
            itemID: item.id,
            summary: "late",
            key: key,
            generation: UUID()
        )
        XCTAssertEqual(stale, .staleGeneration)

        let missingKey = AIJobKey(itemID: UUID(), operation: .summarize)
        await store.activateAIJob(missingKey, generation: generation)
        let missing = await store.applyAISummary(
            itemID: missingKey.itemID,
            summary: "missing",
            key: missingKey,
            generation: generation
        )
        XCTAssertEqual(missing, .targetMissing)

        await repository.setFailNextMutation(true)
        let failingGeneration = UUID()
        await store.activateAIJob(key, generation: failingGeneration)
        let failed = await store.applyAISummary(
            itemID: item.id,
            summary: "fail",
            key: key,
            generation: failingGeneration
        )
        XCTAssertEqual(failed, .failed(.databaseWrite))
    }

    func testPauseAndResumePublishSharedMonitoringState() async {
        let repository = InMemoryRepository()
        let pasteboard = FakePasteboardWriter(result: true)
        let store = makeStore(repository: repository, pasteboard: pasteboard)
        let deadline = Date(timeIntervalSince1970: 200)

        store.pauseMonitoring(.until(deadline))
        XCTAssertEqual(store.monitoringPause, .until(deadline))
        XCTAssertEqual(pasteboard.pauseState, .until(deadline))

        store.resumeMonitoring()
        XCTAssertEqual(store.monitoringPause, .active)
        XCTAssertEqual(pasteboard.pauseState, .active)
    }

    func testTimedPausePublishesActiveStateWhenCountdownExpires() async {
        let repository = InMemoryRepository()
        let pasteboard = FakePasteboardWriter(result: true)
        let sleeper = ManualSleeper()
        let store = makeStore(
            repository: repository,
            pasteboard: pasteboard,
            sleeper: sleeper
        )
        let deadline = Date(timeIntervalSince1970: 200)

        store.pauseMonitoring(.until(deadline))
        await waitForPendingSleeps(1, sleeper: sleeper)
        let pendingSleepCount = await sleeper.pendingSleepCount
        XCTAssertEqual(pendingSleepCount, 1)
        await sleeper.resumeNext()
        await Task.yield()

        XCTAssertEqual(store.monitoringPause, .active)
        XCTAssertEqual(pasteboard.pauseState, .active)
    }

    func testTimedPauseExpiryRemainsStoreOwnedAcrossStopStart() async {
        let repository = InMemoryRepository()
        let pasteboard = FakePasteboardClient()
        var currentTime = Date(timeIntervalSince1970: 100)
        let captureService = ClipboardCaptureService(
            pasteboard: pasteboard,
            sourceBundleID: { nil },
            now: { currentTime }
        )
        let store = makeStore(
            repository: repository,
            captureService: captureService,
            now: { currentTime }
        )
        await store.start()
        store.pauseMonitoring(.until(Date(timeIntervalSince1970: 200)))

        store.stop()
        currentTime = Date(timeIntervalSince1970: 201)
        await store.start()

        XCTAssertEqual(store.monitoringPause, .active)
        XCTAssertEqual(captureService.pauseState, .active)
    }

    func testPrivacyConfigurationCommitsSettingsOnlyAfterPipelineBarrier() async {
        let repository = InMemoryRepository()
        let settings = AppSettingsStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let barrier = ConfigurationBarrier()
        let pipeline = CapturePipeline(
            privacyGuard: PrivacyGuard(detector: SensitiveContentDetector()),
            classifier: TextClassifier(),
            repository: repository,
            configuration: .standard,
            admissionObserver: { operation, _ in
                if operation == .configurationUpdate {
                    await barrier.blockUntilReleased()
                }
            }
        )
        let store = makeStore(
            repository: repository,
            capturePipeline: pipeline,
            settings: settings
        )
        let configuration = PrivacyConfiguration(
            excludedBundleIDs: ["com.example.private"],
            maxUTF8Bytes: 512,
            detectsSensitiveContent: false
        )

        let updateTask = Task {
            await store.updatePrivacyConfiguration(configuration)
        }
        await waitForConfigurationBarrier(barrier)
        XCTAssertNotEqual(settings.maxCaptureBytes, configuration.maxUTF8Bytes)
        XCTAssertNotEqual(settings.excludedBundleIDs, configuration.excludedBundleIDs)

        await barrier.release()
        await updateTask.value

        XCTAssertEqual(settings.maxCaptureBytes, configuration.maxUTF8Bytes)
        XCTAssertEqual(settings.excludedBundleIDs, configuration.excludedBundleIDs)
        XCTAssertEqual(
            settings.sensitiveContentProtectionEnabled,
            configuration.detectsSensitiveContent
        )
    }
}

private extension ClipboardStoreTests {
    func legacyDefaults(categories: [LegacyCustomCategoryV1] = []) -> UserDefaults {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(true, forKey: "ai_integration_enabled")
        defaults.set("http://localhost:11434", forKey: "ollama_base_url")
        defaults.set(Data("usage".utf8), forKey: "api_usage_records")
        let categoryData = (try? JSONEncoder().encode(categories)) ?? Data("categories".utf8)
        defaults.set(categoryData, forKey: "custom_categories")
        return defaults
    }

    func waitForPendingSleeps(_ count: Int, sleeper: ManualSleeper) async {
        for _ in 0..<50 {
            if await sleeper.pendingSleepCount >= count {
                return
            }
            await Task.yield()
        }
    }

    func waitForPendingDeleteCleared(_ id: UUID, store: ClipboardStore) async {
        for _ in 0..<50 {
            if store.pendingDeletes[id] == nil {
                return
            }
            await Task.yield()
        }
    }

    func waitForConfigurationBarrier(_ barrier: ConfigurationBarrier) async {
        for _ in 0..<50 {
            if await barrier.isBlocked {
                return
            }
            await Task.yield()
        }
    }
}

private actor ConfigurationBarrier {
    private(set) var isBlocked = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func blockUntilReleased() async {
        isBlocked = true
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
