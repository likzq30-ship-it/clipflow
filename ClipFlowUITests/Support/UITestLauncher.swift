import AppKit
import XCTest

@MainActor
@discardableResult
func launchFixtureApp(
    readOnlyRecovery: Bool = false,
    file: StaticString = #filePath,
    line: UInt = #line
) -> XCUIApplication {
    terminateInterruptingSystemSettings()

    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing"]
    app.launchEnvironment["CLIPFLOW_TEST_DATABASE"] =
        (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("clipflow-\(UUID().uuidString).sqlite3")
    if readOnlyRecovery {
        app.launchEnvironment["CLIPFLOW_UI_READ_ONLY"] = "1"
    }
    app.launch()

    let search = app.textFields["quick.search"]
    XCTAssertTrue(search.waitForExistence(timeout: 3), file: file, line: line)
    let seededRoadmap = element(in: app, identifier: "quick.row.text.Project roadmap")
    XCTAssertTrue(seededRoadmap.waitForExistence(timeout: 5), file: file, line: line)
    return app
}

@MainActor
private func terminateInterruptingSystemSettings() {
    for bundleID in ["com.apple.SystemSettings", "com.apple.systempreferences"] {
        for runningApp in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            runningApp.terminate()
        }
    }
    for runningApp in NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex") {
        runningApp.hide()
    }
}

@MainActor
func openLibraryFromFixture(
    _ app: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let openHistory = app.buttons["quick.openLibrary"]
    XCTAssertTrue(openHistory.waitForExistence(timeout: 3), file: file, line: line)
    openHistory.click()
    XCTAssertTrue(app.windows["ClipFlow Library"].waitForExistence(timeout: 3), file: file, line: line)
}

@MainActor
func element(
    in app: XCUIApplication,
    identifier: String
) -> XCUIElement {
    app.descendants(matching: .any)
        .matching(identifier: identifier)
        .firstMatch
}

@MainActor
func firstElement(
    in app: XCUIApplication,
    identifierPrefix: String
) -> XCUIElement {
    app.descendants(matching: .any)
        .matching(NSPredicate(format: "identifier BEGINSWITH %@", identifierPrefix))
        .firstMatch
}

@MainActor
func waitUntil(
    timeout: TimeInterval = 3,
    _ predicate: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() {
            return true
        }
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    return predicate()
}
