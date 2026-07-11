import XCTest
@testable import ClipFlow

final class ClipQueryTests: XCTestCase {
    func testQuickPanelQueryIsBounded() {
        let query = ClipQuery.quickPanel(searchText: "api", favoritesOnly: true)
        XCTAssertEqual(query.limit, 50)
        XCTAssertEqual(query.offset, 0)
        XCTAssertEqual(query.scope, .favorites)
    }

    func testRetentionPolicyValidatesRange() throws {
        XCTAssertEqual(try RetentionPolicy.validatedDays(15).dayCount, 15)
        XCTAssertThrowsError(try RetentionPolicy.validatedDays(0))
        XCTAssertThrowsError(try RetentionPolicy.validatedDays(366))
        XCTAssertNil(RetentionPolicy.forever.dayCount)
    }
}
