import SwiftUI

struct AISettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    let actions: SettingsActionAdapter

    @State private var provider: AIProviderKind = .disabled
    @State private var endpoint = ""
    @State private var model = ""
    @State private var lastSaveSucceeded: Bool?

    var body: some View {
        Form {
            Picker("Provider", selection: $provider) {
                Text("Disabled").tag(AIProviderKind.disabled)
                Text("Local Ollama").tag(AIProviderKind.localOllama)
                Text("Remote HTTPS").tag(AIProviderKind.remoteHTTPS)
            }

            TextField("Endpoint", text: $endpoint)
                .disabled(provider == .disabled)
                .accessibilityLabel("AI endpoint")
            TextField("Model", text: $model)
                .disabled(provider == .disabled)
                .accessibilityLabel("AI model")

            HStack {
                Button("Save AI Settings") {
                    Task {
                        lastSaveSucceeded = await actions.saveAIConfiguration(
                            provider: provider,
                            endpoint: URL(string: endpoint),
                            model: model
                        )
                    }
                }
                Button("Remove Credential") {
                    Task { _ = await actions.removeCredential() }
                }
                .disabled(provider != .remoteHTTPS)
            }

            if lastSaveSucceeded == false {
                Text("AI endpoint is invalid for the selected provider.")
                    .foregroundStyle(.red)
            }

            Text("Saving a remote HTTPS endpoint does not grant consent. First-send confirmation is owned by the Library window.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear {
            provider = settings.aiProviderKind
            endpoint = settings.aiEndpoint?.absoluteString ?? ""
            model = settings.aiModel
        }
    }
}
