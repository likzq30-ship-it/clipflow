import Foundation

enum MonitoringPause: Equatable, Sendable {
    case active
    case until(Date)
    case indefinitely
}

@MainActor
protocol ClipboardCaptureServiceProtocol: AnyObject {
    var pauseState: MonitoringPause { get }
    func start(handler: @escaping @MainActor (RawClipboardCapture) -> Void)
    func stop()
    func pause(_ state: MonitoringPause)
    func resume()
    @discardableResult func write(_ text: String) -> Bool
}

@MainActor
final class ClipboardCaptureService: ClipboardCaptureServiceProtocol {
    private static let pollInterval: TimeInterval = 0.5

    private let pasteboard: any PasteboardClient
    private let sourceBundleID: () -> String?
    private let now: () -> Date
    private var handler: (@MainActor (RawClipboardCapture) -> Void)?
    private var timer: Timer?
    private var lastChangeCount: Int

    private(set) var pauseState: MonitoringPause = .active

    init(
        pasteboard: any PasteboardClient,
        sourceBundleID: @escaping () -> String?,
        now: @escaping () -> Date = Date.init
    ) {
        self.pasteboard = pasteboard
        self.sourceBundleID = sourceBundleID
        self.now = now
        lastChangeCount = pasteboard.changeCount
    }

    func start(handler: @escaping @MainActor (RawClipboardCapture) -> Void) {
        self.handler = handler
        guard timer?.isValid != true else {
            return
        }

        timer?.invalidate()
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(
            timeInterval: Self.pollInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkNowForTesting()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
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
        let result = pasteboard.write(text)
        lastChangeCount = pasteboard.changeCount
        return result
    }

    func checkNowForTesting() {
        let detectionTime = now()

        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastChangeCount else {
            return
        }
        lastChangeCount = currentChangeCount

        guard pauseState == .active else {
            return
        }

        let detectedSourceBundleID = sourceBundleID()
        guard let content = pasteboard.string(), !content.isEmpty else {
            return
        }

        handler?(
            RawClipboardCapture(
                content: content,
                capturedAt: detectionTime,
                sourceBundleID: detectedSourceBundleID
            )
        )
    }

    var activeTimerCountForTesting: Int {
        timer?.isValid == true ? 1 : 0
    }

    var timerIntervalForTesting: TimeInterval? {
        timer?.timeInterval
    }
}
