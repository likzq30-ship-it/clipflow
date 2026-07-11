import Foundation

enum CapturePipelineEvent: Equatable, Sendable {
    case persisted(ClipboardItem)
    case skipped(PrivacySkipReason)
    case failed(code: AppErrorCode)
}

enum CapturePipelineAdmissionOperation: Hashable, Sendable {
    case capture(sourceBundleID: String?)
    case configurationUpdate
}

typealias CapturePipelineAdmissionObserver = @Sendable (
    CapturePipelineAdmissionOperation,
    UInt64
) async -> Void

actor CapturePipeline {
    private let privacyGuard: PrivacyGuard
    private let classifier: any TextClassifying
    private let repository: any ClipboardRepositoryProtocol
    private let admissionObserver: CapturePipelineAdmissionObserver?
    private var configuration: PrivacyConfiguration
    private var nextTicket: UInt64 = 0
    private var servingTicket: UInt64 = 0
    private var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]

    init(
        privacyGuard: PrivacyGuard,
        classifier: any TextClassifying,
        repository: any ClipboardRepositoryProtocol,
        configuration: PrivacyConfiguration,
        admissionObserver: CapturePipelineAdmissionObserver? = nil
    ) {
        self.privacyGuard = privacyGuard
        self.classifier = classifier
        self.repository = repository
        self.configuration = configuration
        self.admissionObserver = admissionObserver
    }

    func updateConfiguration(_ configuration: PrivacyConfiguration) async {
        let ticket = issueTicket()
        await admissionObserver?(.configurationUpdate, ticket)
        await waitForTurn(ticket)
        defer { complete(ticket) }

        self.configuration = configuration
    }

    func process(_ raw: RawClipboardCapture) async -> CapturePipelineEvent {
        let ticket = issueTicket()
        await admissionObserver?(.capture(sourceBundleID: raw.sourceBundleID), ticket)
        await waitForTurn(ticket)
        defer { complete(ticket) }

        return await processExclusively(raw)
    }

    private func processExclusively(_ raw: RawClipboardCapture) async -> CapturePipelineEvent {
        switch privacyGuard.evaluate(raw, configuration: configuration) {
        case .allow:
            break
        case .skip(let reason):
            return .skipped(reason)
        }

        let category = await classifier.classify(raw.content)
        let capturedText = CapturedText(
            content: raw.content,
            category: category,
            capturedAt: raw.capturedAt,
            sourceBundleID: raw.sourceBundleID
        )

        do {
            let item = try await repository.upsertCapturedText(capturedText)
            return .persisted(item)
        } catch let error as DatabaseError {
            return .failed(code: Self.errorCode(for: error))
        } catch {
            return .failed(code: .databaseWrite)
        }
    }

    private func issueTicket() -> UInt64 {
        let ticket = nextTicket
        nextTicket += 1
        return ticket
    }

    private func waitForTurn(_ ticket: UInt64) async {
        if ticket == servingTicket {
            return
        }
        precondition(ticket > servingTicket, "Capture pipeline ticket is no longer waiting")

        await withCheckedContinuation { continuation in
            precondition(waiters[ticket] == nil, "Capture pipeline ticket registered twice")
            waiters[ticket] = continuation
        }
    }

    private func complete(_ ticket: UInt64) {
        precondition(ticket == servingTicket, "Capture pipeline ticket completed out of order")
        servingTicket += 1

        if let next = waiters.removeValue(forKey: servingTicket) {
            next.resume()
        }
    }
}

private extension CapturePipeline {
    static func errorCode(for error: DatabaseError) -> AppErrorCode {
        switch error {
        case .openFailed:
            return .databaseOpen
        case .readOnlyRecovery:
            return .databaseReadOnly
        default:
            return .databaseWrite
        }
    }
}
