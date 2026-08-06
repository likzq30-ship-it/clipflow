import Combine
import Foundation

@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var sessions: [ClipSurface: ClipQuerySession]
    @Published private(set) var itemCache: [UUID: ClipboardItem] = [:]
    @Published private(set) var repositoryStartup: RepositoryStartup
    @Published private(set) var monitoringPause: MonitoringPause = .active
    @Published private(set) var banner: AppErrorPresentation?
    @Published private(set) var pendingDeletes: [UUID: PendingDelete] = [:]
    @Published private(set) var customCategories: [PersistedCustomCategory] = []

    private let repository: any ClipboardRepositoryProtocol
    private let captureService: any ClipboardCaptureServiceProtocol
    private let capturePipeline: CapturePipeline
    private let backupManager: any MigrationBackupManaging
    private let settings: AppSettingsStore
    private let logger: any AppLogging
    private let now: () -> Date
    private let sleeper: any SleepProviding

    private var isStarted = false
    private var undoTasks: [UUID: Task<Void, Never>] = [:]
    private var cleanupTask: Task<Void, Never>?
    private var pauseExpirationTask: Task<Void, Never>?

    var isReadOnlyRecovery: Bool { repositoryStartup.isReadOnly }
    var privacyConfiguration: PrivacyConfiguration { settings.privacyConfiguration }

    init(
        repository: any ClipboardRepositoryProtocol,
        captureService: any ClipboardCaptureServiceProtocol,
        capturePipeline: CapturePipeline,
        backupManager: any MigrationBackupManaging,
        settings: AppSettingsStore,
        startup: RepositoryStartup,
        logger: any AppLogging,
        now: @escaping () -> Date = Date.init,
        sleeper: any SleepProviding = ContinuousSleeper()
    ) {
        self.repository = repository
        self.captureService = captureService
        self.capturePipeline = capturePipeline
        self.backupManager = backupManager
        self.settings = settings
        self.repositoryStartup = startup
        self.logger = logger
        self.now = now
        self.sleeper = sleeper
        self.sessions = [
            .quickPanel: Self.emptySession(for: .quickPanel),
            .library: Self.emptySession(for: .library)
        ]
    }

    func start() async {
        guard !isStarted else { return }
        isStarted = true

        if case .readOnlyRecovery(_, let backupURL, _) = repositoryStartup {
            publishBanner(
                code: .databaseReadOnly,
                severity: .warning,
                recoveryTitle: backupURL == nil ? nil : String(localized: "Reveal Backup"),
                recoveryAction: backupURL.map(RecoveryAction.revealBackup)
            )
        }

        if !isReadOnlyRecovery {
            await purgeExpiredTombstonesAndRestoreUndoTimers()
            await performRetentionCleanupAndReload()
            await purgeExpiredBackups()
            startCaptureService()
            synchronizeMonitoringPauseState()
            startCleanupTask()
        }

        await reloadCategories()
        await reload(.quickPanel)
        await reload(.library)

        await consumeLegacySettingsAfterRepositoryStartupIfSafe()
    }

    func stop() {
        guard isStarted else { return }
        captureService.stop()
        cleanupTask?.cancel()
        cleanupTask = nil
        pauseExpirationTask?.cancel()
        pauseExpirationTask = nil
        for task in undoTasks.values {
            task.cancel()
        }
        undoTasks.removeAll()
        isStarted = false
    }

    func session(for surface: ClipSurface) -> ClipQuerySession {
        sessions[surface] ?? Self.emptySession(for: surface)
    }

    func selectedItem(for surface: ClipSurface) -> ClipboardItem? {
        let current = session(for: surface)
        guard let selectedItemID = current.selectedItemID else { return nil }
        return current.items.first { $0.id == selectedItemID }
    }

    func setSelection(_ id: UUID?, for surface: ClipSurface) {
        ensureSession(for: surface)
        guard canSelect(id, for: surface) else {
            sessions[surface]?.selectedItemID = nil
            return
        }
        sessions[surface]?.selectedItemID = id
    }

    func updateQuery(_ query: ClipQuery, for surface: ClipSurface) async {
        ensureSession(for: surface)
        sessions[surface]?.query = ClipQuery(
            searchText: query.searchText,
            scope: query.scope,
            limit: query.limit,
            offset: 0
        )
        await reload(surface)
    }

    func reload(_ surface: ClipSurface, resetOffset: Bool = true) async {
        ensureSession(for: surface)
        var current = session(for: surface)
        if resetOffset {
            current.query.offset = 0
        }
        current.isLoading = true
        sessions[surface] = current

        do {
            let page = try await repository.fetchPage(current.query)
            replaceSession(surface, query: current.query, page: page)
        } catch {
            clearSessionAfterRefreshFailure(surface, code: errorCode(for: error))
        }
    }

    func loadNextPage(_ surface: ClipSurface) async {
        ensureSession(for: surface)
        let current = session(for: surface)
        guard let nextOffset = current.nextOffset, !current.isLoading else { return }
        var loading = current
        loading.isLoading = true
        sessions[surface] = loading

        var query = current.query
        query.offset = nextOffset
        do {
            let page = try await repository.fetchPage(query)
            var existing = current.items
            let seen = Set(existing.map(\.id))
            existing.append(contentsOf: page.items.filter { !seen.contains($0.id) })
            cache(page.items)
            sessions[surface] = ClipQuerySession(
                query: current.query,
                items: existing,
                selectedItemID: selectedID(current.selectedItemID, visibleIn: existing, surface: surface),
                totalCount: page.totalCount,
                nextOffset: page.nextOffset,
                isLoading: false
            )
        } catch {
            sessions[surface]?.isLoading = false
            publishBanner(
                code: errorCode(for: error),
                severity: .error,
                recoveryTitle: String(localized: "Retry"),
                recoveryAction: .retry(surface: surface)
            )
        }
    }

    func loadItem(id: UUID) async {
        do {
            if let item = try await repository.item(id: id) {
                itemCache[id] = item
            } else {
                itemCache.removeValue(forKey: id)
            }
        } catch {
            publishBanner(code: errorCode(for: error), severity: .error)
        }
    }

    func applyCaptureEvent(_ event: CapturePipelineEvent) async {
        switch event {
        case .persisted(let item):
            do {
                guard let committedItem = try await repository.item(id: item.id) else {
                    itemCache.removeValue(forKey: item.id)
                    return
                }
                itemCache[committedItem.id] = committedItem
                mergeIfVisible(committedItem)
            } catch {
                publishBanner(code: errorCode(for: error), severity: .error)
            }
        case .skipped(let reason):
            publishBanner(code: appErrorCode(for: reason), severity: .information)
        case .failed(let code):
            publishBanner(code: code, severity: .error)
        }
    }

    func updatePrivacyConfiguration(_ configuration: PrivacyConfiguration) async {
        await capturePipeline.updateConfiguration(configuration)
        settings.applyPrivacyConfiguration(configuration)
    }

    func pauseMonitoring(_ state: MonitoringPause) {
        monitoringPause = state
        synchronizeMonitoringPauseState()
    }

    func resumeMonitoring() {
        pauseExpirationTask?.cancel()
        pauseExpirationTask = nil
        captureService.resume()
        monitoringPause = .active
    }

    func copy(id: UUID, recoverySurface: ClipSurface = .quickPanel) async -> CopyOutcome {
        guard let item = await cachedOrLoadedItem(id: id) else {
            publishBanner(code: .clipboardRead, severity: .warning)
            return .clipboardWriteFailed
        }
        guard captureService.write(item.content) else {
            publishBanner(
                code: .clipboardWrite,
                severity: .warning,
                recoveryTitle: String(localized: "Retry"),
                recoveryAction: .retry(surface: recoverySurface)
            )
            return .clipboardWriteFailed
        }

        guard !isReadOnlyRecovery else {
            return .copiedWithMetadataWarning
        }

        do {
            let updated = try await repository.markCopied(id: id, at: now())
            itemCache[id] = updated
            updateItemInAllSessions(updated)
            return .copied
        } catch {
            publishBanner(code: .databaseCopyMetadata, severity: .warning)
            return .copiedWithMetadataWarning
        }
    }

    func toggleFavorite(id: UUID) async {
        guard canMutate() else { return }
        guard let current = await cachedOrLoadedItem(id: id) else {
            publishBanner(code: .databaseWrite, severity: .error)
            return
        }

        do {
            let updated = try await repository.setFavorite(id: id, isFavorite: !current.isFavorite)
            itemCache[id] = updated
            updateItemInAllSessions(updated)
        } catch {
            publishBanner(code: errorCode(for: error), severity: .error)
        }
    }

    func updateContent(id: UUID, content: String) async {
        guard canMutate() else { return }
        do {
            let updated = try await repository.setContent(id: id, content: content)
            itemCache[id] = updated
            updateItemInAllSessions(updated)
        } catch {
            publishBanner(code: errorCode(for: error), severity: .error)
        }
    }

    @discardableResult
    func delete(id: UUID) async -> Bool {
        guard canMutate() else { return false }
        let deletedAt = now()
        do {
            try await repository.softDelete(id: id, at: deletedAt)
            itemCache.removeValue(forKey: id)
            removeVisibleItem(id: id)
            createPendingDelete(id: id, deletedAt: deletedAt)
            return true
        } catch {
            publishBanner(code: errorCode(for: error), severity: .error)
            return false
        }
    }

    func undoDelete(id: UUID) async {
        guard canMutate() else { return }
        guard let pendingDelete = pendingDeletes[id] else { return }
        undoTasks[id]?.cancel()
        undoTasks[id] = nil
        do {
            try await repository.restore(id: id)
            pendingDeletes.removeValue(forKey: id)
            await reconcileAllSessionsAfterCommittedMutation()
        } catch {
            startUndoTimer(id: id, expiresAt: pendingDelete.expiresAt)
            publishBanner(code: errorCode(for: error), severity: .error)
        }
    }

    func finalizePendingDelete(id: UUID) async {
        guard canMutate() else { return }
        guard let pendingDelete = pendingDeletes[id] else { return }
        do {
            try await repository.purgeDeleted(id: id)
            undoTasks[id]?.cancel()
            undoTasks[id] = nil
            pendingDeletes.removeValue(forKey: id)
            itemCache.removeValue(forKey: id)
            removeVisibleItem(id: id)
        } catch {
            startUndoTimer(id: id, expiresAt: pendingDelete.expiresAt)
            publishBanner(code: errorCode(for: error), severity: .error)
        }
    }

    func countForRetention(_ policy: RetentionPolicy, now: Date) async -> Int? {
        do {
            return try await repository.countForCleanup(retention: policy, now: now)
        } catch {
            publishBanner(code: errorCode(for: error), severity: .error)
            return nil
        }
    }

    func updateRetention(_ policy: RetentionPolicy, now: Date) async {
        guard canMutate() else { return }
        do {
            _ = try await repository.cleanup(retention: policy, now: now)
            settings.setRetentionPolicy(policy)
            await reloadAfterCommittedCleanup()
        } catch {
            publishBanner(code: errorCode(for: error), severity: .error)
        }
    }

    func activateAIJob(_ key: AIJobKey, generation: UUID) async {
        await repository.activateAIJob(key, generation: generation)
    }

    func cancelAIJob(_ key: AIJobKey, generation: UUID) async {
        await repository.cancelAIJob(key, generation: generation)
    }

    func applyAISummary(
        itemID: UUID,
        summary: String?,
        key: AIJobKey,
        generation: UUID
    ) async -> AIResultApplication {
        guard canMutate() else { return .failed(.databaseReadOnly) }
        do {
            guard let updated = try await repository.setSummaryIfCurrent(
                id: itemID,
                summary: summary,
                key: key,
                generation: generation
            ) else {
                return await staleOrMissing(itemID: itemID)
            }
            itemCache[itemID] = updated
            await reconcileAllSessionsAfterCommittedMutation()
            return .applied(updated)
        } catch DatabaseError.itemNotFound {
            return .targetMissing
        } catch {
            let code = errorCode(for: error)
            publishBanner(code: code, severity: .error)
            return .failed(code)
        }
    }

    func applyAICategory(
        itemID: UUID,
        categoryID: UUID?,
        key: AIJobKey,
        generation: UUID
    ) async -> AIResultApplication {
        guard canMutate() else { return .failed(.databaseReadOnly) }
        do {
            guard let updated = try await repository.setCustomCategoryIfCurrent(
                id: itemID,
                categoryID: categoryID,
                key: key,
                generation: generation
            ) else {
                return await staleOrMissing(itemID: itemID)
            }
            itemCache[itemID] = updated
            await reconcileAllSessionsAfterCommittedMutation()
            return .applied(updated)
        } catch DatabaseError.itemNotFound {
            return .targetMissing
        } catch {
            let code = errorCode(for: error)
            publishBanner(code: code, severity: .error)
            return .failed(code)
        }
    }

    func addAIUsage(_ record: AIUsageRecord) async {
        guard canMutate() else { return }
        do {
            try await repository.addAIUsage(record)
        } catch {
            publishBanner(code: errorCode(for: error), severity: .error)
        }
    }

    func saveCategory(_ category: PersistedCustomCategory) async {
        guard canMutate() else { return }
        do {
            try await repository.saveCategory(category)
            await reloadCategories()
            await reconcileAllSessionsAfterCommittedMutation()
        } catch {
            publishBanner(code: errorCode(for: error), severity: .error)
        }
    }

    func reorderCategories(ids: [UUID]) async {
        guard canMutate() else { return }
        do {
            try await repository.reorderCategories(ids: ids)
            await reloadCategories()
        } catch {
            publishBanner(code: errorCode(for: error), severity: .error)
        }
    }

    func deleteCategory(id: UUID, migrateTo replacementID: UUID?) async {
        guard canMutate() else { return }
        do {
            try await repository.deleteCategory(id: id, migrateTo: replacementID)
            await reloadCategories()
            await reconcileAllSessionsAfterCommittedMutation()
        } catch {
            publishBanner(code: errorCode(for: error), severity: .error)
        }
    }

    func countAllClips() async -> Int? {
        do {
            return try await repository.countAllClips()
        } catch {
            publishBanner(code: errorCode(for: error), severity: .error)
            return nil
        }
    }

    func deleteAllClipboardDataConfirmed() async -> ClearClipboardDataOutcome {
        guard canMutate() else { return .failed(.databaseReadOnly) }
        do {
            let removed = try await repository.deleteAllClipboardData()
            cancelAllPendingDeletes()
            clearAllVisibleClipboardState()
            do {
                try await backupManager.deleteAll()
                return .complete(removedClipCount: removed)
            } catch {
                publishBanner(
                    code: .migrationBackupDelete,
                    severity: .warning,
                    recoveryTitle: String(localized: "Delete Backups"),
                    recoveryAction: .deleteMigrationBackups
                )
                return .partial(removedClipCount: removed, code: .migrationBackupDelete)
            }
        } catch {
            let code = errorCode(for: error)
            publishBanner(code: code, severity: .error)
            return .failed(code)
        }
    }

    func deleteMigrationBackups() async -> Bool {
        do {
            try await backupManager.deleteAll()
            return true
        } catch {
            publishBanner(
                code: .migrationBackupDelete,
                severity: .warning,
                recoveryTitle: "Delete Backups",
                recoveryAction: .deleteMigrationBackups
            )
            return false
        }
    }

    func clearBanner(afterSuccessfulRecoveryOf action: RecoveryAction) {
        guard banner?.recoveryAction == action else { return }
        banner = nil
    }

    #if DEBUG
    func publishBannerForTesting(
        code: AppErrorCode,
        recoveryAction: RecoveryAction
    ) {
        publishBanner(
            code: code,
            severity: .warning,
            recoveryTitle: String(localized: "Recover"),
            recoveryAction: recoveryAction
        )
    }
    #endif

    func clearAIUsage() async {
        guard canMutate() else { return }
        do {
            try await repository.clearAIUsage()
        } catch {
            publishBanner(code: errorCode(for: error), severity: .error)
        }
    }
}

