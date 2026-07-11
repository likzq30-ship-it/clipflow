import AppKit

@MainActor
protocol PasteboardClient: AnyObject {
    var changeCount: Int { get }
    func string() -> String?
    @discardableResult func write(_ text: String) -> Bool
}

@MainActor
final class SystemPasteboardClient: PasteboardClient {
    private let pasteboard = NSPasteboard.general

    var changeCount: Int {
        pasteboard.changeCount
    }

    func string() -> String? {
        pasteboard.string(forType: .string)
    }

    @discardableResult
    func write(_ text: String) -> Bool {
        _ = pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
