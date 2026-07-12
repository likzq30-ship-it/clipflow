import Foundation
import XCTest
@testable import ClipFlow

@MainActor
final class AppEnvironmentTests: XCTestCase {
    func testUITestingDatabaseUsesExplicitTestDatabaseWhenProvided() throws {
        let databaseURL = try AppEnvironment.databaseURLForTesting(
            isUITesting: true,
            environment: ["CLIPFLOW_TEST_DATABASE": "/tmp/clipflow-explicit.sqlite3"]
        )

        XCTAssertEqual(databaseURL.path, "/tmp/clipflow-explicit.sqlite3")
    }

    func testUITestingDatabaseWithoutEnvironmentDoesNotFallBackToProductionDatabase() throws {
        let databaseURL = try AppEnvironment.databaseURLForTesting(
            isUITesting: true,
            environment: [:]
        )
        let productionDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        .appendingPathComponent("ClipFlow", isDirectory: true)

        XCTAssertFalse(
            databaseURL.path.hasPrefix(productionDirectory.path),
            "UI tests must never use the user's production ClipFlow database."
        )
        XCTAssertTrue(
            databaseURL.path.hasPrefix(FileManager.default.temporaryDirectory.path),
            "Missing CLIPFLOW_TEST_DATABASE should fall back to an isolated temporary database."
        )
        XCTAssertEqual(databaseURL.lastPathComponent, "clipflow.sqlite3")
    }
}
