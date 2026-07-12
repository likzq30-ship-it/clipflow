import Foundation

enum AIOperation: String, Codable, Sendable {
    case summarize
    case categorize
    case rewrite
}

struct AIJobKey: Hashable, Sendable {
    let itemID: UUID
    let operation: AIOperation
}

struct AIRequest: Equatable, Sendable {
    let itemID: UUID
    let operation: AIOperation
    let text: String
    let allowedCategories: [PersistedCustomCategory]
}

struct AIResult: Equatable, Sendable {
    let itemID: UUID
    let operation: AIOperation
    let text: String
    let providerLabel: String
}

enum AIProviderConfiguration: Equatable, Sendable {
    case disabled
    case localOllama(baseURL: URL, model: String)
    case remoteHTTPS(baseURL: URL, model: String, consent: AIConsentOrigin)
}

enum AIProviderKind: String, Codable, Sendable {
    case disabled
    case localOllama
    case remoteHTTPS
}

struct AIConsentOrigin: Codable, Hashable, Sendable {
    let scheme: String
    let host: String
    let port: Int

    init(scheme: String, host: String, port: Int) {
        self.scheme = scheme.lowercased()
        self.host = host.lowercased()
        self.port = port
    }

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = url.port ?? (scheme == "https" ? 443 : 80)
    }
}

struct AIUsageRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let operation: AIOperation
    let timestamp: Date
    let provider: String
    let model: String
    let durationMilliseconds: Int
    let succeeded: Bool
    let errorCode: String?
}

enum AIAvailability: Equatable, Sendable {
    case disabled
    case available
    case unavailable(code: AppErrorCode)
}

enum AIError: Error, Equatable, Sendable {
    case disabled
    case invalidEndpoint
    case missingConsent
    case httpStatus(Int)
    case responseTooLarge
    case invalidResponse
    case emptyResponse
    case invalidCategory
    case redirectRejected
    case timedOut
    case cancelled
}

enum AIJobState: Equatable, Sendable {
    case running
    case success(AIResult)
    case failure(code: String, message: String)
}
