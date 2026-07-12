import Foundation
@testable import ClipFlow

actor InMemoryAppLogger: AppLogging {
    private var events: [DiagnosticEvent] = []

    func record(_ event: DiagnosticEvent) async {
        events.append(event)
    }

    func recentEvents(limit: Int) async -> [DiagnosticEvent] {
        guard limit > 0 else { return [] }
        return Array(events.suffix(limit).reversed())
    }
}
