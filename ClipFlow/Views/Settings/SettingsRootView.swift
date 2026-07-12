import SwiftUI

struct SettingsRootView: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var store: ClipboardStore
    @ObservedObject var hotkeyService: HotkeyService
    @ObservedObject var launchAtLogin: LaunchAtLoginService

    let actions: SettingsActionAdapter

    var body: some View {
        TabView {
            GeneralSettingsView(
                settings: settings,
                store: store,
                launchAtLogin: launchAtLogin,
                actions: actions
            )
            .tabItem { Label("General", systemImage: "gearshape") }

            HotkeySettingsView(hotkeyService: hotkeyService)
                .tabItem { Label("Hotkey", systemImage: "keyboard") }

            PrivacySettingsView(settings: settings, actions: actions)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }

            CategorySettingsView(store: store, actions: actions)
                .tabItem { Label("Categories", systemImage: "folder") }

            AISettingsView(settings: settings, actions: actions)
                .tabItem { Label("AI", systemImage: "brain") }

            DiagnosticsSettingsView(actions: actions)
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 560, minHeight: 460, idealHeight: 460)
    }
}
