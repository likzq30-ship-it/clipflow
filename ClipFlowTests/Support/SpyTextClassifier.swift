import Foundation
@testable import ClipFlow

actor SpyTextClassifier: TextClassifying {
    let result: ClipboardItem.Category
    private(set) var callCount = 0
    private(set) var receivedTexts: [String] = []

    init(result: ClipboardItem.Category) {
        self.result = result
    }

    func classify(_ text: String) -> ClipboardItem.Category {
        callCount += 1
        receivedTexts.append(text)
        return result
    }
}

actor SuspendingTextClassifier: TextClassifying {
    let result: ClipboardItem.Category
    private(set) var startedTexts: [String] = []
    private(set) var finishedTexts: [String] = []
    private(set) var maximumConcurrentCallCount = 0

    private var activeCallCount = 0
    private var releaseContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var releasePermits: Set<String> = []
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(result: ClipboardItem.Category) {
        self.result = result
    }

    func classify(_ text: String) async -> ClipboardItem.Category {
        activeCallCount += 1
        maximumConcurrentCallCount = max(maximumConcurrentCallCount, activeCallCount)
        startedTexts.append(text)
        startWaiters.removeValue(forKey: text)?.forEach { $0.resume() }

        if releasePermits.remove(text) == nil {
            await withCheckedContinuation { continuation in
                releaseContinuations[text] = continuation
            }
        }

        finishedTexts.append(text)
        activeCallCount -= 1
        return result
    }

    func waitUntilStarted(_ text: String) async {
        guard !startedTexts.contains(text) else {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters[text, default: []].append(continuation)
        }
    }

    func hasStarted(_ text: String) -> Bool {
        startedTexts.contains(text)
    }

    func release(_ text: String) {
        if let continuation = releaseContinuations.removeValue(forKey: text) {
            continuation.resume()
        } else {
            releasePermits.insert(text)
        }
    }
}

actor AsyncTestSignal {
    private(set) var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !isSignalled else {
            return
        }
        isSignalled = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !isSignalled else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
