import XCTest
@testable import ClipFlow

@MainActor
final class ClipDetailActionTests: XCTestCase {
    func testDetailActionUsesRenderedItemIDNotCurrentSelection() async throws {
        let harness = await ClipDetailActionHarness.make()
        let rendered = await harness.seed(id: UUID(), content: "rendered")
        let selectedAfterRender = await harness.seed(id: UUID(), content: "current selection")
        harness.store.setSelection(selectedAfterRender.id, for: .library)

        await harness.adapter.summarize(itemID: rendered.id)
        await waitForPendingAI(harness.ai)

        let requests = await harness.ai.recordedRequests()
        let requestedItemIDs = requests.map(\.itemID)
        XCTAssertEqual(requestedItemIDs, [rendered.id])
        XCTAssertEqual(requests.first?.text, "rendered")
    }

    func testCopyFavoriteAndDeleteUseExplicitItemID() async throws {
        let harness = await ClipDetailActionHarness.make()
        let rendered = await harness.seed(id: UUID(), content: "rendered")
        let other = await harness.seed(id: UUID(), content: "other")
        harness.store.setSelection(other.id, for: .library)

        await harness.adapter.copy(itemID: rendered.id)
        await harness.adapter.toggleFavorite(itemID: rendered.id)
        await harness.adapter.delete(itemID: rendered.id)

        XCTAssertEqual(harness.pasteboard.writtenText, "rendered")
        let renderedAfterFavorite = try await harness.repository.item(id: rendered.id)
        XCTAssertNil(renderedAfterFavorite, "Delete should target the rendered item, not the later selection.")
        let otherAfterActions = try await harness.repository.item(id: other.id)
        XCTAssertNotNil(otherAfterActions)
    }
}

@MainActor
private final class ClipDetailActionHarness {
    let repository: InMemoryRepository
    let pasteboard: FakePasteboardWriter
    let store: ClipboardStore
    let ai: ControllableAIService
    let adapter: ClipDetailActionAdapter

    private init(
        repository: InMemoryRepository,
        pasteboard: FakePasteboardWriter,
        store: ClipboardStore,
        ai: ControllableAIService,
        adapter: ClipDetailActionAdapter
    ) {
        self.repository = repository
        self.pasteboard = pasteboard
        self.store = store
        self.ai = ai
        self.adapter = adapter
    }

    static func make() async -> ClipDetailActionHarness {
        let repository = InMemoryRepository()
        let pasteboard = FakePasteboardWriter(result: true)
        let settings = AppSettingsStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.setAIProvider(.localOllama)
        settings.setAIEndpoint(URL(string: "http://127.0.0.1:11434")!)
        let store = makeStore(
            repository: repository,
            pasteboard: pasteboard,
            settings: settings
        )
        await store.start()
        let ai = ControllableAIService()
        let jobs = AIJobCoordinator(ai: ai, store: store)
        let actions = AIActionCoordinator(
            settings: settings,
            jobs: jobs,
            consentPresenter: RecordingRemoteConsentPresenter(decisions: [])
        )
        let adapter = ClipDetailActionAdapter(
            store: store,
            aiActions: actions,
            allowedCategories: { [] }
        )
        return ClipDetailActionHarness(
            repository: repository,
            pasteboard: pasteboard,
            store: store,
            ai: ai,
            adapter: adapter
        )
    }

    func seed(id: UUID, content: String) async -> ClipboardItem {
        let item = ClipboardItem(
            id: id,
            content: content,
            category: .english,
            timestamp: Date(timeIntervalSince1970: Double.random(in: 0...1_000))
        )
        let seeded = await repository.seed(item)
        await store.reload(.library)
        return seeded
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
