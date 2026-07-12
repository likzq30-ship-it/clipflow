import Foundation
import OSLog

actor AppLogger: AppLogging {
    private let capacity: Int
    private let logger: Logger
    private var events: [DiagnosticEvent] = []

    init(
        capacity: Int = 200,
        logger: Logger = Logger(subsystem: "com.clipflow.v12", category: "diagnostics")
    ) {
        self.capacity = max(1, capacity)
        self.logger = logger
    }

    func record(_ event: DiagnosticEvent) async {
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
        writeToUnifiedLog(event)
    }

    func recentEvents(limit: Int) async -> [DiagnosticEvent] {
        guard limit > 0 else { return [] }
        return Array(events.suffix(limit).reversed())
    }
}

private extension AppLogger {
    func writeToUnifiedLog(_ event: DiagnosticEvent) {
        switch event.code {
        case .databaseOpen:
            logger.error("Database open failure")
        case .databaseWrite:
            logger.error("Database write failure")
        case .databaseCopyMetadata:
            logger.warning("Clipboard copy metadata update failure")
        case .databaseReadOnly:
            logger.warning("Database opened in read-only recovery")
        case .migrationFailed:
            logger.error("Database migration failure")
        case .migrationBackupDelete:
            logger.warning("Migration backup deletion failure")
        case .clipboardRead:
            logger.warning("Clipboard read failure")
        case .clipboardWrite:
            logger.warning("Clipboard write failure")
        case .hotkeyRegistration:
            logger.warning("Hotkey registration failure")
        case .privacyExcluded:
            logger.info("Clipboard capture skipped by application privacy rule")
        case .privacySize:
            logger.info("Clipboard capture skipped by size privacy rule")
        case .privacySensitive:
            logger.info("Clipboard capture skipped by sensitive-content privacy rule")
        case .aiEndpoint:
            logger.warning("AI endpoint validation failure")
        case .aiConsent:
            logger.warning("AI consent validation failure")
        case .aiRequest:
            logger.warning("AI request failure")
        case .releaseConfiguration:
            logger.error("Release configuration failure")
        }
    }
}
