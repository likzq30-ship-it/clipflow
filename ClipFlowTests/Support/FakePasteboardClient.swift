import Foundation
@testable import ClipFlow

@MainActor
final class FakePasteboardClient: PasteboardClient {
    private(set) var changeCount: Int
    private(set) var storedText: String?
    private(set) var writeCallCount = 0
    var writeResult = true
    var onStringRead: (() -> Void)?

    init(text: String? = nil, changeCount: Int = 0) {
        storedText = text
        self.changeCount = changeCount
    }

    func string() -> String? {
        onStringRead?()
        return storedText
    }

    @discardableResult
    func write(_ text: String) -> Bool {
        writeCallCount += 1
        storedText = text
        changeCount += 1
        return writeResult
    }

    func simulateExternalChange(_ text: String?) {
        storedText = text
        changeCount += 1
    }
}
