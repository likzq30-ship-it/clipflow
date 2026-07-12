import Foundation

@MainActor
final class SettingsActionAdapter {
    private let settings: AppSettingsStore
    private let store: ClipboardStore
    private let aiJobs: AIJobCoordinator
    private let aiService: any AIServiceProtocol
    private let keychain: any KeychainCredentialStoring
    private let launchAtLogin: LaunchAtLoginService
    private let logger: any AppLogging

    init(
        settings: AppSettingsStore,
        store: ClipboardStore,
        aiJobs: AIJobCoordinator,
        aiService: any AIServiceProtocol,
        keychain: any KeychainCredentialStoring,
        launchAtLogin: LaunchAtLoginService,
        logger: any AppLogging
    ) {
        self.settings = settings
        self.store = store
        self.aiJobs = aiJobs
        self.aiService = aiService
        self.keychain = keychain
        self.launchAtLogin = launchAtLogin
        self.logger = logger
    }

    func diagnosticsSnapshot() async -> DiagnosticsSnapshot {
        let aiAvailable: Bool?
        do {
            let provider = try settings.validatedAIProviderConfiguration()
            switch await aiService.checkAvailability(provider: provider) {
            case .available:
                aiAvailable = true
            case .disabled:
                aiAvailable = false
            case .unavailable:
                aiAvailable = false
            }
        } catch {
            aiAvailable = nil
        }

        return DiagnosticsSnapshot(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            aiProviderKind: settings.aiProviderKind.rawValue,
            remoteConfigured: settings.aiProviderKind == .remoteHTTPS && settings.aiEndpoint != nil,
            aiAvailable: aiAvailable,
            sensitiveProtectionEnabled: settings.sensitiveContentProtectionEnabled,
            excludedApplicationCount: settings.excludedBundleIDs.count,
            recentEvents: await logger.recentEvents(limit: 50)
        )
    }

    func updatePrivacyConfiguration(_ configuration: PrivacyConfiguration) async {
        await store.updatePrivacyConfiguration(configuration)
    }

    func pauseMonitoring(_ state: MonitoringPause) {
        store.pauseMonitoring(state)
    }

    func resumeMonitoring() {
        store.resumeMonitoring()
    }

    func clearClipboardDataConfirmed() async -> ClearClipboardDataOutcome {
        _ = await store.countAllClips()
        await aiJobs.cancelAll()
        aiJobs.clearAllTransientResults()
        return await store.deleteAllClipboardDataConfirmed()
    }

    func deleteMigrationBackups() async -> Bool {
        await store.deleteMigrationBackups()
    }

    func setRetentionPolicy(_ policy: RetentionPolicy) async {
        await store.updateRetention(policy, now: Date())
    }

    func setMaxCaptureBytes(_ bytes: Int) async {
        guard bytes > 0 else { return }
        var configuration = settings.privacyConfiguration
        configuration.maxUTF8Bytes = bytes
        await updatePrivacyConfiguration(configuration)
    }

    func setSensitiveProtectionEnabled(_ enabled: Bool) async {
        var configuration = settings.privacyConfiguration
        configuration.detectsSensitiveContent = enabled
        await updatePrivacyConfiguration(configuration)
    }

    func addExcludedBundleID(_ bundleID: String) async {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var configuration = settings.privacyConfiguration
        configuration.excludedBundleIDs.insert(trimmed)
        await updatePrivacyConfiguration(configuration)
    }

    func removeExcludedBundleID(_ bundleID: String) async {
        var configuration = settings.privacyConfiguration
        configuration.excludedBundleIDs.remove(bundleID)
        await updatePrivacyConfiguration(configuration)
    }

    func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        launchAtLogin.setEnabled(enabled)
    }

    func saveCategory(_ category: PersistedCustomCategory) async {
        await store.saveCategory(category)
    }

    func deleteCategory(id: UUID, migrateTo replacementID: UUID?) async {
        await store.deleteCategory(id: id, migrateTo: replacementID)
    }

    func reorderCategories(ids: [UUID]) async {
        await store.reorderCategories(ids: ids)
    }

    func saveAIConfiguration(
        provider: AIProviderKind,
        endpoint: URL?,
        model: String
    ) async -> Bool {
        settings.setAIProvider(provider)
        settings.setAIEndpoint(endpoint)
        settings.setAIModel(model.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            _ = try settings.validatedAIProviderConfiguration()
            return true
        } catch {
            await logger.record(DiagnosticEvent(code: .aiEndpoint, timestamp: Date()))
            return provider == .disabled
        }
    }

    func removeCredential() async -> Bool {
        guard let endpoint = settings.aiEndpoint,
              let origin = AIConsentOrigin(url: endpoint) else { return true }
        do {
            try await keychain.deleteCredential(for: origin)
            return true
        } catch {
            await logger.record(DiagnosticEvent(code: .aiEndpoint, timestamp: Date()))
            return false
        }
    }

    func clearAIUsage() async {
        await store.clearAIUsage()
    }
}
