import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var store: ClipboardStore
    @ObservedObject var launchAtLogin: LaunchAtLoginService

    let actions: SettingsActionAdapter

    @State private var retentionDays = 15
    @State private var storesForever = false
    @State private var maxCaptureText = "1048576"

    var body: some View {
        Form {
            Toggle("Launch at Login", isOn: launchBinding)
                .help("Start ClipFlow when you sign in.")

            Picker("Retention", selection: $storesForever) {
                Text("Days").tag(false)
                Text("Forever").tag(true)
            }
            .pickerStyle(.segmented)
            .onChange(of: storesForever) { newValue in
                Task {
                    await actions.setRetentionPolicy(newValue ? .forever : .days(retentionDays))
                }
            }

            Stepper(String(localized: "Retention Days: \(retentionDays)"), value: $retentionDays, in: 1...365)
                .disabled(storesForever)
                .onChange(of: retentionDays) { newValue in
                    Task { await actions.setRetentionPolicy(.days(newValue)) }
                }

            TextField("Maximum captured text bytes", text: $maxCaptureText)
                .onSubmit {
                    if let bytes = Int(maxCaptureText) {
                        Task { await actions.setMaxCaptureBytes(bytes) }
                    }
                }
                .accessibilityLabel("Maximum captured text bytes")

            LabeledContent("Clipboard Monitoring") {
                HStack {
                    Button("Pause") { actions.pauseMonitoring(.indefinitely) }
                        .disabled(store.monitoringPause != .active)
                    Button("Resume") { actions.resumeMonitoring() }
                        .disabled(store.monitoringPause == .active)
                }
            }

            if let lastError = launchAtLogin.lastError {
                Text(String(localized: "Launch at Login failed: \(String(describing: lastError))"))
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            storesForever = settings.retentionPolicy == .forever
            retentionDays = settings.retentionPolicy.dayCount ?? 15
            maxCaptureText = String(settings.maxCaptureBytes)
        }
    }

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isEnabled },
            set: { _ = actions.setLaunchAtLogin($0) }
        )
    }
}
