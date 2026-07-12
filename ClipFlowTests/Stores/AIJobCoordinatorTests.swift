import XCTest
@testable import ClipFlow

@MainActor
final class AIJobCoordinatorTests: XCTestCase {
    func testResultWritesBackToRequestItemAfterSelectionChanges() async throws {
        let repository = InMemoryRepository()
        let first = await repository.seed(.fixture(content: "first"))
        let second = await repository.seed(.fixture(content: "second"))
        let store = makeStore(repository: repository)
        await store.start()
        let ai = ControllableAIService()
        let coordinator = AIJobCoordinator(ai: ai, store: store)

        await coordinator.start(
            AIRequest(
                itemID: first.id,
                operation: .summarize,
                text: first.content,
                allowedCategories: []
            ),
            provider: .localOllama(
                baseURL: URL(string: "http://127.0.0.1:11434")!,
                model: "fixture"
            )
        )
        await waitForPendingAI(ai)
        coordinator.visibleItemID = second.id
        await ai.complete(with: AIResult(
            itemID: first.id,
            operation: .summarize,
            text: "first summary",
            providerLabel: "fixture"
        ))
        await coordinator.waitForIdle()

        let persistedFirst = try await repository.item(id: first.id)
        let persistedSecond = try await repository.item(id: second.id)
        XCTAssertEqual(persistedFirst?.aiSummary, "first summary")
        XCTAssertNil(persistedSecond?.aiSummary)
        XCTAssertEqual(store.itemCache[first.id]?.aiSummary, "first summary")
        XCTAssertNil(store.itemCache[second.id]?.aiSummary)
    }

