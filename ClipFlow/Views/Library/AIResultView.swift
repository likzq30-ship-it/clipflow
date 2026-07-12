import AppKit
import SwiftUI

struct AIResultView: View {
    let title: String
    let persistedText: String?
    let state: AIJobState?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator, lineWidth: 1)
        )
    }
}

private extension AIResultView {
    @ViewBuilder
    var content: some View {
        switch state {
        case .running:
            HStack {
                ProgressView()
                Text("Running…")
            }
        case .success(let result):
            success(text: result.text)
        case .failure(_, let message):
            Text(message)
                .foregroundStyle(.red)
        case .none:
            if let persistedText, !persistedText.isEmpty {
                success(text: persistedText)
            } else {
                Text("Idle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    func success(text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .textSelection(.enabled)
            Button("Copy Result") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }
}
