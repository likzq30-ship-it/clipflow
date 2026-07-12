import XCTest
@testable import ClipFlow

@MainActor
final class SettingsActionAdapterTests: XCTestCase {
    func testDiagnosticsNeverContainsClipCredentialEndpointOrErrorText() async {
        let remoteURL = URL(string: "https://private-ai.example.com/v1")!
        let harness = await SettingsDiagnosticsHarness.make(
            clipText: "secret clip",
            credential: "Bearer top-secret",
            remoteURL: remoteURL
        )
        await harness.logger.record(
            DiagnosticEvent(code: .aiRequest, timestamp: Date(timeIntervalSince1970: 0))
        )

        let snapshot = await harness.adapter.diagnosticsSnapshot()
        let report = DiagnosticsReportBuilder().render(snapshot)

        for canary in ["secret clip", "Bearer top-secret", "private-ai.example.com", "upstream says secret"] {
            XCTAssertFalse(report.contains(canary), "Diagnostics leaked canary: \(canary)")
        }
        XCTAssertTrue(report.contains("ai.request"))
        XCTAssertTrue(report.contains("remoteConfigured=true"))
    }

    func testUpdatePrivacyConfigurationPersistsThroughStoreAndSettings() async {
        let harness = await SettingsDiagnosticsHarness.make()
        let configuration = PrivacyConfiguration(
            excludedBundleIDs: ["com.example.Secret"],
            maxUTF8Bytes: 512,
            detectsSensitiveContent: false
        )

        await harness.adapter.updatePrivacyConfiguration(configuration)

        XCTAssertEqual(harness.store.privacyConfiguration, configuration)
        XCTAssertEqual(harness.settings.privacyConfiguration, configuration)
    }

    func testClearClipboardDataCancelsAIJobsBeforeDeleting() async {
        let harness = await SettingsDiagnosticsHarness.make(clipText: "delete me")
        let item = await harness.repository.seed(.fixture(content: "running ai"))
        let request = AIRequest(
            itemID: item.id,
            operation: .rewrite,
            text: item.content,
            allowedCategories: []
        )
        await harness.jobs.start(
            request,
            provider: .localOllama(baseURL: URL(string: "http://127.0.0.1:11434")!, model: "tiny")
        )
        await waitForPendingAI(harness.ai)

        let outcome = await harness.adapter.clearClipboardDataConfirmed()

        XCTAssertEqual(outcome, .complete(removedClipCount: 2))
        XCTAssertFalse(harness.jobs.states.values.contains {
            if case .running = $0 {
                return true
            }
            return false
        })
        let remainingClipCount = try? await harness.repository.countAllClips()
        XCTAssertEqual(remainingClipCount, 0)
    }
}

@MainActor
private struct SettingsDiagnosticsHarness {
    let repository: InMemoryRepository
    let settings: AppSettingsStore
    let store: ClipboardStore
    let ai: ControllableAIService
    let jobs: AIJobCoordinator
    let keychain: InMemoryKeychainCredentialStore
    let logger: InMemoryAppLogger
    let adapter: SettingsActionAdapter

    static func make(
        clipText: String = "clip",
        credential: String = "credential",
        remoteURL: URL = URL(string: "https://ai.example.com")!
    ) async -> SettingsDiagnosticsHarness {
        let repository = InMemoryRepository()
        let settings = AppSettingsStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.setAIProvider(.remoteHTTPS)
        settings.setAIEndpoint(remoteURL)
        settings.setAIModel("remote-model")
        let store = makeStore(repository: repository, settings: settings)
        await store.start()
        _ = await repository.seed(.fixture(content: clipText))
        await store.reload(.library)
        let ai = ControllableAIService()
        let jobs = AIJobCoordinator(ai: ai, store: store)
        let keychain = InMemoryKeychainCredentialStore()
        if let origin = AIConsentOrigin(url: remoteURL) {
            try? await keychain.setCredential(credential, for: origin)
        }
        let logger = InMemoryAppLogger()
        let adapter = SettingsActionAdapter(
            settings: settings,
            store: store,
            aiJobs: jobs,
            aiService: ai,
            keychain: keychain,
            launchAtLogin: LaunchAtLoginService(registrar: FakeLoginItemRegistrar()),
            logger: logger
        )
        return SettingsDiagnosticsHarness(
            repository: repository,
            settings: settings,
            store: store,
            ai: ai,
            jobs: jobs,
            keychain: keychain,
            logger: logger,
            adapter: adapter
        )
    }
}

private func waitForPendingAI(_ ai: ControllableAIService, count: Int = 1) async {
    for _ in 0..<50 {
        if await ai.pendingCount() >= count {
            return
        }
        await Task.yield()
    }
}