private extension ClipboardStore {
    static func emptySession(for surface: ClipSurface) -> ClipQuerySession {
        ClipQuerySession(
            query: defaultQuery(for: surface),
            items: [],
            selectedItemID: nil,
            totalCount: 0,
            nextOffset: nil,
            isLoading: false
        )
    }

    static func defaultQuery(for surface: ClipSurface) -> ClipQuery {
        switch surface {
        case .quickPanel:
            return .quickPanel(searchText: "", favoritesOnly: false)
        case .library:
            return ClipQuery(searchText: "", scope: .all, limit: 100, offset: 0)
        }
    }

    func ensureSession(for surface: ClipSurface) {
        if sessions[surface] == nil {
            sessions[surface] = Self.emptySession(for: surface)
        }
    }

    func replaceSession(_ surface: ClipSurface, query: ClipQuery, page: ClipPage) {
        cache(page.items)
        let currentSelection = sessions[surface]?.selectedItemID
        sessions[surface] = ClipQuerySession(
            query: query,
            items: page.items,
            selectedItemID: selectedID(currentSelection, visibleIn: page.items, surface: surface),
            totalCount: page.totalCount,
            nextOffset: page.nextOffset,
            isLoading: false
        )
    }

    func cache(_ items: [ClipboardItem]) {
        for item in items {
            itemCache[item.id] = item
        }
    }

