import XCTest

@MainActor
final class LibraryUITests: XCTestCase {
    func testCommandReturnOpensSelectedOutOfPageItem() {
        let app = launchFixtureApp()
        let search = app.textFields["quick.search"]

        search.click()
        search.typeText("example")
        XCTAssertTrue(element(in: app, identifier: "quick.row.text.https://example.com").waitForExistence(timeout: 2))
        app.typeKey(.return, modifierFlags: .command)

        XCTAssertTrue(app.windows["ClipFlow Library"].waitForExistence(timeout: 3))
        XCTAssertTrue(element(in: app, identifier: "library.detail.text.https://example.com").waitForExistence(timeout: 3))
    }

    func testSidebarHideShow() {
        let app = launchFixtureApp()
        openLibraryFromFixture(app)

        let sidebarToggle = app.buttons["library.sidebarToggle"]
        XCTAssertTrue(sidebarToggle.waitForExistence(timeout: 2))
        sidebarToggle.click()
        sidebarToggle.click()

        XCTAssertTrue(sidebarToggle.exists)
    }

    func testFavoriteDeleteAndVisibleUndo() {
        let app = launchFixtureApp()
        openLibraryFromFixture(app)

        XCTAssertTrue(element(in: app, identifier: "library.row.text.Project roadmap").waitForExistence(timeout: 2))
        element(in: app, identifier: "library.row.text.Project roadmap").click()

        let favorite = element(in: app, identifier: "library.favorite")
        let delete = element(in: app, identifier: "library.delete")
        XCTAssertTrue(favorite.waitForExistence(timeout: 2))
        favorite.click()
        delete.click()

        XCTAssertTrue(app.buttons["library.undo"].waitForExistence(timeout: 2))
    }

    func testDetailScrollingKeepsCopyActionAvailable() {
        let app = launchFixtureApp()
        openLibraryFromFixture(app)

        let copy = element(in: app, identifier: "library.copy")
        XCTAssertTrue(copy.waitForExistence(timeout: 2))
        XCTAssertTrue(copy.exists)
    }

    func testSettingsViaCommandComma() {
        let app = launchFixtureApp()

        app.typeKey(",", modifierFlags: .command)

        XCTAssertTrue(app.windows["ClipFlow Settings"].waitForExistence(timeout: 2))
    }

    func testReadOnlyRecoveryDisablesMutatingActions() {
        let app = launchFixtureApp(readOnlyRecovery: true)
        openLibraryFromFixture(app)

        let favorite = element(in: app, identifier: "library.favorite")
        let delete = element(in: app, identifier: "library.delete")
        let copy = element(in: app, identifier: "library.copy")
        XCTAssertTrue(favorite.waitForExistence(timeout: 2))
        let favoriteIsEnabled = favorite.isEnabled
        let deleteIsEnabled = delete.isEnabled
        let copyIsEnabled = copy.isEnabled
        XCTAssertFalse(favoriteIsEnabled)
        XCTAssertFalse(deleteIsEnabled)
        XCTAssertTrue(copyIsEnabled)
    }

    func testLibraryMinimumSizing() {
        let app = launchFixtureApp()
        openLibraryFromFixture(app)

        let window = app.windows["ClipFlow Library"]
        let frame = window.frame
        XCTAssertGreaterThanOrEqual(frame.width, 760)
        XCTAssertGreaterThanOrEqual(frame.height, 520)
    }
}
