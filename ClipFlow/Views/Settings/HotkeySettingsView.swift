import SwiftUI

struct HotkeySettingsView: View {
    @ObservedObject var hotkeyService: HotkeyService

    var body: some View {
        Form {
            LabeledContent("Open Quick Panel") {
                Text(hotkeyService.currentShortcut.displayString)
                    .font(.system(.body, design: .monospaced))
            }

            Button("Reset to Default") {
                hotkeyService.resetToDefault()
            }

            if let lastError = hotkeyService.lastError {
                Text("Hotkey update failed: \(String(describing: lastError))")
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }
}