    func testCancelledResultNeverReachesStore() async throws {
        let repository = InMemoryRepository()
        let item = await repository.seed(.fixture(content: "cancel"))
        let store = makeStore(repository: repository)
        await store.start()
        let ai = ControllableAIService()
        let coordinator = AIJobCoordinator(ai: ai, store: store)
        let request = AIRequest(itemID: item.id, operation: .summarize, text: item.content, allowedCategories: [])

        await coordinator.start(
            request,
            provider: .localOllama(baseURL: URL(string: "http://127.0.0.1:11434")!, model: "fixture")
        )
        await waitForPendingAI(ai)
        await coordinator.cancel(itemID: item.id, operation: .summarize)
        await ai.complete(with: AIResult(
            itemID: item.id,
            operation: .summarize,
            text: "late",
            providerLabel: "fixture"
        ))
        await coordinator.waitForIdle()

        let persisted = try await repository.item(id: item.id)
        XCTAssertNil(persisted?.aiSummary)
        XCTAssertNil(store.itemCache[item.id]?.aiSummary)
        let usage = await repository.usage
        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage.first?.operation, .summarize)
        XCTAssertEqual(usage.first?.succeeded, false)
        XCTAssertEqual(usage.first?.errorCode, "ai.cancelled")
    }

    func testCancelAllForItemDoesNotCancelOtherItems() async throws {
        let repository = InMemoryRepository()
        let first = await repository.seed(.fixture(content: "first"))
        let second = await repository.seed(.fixture(content: "second"))
        let category = PersistedCustomCategory.fixture(name: "Project", sortOrder: 0)
        let store = makeStore(repository: repository)
        await store.start()
        let ai = ControllableAIService()
        let coordinator = AIJobCoordinator(ai: ai, store: store)
        let provider = AIProviderConfiguration.localOllama(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            model: "fixture"
        )

        await coordinator.start(.init(itemID: first.id, operation: .summarize, text: "first", allowedCategories: []), provider: provider)
        await coordinator.start(.init(itemID: first.id, operation: .categorize, text: "first", allowedCategories: [category]), provider: provider)
        await coordinator.start(.init(itemID: second.id, operation: .summarize, text: "second", allowedCategories: []), provider: provider)
        await waitForPendingAI(ai, count: 3)
        await coordinator.cancelAll(itemID: first.id)

        await ai.complete(with: .init(itemID: first.id, operation: .summarize, text: "late summary", providerLabel: "fixture"))
        await ai.complete(with: .init(itemID: first.id, operation: .categorize, text: category.name, providerLabel: "fixture"))
        await ai.complete(with: .init(itemID: second.id, operation: .summarize, text: "second summary", providerLabel: "fixture"))
        await coordinator.waitForIdle()

        let persistedFirst = try await repository.item(id: first.id)
        let persistedSecond = try await repository.item(id: second.id)
        XCTAssertNil(persistedFirst?.aiSummary)
        XCTAssertNil(persistedFirst?.customCategoryID)
        XCTAssertEqual(persistedSecond?.aiSummary, "second summary")
        XCTAssertEqual(
            coordinator.states[AIJobKey(itemID: first.id, operation: .summarize)],
            .failure(code: "ai.cancelled", message: "ai.cancelled")
        )
        XCTAssertEqual(
            coordinator.states[AIJobKey(itemID: first.id, operation: .categorize)],
            .failure(code: "ai.cancelled", message: "ai.cancelled")
        )
    }

    func testNewerGenerationWinsForSameKey() async throws {
        let repository = InMemoryRepository()
        let item = await repository.seed(.fixture(content: "newest"))
        let store = makeStore(repository: repository)
        await store.start()
        let ai = ControllableAIService()
        let coordinator = AIJobCoordinator(ai: ai, store: store)
        let provider = AIProviderConfiguration.localOllama(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            model: "fixture"
        )

        await coordinator.start(.init(itemID: item.id, operation: .summarize, text: "old", allowedCategories: []), provider: provider)
        await waitForPendingAI(ai)
        await coordinator.start(.init(itemID: item.id, operation: .summarize, text: "new", allowedCategories: []), provider: provider)
        await waitForPendingAI(ai, count: 2)
        await ai.complete(with: .init(itemID: item.id, operation: .summarize, text: "old", providerLabel: "fixture"))
        await ai.complete(with: .init(itemID: item.id, operation: .summarize, text: "new", providerLabel: "fixture"))
        await coordinator.waitForIdle()

        let persisted = try await repository.item(id: item.id)
        XCTAssertEqual(persisted?.aiSummary, "new")
    }

    func testRepositoryFailureLeavesStoreCacheUnchanged() async throws {
        let repository = InMemoryRepository()
        let item = await repository.seed(.fixture(content: "stable"))
        let store = makeStore(repository: repository)
        await store.start()
        let ai = ControllableAIService()
        let coordinator = AIJobCoordinator(ai: ai, store: store)
        await repository.setFailNextMutation(true)

        await coordinator.start(
            .init(itemID: item.id, operation: .summarize, text: item.content, allowedCategories: []),
            provider: .localOllama(baseURL: URL(string: "http://127.0.0.1:11434")!, model: "fixture")
        )
        await waitForPendingAI(ai)
        await ai.complete(with: .init(itemID: item.id, operation: .summarize, text: "failed", providerLabel: "fixture"))
        await coordinator.waitForIdle()

        let persisted = try await repository.item(id: item.id)
        XCTAssertNil(persisted?.aiSummary)
        XCTAssertNil(store.itemCache[item.id]?.aiSummary)
        XCTAssertEqual(coordinator.states[AIJobKey(itemID: item.id, operation: .summarize)], .failure(code: "database.write", message: "database.write"))
    }

    func testDeletedTargetDropsResultAndRecordsOnlyContentFreeUsageMetadata() async throws {
        let repository = InMemoryRepository()
        let item = await repository.seed(.fixture(content: "delete me"))
        let store = makeStore(
            repository: repository,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        await store.start()
        let ai = ControllableAIService()
        let coordinator = AIJobCoordinator(
            ai: ai,
            store: store,
            now: { Date(timeIntervalSince1970: 1_001) }
        )

        await coordinator.start(
            .init(itemID: item.id, operation: .summarize, text: item.content, allowedCategories: []),
            provider: .localOllama(baseURL: URL(string: "http://127.0.0.1:11434")!, model: "fixture")
        )
        await waitForPendingAI(ai)
        try await repository.softDelete(id: item.id, at: Date(timeIntervalSince1970: 1_000))
        await ai.complete(with: .init(itemID: item.id, operation: .summarize, text: "late summary", providerLabel: "fixture"))
        await coordinator.waitForIdle()

        let deleted = try await repository.item(id: item.id)
        XCTAssertNil(deleted)
        XCTAssertNil(store.itemCache[item.id]?.aiSummary)
        XCTAssertEqual(
            coordinator.states[AIJobKey(itemID: item.id, operation: .summarize)],
            .failure(code: "ai.targetMissing", message: "ai.targetMissing")
        )
        let usage = await repository.usage
        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage.first?.operation, .summarize)
        XCTAssertEqual(usage.first?.provider, "local")
        XCTAssertEqual(usage.first?.model, "fixture")
        XCTAssertEqual(usage.first?.succeeded, false)
        XCTAssertEqual(usage.first?.errorCode, "ai.targetMissing")
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
