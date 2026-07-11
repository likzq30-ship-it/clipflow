import XCTest
@testable import ClipFlow

final class SmokeTests: XCTestCase {
    func testVersionContract() {
        let info = Bundle(for: AppDelegate.self).infoDictionary
        XCTAssertEqual(info?["CFBundleShortVersionString"] as? String, "2.0.0")
        XCTAssertEqual(info?["CFBundleVersion"] as? String, "200")
    }
}
