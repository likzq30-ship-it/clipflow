import XCTest
@testable import ClipFlow

final class ClipboardItemModelTests: XCTestCase {
    func testLegacyTimestampMapsToCreatedAndLastCopiedAt() {
        let date = Date(timeIntervalSince1970: 123)
        let item = ClipboardItem(content: "hello", timestamp: date)

        XCTAssertEqual(item.createdAt, date)
        XCTAssertEqual(item.lastCopiedAt, date)
        XCTAssertEqual(item.timestamp, date)
        XCTAssertEqual(item.copyCount, 1)
        XCTAssertNil(item.deletedAt)
    }

    func testDisplayCategoryPrefersResolvedCustomName() {
        var item = ClipboardItem(content: "roadmap", category: .english)
        item.customCategoryID = UUID()
        item.customCategory = "工作"
        XCTAssertEqual(item.displayCategory, "工作")
    }
}
