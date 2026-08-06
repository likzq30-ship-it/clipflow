import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
struct ApplicationPicker {
    func pickBundleIdentifier() -> String? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Application")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]

        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier,
              !bundleID.isEmpty else {
            return nil
        }
        return bundleID
    }
}
