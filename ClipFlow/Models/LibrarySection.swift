import Foundation

enum LibrarySection: Hashable, Sendable {
    case all
    case favorites
    case today
    case builtIn(ClipboardItem.Category)
    case custom(UUID)

    static let fixed: [LibrarySection] = [.all, .favorites, .today]

    var clipScope: ClipScope {
        switch self {
        case .all:
            return .all
        case .favorites:
            return .favorites
        case .today:
            return .today
        case .builtIn(let category):
            return .builtIn(category)
        case .custom(let id):
            return .custom(id)
        }
    }

    var title: String {
        switch self {
        case .all:
            return String(localized: "All Clips")
        case .favorites:
            return String(localized: "Favorites")
        case .today:
            return String(localized: "Today")
        case .builtIn(let category):
            return category.label
        case .custom:
            return String(localized: "Custom")
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            return "tray.full"
        case .favorites:
            return "star"
        case .today:
            return "calendar"
        case .builtIn(let category):
            switch category {
            case .url: return "link"
            case .email: return "envelope"
            case .code: return "chevron.left.forwardslash.chevron.right"
            case .number: return "number"
            case .chinese: return "character.book.closed"
            case .english: return "textformat"
            case .mixed: return "text.bubble"
            case .other: return "folder"
            }
        case .custom:
            return "tag"
        }
    }
}
