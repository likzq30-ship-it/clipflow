import Foundation

struct APIUsageRecord: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var timestamp: Date
    var type: String  // "summarize" | "categorize" | "rewrite"
    var contentPreview: String
    var result: String
    var model: String
}

class APIUsageStore: ObservableObject {
    static let shared = APIUsageStore()

    @Published var records: [APIUsageRecord] = [] {
        didSet { save() }
    }

    private let key = "api_usage_records"

    init() { load() }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let r = try? JSONDecoder().decode([APIUsageRecord].self, from: data) else { return }
        records = r
    }

    func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func add(_ record: APIUsageRecord) {
        records.insert(record, at: 0)
        if records.count > 200 { records = Array(records.prefix(200)) }
    }

    func delete(_ record: APIUsageRecord) {
        records.removeAll { $0.id == record.id }
    }

    func clearAll() {
        records.removeAll()
    }
}

struct CustomCategory: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var prompt: String

    init(id: UUID = UUID(), name: String, prompt: String) {
        self.id = id
        self.name = name
        self.prompt = prompt
    }
}

class CustomCategoryStore: ObservableObject {
    static let shared = CustomCategoryStore()

    @Published var categories: [CustomCategory] = [] {
        didSet { save() }
    }

    private let key = "custom_categories"

    init() {
        load()
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let cats = try? JSONDecoder().decode([CustomCategory].self, from: data) else { return }
        categories = cats
    }

    func save() {
        guard let data = try? JSONEncoder().encode(categories) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func add(name: String, prompt: String) {
        categories.append(CustomCategory(name: name, prompt: prompt))
    }

    func delete(_ cat: CustomCategory) {
        categories.removeAll { $0.id == cat.id }
    }
}

struct ClipboardItem: Identifiable, Codable, Equatable {
    let id: UUID
    var content: String
    var contentType: ContentType
    var category: Category
    var customCategory: String?
    var timestamp: Date
    var isFavorite: Bool
    var aiSummary: String?

    var displayCategory: String {
        if let customCategory, !customCategory.isEmpty {
            return customCategory
        }
        return category.label
    }

    enum ContentType: String, Codable {
        case text
        case image
        case file
    }

    enum Category: String, Codable, CaseIterable {
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

    init(id: UUID = UUID(), content: String, contentType: ContentType = .text, category: Category = .other, customCategory: String? = nil, timestamp: Date = Date(), isFavorite: Bool = false, aiSummary: String? = nil) {
        self.id = id
        self.content = content
        self.contentType = contentType
        self.category = category
        self.customCategory = customCategory
        self.timestamp = timestamp
        self.isFavorite = isFavorite
        self.aiSummary = aiSummary
    }

    static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool {
        lhs.id == rhs.id
    }
}

extension ClipboardItem {
    var displayContent: String {
        switch contentType {
        case .text:
            return content.count > 200 ? String(content.prefix(200)) + "..." : content
        case .image:
            return "[图片]"
        case .file:
            return content
        }
    }

    var timeAgo: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: timestamp, relativeTo: Date())
    }

    static func categorize(_ text: String) -> Category {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .other }

        let range = NSRange(trimmed.startIndex..., in: trimmed)
        func matches(_ pattern: String) -> Bool {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
            return regex.firstMatch(in: trimmed, range: range) != nil
        }

        if matches(#"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#) {
            return .email
        }
        if matches(#"(https?://|www\.)[^\s]+|\blocalhost(:\d+)?(/[^\s]*)?\b|\b\d{1,3}(\.\d{1,3}){3}(:\d+|/)[^\s]*|\b[a-z0-9][a-z0-9.-]*\.(com|cn|org|net|io|dev|app|co|uk|edu|gov|me|ai|xyz|info|biz|top|shop|site|online|tech)(:\d+)?(/[^\s]*)?\b"#) {
            return .url
        }

        let codePatterns = [
            #"^(npm|yarn|pnpm|git|brew|pip3?|python3?|node|curl|ssh|sudo|docker|kubectl|cd|ls|cat|grep|rg)\b"#,
            #"\b(select|insert|update|delete|create|drop|alter)\b.*\b(from|where|table|into|set|values)\b"#,
            #"\b(function|func|def|class|import|var|let|const|if|else|for|while|return|async|await)\b"#,
            #"[{}]"#,
            #"^\[[^\]]*(,|:)[^\]]*\]$"#,
            #"[A-Za-z_][A-Za-z0-9_]*\([^)]*\)"#,
            #"[A-Za-z_][A-Za-z0-9_]*\s*(==|!=|<=|>=|=>|=)"#
        ]
        if codePatterns.contains(where: matches) {
            return .code
        }

        let normalizedNumber = trimmed.replacingOccurrences(of: ",", with: "")
        if Double(normalizedNumber) != nil ||
            matches(#"^\+?\d[\d\s\-()]{6,}\d$"#) ||
            matches(#"^\d{1,3}(\.\d{1,3}){3}$"#) ||
            matches(#"^\d{4}[-/年]\d{1,2}[-/月]\d{1,2}([日\sT]+\d{1,2}:\d{2}(:\d{2})?)?$"#) {
            return .number
        }

        let hasChinese = trimmed.contains { ("\u{4E00}"..."\u{9FFF}") ~= $0 }
        let hasEnglish = trimmed.contains { $0.isASCII && $0.isLetter }

        if hasChinese && hasEnglish { return .mixed }
        if hasChinese { return .chinese }
        if hasEnglish { return .english }

        return .other
    }
}
