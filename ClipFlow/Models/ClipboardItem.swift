import Foundation

struct ClipboardItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var content: String
    var category: Category
    var customCategoryID: UUID?
    var customCategory: String?
    var createdAt: Date
    var lastCopiedAt: Date
    var copyCount: Int
    var isFavorite: Bool
    var aiSummary: String?
    var deletedAt: Date?

    var timestamp: Date {
        get { lastCopiedAt }
        set { lastCopiedAt = newValue }
    }

    var displayCategory: String {
        if let customCategory, !customCategory.isEmpty {
            return customCategory
        }
        return category.label
    }

    enum Category: String, Codable, CaseIterable, Sendable {
        case url
        case email
        case code
        case number
        case chinese
        case english
        case mixed
        case other

        var label: String {
            switch self {
            case .url: return "链接"
            case .email: return "邮件"
            case .code: return "代码"
            case .number: return "数字"
            case .chinese: return "中文"
            case .english: return "英文"
            case .mixed: return "中英"
            case .other: return "其他"
            }
        }
    }

    init(
        id: UUID = UUID(),
        content: String,
        category: Category = .other,
        customCategoryID: UUID? = nil,
        customCategory: String? = nil,
        timestamp: Date = Date(),
        createdAt: Date? = nil,
        copyCount: Int = 1,
        isFavorite: Bool = false,
        aiSummary: String? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.content = content
        self.category = category
        self.customCategoryID = customCategoryID
        self.customCategory = customCategory
        self.createdAt = createdAt ?? timestamp
        self.lastCopiedAt = timestamp
        self.copyCount = copyCount
        self.isFavorite = isFavorite
        self.aiSummary = aiSummary
        self.deletedAt = deletedAt
    }

    static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool {
        lhs.id == rhs.id
    }
}

extension ClipboardItem {
    var displayContent: String {
        content.count > 200 ? String(content.prefix(200)) + "..." : content
    }

    private nonisolated(unsafe) static let sharedRelativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var timeAgo: String {
        Self.sharedRelativeFormatter.localizedString(for: timestamp, relativeTo: Date())
    }

}
