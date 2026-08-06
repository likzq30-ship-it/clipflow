import SwiftUI

struct PrivacySettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    let actions: SettingsActionAdapter

    @State private var pendingBundleID = ""
    private let picker = ApplicationPicker()

    var body: some View {
        Form {
            Toggle("Sensitive Content Protection", isOn: sensitiveBinding)

            Section("Excluded Applications") {
                HStack {
                    TextField("Bundle identifier", text: $pendingBundleID)
                        .accessibilityLabel("Excluded application bundle identifier")
                    Button("Add") {
                        Task {
                            await actions.addExcludedBundleID(pendingBundleID)
                            pendingBundleID = ""
                        }
                    }
                }

                Button {
                    if let bundleID = picker.pickBundleIdentifier() {
                        Task { await actions.addExcludedBundleID(bundleID) }
                    }
                } label: {
                    Label("Choose Application…", systemImage: "app.dashed")
                }

                ForEach(settings.excludedBundleIDs.sorted(), id: \.self) { bundleID in
                    HStack {
                        Text(bundleID)
                        Spacer()
                        Button {
                            Task { await actions.removeExcludedBundleID(bundleID) }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .accessibilityLabel(String(localized: "Remove \(bundleID)"))
                        .help("Remove excluded application")
                    }
                }
            }

            Text("Source application detection is best effort because foreground ownership can change before ClipFlow’s 0.5-second clipboard poll.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var sensitiveBinding: Binding<Bool> {
        Binding(
            get: { settings.sensitiveContentProtectionEnabled },
            set: { enabled in
                Task { await actions.setSensitiveProtectionEnabled(enabled) }
            }
        )
    }
}
