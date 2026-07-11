import Foundation

enum ClipScope: Equatable, Sendable {
    case all
    case favorites
    case today
    case builtIn(ClipboardItem.Category)
    case custom(UUID)
}

struct ClipQuery: Equatable, Sendable {
    var searchText: String
    var scope: ClipScope
    var limit: Int
    var offset: Int

    static func quickPanel(searchText: String, favoritesOnly: Bool) -> Self {
        .init(
            searchText: searchText,
            scope: favoritesOnly ? .favorites : .all,
            limit: 50,
            offset: 0
        )
    }
}

struct ClipPage: Equatable, Sendable {
    var items: [ClipboardItem]
    var nextOffset: Int?
    var totalCount: Int
}

struct DeletedClipTombstone: Equatable, Sendable {
    let itemID: UUID
    let deletedAt: Date
}

enum RetentionPolicy: Equatable, Sendable {
    case days(Int)
    case forever

    var dayCount: Int? {
        switch self {
        case .days(let value): return value
        case .forever: return nil
        }
    }

    static func validatedDays(_ value: Int) throws -> Self {
        guard (1...365).contains(value) else {
            throw ValidationError.invalidRetentionDays(value)
        }
        return .days(value)
    }
}

enum ValidationError: Error, Equatable, Sendable {
    case invalidRetentionDays(Int)
}

struct RawClipboardCapture: Equatable, Sendable {
    var content: String
    var capturedAt: Date
    var sourceBundleID: String?
}

struct CapturedText: Equatable, Sendable {
    var content: String
    var category: ClipboardItem.Category
    var capturedAt: Date
    var sourceBundleID: String?
}
