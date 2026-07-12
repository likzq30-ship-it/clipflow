import XCTest
@testable import ClipFlow

final class LibrarySectionTests: XCTestCase {
    func testFixedSidebarSectionsHaveStableOrder() {
        XCTAssertEqual(
            LibrarySection.fixed,
            [.all, .favorites, .today]
        )
    }

    func testSectionsMapToClipScopes() {
        let categoryID = UUID()

        XCTAssertEqual(LibrarySection.all.clipScope, .all)
        XCTAssertEqual(LibrarySection.favorites.clipScope, .favorites)
        XCTAssertEqual(LibrarySection.today.clipScope, .today)
        XCTAssertEqual(LibrarySection.builtIn(.code).clipScope, .builtIn(.code))
        XCTAssertEqual(LibrarySection.custom(categoryID).clipScope, .custom(categoryID))
    }
}
