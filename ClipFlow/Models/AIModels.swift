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

enum AIProviderKind: String, Codable, Sendable {
    case disabled
    case localOllama
    case remoteHTTPS
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
