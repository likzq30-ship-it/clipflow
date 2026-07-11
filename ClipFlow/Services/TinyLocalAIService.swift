import Foundation

struct TinyLocalAIService {
    static let shared = TinyLocalAIService()
    static let modelName = "ClipFlow Tiny Local"

    private init() {}

    func categorizeContent(_ text: String, customCategories: [CustomCategory]) -> String? {
        let content = normalize(text)
        guard !content.isEmpty, !customCategories.isEmpty else { return nil }

        let scored = customCategories.compactMap { category -> (name: String, score: Int)? in
            let tokens = categoryTokens(category)
            let score = tokens.reduce(0) { total, token in
                total + tokenScore(token, in: content)
            }
            return score > 0 ? (category.name, score) : nil
        }

        return scored.sorted { $0.score > $1.score }.first?.name
    }

    func rewrite(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let compact = trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let points = splitPoints(compact)
        let isChinese = compact.contains { ("\u{4E00}"..."\u{9FFF}") ~= $0 }
        let topic = clipped(points.first ?? compact, limit: 80)

        // ponytail: template rewrite keeps the bundle tiny; swap in GGUF/Core ML if real generation quality matters.
        if isChinese {
            if looksLikeMeeting(compact) {
                return """
                拓写草稿：
                背景：围绕「\(topic)」先对齐当前进度、阻塞点和预期结果。
                议程：1. 确认现状；2. 梳理风险；3. 明确下一步负责人和时间。
                下一步：会前准备相关资料，会后同步结论和待办。
                """
            }

            if looksLikeCode(compact) {
                return """
                拓写草稿：
                背景：当前问题是「\(topic)」，需要先确认复现路径和影响范围。
                排查：检查输入、日志、异常栈和最近改动，优先定位最小失败点。
                下一步：给出修复方案，补一个能防回退的检查。
                """
            }

            return """
            拓写草稿：
            背景：\(topic)
            补充说明：\(points.dropFirst().joined(separator: "；").nilIfEmpty ?? "可以继续补充目标、约束和预期结果。")
            下一步：整理成可执行事项，标出时间、负责人和优先级。
            """
        }

        return """
        Expanded draft:
        Background: \(topic)
        Context: \(points.dropFirst().joined(separator: "; ").nilIfEmpty ?? "Add the goal, constraints, and expected outcome.")
        Next step: Turn this into clear actions with owner, timing, and priority.
        """
    }

    private func categoryTokens(_ category: CustomCategory) -> [String] {
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

    private func splitPoints(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: "。！？!?；;\n")
        let parts = text
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(parts.prefix(4))
    }

    private func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func tokenScore(_ token: String, in content: String) -> Int {
        let normalized = normalize(token)
        guard !normalized.isEmpty, content.contains(normalized) else { return 0 }
        return max(2, normalized.count)
    }

    private func aliases(for token: String) -> [String] {
        switch normalize(token) {
        case "会议", "纪要":
            return ["开会", "同步", "评审", "议程", "参会", "复盘", "讨论"]
        case "项目":
            return ["需求", "进度", "排期", "里程碑", "交付"]
        case "代码", "函数", "api", "swift":
            return ["接口", "日志", "异常", "报错", "修复", "bug", "返回", "栈"]
        default:
            return []
        }
    }

    private func looksLikeMeeting(_ text: String) -> Bool {
        containsAny(text, ["会议", "开会", "同步", "评审", "议程", "纪要", "参会", "复盘", "讨论"])
    }

    private func looksLikeCode(_ text: String) -> Bool {
        containsAny(normalize(text), ["代码", "函数", "api", "接口", "日志", "异常", "报错", "bug", "swift", "json", "返回", "栈"])
    }

    private func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private func clipped(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "..." : text
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
