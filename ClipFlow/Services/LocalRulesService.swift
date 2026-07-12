import Foundation

struct LocalRulesService: Sendable {
    static let providerLabel = "ClipFlow Local Rules"

    func categorize(
        _ text: String,
        categories: [PersistedCustomCategory]
    ) -> PersistedCustomCategory? {
        let normalizedText = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased(with: Locale(identifier: "en_US_POSIX"))
        guard !normalizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let scored = categories.compactMap { category -> (PersistedCustomCategory, Int)? in
            let score = tokens(for: category).reduce(0) { total, token in
                total + tokenScore(token, in: normalizedText)
            }
            return score > 0 ? (category, score) : nil
        }

        return scored.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.sortOrder != $1.0.sortOrder { return $0.0.sortOrder < $1.0.sortOrder }
            return $0.0.id.uuidString < $1.0.id.uuidString
        }.first?.0
    }

    func rewrite(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let compact = trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let topic = compact.count > 80 ? String(compact.prefix(80)) + "..." : compact
        if compact.contains(where: { ("\u{4E00}"..."\u{9FFF}") ~= $0 }) {
            return """
            拓写草稿：
            背景：\(topic)
            下一步：整理成可执行事项，标出时间、负责人和优先级。
            """
        }
        return """
        Expanded draft:
        Background: \(topic)
        Next step: Turn this into clear actions with owner, timing, and priority.
        """
    }
}

private extension LocalRulesService {
    func tokens(for category: PersistedCustomCategory) -> [String] {
        let raw = "\(category.name) \(category.prompt)"
            .replacingOccurrences(of: "包含", with: " ")
            .replacingOccurrences(of: "属于", with: " ")
        let separators = CharacterSet(charactersIn: " \n\t,，、.。;；:：/\\|()（）[]【】\"'")
        return raw
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
            .flatMap { [$0] + aliases(for: $0) }
    }

    func tokenScore(_ token: String, in text: String) -> Int {
        let normalized = token.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased(with: Locale(identifier: "en_US_POSIX"))
        guard !normalized.isEmpty else { return 0 }
        if containsCJK(normalized) {
            guard normalized.count >= 2, text.contains(normalized) else { return 0 }
            return 1
        }
        guard latinToken(normalized, appearsIn: text) else { return 0 }
        return 1
    }

    func latinToken(_ token: String, appearsIn text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        let pattern = #"(?<![A-Za-z0-9_])"# + escaped + #"(?![A-Za-z0-9_])"#
        return (try? NSRegularExpression(pattern: pattern))
            .flatMap {
                $0.firstMatch(
                    in: text,
                    range: NSRange(text.startIndex..., in: text)
                )
            } != nil
    }

    func containsCJK(_ text: String) -> Bool {
        text.contains { ("\u{4E00}"..."\u{9FFF}") ~= $0 }
    }

    func aliases(for token: String) -> [String] {
        switch token.lowercased(with: Locale(identifier: "en_US_POSIX")) {
        case "meeting", "会议", "纪要":
            return ["开会", "同步", "评审", "议程", "复盘"]
        case "project", "项目":
            return ["需求", "进度", "排期", "里程碑", "交付"]
        case "code", "api", "swift", "代码", "函数":
            return ["api", "swift", "json", "接口", "日志", "异常", "报错", "修复", "bug"]
        default:
            return []
        }
    }
}
