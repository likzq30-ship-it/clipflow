import Foundation
@testable import ClipFlow

actor ManualSleeper: SleepProviding {
    private var continuations: [CheckedContinuation<Void, Error>] = []
    private(set) var requestedDurations: [Duration] = []

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { continuation in
            requestedDurations.append(duration)
            continuations.append(continuation)
        }
    }

    func resumeNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func resumeAll() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }

    var pendingSleepCount: Int {
        continuations.count
    }
}
