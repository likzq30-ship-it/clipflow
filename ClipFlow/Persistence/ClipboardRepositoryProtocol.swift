import Foundation

protocol ClipboardRepositoryProtocol: Sendable {
    func fetchPage(_ query: ClipQuery) async throws -> ClipPage
    func item(id: UUID) async throws -> ClipboardItem?
    func upsertCapturedText(_ capture: CapturedText) async throws -> ClipboardItem
    func markCopied(id: UUID, at: Date) async throws -> ClipboardItem
    func setContent(id: UUID, content: String) async throws -> ClipboardItem
    func setFavorite(id: UUID, isFavorite: Bool) async throws -> ClipboardItem
    func setSummary(id: UUID, summary: String?) async throws -> ClipboardItem
    func setCustomCategory(id: UUID, categoryID: UUID?) async throws -> ClipboardItem
    func activateAIJob(_ key: AIJobKey, generation: UUID) async
    func cancelAIJob(_ key: AIJobKey, generation: UUID) async
    func setSummaryIfCurrent(
        id: UUID,
        summary: String?,
        key: AIJobKey,
        generation: UUID
    ) async throws -> ClipboardItem?
    func setCustomCategoryIfCurrent(
        id: UUID,
        categoryID: UUID?,
        key: AIJobKey,
        generation: UUID
    ) async throws -> ClipboardItem?
    func softDelete(id: UUID, at: Date) async throws
    func deletedTombstones(since: Date) async throws -> [DeletedClipTombstone]
    func restore(id: UUID) async throws
    func purgeDeleted(id: UUID) async throws
    func purgeDeleted(before: Date) async throws -> Int
    func countForCleanup(retention: RetentionPolicy, now: Date) async throws -> Int
    func cleanup(retention: RetentionPolicy, now: Date) async throws -> Int
    func countAllClips() async throws -> Int
    func deleteAllClipboardData() async throws -> Int
    func fetchCategories() async throws -> [PersistedCustomCategory]
    func saveCategory(_ category: PersistedCustomCategory) async throws
    func reorderCategories(ids: [UUID]) async throws
    func deleteCategory(id: UUID, migrateTo replacementID: UUID?) async throws
    func addAIUsage(_ record: AIUsageRecord) async throws
    func fetchAIUsage(limit: Int) async throws -> [AIUsageRecord]
    func clearAIUsage() async throws
}
