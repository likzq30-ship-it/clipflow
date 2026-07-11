import Foundation

protocol TextClassifying: Sendable {
    func classify(_ text: String) async -> ClipboardItem.Category
}

actor TextClassifier: TextClassifying {
    private let emailExpression: NSRegularExpression
    private let urlExpression: NSRegularExpression
    private let codeExpressions: [NSRegularExpression]
    private let phoneExpression: NSRegularExpression
    private let ipv4Expression: NSRegularExpression
    private let dateExpression: NSRegularExpression

    init() {
        emailExpression = Self.compile(
            #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#
        )
        urlExpression = Self.compile(
            #"(https?://|www\.)[^\s]+|\blocalhost(:\d+)?(/[^\s]*)?\b|\b\d{1,3}(\.\d{1,3}){3}(:\d+|/)[^\s]*|\b[a-z0-9][a-z0-9.-]*\.(com|cn|org|net|io|dev|app|co|uk|edu|gov|me|ai|xyz|info|biz|top|shop|site|online|tech)(:\d+)?(/[^\s]*)?\b"#
        )
        codeExpressions = [
            #"^(npm|yarn|pnpm|git|brew|pip3?|python3?|node|curl|ssh|sudo|docker|kubectl|cd|ls|cat|grep|rg)\b"#,
            #"\b(select|insert|update|delete|create|drop|alter)\b.*\b(from|where|table|into|set|values)\b"#,
            #"\b(function|func|def|class|import|var|let|const|if|else|for|while|return|async|await|api)\b"#,
            #"[{}]"#,
            #"^\[[^\]]*(,|:)[^\]]*\]$"#,
            #"[A-Za-z_][A-Za-z0-9_]*\([^)]*\)"#,
            #"[A-Za-z_][A-Za-z0-9_]*\s*(==|!=|<=|>=|=>|=)"#
        ].map(Self.compile)
        phoneExpression = Self.compile(#"^\+?\d[\d\s\-()]{6,}\d$"#)
        ipv4Expression = Self.compile(#"^\d{1,3}(\.\d{1,3}){3}$"#)
        dateExpression = Self.compile(
            #"^\d{4}[-/年]\d{1,2}[-/月]\d{1,2}([日\sT]+\d{1,2}:\d{2}(:\d{2})?)?$"#
        )
    }

    func classify(_ text: String) -> ClipboardItem.Category {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .other
        }

        if matches(emailExpression, in: trimmed) {
            return .email
        }
        if matches(urlExpression, in: trimmed) {
            return .url
        }
        if codeExpressions.contains(where: { matches($0, in: trimmed) }) {
            return .code
        }

        let normalizedNumber = trimmed.replacingOccurrences(of: ",", with: "")
        if Double(normalizedNumber) != nil
            || matches(phoneExpression, in: trimmed)
            || matches(ipv4Expression, in: trimmed)
            || matches(dateExpression, in: trimmed) {
            return .number
        }

        let hasChinese = trimmed.contains { ("\u{4E00}"..."\u{9FFF}") ~= $0 }
        let hasEnglish = trimmed.contains { $0.isASCII && $0.isLetter }

        if hasChinese && hasEnglish {
            return .mixed
        }
        if hasChinese {
            return .chinese
        }
        if hasEnglish {
            return .english
        }
        return .other
    }
}

private extension TextClassifier {
    static func compile(_ pattern: String) -> NSRegularExpression {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            preconditionFailure("Invalid built-in text-classifier expression")
        }
        return expression
    }

    func matches(_ expression: NSRegularExpression, in text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return expression.firstMatch(in: text, range: range) != nil
    }
}
