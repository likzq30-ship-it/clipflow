import Foundation
@testable import ClipFlow

@MainActor
final class RecordingRemoteConsentPresenter: RemoteConsentPresenting {
    private var decisions: [Bool]
    private(set) var requestedOrigins: [AIConsentOrigin] = []

    init(decisions: [Bool]) {
        self.decisions = decisions
    }

    func confirmFirstSend(to origin: AIConsentOrigin) async -> Bool {
        requestedOrigins.append(origin)
        guard !decisions.isEmpty else { return true }
        return decisions.removeFirst()
    }
}