    func reloadCategories() async {
        do {
            customCategories = try await repository.fetchCategories()
        } catch {
            publishBanner(code: errorCode(for: error), severity: .error)
        }
    }

    func selectedID(_ id: UUID?, visibleIn items: [ClipboardItem], surface: ClipSurface) -> UUID? {
        guard let id else { return nil }
        guard items.contains(where: { $0.id == id }) || (surface == .library && itemCache[id] != nil) else {
            return nil
        }
        return id
    }

    func canSelect(_ id: UUID?, for surface: ClipSurface) -> Bool {
        guard let id else { return true }
        if session(for: surface).items.contains(where: { $0.id == id }) {
            return true
        }
        return surface == .library && itemCache[id] != nil
    }

    func cachedOrLoadedItem(id: UUID) async -> ClipboardItem? {
        if let item = itemCache[id] {
            return item
        }
        do {
            let item = try await repository.item(id: id)
            if let item {
                itemCache[id] = item
            }
            return item
        } catch {
            publishBanner(code: errorCode(for: error), severity: .error)
            return nil
        }
    }

    func canMutate() -> Bool {
        guard !isReadOnlyRecovery else {
            if case .readOnlyRecovery(_, let backupURL, _) = repositoryStartup {
                publishBanner(
                    code: .databaseReadOnly,
                    severity: .warning,
                    recoveryTitle: backupURL == nil ? nil : String(localized: "Reveal Backup"),
                    recoveryAction: backupURL.map(RecoveryAction.revealBackup)
                )
            } else {
                publishBanner(code: .databaseReadOnly, severity: .warning)
            }
            return false
        }
        return true
    }

