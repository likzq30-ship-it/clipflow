import SwiftUI

struct MonitoringStatusView: View {
    let pause: MonitoringPause

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            Label(statusText(now: context.date), systemImage: iconName(now: context.date))
                .font(.caption2)
                .foregroundColor(isActive(now: context.date) ? .secondary : .orange)
                .labelStyle(.titleAndIcon)
                .accessibilityIdentifier("quick.monitoring")
        }
    }
}

private extension MonitoringStatusView {
    func isActive(now: Date) -> Bool {
        switch pause {
        case .active:
            return true
        case .indefinitely:
            return false
        case .until(let deadline):
            return deadline <= now
        }
    }

    func iconName(now: Date) -> String {
        isActive(now: now) ? "record.circle" : "pause.circle"
    }

    func statusText(now: Date) -> String {
        switch pause {
        case .active:
            return "Monitoring"
        case .indefinitely:
            return "Paused"
        case .until(let deadline):
            let remaining = max(0, Int(deadline.timeIntervalSince(now)))
            if remaining == 0 { return "Monitoring" }
            let minutes = max(1, remaining / 60)
            return "Paused \(minutes)m"
        }
    }
}
