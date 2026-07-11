import Foundation
@testable import ClipFlow

actor InMemoryRepository: ClipboardRepositoryProtocol {
    enum InjectedFailure: Error { case requested }

    var items: [UUID: ClipboardItem] = [:]
    var categories: [UUID: PersistedCustomCategory] = [:]
    var usage: [AIUsageRecord] = []
    var failNextMutation = false

    private let searchMode: SearchMode
    private var activeAIGenerations: [AIJobKey: UUID] = [:]

    init(searchMode: SearchMode = .parameterizedContains) {
        self.searchMode = searchMode
    }

    private func consumeFailure() throws {
        if failNextMutation {
            failNextMutation = false
            throw InjectedFailure.requested
        }
    }

    func setFailNextMutation(_ value: Bool) {
        failNextMutation = value
    }

    @discardableResult
    func seed(_ item: ClipboardItem) -> ClipboardItem {
        items[item.id] = item
        return item
    }

    func seedCategory(name: String) -> PersistedCustomCategory {
        let now = Date(timeIntervalSince1970: 0)
        let category = PersistedCustomCategory(
            id: UUID(),
            name: name,
            prompt: "",
            sortOrder: 0,
            isEnabled: true,
            createdAt: now,
            updatedAt: now
        )
        categories[category.id] = category
        return category
    }

    func fetchPage(_ query: ClipQuery) async throws -> ClipPage {
        let search = RepositorySearchPlan.make(searchText: query.searchText, mode: searchMode)
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
        let filtered = items.values.filter { item in
            guard item.deletedAt == nil else { return false }
            if !search.matches(item.content) {
                return false
            }
            switch query.scope {
            case .all:
                return true
            case .favorites:
                return item.isFavorite
            case .today:
                return item.lastCopiedAt >= start && item.lastCopiedAt < end
            case .builtIn(let category):
                return item.category == category
            case .custom(let id):
                return item.customCategoryID == id
            }
        }.sorted(by: Self.itemOrder)
        let totalCount = filtered.count
        let limit = min(max(query.limit, 0), 100)
        let offset = min(max(query.offset, 0), totalCount)
        guard limit > 0 else {
            return ClipPage(items: [], nextOffset: nil, totalCount: totalCount)
        }
        let endIndex = min(offset + limit, totalCount)
        let pageItems = Array(filtered[offset..<endIndex])
        return ClipPage(
            items: pageItems,
            nextOffset: endIndex < totalCount ? endIndex : nil,
            totalCount: totalCount
        )
    }

    func item(id: UUID) async throws -> ClipboardItem? {
        guard let item = items[id], item.deletedAt == nil else { return nil }
        return item
    }

    func upsertCapturedText(_ capture: CapturedText) async throws -> ClipboardItem {
        try consumeFailure()
        if var match = items.values.first(where: {
            $0.deletedAt == nil && $0.content == capture.content
        }) {
            match.lastCopiedAt = capture.capturedAt
            match.copyCount += 1
            items[match.id] = match
            return match
        }
        let item = ClipboardItem(
            content: capture.content,
            category: capture.category,
            timestamp: capture.capturedAt
        )
        items[item.id] = item
        return item
    }

    func markCopied(id: UUID, at: Date) async throws -> ClipboardItem {
        try consumeFailure()
        var item = try activeItem(id)
        item.lastCopiedAt = at
        item.copyCount += 1
        items[id] = item
        return item
    }

    func setFavorite(id: UUID, isFavorite: Bool) async throws -> ClipboardItem {
        try consumeFailure()
        var item = try activeItem(id)
        item.isFavorite = isFavorite
        items[id] = item
        return item
    }

    func setSummary(id: UUID, summary: String?) async throws -> ClipboardItem {
        try consumeFailure()
        return try setSummarySynchronously(id: id, summary: summary)
    }

    func setCustomCategory(id: UUID, categoryID: UUID?) async throws -> ClipboardItem {
        try consumeFailure()
        return try setCustomCategorySynchronously(id: id, categoryID: categoryID)
    }

    func activateAIJob(_ key: AIJobKey, generation: UUID) async {
        activeAIGenerations[key] = generation
    }

    func cancelAIJob(_ key: AIJobKey, generation: UUID) async {
        guard activeAIGenerations[key] == generation else { return }
        activeAIGenerations.removeValue(forKey: key)
    }

    func setSummaryIfCurrent(
        id: UUID,
        summary: String?,
        key: AIJobKey,
        generation: UUID
    ) async throws -> ClipboardItem? {
        guard key.itemID == id,
              key.operation == .summarize,
              activeAIGenerations[key] == generation else { return nil }
        try consumeFailure()
        return try setSummarySynchronously(id: id, summary: summary)
    }

    func setCustomCategoryIfCurrent(
        id: UUID,
        categoryID: UUID?,
        key: AIJobKey,
        generation: UUID
    ) async throws -> ClipboardItem? {
        guard key.itemID == id,
              key.operation == .categorize,
              activeAIGenerations[key] == generation else { return nil }
        try consumeFailure()
        return try setCustomCategorySynchronously(id: id, categoryID: categoryID)
    }

    func softDelete(id: UUID, at: Date) async throws {
        try consumeFailure()
        var item = try activeItem(id)
        item.deletedAt = at
        items[id] = item
    }

    func deletedTombstones(since: Date) async throws -> [DeletedClipTombstone] {
        items.values.compactMap { item in
            guard let deletedAt = item.deletedAt, deletedAt >= since else { return nil }
            return DeletedClipTombstone(itemID: item.id, deletedAt: deletedAt)
        }.sorted {
            if $0.deletedAt != $1.deletedAt { return $0.deletedAt < $1.deletedAt }
            return $0.itemID.uuidString < $1.itemID.uuidString
        }
    }

    func restore(id: UUID) async throws {
        try consumeFailure()
        guard var item = items[id], item.deletedAt != nil else {
            throw DatabaseError.itemNotFound(id)
        }
        item.deletedAt = nil
        items[id] = item
    }

    func purgeDeleted(id: UUID) async throws {
        try consumeFailure()
        guard let item = items[id] else { throw DatabaseError.itemNotFound(id) }
        guard item.deletedAt != nil else { return }
        items.removeValue(forKey: id)
    }

    func purgeDeleted(before: Date) async throws -> Int {
        try consumeFailure()
        let ids = items.values.compactMap { item -> UUID? in
            guard let deletedAt = item.deletedAt, deletedAt < before else { return nil }
            return item.id
        }
        ids.forEach { items.removeValue(forKey: $0) }
        return ids.count
    }

    func countForCleanup(retention: RetentionPolicy, now: Date) async throws -> Int {
        guard let cutoff = try Self.cleanupCutoff(retention: retention, now: now) else { return 0 }
        return items.values.filter {
            $0.deletedAt == nil && !$0.isFavorite && $0.lastCopiedAt < cutoff
        }.count
    }

    func cleanup(retention: RetentionPolicy, now: Date) async throws -> Int {
        try consumeFailure()
        guard let cutoff = try Self.cleanupCutoff(retention: retention, now: now) else { return 0 }
        let ids = items.values.compactMap { item -> UUID? in
            guard item.deletedAt == nil,
                  !item.isFavorite,
                  item.lastCopiedAt < cutoff else { return nil }
            return item.id
        }
        ids.forEach { items.removeValue(forKey: $0) }
        return ids.count
    }

    func countAllClips() async throws -> Int {
        items.count
    }

    func deleteAllClipboardData() async throws -> Int {
        try consumeFailure()
        let count = items.count
        items.removeAll()
        usage.removeAll()
        return count
    }

    func fetchCategories() async throws -> [PersistedCustomCategory] {
        categories.values.sorted(by: Self.categoryOrder)
    }

    func saveCategory(_ category: PersistedCustomCategory) async throws {
        try consumeFailure()
        guard let name = Self.nonemptyTrimmed(category.name) else {
            throw DatabaseError.stepFailed("custom category name must not be empty")
        }
        let normalized = Self.normalizeCategoryName(name)
        guard !categories.values.contains(where: {
            $0.id != category.id && Self.normalizeCategoryName($0.name) == normalized
        }) else {
            throw DatabaseError.stepFailed("custom category name is already in use")
        }
        var stored = category
        stored.name = name
        categories[category.id] = stored
        for itemID in Array(items.keys) where items[itemID]?.customCategoryID == category.id {
            items[itemID]?.customCategory = name
        }
    }

    func reorderCategories(ids: [UUID]) async throws {
        try consumeFailure()
        if let missingID = ids.first(where: { categories[$0] == nil }) {
            throw DatabaseError.itemNotFound(missingID)
        }
        guard ids.count == categories.count,
              Set(ids).count == ids.count,
              Set(ids) == Set(categories.keys) else {
            throw DatabaseError.stepFailed(
                "category reorder must contain every category exactly once"
            )
        }
        for (sortOrder, id) in ids.enumerated() {
            categories[id]?.sortOrder = sortOrder
        }
    }

    func deleteCategory(id: UUID, migrateTo replacementID: UUID?) async throws {
        try consumeFailure()
        guard categories[id] != nil else { throw DatabaseError.itemNotFound(id) }
        if let replacementID {
            guard replacementID != id, categories[replacementID] != nil else {
                throw DatabaseError.itemNotFound(replacementID)
            }
        }
        for itemID in items.keys {
            guard items[itemID]?.customCategoryID == id else { continue }
            items[itemID]?.customCategoryID = replacementID
            items[itemID]?.customCategory = replacementID.flatMap { categories[$0]?.name }
        }
        categories.removeValue(forKey: id)
    }

    func addAIUsage(_ record: AIUsageRecord) async throws {
        try consumeFailure()
        usage.removeAll { $0.id == record.id }
        usage.append(record)
        usage.sort(by: Self.usageOrder)
        if usage.count > 200 {
            usage = Array(usage.prefix(200))
        }
    }

    func fetchAIUsage(limit: Int) async throws -> [AIUsageRecord] {
        Array(usage.sorted(by: Self.usageOrder).prefix(min(max(limit, 0), 200)))
    }

    func clearAIUsage() async throws {
        try consumeFailure()
        usage.removeAll()
    }
}

