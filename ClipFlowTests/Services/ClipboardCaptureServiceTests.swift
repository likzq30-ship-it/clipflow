import XCTest
@testable import ClipFlow

@MainActor
final class ClipboardCaptureServiceTests: XCTestCase {
    func testStartIsIdempotentAndUsesHalfSecondTimer() {
        let pasteboard = FakePasteboardClient()
        let service = ClipboardCaptureService(
            pasteboard: pasteboard,
            sourceBundleID: { "com.example.source" }
        )
        defer { service.stop() }

        service.start { _ in }
        service.start { _ in }

        XCTAssertEqual(service.activeTimerCountForTesting, 1)
        XCTAssertEqual(service.timerIntervalForTesting, 0.5)
    }

    func testStopAndRestartRemainIdempotent() {
        let service = ClipboardCaptureService(
            pasteboard: FakePasteboardClient(),
            sourceBundleID: { nil }
        )
        defer { service.stop() }

        service.start { _ in }
        service.stop()
        service.stop()
        XCTAssertEqual(service.activeTimerCountForTesting, 0)

        service.start { _ in }
        service.start { _ in }
        XCTAssertEqual(service.activeTimerCountForTesting, 1)
    }

    func testFakePasteboardWriteIncrementsChangeCountExactlyOnce() {
        let pasteboard = FakePasteboardClient(changeCount: 7)

        XCTAssertTrue(pasteboard.write("value"))

        XCTAssertEqual(pasteboard.writeCallCount, 1)
        XCTAssertEqual(pasteboard.changeCount, 8)
        XCTAssertEqual(pasteboard.storedText, "value")
    }

    func testWritingThroughServiceDoesNotRecaptureText() {
        let pasteboard = FakePasteboardClient()
        let service = ClipboardCaptureService(
            pasteboard: pasteboard,
            sourceBundleID: { nil }
        )
        defer { service.stop() }
        var captures: [RawClipboardCapture] = []
        service.start { captures.append($0) }

        XCTAssertTrue(service.write("copied by ClipFlow"))
        service.checkNowForTesting()

        XCTAssertTrue(captures.isEmpty)
        XCTAssertEqual(pasteboard.changeCount, 1)
    }

    func testFailedWriteStillAdvancesObservedChangeCount() {
        let pasteboard = FakePasteboardClient()
        pasteboard.writeResult = false
        let service = ClipboardCaptureService(
            pasteboard: pasteboard,
            sourceBundleID: { nil }
        )
        defer { service.stop() }
        var captures: [RawClipboardCapture] = []
        service.start { captures.append($0) }

        XCTAssertFalse(service.write("failed ClipFlow write"))
        service.checkNowForTesting()

        XCTAssertTrue(captures.isEmpty)
        XCTAssertEqual(pasteboard.changeCount, 1)
    }

    func testExternalChangeEmitsRawCaptureWithPollTimestamp() {
        let timestamp = Date(timeIntervalSince1970: 123)
        let pasteboard = FakePasteboardClient()
        let service = ClipboardCaptureService(
            pasteboard: pasteboard,
            sourceBundleID: { "com.example.editor" },
            now: { timestamp }
        )
        defer { service.stop() }
        var captures: [RawClipboardCapture] = []
        service.start { captures.append($0) }

        pasteboard.simulateExternalChange("external text")
        service.checkNowForTesting()

        XCTAssertEqual(
            captures,
            [
                RawClipboardCapture(
                    content: "external text",
                    capturedAt: timestamp,
                    sourceBundleID: "com.example.editor"
                )
            ]
        )
    }

    func testSourceBundleIsCapturedAtChangeDetectionBeforePasteboardRead() {
        var sourceBundleID: String? = "com.example.before"
        let pasteboard = FakePasteboardClient()
        pasteboard.onStringRead = { sourceBundleID = "com.example.after" }
        let service = ClipboardCaptureService(
            pasteboard: pasteboard,
            sourceBundleID: { sourceBundleID }
        )
        defer { service.stop() }
        var captures: [RawClipboardCapture] = []
        service.start { captures.append($0) }

        pasteboard.simulateExternalChange("snapshot source")
        service.checkNowForTesting()
        sourceBundleID = "com.example.later"

        XCTAssertEqual(captures.first?.sourceBundleID, "com.example.before")
    }