    func consumeLegacySettingsAfterRepositoryStartupIfSafe() async {
        guard !isReadOnlyRecovery,
              let snapshot = settings.pendingLegacySettingsSnapshot else {
            return
        }

        guard await legacyCategoriesWereCommitted(snapshot) else {
            publishBanner(code: .migrationFailed, severity: .error)
            return
        }

        settings.consumeLegacySettingsAfterSuccessfulMigration(snapshot)
    }

    func legacyCategoriesWereCommitted(_ snapshot: LegacySettingsSnapshot) async -> Bool {
        let requiredCategoryIDs = Set(snapshot.categories.compactMap { category -> UUID? in
            let trimmedName = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedName.isEmpty ? nil : category.id
        })
        guard !requiredCategoryIDs.isEmpty else {
            return true
        }

        do {
            let committedCategoryIDs = Set(try await repository.fetchCategories().map(\.id))
            return requiredCategoryIDs.isSubset(of: committedCategoryIDs)
        } catch {
            return false
        }
    }

    func synchronizeMonitoringPauseState() {
        pauseExpirationTask?.cancel()
        pauseExpirationTask = nil

        switch monitoringPause {
        case .active:
            captureService.resume()
        case .indefinitely:
            captureService.pause(.indefinitely)
        case .until(let deadline):
            guard deadline > now() else {
                resumeMonitoring()
                return
            }
            captureService.pause(.until(deadline))
            schedulePauseExpiration(at: deadline)
        }
    }