private extension InMemoryRepository {
    func activeItem(_ id: UUID) throws -> ClipboardItem {
        guard let item = items[id], item.deletedAt == nil else {
            throw DatabaseError.itemNotFound(id)
        }
        return item
    }

    func setSummarySynchronously(id: UUID, summary: String?) throws -> ClipboardItem {
        var item = try activeItem(id)
        item.aiSummary = summary
        items[id] = item
        return item
    }

    func setCustomCategorySynchronously(
        id: UUID,
        categoryID: UUID?
    ) throws -> ClipboardItem {
        var item = try activeItem(id)
        if let categoryID, categories[categoryID] == nil {
            throw DatabaseError.itemNotFound(categoryID)
        }
        item.customCategoryID = categoryID
        item.customCategory = categoryID.flatMap { categories[$0]?.name }
        items[id] = item
        return item
    }

    static func itemOrder(_ lhs: ClipboardItem, _ rhs: ClipboardItem) -> Bool {
        if lhs.lastCopiedAt != rhs.lastCopiedAt {
            return lhs.lastCopiedAt > rhs.lastCopiedAt
        }
        return lhs.id.uuidString > rhs.id.uuidString
    }

    static func usageOrder(_ lhs: AIUsageRecord, _ rhs: AIUsageRecord) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
        return lhs.id.uuidString > rhs.id.uuidString
    }

    static func categoryOrder(
        _ lhs: PersistedCustomCategory,
        _ rhs: PersistedCustomCategory
    ) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    static func cleanupCutoff(retention: RetentionPolicy, now: Date) throws -> Date? {
        switch retention {
        case .forever:
            return nil
        case .days(let days):
            guard (1...365).contains(days) else {
                throw ValidationError.invalidRetentionDays(days)
            }
            return now.addingTimeInterval(-Double(days) * 86_400)
        }
    }

    static func nonemptyTrimmed(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizeCategoryName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }
}
