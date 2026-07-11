import Foundation

struct PersistedCustomCategory: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var name: String
    var prompt: String
    var sortOrder: Int
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date
}
