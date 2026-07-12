import XCTest

@MainActor
final class QuickPanelUITests: XCTestCase {
    func testKeyboardSearchSelectionAndCopy() {
        let app = launchFixtureApp()
        let search = app.textFields["quick.search"]

        search.click()
        search.typeText("roadmap")
        XCTAssertTrue(element(in: app, identifier: "quick.row.text.Project roadmap").waitForExistence(timeout: 2))
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])

        XCTAssertFalse(app.windows["ClipFlow Quick Panel"].waitForExistence(timeout: 1))
    }

    func testEscapeClearsThenCloses() {
        let app = launchFixtureApp()
        let search = app.textFields["quick.search"]

        search.click()
        search.typeText("notes")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { (search.value as? String) == "" })
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertFalse(app.windows["ClipFlow Quick Panel"].waitForExistence(timeout: 1))
    }

    func testRowContextMenuShowsActionsAndUndoIdentifier() {
        let app = launchFixtureApp()
        let rowText = element(in: app, identifier: "quick.row.text.Project roadmap")
        XCTAssertTrue(rowText.waitForExistence(timeout: 2))

        rowText.rightClick()

        XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.menuItems["Favorite"].exists)
        XCTAssertTrue(app.menuItems["Open in History"].exists)
        XCTAssertTrue(app.menuItems["Delete"].exists)

        app.menuItems["Delete"].click()
        XCTAssertTrue(firstElement(in: app, identifierPrefix: "quick.undo.").waitForExistence(timeout: 2))
    }
}
