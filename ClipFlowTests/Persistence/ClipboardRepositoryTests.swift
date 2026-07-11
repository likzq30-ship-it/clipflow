import CryptoKit
import Foundation
import XCTest
@testable import ClipFlow

private enum RepositoryPermissionHookError: Error, Equatable {
    case injected
}

final class ClipboardRepositoryTests: XCTestCase {
    func testPrepareStoresReadWriteStartupState() async throws {
        let repository = try await makeRepository()

        let startup = await repository.startupState()

        guard case .readWrite(let preparation) = startup else {
            return XCTFail("expected read-write startup")
        }
        XCTAssertEqual(preparation.schemaVersion, DatabaseMigrator.schemaVersion)
        XCTAssertFalse(startup?.isReadOnly ?? true)
    }

    func testDuplicateCaptureRefreshesExistingRowAndPreservesMetadata() async throws {
        let repository = try await makeRepository()
        let first = try await repository.upsertCapturedText(
            CapturedText(
                content: "same",
                category: .english,
                capturedAt: Date(timeIntervalSince1970: 10),
                sourceBundleID: "com.example.one"
            )
        )
        _ = try await repository.setFavorite(id: first.id, isFavorite: true)
        _ = try await repository.setSummary(id: first.id, summary: "summary")

        let second = try await repository.upsertCapturedText(
            CapturedText(
                content: "same",
                category: .code,
                capturedAt: Date(timeIntervalSince1970: 20),
                sourceBundleID: "com.example.two"
            )
        )

        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.lastCopiedAt, Date(timeIntervalSince1970: 20))
        XCTAssertEqual(second.copyCount, 2)
        XCTAssertTrue(second.isFavorite)
        XCTAssertEqual(second.aiSummary, "summary")
        XCTAssertEqual(second.category, .english)
        XCTAssertEqual(second.createdAt, Date(timeIntervalSince1970: 10))
    }

    func testDuplicateCaptureComparesCompleteStringAfterHashMatch() async throws {
        let fixture = try DatabaseFixture()
        let collidingContent = "different\0content👍🏽"
        let hash = SHA256.hash(data: Data(collidingContent.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        _ = try DatabaseMigrator.prepare(
            database: fixture.database,
            databaseURL: fixture.url,
            legacyCategories: []
        )
        let plantedID = UUID()
        try fixture.execute("""
            INSERT INTO clipboard_items (
                id, content, content_hash, builtin_category, custom_category_id,
                created_at, last_copied_at, copy_count, is_favorite, ai_summary, deleted_at
            ) VALUES (
                '\(plantedID.uuidString)', 'planted', '\(hash)', 'english', NULL,
                0, 0, 1, 0, NULL, NULL
            )
            """)
        fixture.close()
        let repository = try await makeRepositoryAtURL(fixture.url)

        let inserted = try await repository.upsertCapturedText(.fixture(collidingContent, at: 2))
        let count = try await repository.countAllClips()
        let plantedAfter = try await repository.item(id: plantedID)
        let insertedAfter = try await repository.item(id: inserted.id)

        XCTAssertNotEqual(inserted.id, plantedID)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(plantedAfter?.copyCount, 1)
        XCTAssertEqual(insertedAfter?.content, collidingContent)
    }

    func testSoftDeletedDuplicateCreatesNewActiveRow() async throws {
        let repository = try await makeRepository()
        let deleted = try await repository.upsertCapturedText(.fixture("repeat", at: 1))
        try await repository.softDelete(id: deleted.id, at: Date(timeIntervalSince1970: 2))

        let active = try await repository.upsertCapturedText(.fixture("repeat", at: 3))
        let count = try await repository.countAllClips()

        XCTAssertNotEqual(active.id, deleted.id)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(active.copyCount, 1)
    }

    func testMarkCopiedUpdatesTimestampAndCount() async throws {
        let repository = try await makeRepository()
        let item = try await repository.upsertCapturedText(.fixture("copy", at: 1))

        let copied = try await repository.markCopied(
            id: item.id,
            at: Date(timeIntervalSince1970: 25)
        )

        XCTAssertEqual(copied.lastCopiedAt, Date(timeIntervalSince1970: 25))
        XCTAssertEqual(copied.copyCount, 2)
        XCTAssertEqual(copied.createdAt, Date(timeIntervalSince1970: 1))
    }

    func testEverySingleWriteReappliesPrivateDatabasePermissions() async throws {
        let location = try TemporaryDatabaseLocation()
        let repository = try await makeRepositoryAtURL(location.url)
        let category = makeCategory(name: "Permissions", sortOrder: 0)
        try await repository.saveCategory(category)
        let item = try await repository.upsertCapturedText(.fixture("permissions"))

        try await assertReappliesPrivatePermissions(at: location.url) {
            _ = try await repository.markCopied(id: item.id, at: Date(timeIntervalSince1970: 2))
        }
        try await assertReappliesPrivatePermissions(at: location.url) {
            _ = try await repository.setFavorite(id: item.id, isFavorite: true)
        }
        try await assertReappliesPrivatePermissions(at: location.url) {
            _ = try await repository.setSummary(id: item.id, summary: "summary")
        }
        try await assertReappliesPrivatePermissions(at: location.url) {
            _ = try await repository.setCustomCategory(id: item.id, categoryID: category.id)
        }
        try await assertReappliesPrivatePermissions(at: location.url) {
            try await repository.softDelete(id: item.id, at: Date(timeIntervalSince1970: 3))
        }
        try await assertReappliesPrivatePermissions(at: location.url) {
            try await repository.restore(id: item.id)
        }

        let purgeByID = try await repository.upsertCapturedText(.fixture("purge ID"))
        try await repository.softDelete(id: purgeByID.id, at: Date(timeIntervalSince1970: 4))
        try await assertReappliesPrivatePermissions(at: location.url) {
            try await repository.purgeDeleted(id: purgeByID.id)
        }

        let purgeByDate = try await repository.upsertCapturedText(.fixture("purge date"))
        try await repository.softDelete(id: purgeByDate.id, at: Date(timeIntervalSince1970: 5))
        try await assertReappliesPrivatePermissions(at: location.url) {
            _ = try await repository.purgeDeleted(before: Date(timeIntervalSince1970: 6))
        }

        var renamed = category
        renamed.name = "Permissions Renamed"
        try await assertReappliesPrivatePermissions(at: location.url) {
            try await repository.saveCategory(renamed)
        }
        try await repository.addAIUsage(makeUsage(index: 1))
        try await assertReappliesPrivatePermissions(at: location.url) {
            try await repository.clearAIUsage()
        }
    }

    func testPreCommitPermissionFailureRollsBackMutation() async throws {
        let location = try TemporaryDatabaseLocation()
        let repository = try await makeRepositoryAtURL(location.url)
        let item = try await repository.upsertCapturedText(.fixture("permission rollback"))
        await repository.setPreCommitPermissionHookForTesting {
            throw RepositoryPermissionHookError.injected
        }

        do {
            _ = try await repository.setFavorite(id: item.id, isFavorite: true)
            XCTFail("expected injected pre-commit permission failure")
        } catch let error as RepositoryPermissionHookError {
            XCTAssertEqual(error, .injected)
        }

        let freshRepository = try await makeRepositoryAtURL(location.url)
        let durableItem = try await freshRepository.item(id: item.id)
        XCTAssertEqual(durableItem?.isFavorite, false)
    }

    func testFavoriteSummaryAndCustomCategoryMutationsRoundTrip() async throws {
        let repository = try await makeRepository()
        let category = makeCategory(name: "Work", sortOrder: 0)
        try await repository.saveCategory(category)
        let item = try await repository.upsertCapturedText(.fixture("metadata"))

        let favorite = try await repository.setFavorite(id: item.id, isFavorite: true)
        let summarized = try await repository.setSummary(id: item.id, summary: "short")
        let categorized = try await repository.setCustomCategory(
            id: item.id,
            categoryID: category.id
        )
        let clearedSummary = try await repository.setSummary(id: item.id, summary: nil)
        let clearedCategory = try await repository.setCustomCategory(id: item.id, categoryID: nil)

        XCTAssertTrue(favorite.isFavorite)
        XCTAssertEqual(summarized.aiSummary, "short")
        XCTAssertEqual(categorized.customCategoryID, category.id)
        XCTAssertEqual(categorized.customCategory, "Work")
        XCTAssertNil(clearedSummary.aiSummary)
        XCTAssertNil(clearedCategory.customCategoryID)
        XCTAssertNil(clearedCategory.customCategory)
    }

    func testEveryMissingIDClipboardMutationThrowsItemNotFound() async throws {
        let repository = try await makeRepository()
        let missingID = UUID()
        let summaryKey = AIJobKey(itemID: missingID, operation: .summarize)
        let categoryKey = AIJobKey(itemID: missingID, operation: .categorize)
        let summaryGeneration = UUID()
        let categoryGeneration = UUID()
        await repository.activateAIJob(summaryKey, generation: summaryGeneration)
        await repository.activateAIJob(categoryKey, generation: categoryGeneration)

        await assertItemNotFound(missingID) {
            _ = try await repository.markCopied(id: missingID, at: Date())
        }
        await assertItemNotFound(missingID) {
            _ = try await repository.setFavorite(id: missingID, isFavorite: true)
        }
        await assertItemNotFound(missingID) {
            _ = try await repository.setSummary(id: missingID, summary: "summary")
        }
        await assertItemNotFound(missingID) {
            _ = try await repository.setCustomCategory(id: missingID, categoryID: nil)
        }
        await assertItemNotFound(missingID) {
            _ = try await repository.setSummaryIfCurrent(
                id: missingID,
                summary: "summary",
                key: summaryKey,
                generation: summaryGeneration
            )
        }
        await assertItemNotFound(missingID) {
            _ = try await repository.setCustomCategoryIfCurrent(
                id: missingID,
                categoryID: nil,
                key: categoryKey,
                generation: categoryGeneration
            )
        }
        await assertItemNotFound(missingID) {
            try await repository.softDelete(id: missingID, at: Date())
        }
        await assertItemNotFound(missingID) {
            try await repository.restore(id: missingID)
        }
        await assertItemNotFound(missingID) {
            try await repository.purgeDeleted(id: missingID)
        }
    }

    func testFetchPageSupportsAllFavoriteBuiltInAndCustomScopes() async throws {
        let repository = try await makeRepository()
        let category = makeCategory(name: "Projects", sortOrder: 0)
        try await repository.saveCategory(category)
        let english = try await repository.upsertCapturedText(
            .fixture("english", at: 1, category: .english)
        )
        let code = try await repository.upsertCapturedText(
            .fixture("code", at: 2, category: .code)
        )
        _ = try await repository.setFavorite(id: english.id, isFavorite: true)
        _ = try await repository.setCustomCategory(id: code.id, categoryID: category.id)

        let all = try await repository.fetchPage(query(scope: .all))
        let favorites = try await repository.fetchPage(query(scope: .favorites))
        let builtIn = try await repository.fetchPage(query(scope: .builtIn(.code)))
        let custom = try await repository.fetchPage(query(scope: .custom(category.id)))

        XCTAssertEqual(Set(all.items.map(\.id)), Set([english.id, code.id]))
        XCTAssertEqual(favorites.items.map(\.id), [english.id])
        XCTAssertEqual(builtIn.items.map(\.id), [code.id])
        XCTAssertEqual(custom.items.map(\.id), [code.id])
    }

    func testTodayScopeUsesLastCopiedAtInLocalCalendar() async throws {
        let repository = try await makeRepository()
        let calendar = Calendar.current
        let now = Date()
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: now))
        let old = try await repository.upsertCapturedText(
            CapturedText(content: "old", category: .english, capturedAt: yesterday, sourceBundleID: nil)
        )
        let today = try await repository.upsertCapturedText(
            CapturedText(content: "today", category: .english, capturedAt: now, sourceBundleID: nil)
        )

        let page = try await repository.fetchPage(query(scope: .today))

        XCTAssertEqual(page.items.map(\.id), [today.id])
        XCTAssertFalse(page.items.map(\.id).contains(old.id))
    }

    func testStablePaginationUsesIDTieBreakerForEqualTimestamps() async throws {
        let repository = try await makeRepository()
        let first = try await repository.upsertCapturedText(.fixture("one", at: 10))
        let second = try await repository.upsertCapturedText(.fixture("two", at: 10))
        let third = try await repository.upsertCapturedText(.fixture("three", at: 10))
        let expected = [first.id, second.id, third.id]
            .sorted { $0.uuidString > $1.uuidString }

        let pageOne = try await repository.fetchPage(
            .init(searchText: "", scope: .all, limit: 2, offset: 0)
        )
        let pageTwo = try await repository.fetchPage(
            .init(searchText: "", scope: .all, limit: 2, offset: 2)
        )

        XCTAssertEqual(pageOne.items.map(\.id), Array(expected.prefix(2)))
        XCTAssertEqual(pageTwo.items.map(\.id), Array(expected.dropFirst(2)))
        XCTAssertEqual(pageOne.totalCount, 3)
        XCTAssertEqual(pageOne.nextOffset, 2)
        XCTAssertNil(pageTwo.nextOffset)
        XCTAssertEqual(Set(pageOne.items.map(\.id) + pageTwo.items.map(\.id)).count, 3)
    }

    func testPaginationClampsLimitAndOffsetSafely() async throws {
        let repository = try await makeRepository()
        for index in 0..<105 {
            _ = try await repository.upsertCapturedText(.fixture("item-\(index)", at: Double(index)))
        }

        let clamped = try await repository.fetchPage(
            .init(searchText: "", scope: .all, limit: 500, offset: -20)
        )
        let empty = try await repository.fetchPage(
            .init(searchText: "", scope: .all, limit: -1, offset: 0)
        )

        XCTAssertEqual(clamped.items.count, 100)
        XCTAssertEqual(clamped.totalCount, 105)
        XCTAssertEqual(clamped.nextOffset, 100)
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertEqual(empty.totalCount, 105)
        XCTAssertNil(empty.nextOffset)
    }

    func testSearchIsBoundAndParameterised() async throws {
        let repository = try await makeRepository()
        _ = try await repository.upsertCapturedText(.fixture("100%_literal\\path 'quoted'"))
        _ = try await repository.upsertCapturedText(.fixture("ordinary"))

        let percentUnderscore = try await repository.fetchPage(
            .init(searchText: "%_", scope: .all, limit: 100, offset: 0)
        )
        let backslash = try await repository.fetchPage(
            .init(searchText: "\\path", scope: .all, limit: 100, offset: 0)
        )
        let quote = try await repository.fetchPage(
            .init(searchText: "'quoted'", scope: .all, limit: 100, offset: 0)
        )
        let injection = try await repository.fetchPage(
            .init(searchText: "' OR 1=1 --", scope: .all, limit: 100, offset: 0)
        )

        XCTAssertEqual(percentUnderscore.items.map(\.content), ["100%_literal\\path 'quoted'"])
        XCTAssertEqual(backslash.items.map(\.content), ["100%_literal\\path 'quoted'"])
        XCTAssertEqual(quote.items.map(\.content), ["100%_literal\\path 'quoted'"])
        XCTAssertTrue(injection.items.isEmpty)
        XCTAssertEqual(injection.totalCount, 0)
    }

    func testSearchMatchesWhitespaceDelimitedLiteralTokens() async throws {
        let repository = try await makeRepository()
        _ = try await repository.upsertCapturedText(.fixture("alpha beta gamma"))
        _ = try await repository.upsertCapturedText(.fixture("alpha only"))

        let page = try await repository.fetchPage(
            .init(searchText: "alpha beta", scope: .all, limit: 100, offset: 0)
        )

        XCTAssertEqual(page.items.map(\.content), ["alpha beta gamma"])
        XCTAssertEqual(page.totalCount, 1)
    }

    func testMixedPunctuationFTSQueryFallsBackAsCompleteLiteral() async throws {
        let repository = try await makeRepository()
        await repository.setSearchModeForTesting(.fts5)
        _ = try await repository.upsertCapturedText(.fixture("alpha %_ exact", at: 2))
        _ = try await repository.upsertCapturedText(.fixture("alpha ordinary", at: 1))

        let page = try await repository.fetchPage(
            .init(searchText: "alpha %_", scope: .all, limit: 100, offset: 0)
        )

        XCTAssertEqual(page.items.map(\.content), ["alpha %_ exact"])
        XCTAssertEqual(page.totalCount, 1)
        XCTAssertNil(page.nextOffset)
    }

    func testInMemoryFTSMatchesWholeTokensNotSubstrings() async throws {
        let repository = InMemoryRepository(searchMode: .fts5)
        let token = await repository.seed(.fixture(content: "alpha token", at: 2))
        _ = await repository.seed(.fixture(content: "alphabet token", at: 1))

        let page = try await repository.fetchPage(
            .init(searchText: "alpha", scope: .all, limit: 1, offset: 0)
        )

        XCTAssertEqual(page.items.map(\.id), [token.id])
        XCTAssertEqual(page.totalCount, 1)
        XCTAssertNil(page.nextOffset)
    }

    func testSharedSearchPlanClassifiesMixedLiteralAndWholeTokens() {
        let mixed = RepositorySearchPlan.make(searchText: "alpha %_", mode: .fts5)
        XCTAssertEqual(
            mixed,
            .parameterizedContains(text: "alpha %_", escapedPattern: "%alpha \\%\\_%")
        )
        XCTAssertTrue(mixed.matches("alpha %_ exact"))
        XCTAssertFalse(mixed.matches("alpha ordinary"))

        let token = RepositorySearchPlan.make(searchText: "alpha", mode: .fts5)
        XCTAssertTrue(token.matches("alpha token"))
        XCTAssertFalse(token.matches("alphabet token"))
    }

    func testFTSPageAndTotalMatchInMemoryRepository() async throws {
        try await assertSearchParity(
            mode: .fts5,
            expectedTotalCount: 2
        )
    }

    func testParameterizedContainsPageAndTotalMatchInMemoryRepository() async throws {
        try await assertSearchParity(
            mode: .parameterizedContains,
            expectedTotalCount: 3
        )
    }

    func testSoftDeleteCanRestoreWithinUndoWindow() async throws {
        let repository = try await makeRepository()
        let item = try await repository.upsertCapturedText(.fixture("undo"))

        try await repository.softDelete(id: item.id, at: Date(timeIntervalSince1970: 30))
        let deleted = try await repository.item(id: item.id)
        XCTAssertNil(deleted)

        let tombstones = try await repository.deletedTombstones(
            since: Date(timeIntervalSince1970: 30)
        )
        XCTAssertEqual(tombstones, [
            DeletedClipTombstone(itemID: item.id, deletedAt: Date(timeIntervalSince1970: 30))
        ])

        try await repository.restore(id: item.id)
        let restored = try await repository.item(id: item.id)
        XCTAssertEqual(restored?.content, "undo")
        XCTAssertNil(restored?.deletedAt)
    }

    func testPurgeDeletedOnlyPurgesTombstonesAndUsesStrictBeforeBoundary() async throws {
        let repository = try await makeRepository()
        let first = try await repository.upsertCapturedText(.fixture("first"))
        let boundary = try await repository.upsertCapturedText(.fixture("boundary"))
        let active = try await repository.upsertCapturedText(.fixture("active"))
        try await repository.softDelete(id: first.id, at: Date(timeIntervalSince1970: 10))
        try await repository.softDelete(id: boundary.id, at: Date(timeIntervalSince1970: 20))

        let count = try await repository.purgeDeleted(before: Date(timeIntervalSince1970: 20))
        try await repository.purgeDeleted(id: active.id)
        let purged = try await repository.item(id: first.id)
        let remainingCount = try await repository.countAllClips()

        XCTAssertEqual(count, 1)
        XCTAssertNil(purged)
        XCTAssertEqual(remainingCount, 2)
        try await repository.restore(id: boundary.id)
        let restoredBoundary = try await repository.item(id: boundary.id)
        let keptActive = try await repository.item(id: active.id)
        XCTAssertNotNil(restoredBoundary)
        XCTAssertNotNil(keptActive)
    }

    func testCleanupUsesLastCopiedAtAndKeepsFavorites() async throws {
        let repository = try await makeRepository()
        let old = try await repository.upsertCapturedText(.fixture("old", at: 0))
        let recentlyCopied = try await repository.upsertCapturedText(.fixture("recent", at: 0))
        _ = try await repository.markCopied(
            id: recentlyCopied.id,
            at: Date(timeIntervalSince1970: 19 * 86_400)
        )
        let favorite = try await repository.upsertCapturedText(.fixture("favorite", at: 0))
        _ = try await repository.setFavorite(id: favorite.id, isFavorite: true)
        let tombstone = try await repository.upsertCapturedText(.fixture("tombstone", at: 0))
        try await repository.softDelete(id: tombstone.id, at: Date(timeIntervalSince1970: 1))

        let count = try await repository.countForCleanup(
            retention: .days(15),
            now: Date(timeIntervalSince1970: 20 * 86_400)
        )
        let removed = try await repository.cleanup(
            retention: .days(15),
            now: Date(timeIntervalSince1970: 20 * 86_400)
        )
        let removedItem = try await repository.item(id: old.id)
        let keptRecent = try await repository.item(id: recentlyCopied.id)
        let keptFavorite = try await repository.item(id: favorite.id)
        let remainingCount = try await repository.countAllClips()

        XCTAssertEqual(count, 1)
        XCTAssertEqual(removed, 1)
        XCTAssertNil(removedItem)
        XCTAssertNotNil(keptRecent)
        XCTAssertNotNil(keptFavorite)
        XCTAssertEqual(remainingCount, 3)
    }

    func testCleanupForeverIsNoOpAndInvalidDaysAreRejected() async throws {
        let repository = try await makeRepository()
        _ = try await repository.upsertCapturedText(.fixture("keep", at: 0))

        let foreverCount = try await repository.countForCleanup(retention: .forever, now: Date())
        let foreverRemoved = try await repository.cleanup(retention: .forever, now: Date())
        XCTAssertEqual(foreverCount, 0)
        XCTAssertEqual(foreverRemoved, 0)

        await assertInvalidRetentionDays(0) {
            _ = try await repository.countForCleanup(retention: .days(0), now: Date())
        }
        await assertInvalidRetentionDays(366) {
            _ = try await repository.cleanup(retention: .days(366), now: Date())
        }
        let remainingCount = try await repository.countAllClips()
        XCTAssertEqual(remainingCount, 1)
    }

    func testSaveCategoryTrimsAndEnforcesNormalizedUniqueness() async throws {
        let repository = try await makeRepository()
        let first = makeCategory(name: "  Café  ", sortOrder: 0)
        try await repository.saveCategory(first)

        let savedCategories = try await repository.fetchCategories()
        let stored = try XCTUnwrap(savedCategories.first)
        XCTAssertEqual(stored.id, first.id)
        XCTAssertEqual(stored.name, "Café")

        let duplicate = makeCategory(name: "CAFE\u{301}", sortOrder: 1)
        do {
            try await repository.saveCategory(duplicate)
            XCTFail("normalized duplicate must fail")
        } catch let error as DatabaseError {
            guard case .stepFailed(let message) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertFalse(message.contains("Café"))
        }

        var updated = first
        updated.name = "  Work  "
        updated.prompt = "prompt"
        try await repository.saveCategory(updated)
        let categories = try await repository.fetchCategories()
        XCTAssertEqual(categories.count, 1)
        XCTAssertEqual(categories.first?.name, "Work")
        XCTAssertEqual(categories.first?.prompt, "prompt")
    }

    func testCategoryReorderRequiresExactUniqueIDSetAndIsStable() async throws {
        let repository = try await makeRepository()
        let first = makeCategory(name: "First", sortOrder: 0)
        let second = makeCategory(name: "Second", sortOrder: 1)
        let third = makeCategory(name: "Third", sortOrder: 2)
        for category in [first, second, third] {
            try await repository.saveCategory(category)
        }

        try await repository.reorderCategories(ids: [third.id, first.id, second.id])
        let reordered = try await repository.fetchCategories().map(\.id)
        XCTAssertEqual(reordered, [third.id, first.id, second.id])

        do {
            try await repository.reorderCategories(ids: [first.id, first.id, third.id])
            XCTFail("duplicate reorder IDs must fail")
        } catch {
            let stillReordered = try await repository.fetchCategories().map(\.id)
            XCTAssertEqual(stillReordered, [third.id, first.id, second.id])
        }
    }

    func testCategoryMutationsReportEveryMissingID() async throws {
        let repository = try await makeRepository()
        let category = makeCategory(name: "Existing", sortOrder: 0)
        try await repository.saveCategory(category)
        let item = try await repository.upsertCapturedText(.fixture("category IDs"))
        let missingID = UUID()

        await assertItemNotFound(missingID) {
            _ = try await repository.setCustomCategory(id: item.id, categoryID: missingID)
        }
        await assertItemNotFound(missingID) {
            try await repository.deleteCategory(id: missingID, migrateTo: nil)
        }
        await assertItemNotFound(missingID) {
            try await repository.deleteCategory(id: category.id, migrateTo: missingID)
        }
        await assertItemNotFound(missingID) {
            try await repository.reorderCategories(ids: [missingID])
        }
    }

    func testDeleteCategoryCanClearOrMigrateReferencesIncludingTombstones() async throws {
        let repository = try await makeRepository()
        let source = makeCategory(name: "Source", sortOrder: 0)
        let replacement = makeCategory(name: "Replacement", sortOrder: 1)
        let clearSource = makeCategory(name: "Clear", sortOrder: 2)
        for category in [source, replacement, clearSource] {
            try await repository.saveCategory(category)
        }
        let active = try await repository.upsertCapturedText(.fixture("active"))
        let deleted = try await repository.upsertCapturedText(.fixture("deleted"))
        let cleared = try await repository.upsertCapturedText(.fixture("cleared"))
        _ = try await repository.setCustomCategory(id: active.id, categoryID: source.id)
        _ = try await repository.setCustomCategory(id: deleted.id, categoryID: source.id)
        _ = try await repository.setCustomCategory(id: cleared.id, categoryID: clearSource.id)
        try await repository.softDelete(id: deleted.id, at: Date(timeIntervalSince1970: 5))

        try await repository.deleteCategory(id: source.id, migrateTo: replacement.id)
        try await repository.deleteCategory(id: clearSource.id, migrateTo: nil)
        try await repository.restore(id: deleted.id)
        let migratedActive = try await repository.item(id: active.id)
        let migratedDeleted = try await repository.item(id: deleted.id)
        let clearedItem = try await repository.item(id: cleared.id)
        let categoryIDs = try await repository.fetchCategories().map(\.id)

        XCTAssertEqual(migratedActive?.customCategoryID, replacement.id)
        XCTAssertEqual(migratedDeleted?.customCategoryID, replacement.id)
        XCTAssertNil(clearedItem?.customCategoryID)
        XCTAssertEqual(categoryIDs, [replacement.id])
    }

    func testDeleteCategoryRollsBackReferenceMigrationWhenDeleteFails() async throws {
        let repository = try await makeRepository()
        let source = makeCategory(name: "Source", sortOrder: 0)
        let replacement = makeCategory(name: "Replacement", sortOrder: 1)
        try await repository.saveCategory(source)
        try await repository.saveCategory(replacement)
        let item = try await repository.upsertCapturedText(.fixture("atomic category"))
        _ = try await repository.setCustomCategory(id: item.id, categoryID: source.id)
        try await repository.failNextStatementForTesting(containing: "DELETE FROM custom_categories")

        do {
            try await repository.deleteCategory(id: source.id, migrateTo: replacement.id)
            XCTFail("injected delete must fail")
        } catch {
            let rolledBackItem = try await repository.item(id: item.id)
            let rolledBackCategories = try await repository.fetchCategories().map(\.id)
            XCTAssertEqual(rolledBackItem?.customCategoryID, source.id)
            XCTAssertEqual(Set(rolledBackCategories), Set([source.id, replacement.id]))
        }
    }

    func testAIUsageIsNewestFirstCappedAt200AndCanBeCleared() async throws {
        let repository = try await makeRepository()
        var records: [AIUsageRecord] = []
        for index in 0..<205 {
            let record = makeUsage(index: index)
            records.append(record)
            try await repository.addAIUsage(record)
        }

        let fetched = try await repository.fetchAIUsage(limit: 500)

        XCTAssertEqual(fetched.count, 200)
        XCTAssertEqual(fetched.first?.id, records.last?.id)
        XCTAssertEqual(fetched.last?.id, records[5].id)
        let negativeLimit = try await repository.fetchAIUsage(limit: -1)
        XCTAssertEqual(negativeLimit, [])

        try await repository.clearAIUsage()
        let cleared = try await repository.fetchAIUsage(limit: 200)
        XCTAssertTrue(cleared.isEmpty)
    }

    func testDeleteAllClipboardDataIsAtomicPreservesCategoriesAndClearsUsage() async throws {
        let repository = try await makeRepository()
        let category = makeCategory(name: "Keep", sortOrder: 0)
        try await repository.saveCategory(category)
        let favorite = try await repository.upsertCapturedText(.fixture("favorite"))
        _ = try await repository.setFavorite(id: favorite.id, isFavorite: true)
        let deleted = try await repository.upsertCapturedText(.fixture("deleted"))
        try await repository.softDelete(id: deleted.id, at: Date())
        try await repository.addAIUsage(makeUsage(index: 1))

        let count = try await repository.deleteAllClipboardData()
        let clipCount = try await repository.countAllClips()
        let usage = try await repository.fetchAIUsage(limit: 200)
        let categoryIDs = try await repository.fetchCategories().map(\.id)

        XCTAssertEqual(count, 2)
        XCTAssertEqual(clipCount, 0)
        XCTAssertTrue(usage.isEmpty)
        XCTAssertEqual(categoryIDs, [category.id])
    }

    func testDeleteAllClipboardDataRollsBackWhenUsageDeleteFails() async throws {
        let repository = try await makeRepository()
        let item = try await repository.upsertCapturedText(.fixture("atomic delete-all"))
        let usage = makeUsage(index: 1)
        try await repository.addAIUsage(usage)
        try await repository.failNextStatementForTesting(containing: "DELETE FROM ai_usage")

        do {
            _ = try await repository.deleteAllClipboardData()
            XCTFail("injected usage delete must fail")
        } catch {
            let rolledBackItem = try await repository.item(id: item.id)
            let rolledBackUsage = try await repository.fetchAIUsage(limit: 200).map(\.id)
            XCTAssertNotNil(rolledBackItem)
            XCTAssertEqual(rolledBackUsage, [usage.id])
        }
    }

    func testCurrentAIGenerationCommitsConditionalMutations() async throws {
        let repository = try await makeRepository()
        let item = try await repository.upsertCapturedText(.fixture("AI"))
        let category = makeCategory(name: "AI Category", sortOrder: 0)
        try await repository.saveCategory(category)
        let summaryKey = AIJobKey(itemID: item.id, operation: .summarize)
        let categoryKey = AIJobKey(itemID: item.id, operation: .categorize)
        let summaryGeneration = UUID()
        let categoryGeneration = UUID()
        await repository.activateAIJob(summaryKey, generation: summaryGeneration)
        await repository.activateAIJob(categoryKey, generation: categoryGeneration)

        let summarized = try await repository.setSummaryIfCurrent(
            id: item.id,
            summary: "current",
            key: summaryKey,
            generation: summaryGeneration
        )
        let categorized = try await repository.setCustomCategoryIfCurrent(
            id: item.id,
            categoryID: category.id,
            key: categoryKey,
            generation: categoryGeneration
        )

        XCTAssertEqual(summarized?.aiSummary, "current")
        XCTAssertEqual(categorized?.customCategoryID, category.id)
    }

    func testConditionalAIWriteRequiresMatchingItemAndOperation() async throws {
        let repository = try await makeRepository()
        let first = try await repository.upsertCapturedText(.fixture("first AI"))
        let second = try await repository.upsertCapturedText(.fixture("second AI"))
        let summaryKey = AIJobKey(itemID: first.id, operation: .summarize)
        let categoryKey = AIJobKey(itemID: first.id, operation: .categorize)
        let summaryGeneration = UUID()
        let categoryGeneration = UUID()
        await repository.activateAIJob(summaryKey, generation: summaryGeneration)
        await repository.activateAIJob(categoryKey, generation: categoryGeneration)

        let wrongItem = try await repository.setSummaryIfCurrent(
            id: second.id,
            summary: "must not write",
            key: summaryKey,
            generation: summaryGeneration
        )
        let wrongSummaryOperation = try await repository.setSummaryIfCurrent(
            id: first.id,
            summary: "must not write",
            key: categoryKey,
            generation: categoryGeneration
        )
        let wrongCategoryOperation = try await repository.setCustomCategoryIfCurrent(
            id: first.id,
            categoryID: nil,
            key: summaryKey,
            generation: summaryGeneration
        )
        let firstAfter = try await repository.item(id: first.id)
        let secondAfter = try await repository.item(id: second.id)

        XCTAssertNil(wrongItem)
        XCTAssertNil(wrongSummaryOperation)
        XCTAssertNil(wrongCategoryOperation)
        XCTAssertNil(firstAfter?.aiSummary)
        XCTAssertNil(secondAfter?.aiSummary)
    }

    func testCancelledGenerationCannotCommitAfterReentrantGate() async throws {
        let repository = try await makeRepository()
        let item = try await repository.upsertCapturedText(.fixture("cancel race"))
        let key = AIJobKey(itemID: item.id, operation: .summarize)
        let generation = UUID()
        let gate = RepositoryMutationGate()
        await repository.activateAIJob(key, generation: generation)
        await repository.setConditionalMutationGateForTesting {
            await gate.suspendUntilReleased()
        }

        let write = Task {
            try await repository.setSummaryIfCurrent(
                id: item.id,
                summary: "must not commit",
                key: key,
                generation: generation
            )
        }
        await gate.waitUntilEntered()
        await repository.cancelAIJob(key, generation: generation)
        await gate.release()

        let staleResult = try await write.value
        let unchanged = try await repository.item(id: item.id)
        XCTAssertNil(staleResult)
        XCTAssertNil(unchanged?.aiSummary)
    }

    func testReplacementGenerationCannotBeOverwrittenAfterReentrantGate() async throws {
        let repository = try await makeRepository()
        let item = try await repository.upsertCapturedText(.fixture("replace race"))
        let category = makeCategory(name: "Replacement", sortOrder: 0)
        try await repository.saveCategory(category)
        let key = AIJobKey(itemID: item.id, operation: .categorize)
        let staleGeneration = UUID()
        let currentGeneration = UUID()
        let gate = RepositoryMutationGate()
        await repository.activateAIJob(key, generation: staleGeneration)
        await repository.setConditionalMutationGateForTesting {
            await gate.suspendUntilReleased()
        }

        let write = Task {
            try await repository.setCustomCategoryIfCurrent(
                id: item.id,
                categoryID: category.id,
                key: key,
                generation: staleGeneration
            )
        }
        await gate.waitUntilEntered()
        await repository.activateAIJob(key, generation: currentGeneration)
        await repository.cancelAIJob(key, generation: staleGeneration)
        await gate.release()

        let staleResult = try await write.value
        let unchanged = try await repository.item(id: item.id)
        XCTAssertNil(staleResult)
        XCTAssertNil(unchanged?.customCategoryID)

        let current = try await repository.setCustomCategoryIfCurrent(
            id: item.id,
            categoryID: category.id,
            key: key,
            generation: currentGeneration
        )
        XCTAssertEqual(current?.customCategoryID, category.id)
    }

    func testMigrationFailureReopensLegacyDatabaseReadOnly() async throws {
        let fixture = try DatabaseFixture()
        try fixture.createLegacySchema()
        let legacyID = UUID()
        let content = "recover\0me"
        try fixture.insertLegacyClip(
            id: legacyID,
            content: content,
            category: "english",
            customCategory: nil,
            timestamp: 10,
            isFavorite: true,
            aiSummary: nil
        )
        fixture.failNextStatement(containing: "ALTER TABLE")
        let repository = ClipboardRepository(
            database: fixture.database,
            databaseURL: fixture.url
        )

        let startup = try await repository.prepare(legacyCategories: [])
        XCTAssertTrue(startup.isReadOnly)
        guard case .readOnlyRecovery(let databaseURL, let backupURL, let errorCode) = startup else {
            return XCTFail("expected read-only recovery")
        }
        XCTAssertEqual(databaseURL, fixture.url)
        XCTAssertNotNil(backupURL)
        XCTAssertEqual(errorCode, "migration_failed")

        let page = try await repository.fetchPage(
            .init(searchText: "", scope: .all, limit: 100, offset: 0)
        )
        XCTAssertEqual(page.items.map(\.id), [legacyID])
        XCTAssertEqual(page.items.first?.content, content)
        XCTAssertEqual(page.items.first?.category, .english)
        XCTAssertEqual(page.items.first?.createdAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(page.items.first?.lastCopiedAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(page.items.first?.copyCount, 1)
        XCTAssertTrue(page.items.first?.isFavorite ?? false)
        XCTAssertNil(page.items.first?.aiSummary)
        let recoveredItem = try await repository.item(id: legacyID)
        let recoveredCategories = try await repository.fetchCategories()
        XCTAssertEqual(recoveredItem?.content, content)
        XCTAssertEqual(recoveredCategories, [])
        await assertEveryPersistentMutationRejectsReadOnly(
            repository: repository,
            itemID: legacyID
        )
    }

    func testUnreadableDatabaseRemainsBlockingAndIsNotReplaced() async throws {
        let location = try TemporaryDatabaseLocation()
        let bytes = Data("not a sqlite database".utf8)
        try bytes.write(to: location.url)
        let repository = ClipboardRepository(databaseURL: location.url)

        do {
            _ = try await repository.prepare(legacyCategories: [])
            XCTFail("corrupt database must block startup")
        } catch let error as DatabaseError {
            guard case .migrationFailed = error else {
                return XCTFail("unexpected \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: location.url), bytes)
        let startup = await repository.startupState()
        XCTAssertNil(startup)
    }

    func testCanonicalRecoveryHandlesDuplicateNormalizedDisplayNamesWithoutTrap() async throws {
        let fixture = try DatabaseFixture()
        _ = try DatabaseMigrator.prepare(
            database: fixture.database,
            databaseURL: fixture.url,
            legacyCategories: []
        )
        let firstID = UUID()
        let secondID = UUID()
        try fixture.execute("""
            INSERT INTO custom_categories (
                id, name, normalized_name, prompt, sort_order, is_enabled, created_at, updated_at
            ) VALUES
                ('\(firstID.uuidString)', 'Café', 'stored-one', '', 0, 1, 0, 0),
                ('\(secondID.uuidString)', 'CAFE', 'stored-two', '', 1, 1, 0, 0)
            """)
        fixture.close()
        try fixture.setMode(0o400, at: fixture.url)
        let repository = ClipboardRepository(databaseURL: fixture.url)

        let startup = try await repository.prepare(legacyCategories: [])
        let categories = try await repository.fetchCategories()

        XCTAssertTrue(startup.isReadOnly)
        XCTAssertEqual(categories.map(\.id), [firstID, secondID])
    }

    func testInMemoryRepositoryInjectsExactlyOneMutationFailure() async throws {
        let repository = InMemoryRepository()
        let item = await repository.seed(.fixture(content: "memory"))
        await repository.setFailNextMutation(true)

        do {
            _ = try await repository.setFavorite(id: item.id, isFavorite: true)
            XCTFail("injected failure must surface")
        } catch is InMemoryRepository.InjectedFailure {
            // Expected.
        }

        let favorite = try await repository.setFavorite(id: item.id, isFavorite: true)
        XCTAssertTrue(favorite.isFavorite)
    }

    func testInMemoryRepositoryReflectsCategoryRenamesLikeSQLite() async throws {
        let repository = InMemoryRepository()
        let category = await repository.seedCategory(name: "Original")
        let item = await repository.seed(.fixture(content: "rename"))
        _ = try await repository.setCustomCategory(id: item.id, categoryID: category.id)
        var renamed = category
        renamed.name = "  Renamed  "

        try await repository.saveCategory(renamed)
        let fetched = try await repository.item(id: item.id)

        XCTAssertEqual(fetched?.customCategoryID, category.id)
        XCTAssertEqual(fetched?.customCategory, "Renamed")
    }

    func testInMemoryRepositoryMatchesConfiguredSearchMode() async throws {
        let fallback = InMemoryRepository()
        _ = await fallback.seed(.fixture(content: "alpha beta gamma"))
        let fallbackPage = try await fallback.fetchPage(
            .init(searchText: "alpha gamma", scope: .all, limit: 100, offset: 0)
        )

        let fts = InMemoryRepository(searchMode: .fts5)
        let matching = await fts.seed(.fixture(content: "alpha beta gamma"))
        _ = await fts.seed(.fixture(content: "alpha only"))

        let ftsPage = try await fts.fetchPage(
            .init(searchText: "alpha gamma", scope: .all, limit: 100, offset: 0)
        )

        XCTAssertTrue(fallbackPage.items.isEmpty)
        XCTAssertEqual(fallbackPage.totalCount, 0)
        XCTAssertEqual(ftsPage.items.map(\.id), [matching.id])
        XCTAssertEqual(ftsPage.totalCount, 1)
    }
}

private extension ClipboardRepositoryTests {
    func query(scope: ClipScope) -> ClipQuery {
        .init(searchText: "", scope: scope, limit: 100, offset: 0)
    }

    func makeRepositoryAtURL(_ url: URL) async throws -> ClipboardRepository {
        let repository = ClipboardRepository(databaseURL: url)
        let startup = try await repository.prepare(legacyCategories: [])
        guard case .readWrite = startup else {
            throw DatabaseError.readOnlyRecovery(databaseURL: url, backupURL: nil)
        }
        return repository
    }

    func assertSearchParity(
        mode: SearchMode,
        expectedTotalCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let repository = try await makeRepository()
        await repository.setSearchModeForTesting(mode)
        let inMemory = InMemoryRepository(searchMode: mode)
        let fixtures: [(content: String, timestamp: TimeInterval)] = [
            ("alpha token", 3),
            ("alphabet token", 2),
            ("prefix alpha suffix", 1)
        ]

        for fixture in fixtures {
            _ = try await repository.upsertCapturedText(
                .fixture(fixture.content, at: fixture.timestamp)
            )
            _ = await inMemory.seed(
                .fixture(content: fixture.content, at: fixture.timestamp)
            )
        }

        let query = ClipQuery(searchText: "alpha", scope: .all, limit: 1, offset: 0)
        let persistentPage = try await repository.fetchPage(query)
        let inMemoryPage = try await inMemory.fetchPage(query)

        XCTAssertEqual(
            persistentPage.items.map(\.content),
            inMemoryPage.items.map(\.content),
            file: file,
            line: line
        )
        XCTAssertEqual(persistentPage.totalCount, expectedTotalCount, file: file, line: line)
        XCTAssertEqual(inMemoryPage.totalCount, expectedTotalCount, file: file, line: line)
        XCTAssertEqual(persistentPage.nextOffset, inMemoryPage.nextOffset, file: file, line: line)
        XCTAssertEqual(persistentPage.nextOffset, 1, file: file, line: line)
    }

    func assertReappliesPrivatePermissions(
        at databaseURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async throws -> Void
    ) async throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o666)],
            ofItemAtPath: databaseURL.path
        )
        try await operation()
        let attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(mode & 0o777, 0o600, file: file, line: line)
    }

    func assertEveryPersistentMutationRejectsReadOnly(
        repository: ClipboardRepository,
        itemID: UUID
    ) async {
        let category = makeCategory(name: "Nope", sortOrder: 0)
        let key = AIJobKey(itemID: itemID, operation: .summarize)
        let generation = UUID()
        await repository.activateAIJob(key, generation: generation)
        let mutations: [(String, () async throws -> Void)] = [
            ("upsert", { _ = try await repository.upsertCapturedText(.fixture("new")) }),
            ("markCopied", { _ = try await repository.markCopied(id: itemID, at: Date()) }),
            ("favorite", { _ = try await repository.setFavorite(id: itemID, isFavorite: true) }),
            ("summary", { _ = try await repository.setSummary(id: itemID, summary: "x") }),
            ("category", {
                _ = try await repository.setCustomCategory(id: itemID, categoryID: nil)
            }),
            ("conditionalSummary", {
                _ = try await repository.setSummaryIfCurrent(
                    id: itemID, summary: "x", key: key, generation: generation
                )
            }),
            ("conditionalCategory", {
                _ = try await repository.setCustomCategoryIfCurrent(
                    id: itemID, categoryID: nil, key: key, generation: generation
                )
            }),
            ("softDelete", { try await repository.softDelete(id: itemID, at: Date()) }),
            ("restore", { try await repository.restore(id: itemID) }),
            ("purgeID", { try await repository.purgeDeleted(id: itemID) }),
            ("purgeBefore", { _ = try await repository.purgeDeleted(before: Date()) }),
            ("cleanup", {
                _ = try await repository.cleanup(retention: .days(15), now: Date())
            }),
            ("deleteAll", { _ = try await repository.deleteAllClipboardData() }),
            ("saveCategory", { try await repository.saveCategory(category) }),
            ("reorder", { try await repository.reorderCategories(ids: []) }),
            ("deleteCategory", {
                try await repository.deleteCategory(id: category.id, migrateTo: nil)
            }),
            ("addUsage", { try await repository.addAIUsage(self.makeUsage(index: 1)) }),
            ("clearUsage", { try await repository.clearAIUsage() })
        ]

        for (name, mutation) in mutations {
            do {
                try await mutation()
                XCTFail("\(name) must reject read-only recovery")
            } catch let error as DatabaseError {
                guard case .readOnlyRecovery = error else {
                    return XCTFail("\(name) produced unexpected \(error)")
                }
            } catch {
                return XCTFail("\(name) produced unexpected \(error)")
            }
        }
    }

    func makeCategory(name: String, sortOrder: Int) -> PersistedCustomCategory {
        let timestamp = Date(timeIntervalSince1970: Double(sortOrder))
        return PersistedCustomCategory(
            id: UUID(),
            name: name,
            prompt: "",
            sortOrder: sortOrder,
            isEnabled: true,
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }

    func makeUsage(index: Int) -> AIUsageRecord {
        AIUsageRecord(
            id: UUID(),
            operation: index.isMultiple(of: 2) ? .summarize : .categorize,
            timestamp: Date(timeIntervalSince1970: Double(index)),
            provider: "provider",
            model: "model",
            durationMilliseconds: index,
            succeeded: index.isMultiple(of: 3),
            errorCode: index.isMultiple(of: 3) ? nil : "request_failed"
        )
    }

    func assertItemNotFound(
        _ id: UUID,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected itemNotFound", file: file, line: line)
        } catch let error as DatabaseError {
            XCTAssertEqual(error, .itemNotFound(id), file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    func assertInvalidRetentionDays(
        _ expected: Int,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected invalid retention", file: file, line: line)
        } catch let error as ValidationError {
            XCTAssertEqual(error, .invalidRetentionDays(expected), file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}

private actor RepositoryMutationGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspendUntilReleased() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
