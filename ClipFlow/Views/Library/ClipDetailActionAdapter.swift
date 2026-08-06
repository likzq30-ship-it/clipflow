import Foundation

@MainActor
protocol ClipDetailActions: AnyObject {
    func copy(itemID: UUID) async
    func toggleFavorite(itemID: UUID) async
    func delete(itemID: UUID) async
    func updateContent(itemID: UUID, content: String) async
    func summarize(itemID: UUID) async
    func categorize(itemID: UUID) async
    func rewrite(itemID: UUID) async
}

@MainActor
final class ClipDetailActionAdapter: ClipDetailActions {
    private let store: ClipboardStore
    private let aiActions: AIActionCoordinator
    private let jobs: AIJobCoordinator
    private let allowedCategories: () -> [PersistedCustomCategory]

    init(
        store: ClipboardStore,
        aiActions: AIActionCoordinator,
        jobs: AIJobCoordinator,
        allowedCategories: @escaping () -> [PersistedCustomCategory]
    ) {
        self.store = store
        self.aiActions = aiActions
        self.jobs = jobs
        self.allowedCategories = allowedCategories
    }

    func copy(itemID: UUID) async {
        _ = await store.copy(id: itemID, recoverySurface: .library)
    }

    func toggleFavorite(itemID: UUID) async {
        await store.toggleFavorite(id: itemID)
    }

    func delete(itemID: UUID) async {
        guard await store.delete(id: itemID) else { return }
        await jobs.cancelAll(itemID: itemID)
        jobs.clearTransientResults(itemID: itemID)
    }

    func updateContent(itemID: UUID, content: String) async {
        await store.updateContent(id: itemID, content: content)
    }

    func summarize(itemID: UUID) async {
        await startAI(itemID: itemID, operation: .summarize)
    }

    func categorize(itemID: UUID) async {
        await startAI(itemID: itemID, operation: .categorize)
    }

    func rewrite(itemID: UUID) async {
        await startAI(itemID: itemID, operation: .rewrite)
    }
}

private extension ClipDetailActionAdapter {
    func startAI(itemID: UUID, operation: AIOperation) async {
        guard let item = await itemForAction(itemID) else { return }
        await aiActions.start(
            item: item,
            operation: operation,
            allowedCategories: allowedCategories()
        )
    }

    func itemForAction(_ id: UUID) async -> ClipboardItem? {
        if let item = store.itemCache[id] {
            return item
        }
        await store.loadItem(id: id)
        return store.itemCache[id]
    }
}
