import Foundation

struct DiagnosticsSnapshot: Equatable, Sendable {
    var appVersion: String
    var buildNumber: String
    var macOSVersion: String
    var aiProviderKind: String
    var remoteConfigured: Bool
    var aiAvailable: Bool?
    var sensitiveProtectionEnabled: Bool
    var excludedApplicationCount: Int
    var recentEvents: [DiagnosticEvent]
}

struct DiagnosticsReportBuilder {
    func render(_ snapshot: DiagnosticsSnapshot) -> String {
        var lines: [String] = [
            "ClipFlow Diagnostics",
            "appVersion=\(snapshot.appVersion)",
            "buildNumber=\(snapshot.buildNumber)",
            "macOSVersion=\(snapshot.macOSVersion)",
            "aiProviderKind=\(snapshot.aiProviderKind)",
            "remoteConfigured=\(snapshot.remoteConfigured)",
            "aiAvailable=\(snapshot.aiAvailable.map(String.init(describing:)) ?? "unknown")",
            "sensitiveProtectionEnabled=\(snapshot.sensitiveProtectionEnabled)",
            "excludedApplicationCount=\(snapshot.excludedApplicationCount)",
            "recentEvents:"
        ]

        lines.append(contentsOf: snapshot.recentEvents.map { event in
            "- \(event.timestamp.timeIntervalSince1970): \(event.code.rawValue)"
        })
        return lines.joined(separator: "\n")
    }
}
