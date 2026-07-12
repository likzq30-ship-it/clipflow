import SwiftUI

struct ErrorBanner: View {
    let presentation: AppErrorPresentation
    var isUndismissable = false
    let onRecoveryAction: (RecoveryAction) async -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.message)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if let recoveryTitle = presentation.recoveryTitle,
                   let recoveryAction = presentation.recoveryAction {
                    Button(recoveryTitle) {
                        Task { await onRecoveryAction(recoveryAction) }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            Spacer(minLength: 0)

            if isUndismissable {
                Text("Recovery")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(iconColor.opacity(0.25))
        )
    }
}

private extension ErrorBanner {
    var iconName: String {
        switch presentation.severity {
        case .information: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var iconColor: Color {
        switch presentation.severity {
        case .information: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}
