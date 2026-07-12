import XCTest
@testable import ClipFlow

final class DiagnosticsReportBuilderTests: XCTestCase {
    func testRenderUsesClosedRedactedSchema() {
        let snapshot = DiagnosticsSnapshot(
            appVersion: "2.0.0",
            buildNumber: "200",
            macOSVersion: "26.0",
            aiProviderKind: "remoteHTTPS",
            remoteConfigured: true,
            aiAvailable: nil,
            sensitiveProtectionEnabled: true,
            excludedApplicationCount: 2,
            recentEvents: [
                DiagnosticEvent(
                    code: .aiRequest,
                    timestamp: Date(timeIntervalSince1970: 0)
                )
            ]
        )

        let report = DiagnosticsReportBuilder().render(snapshot)

        XCTAssertTrue(report.contains("appVersion=2.0.0"))
        XCTAssertTrue(report.contains("buildNumber=200"))
        XCTAssertTrue(report.contains("aiProviderKind=remoteHTTPS"))
        XCTAssertTrue(report.contains("remoteConfigured=true"))
        XCTAssertTrue(report.contains("ai.request"))
        XCTAssertFalse(report.contains("http"))
        XCTAssertFalse(report.contains("secret"))
    }
}