    func testUnchangedAndEmptyPasteboardDoNotEmitCapture() {
        let pasteboard = FakePasteboardClient()
        let service = ClipboardCaptureService(
            pasteboard: pasteboard,
            sourceBundleID: { nil }
        )
        defer { service.stop() }
        var captures: [RawClipboardCapture] = []
        service.start { captures.append($0) }

        service.checkNowForTesting()
        pasteboard.simulateExternalChange("")
        service.checkNowForTesting()
        pasteboard.simulateExternalChange(nil)
        service.checkNowForTesting()

        XCTAssertTrue(captures.isEmpty)
    }

    func testPauseStoresFiveMinuteOneHourAndIndefiniteStates() {
        let now = Date(timeIntervalSince1970: 100)
        let service = ClipboardCaptureService(
            pasteboard: FakePasteboardClient(),
            sourceBundleID: { nil },
            now: { now }
        )

        service.pause(.until(now.addingTimeInterval(5 * 60)))
        XCTAssertEqual(service.pauseState, .until(Date(timeIntervalSince1970: 400)))

        service.pause(.until(now.addingTimeInterval(60 * 60)))
        XCTAssertEqual(service.pauseState, .until(Date(timeIntervalSince1970: 3_700)))

        service.pause(.indefinitely)
        XCTAssertEqual(service.pauseState, .indefinitely)
    }

    func testPauseUntilAutomaticallyResumesAtDeadline() {
        var currentTime = Date(timeIntervalSince1970: 100)
        let service = ClipboardCaptureService(
            pasteboard: FakePasteboardClient(),
            sourceBundleID: { nil },
            now: { currentTime }
        )
        service.pause(.until(Date(timeIntervalSince1970: 200)))

        service.checkNowForTesting()
        XCTAssertEqual(service.pauseState, .until(Date(timeIntervalSince1970: 200)))

        currentTime = Date(timeIntervalSince1970: 200)
        service.checkNowForTesting()
        XCTAssertEqual(service.pauseState, .active)
    }

    func testIndefinitePauseConsumesChangesWithoutReplayingOnResume() {
        let pasteboard = FakePasteboardClient()
        let service = ClipboardCaptureService(
            pasteboard: pasteboard,
            sourceBundleID: { nil }
        )
        defer { service.stop() }
        var captures: [RawClipboardCapture] = []
        service.start { captures.append($0) }
        service.pause(.indefinitely)

        pasteboard.simulateExternalChange("while paused")
        service.checkNowForTesting()
        service.resume()
        service.checkNowForTesting()

        XCTAssertTrue(captures.isEmpty)
        XCTAssertEqual(service.pauseState, .active)

        pasteboard.simulateExternalChange("after resume")
        service.checkNowForTesting()
        XCTAssertEqual(captures.map(\.content), ["after resume"])
    }

    func testFuturePauseSuppressesCaptureAndExpiredPauseCapturesCurrentChange() {
        var currentTime = Date(timeIntervalSince1970: 100)
        let pasteboard = FakePasteboardClient()
        let service = ClipboardCaptureService(
            pasteboard: pasteboard,
            sourceBundleID: { nil },
            now: { currentTime }
        )
        defer { service.stop() }
        var captures: [RawClipboardCapture] = []
        service.start { captures.append($0) }
        service.pause(.until(Date(timeIntervalSince1970: 200)))

        pasteboard.simulateExternalChange("suppressed")
        service.checkNowForTesting()
        XCTAssertTrue(captures.isEmpty)

        currentTime = Date(timeIntervalSince1970: 200)
        pasteboard.simulateExternalChange("at deadline")
        service.checkNowForTesting()

        XCTAssertEqual(service.pauseState, .active)
        XCTAssertEqual(captures.map(\.content), ["at deadline"])
    }
}
