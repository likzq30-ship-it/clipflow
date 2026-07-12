import XCTest
@testable import ClipFlow

@MainActor
final class AIActionCoordinatorTests: XCTestCase {
    func testDisabledProviderReturnsWithoutRequest() async {
        let harness = await AIActionHarness.make()
        harness.settings.setAIProvider(.disabled)

        await harness.actions.start(
            item: harness.item,
            operation: .summarize,
            allowedCategories: []
        )

        let requests = await harness.ai.recordedRequests()
        XCTAssertEqual(requests.count, 0)
        XCTAssertTrue(harness.consentPresenter.requestedOrigins.isEmpty)
    }

    func testRemoteConsentRejectProducesZeroAIRequests() async {
        let harness = await AIActionHarness.make(remoteConsentDecisions: [false])
        harness.configureRemoteEndpoint("https://ai.example.com")

        await harness.actions.start(
            item: harness.item,
            operation: .summarize,
            allowedCategories: []
        )

        let requests = await harness.ai.recordedRequests()
        XCTAssertEqual(requests.count, 0)
        XCTAssertEqual(
            harness.consentPresenter.requestedOrigins,
            [AIConsentOrigin(scheme: "https", host: "ai.example.com", port: 443)]
        )
    }

    func testRemoteConsentAcceptProducesExactlyOneItemBoundRequest() async {
        let harness = await AIActionHarness.make(remoteConsentDecisions: [true])
        harness.configureRemoteEndpoint("https://ai.example.com:8443")

        await harness.actions.start(
            item: harness.item,
            operation: .rewrite,
            allowedCategories: []
        )
        await waitForPendingAIAction(harness.ai)

        let requests = await harness.ai.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.itemID, harness.item.id)
        XCTAssertEqual(requests.first?.operation, .rewrite)
        XCTAssertEqual(requests.first?.text, harness.item.content)
        XCTAssertEqual(
            harness.consentPresenter.requestedOrigins,
            [AIConsentOrigin(scheme: "https", host: "ai.example.com", port: 8443)]
        )
    }

    func testChangingRemoteOriginRequiresScenePresenterAgain() async {
        let harness = await AIActionHarness.make(remoteConsentDecisions: [true, true])
        harness.configureRemoteEndpoint("https://ai.example.com")

        await harness.actions.start(
            item: harness.item,
            operation: .summarize,
            allowedCategories: []
        )
        await waitForPendingAIAction(harness.ai)
        await harness.ai.complete(with: AIResult(
            itemID: harness.item.id,
            operation: .summarize,
            text: "summary",
            providerLabel: "remote"
        ))
        await harness.jobs.waitForIdle()

        harness.configureRemoteEndpoint("https://other.example.com:8443")
        await harness.actions.start(
            item: harness.item,
            operation: .categorize,
            allowedCategories: [.fixture(name: "Project", sortOrder: 0)]
        )

        XCTAssertEqual(
            harness.consentPresenter.requestedOrigins,
            [
                AIConsentOrigin(scheme: "https", host: "ai.example.com", port: 443),
                AIConsentOrigin(scheme: "https", host: "other.example.com", port: 8443)
            ]
        )
    }

    func testLocalProviderIsRevalidatedImmediatelyBeforeRequest() async {
        let harness = await AIActionHarness.make()
        harness.settings.setAIProvider(.localOllama)
        harness.settings.setAIEndpoint(URL(string: "https://not-loopback.example.com")!)

        await harness.actions.start(
            item: harness.item,
            operation: .summarize,
            allowedCategories: []
        )

        let requests = await harness.ai.recordedRequests()
        XCTAssertEqual(requests.count, 0)
    }
}

private func waitForPendingAIAction(_ ai: ControllableAIService, count: Int = 1) async {
    for _ in 0..<50 {
        if await ai.pendingCount() >= count {
            return
        }
        await Task.yield()
    }
}

@MainActor
private final class AIActionHarness {
    let repository: InMemoryRepository
    let store: ClipboardStore
    let settings: AppSettingsStore
    let ai: ControllableAIService
    let jobs: AIJobCoordinator
    let consentPresenter: RecordingRemoteConsentPresenter
    let actions: AIActionCoordinator
    let item: ClipboardItem

    private init(
        repository: InMemoryRepository,
        store: ClipboardStore,
        settings: AppSettingsStore,
        ai: ControllableAIService,
        jobs: AIJobCoordinator,
        consentPresenter: RecordingRemoteConsentPresenter,
        actions: AIActionCoordinator,
        item: ClipboardItem
    ) {
        self.repository = repository
        self.store = store
        self.settings = settings
        self.ai = ai
        self.jobs = jobs
        self.consentPresenter = consentPresenter
        self.actions = actions
        self.item = item
    }

    static func make(remoteConsentDecisions: [Bool] = []) async -> AIActionHarness {
        let repository = InMemoryRepository()
        let item = await repository.seed(.fixture(content: "item-bound text"))
        let settings = AppSettingsStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = makeStore(repository: repository, settings: settings)
        await store.start()
        let ai = ControllableAIService()
        let jobs = AIJobCoordinator(ai: ai, store: store)
        let consentPresenter = RecordingRemoteConsentPresenter(decisions: remoteConsentDecisions)
        let actions = AIActionCoordinator(
            settings: settings,
            jobs: jobs,
            consentPresenter: consentPresenter
        )
        return AIActionHarness(
            repository: repository,
            store: store,
            settings: settings,
            ai: ai,
            jobs: jobs,
            consentPresenter: consentPresenter,
            actions: actions,
            item: item
        )
    }

    func configureRemoteEndpoint(_ urlString: String) {
        settings.setAIProvider(.remoteHTTPS)
        settings.setAIEndpoint(URL(string: urlString)!)
    }
}
