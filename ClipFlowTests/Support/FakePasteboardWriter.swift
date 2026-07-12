import Foundation
@testable import ClipFlow

@MainActor
final class FakePasteboardWriter: ClipboardCaptureServiceProtocol {
    var result: Bool
    private(set) var writtenText: String?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var handler: (@MainActor (RawClipboardCapture) -> Void)?
    private(set) var pauseState: MonitoringPause = .active

    nonisolated init(result: Bool) {
        self.result = result
    }

    func start(handler: @escaping @MainActor (RawClipboardCapture) -> Void) {
        startCount += 1
        self.handler = handler
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func pause(_ state: MonitoringPause) {
        pauseState = state
    }

    func resume() {
        pauseState = .active
    }

    @discardableResult
    func write(_ text: String) -> Bool {
        writtenText = text
        return result
    }

    func emit(_ capture: RawClipboardCapture) {
        handler?(capture)
    }
}