    func schedulePauseExpiration(at deadline: Date) {
        let remaining = max(0, deadline.timeIntervalSince(now()))
        pauseExpirationTask = Task { [weak self, sleeper] in
            do {
                try await sleeper.sleep(for: .seconds(remaining))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.resumeMonitoring()
        }
    }

    func publishBanner(
        code: AppErrorCode,
        severity: AppBannerSeverity,
        recoveryTitle: String? = nil,
        recoveryAction: RecoveryAction? = nil
    ) {
        banner = AppErrorPresentation(
            code: code,
            message: message(for: code),
            severity: severity,
            recoveryTitle: recoveryTitle,
            recoveryAction: recoveryAction
        )
        Task { [logger, now] in
            await logger.record(DiagnosticEvent(code: code, timestamp: now()))
        }
    }

    func errorCode(for error: Error) -> AppErrorCode {
        switch error {
        case DatabaseError.openFailed:
            return .databaseOpen
        case DatabaseError.readOnlyRecovery:
            return .databaseReadOnly
        default:
            return .databaseWrite
        }
    }

    func appErrorCode(for reason: PrivacySkipReason) -> AppErrorCode {
        switch reason {
        case .excludedApplication:
            return .privacyExcluded
        case .exceedsSizeLimit:
            return .privacySize
        case .sensitive:
            return .privacySensitive
        }
    }

    func message(for code: AppErrorCode) -> String {
        switch code {
        case .databaseOpen:
            return String(localized: "ClipFlow could not open its clipboard database.")
        case .databaseWrite:
            return String(localized: "ClipFlow could not save the requested clipboard change.")
        case .databaseCopyMetadata:
            return String(localized: "Copied, but ClipFlow could not refresh copy metadata.")
        case .databaseReadOnly:
            return String(localized: "ClipFlow is running in read-only recovery mode.")
        case .migrationFailed:
            return String(localized: "ClipFlow could not finish database migration.")
        case .migrationBackupDelete:
            return String(localized: "ClipFlow could not delete all migration backups.")
        case .clipboardRead:
            return String(localized: "ClipFlow could not read that clipboard item.")
        case .clipboardWrite:
            return String(localized: "ClipFlow could not write to the system pasteboard.")
        case .hotkeyRegistration:
            return String(localized: "ClipFlow could not register the global shortcut.")
        case .privacyExcluded:
            return String(localized: "Clipboard capture was skipped for an excluded app.")
        case .privacySize:
            return String(localized: "Clipboard capture was skipped because the text is too large.")
        case .privacySensitive:
            return String(localized: "Clipboard capture was skipped because it may contain sensitive content.")
        case .aiEndpoint:
            return String(localized: "ClipFlow could not validate the AI endpoint.")
        case .aiConsent:
            return String(localized: "Remote AI consent is required before sending text.")
        case .aiRequest:
            return String(localized: "ClipFlow could not complete the AI request.")
        case .releaseConfiguration:
            return String(localized: "ClipFlow found an invalid release configuration.")
        }
    }

    func clearSessionAfterRefreshFailure(_ surface: ClipSurface, code: AppErrorCode) {
        ensureSession(for: surface)
        let current = session(for: surface)
        let query = current.query
        for id in current.items.map(\.id) {
            itemCache.removeValue(forKey: id)
        }
        sessions[surface] = ClipQuerySession(
            query: query,
            items: [],
            selectedItemID: nil,
            totalCount: 0,
            nextOffset: nil,
            isLoading: false
        )
        publishBanner(
            code: code,
            severity: .error,
            recoveryTitle: "Retry",
            recoveryAction: .retry(surface: surface)
        )
    }

    func reconcileAllSessionsAfterCommittedMutation() async {
        for surface in [ClipSurface.quickPanel, .library] {
            await reconcileLoadedExtent(surface)
        }
    }

    func reconcileLoadedExtent(_ surface: ClipSurface) async {
        ensureSession(for: surface)
        let current = session(for: surface)
        do {
            let page = try await fetchLoadedExtent(for: current)
            replaceSession(surface, query: current.query, page: page)
        } catch {
            clearSessionAfterRefreshFailure(surface, code: errorCode(for: error))
        }
    }

    func fetchLoadedExtent(for session: ClipQuerySession) async throws -> ClipPage {
        let targetCount = max(session.items.count, session.query.limit)
        var accumulated: [ClipboardItem] = []
        var nextOffset: Int? = 0
        var totalCount = 0
        let pageLimit = max(1, min(session.query.limit, 100))

        while let offset = nextOffset, accumulated.count < targetCount {
            var query = session.query
            query.offset = offset
            query.limit = min(pageLimit, max(pageLimit, targetCount - accumulated.count))
            let page = try await repository.fetchPage(query)
            let seen = Set(accumulated.map(\.id))
            accumulated.append(contentsOf: page.items.filter { !seen.contains($0.id) })
            totalCount = page.totalCount
            nextOffset = page.nextOffset
            if page.items.isEmpty {
                break
            }
        }

        return ClipPage(items: accumulated, nextOffset: nextOffset, totalCount: totalCount)
    }

    func reloadAfterCommittedCleanup() async {
        itemCache.removeAll()
        for surface in [ClipSurface.quickPanel, .library] {
            await reload(surface)
        }
    }

    func updateItemInAllSessions(_ updated: ClipboardItem) {
        for surface in [ClipSurface.quickPanel, .library] {
            ensureSession(for: surface)
            guard var current = sessions[surface] else { continue }
            guard let index = current.items.firstIndex(where: { $0.id == updated.id }) else { continue }
            current.items[index] = updated
            sessions[surface] = current
        }
    }

    func removeVisibleItem(id: UUID) {
        for surface in [ClipSurface.quickPanel, .library] {
            ensureSession(for: surface)
            guard var current = sessions[surface] else { continue }
            current.items.removeAll { $0.id == id }
            current.totalCount = max(0, current.totalCount - 1)
            if current.selectedItemID == id {
                current.selectedItemID = nil
            }
            sessions[surface] = current
        }
    }

    func createPendingDelete(id: UUID, deletedAt: Date) {
        let expiresAt = deletedAt.addingTimeInterval(Self.pendingDeleteSeconds)
        pendingDeletes[id] = PendingDelete(itemID: id, deletedAt: deletedAt, expiresAt: expiresAt)
        startUndoTimer(id: id, expiresAt: expiresAt)
    }

    func startUndoTimer(id: UUID, expiresAt: Date) {
        undoTasks[id]?.cancel()
        let remaining = max(0, expiresAt.timeIntervalSince(now()))
        undoTasks[id] = Task { [weak self, sleeper] in
            do {
                try await sleeper.sleep(for: .seconds(remaining))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.finalizePendingDelete(id: id)
        }
    }

    func cancelAllPendingDeletes() {
        for task in undoTasks.values {
            task.cancel()
        }
        undoTasks.removeAll()
        pendingDeletes.removeAll()
    }

    func clearAllVisibleClipboardState() {
        itemCache.removeAll()
        for surface in [ClipSurface.quickPanel, .library] {
            let query = session(for: surface).query
            sessions[surface] = ClipQuerySession(
                query: query,
                items: [],
                selectedItemID: nil,
                totalCount: 0,
                nextOffset: nil,
                isLoading: false
            )
        }
    }

    func staleOrMissing(itemID: UUID) async -> AIResultApplication {
        do {
            return try await repository.item(id: itemID) == nil ? .targetMissing : .staleGeneration
        } catch {
            return .targetMissing
        }
    }

    func purgeExpiredTombstonesAndRestoreUndoTimers() async {
        for task in undoTasks.values {
            task.cancel()
        }
        undoTasks.removeAll()
        pendingDeletes.removeAll()

        let cutoff = now().addingTimeInterval(-Self.pendingDeleteSeconds + 0.000_001)
        do {
            _ = try await repository.purgeDeleted(before: cutoff)
            let recent = try await repository.deletedTombstones(
                since: now().addingTimeInterval(-Self.pendingDeleteSeconds)
            )
            for tombstone in recent {
                let expiresAt = tombstone.deletedAt.addingTimeInterval(Self.pendingDeleteSeconds)
                guard expiresAt > now() else {
                    try await repository.purgeDeleted(id: tombstone.itemID)
                    continue
                }
                pendingDeletes[tombstone.itemID] = PendingDelete(
                    itemID: tombstone.itemID,
                    deletedAt: tombstone.deletedAt,
                    expiresAt: expiresAt
                )
                startUndoTimer(id: tombstone.itemID, expiresAt: expiresAt)
            }
        } catch {
            publishBanner(code: errorCode(for: error), severity: .warning)
        }
    }

    func performRetentionCleanupAndReload() async {
        do {
            _ = try await repository.cleanup(retention: settings.retentionPolicy, now: now())
        } catch {
            publishBanner(code: errorCode(for: error), severity: .warning)
        }
    }

    func purgeExpiredBackups() async {
        do {
            _ = try await backupManager.purgeExpired(now: now())
        } catch {
            publishBanner(
                code: .migrationBackupDelete,
                severity: .warning,
                recoveryTitle: "Delete Backups",
                recoveryAction: .deleteMigrationBackups
            )
        }
    }

    func startCaptureService() {
        captureService.start { [weak self] rawCapture in
            guard let self else { return }
            Task {
                let event = await self.capturePipeline.process(rawCapture)
                await self.applyCaptureEvent(event)
            }
        }
    }

    func startCleanupTask() {
        cleanupTask?.cancel()
        cleanupTask = Task { [weak self, sleeper] in
            while !Task.isCancelled {
                do {
                    try await sleeper.sleep(for: .seconds(86_400))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.runScheduledCleanupTick()
            }
        }
    }

    func runScheduledCleanupTick() async {
        guard !isReadOnlyRecovery else { return }
        await performRetentionCleanupAndReload()
        await purgeExpiredBackups()
        await reconcileAllSessionsAfterCommittedMutation()
    }

    func mergeIfVisible(_ item: ClipboardItem) {
        for surface in [ClipSurface.quickPanel, .library] {
            ensureSession(for: surface)
            var current = session(for: surface)
            guard matches(item, query: current.query) else { continue }
            current.items.removeAll { $0.id == item.id }
            current.items.append(item)
            current.items.sort(by: Self.itemOrder)
            if current.items.count > current.query.limit {
                current.items = Array(current.items.prefix(current.query.limit))
            }
            current.totalCount = max(current.totalCount, current.items.count)
            current.selectedItemID = selectedID(
                current.selectedItemID,
                visibleIn: current.items,
                surface: surface
            )
            sessions[surface] = current
        }
    }

    func matches(_ item: ClipboardItem, query: ClipQuery) -> Bool {
        guard item.deletedAt == nil else { return false }
        guard query.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                item.content.localizedCaseInsensitiveContains(query.searchText) else {
            return false
        }
        switch query.scope {
        case .all:
            return true
        case .favorites:
            return item.isFavorite
        case .today:
            return Calendar.current.isDateInToday(item.lastCopiedAt)
        case .builtIn(let category):
            return item.category == category
        case .custom(let id):
            return item.customCategoryID == id
        }
    }

    static func itemOrder(_ lhs: ClipboardItem, _ rhs: ClipboardItem) -> Bool {
        if lhs.lastCopiedAt != rhs.lastCopiedAt {
            return lhs.lastCopiedAt > rhs.lastCopiedAt
        }
        return lhs.id.uuidString > rhs.id.uuidString
    }

    static let pendingDeleteSeconds: TimeInterval = 8
}
