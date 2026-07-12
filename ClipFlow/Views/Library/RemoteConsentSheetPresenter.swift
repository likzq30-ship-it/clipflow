import AppKit

@MainActor
final class RemoteConsentSheetPresenter: RemoteConsentPresenting {
    weak var window: NSWindow?

    init(window: NSWindow? = nil) {
        self.window = window
    }

    func confirmFirstSend(to origin: AIConsentOrigin) async -> Bool {
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Send clipboard text to remote AI?"
            alert.informativeText = """
            ClipFlow will send the selected clipboard item to \(origin.scheme)://\(origin.host):\(origin.port). Continue?
            """
            alert.addButton(withTitle: "Send")
            alert.addButton(withTitle: "Cancel")

            if let window {
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
            } else {
                continuation.resume(returning: alert.runModal() == .alertFirstButtonReturn)
            }
        }
    }
}
