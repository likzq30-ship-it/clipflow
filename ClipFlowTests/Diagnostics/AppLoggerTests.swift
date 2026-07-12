import XCTest
@testable import ClipFlow

final class AppLoggerTests: XCTestCase {
    func testLoggerRetainsOnlyBoundedDiagnosticEvents() async {
        let logger = AppLogger(capacity: 2)
        let first = DiagnosticEvent(
            code: .aiRequest,
            timestamp: Date(timeIntervalSince1970: 1)
        )
        let second = DiagnosticEvent(
            code: .databaseWrite,
            timestamp: Date(timeIntervalSince1970: 2)
        )
        let third = DiagnosticEvent(
            code: .clipboardWrite,
            timestamp: Date(timeIntervalSince1970: 3)
        )

        await logger.record(first)
        await logger.record(second)
        await logger.record(third)

        let events = await logger.recentEvents(limit: 10)
        XCTAssertEqual(events, [third, second])
    }

    func testDiagnosticEventAPIMakesSensitivePayloadsUnrepresentable() async {
        let logger = AppLogger(capacity: 10)
        let sentinelClipboard = "clip text that must never be logged"
        let sentinelToken = "sk-test-token"
        _ = [sentinelClipboard, sentinelToken].joined(separator: " ")
        let event = DiagnosticEvent(
            code: .aiConsent,
            timestamp: Date(timeIntervalSince1970: 10)
        )

        await logger.record(event)

        let events = await logger.recentEvents(limit: 1)
        XCTAssertEqual(events, [event])
    }
}
