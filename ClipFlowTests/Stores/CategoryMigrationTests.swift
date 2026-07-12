import XCTest
@testable import ClipFlow

final class CategoryMigrationTests: XCTestCase {
    func testDeletingCategoryMigratesItemsBeforeRemovingCategory() async throws {
        let location = try TemporaryDatabaseLocation()
        let repository = ClipboardRepository(databaseURL: location.url)
        _ = try await repository.prepare(legacyCategories: [])
        let source = PersistedCustomCategory.fixture(name: "Old", sortOrder: 0)
        let target = PersistedCustomCategory.fixture(name: "New", sortOrder: 1)
        try await repository.saveCategory(source)
        try await repository.saveCategory(target)
        let item = try await repository.upsertCapturedText(.fixture("categorized"))
        _ = try await repository.setCustomCategory(id: item.id, categoryID: source.id)

        try await repository.deleteCategory(id: source.id, migrateTo: target.id)

        let migratedItem = try await repository.item(id: item.id)
        let categories = try await repository.fetchCategories()
        XCTAssertEqual(migratedItem?.customCategoryID, target.id)
        XCTAssertFalse(categories.contains { $0.id == source.id })
    }
}
