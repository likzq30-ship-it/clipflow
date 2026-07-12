import AppKit
import SwiftUI

struct DiagnosticsSettingsView: View {
    let actions: SettingsActionAdapter

    @State private var report = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Refresh") {
                    Task { await refresh() }
                }
                Button("Copy Report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }
                .disabled(report.isEmpty)
                Button("Clear AI Metadata") {
                    Task {
                        await actions.clearAIUsage()
                        await refresh()
                    }
                }
            }

            ScrollView {
                Text(report.isEmpty ? "No diagnostics loaded." : report)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .onAppear {
            Task { await refresh() }
        }
    }

    private func refresh() async {
        let snapshot = await actions.diagnosticsSnapshot()
        report = DiagnosticsReportBuilder().render(snapshot)
    }
}
