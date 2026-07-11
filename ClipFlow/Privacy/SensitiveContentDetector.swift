import Foundation

struct SensitiveContentDetector: Sendable {
    private static let privateKeyPattern =
        #"-----BEGIN(?: [A-Z0-9]+)* PRIVATE KEY-----"#
    private static let prefixedTokenPattern =
        #"(?<![A-Za-z0-9_-])(?:sk-|ghp_|github_pat_|xoxb-|xoxp-|xoxa-|xoxr-|xoxs-)[A-Za-z0-9_-]{20,}(?![A-Za-z0-9_-])"#
    private static let awsAccessKeyPattern =
        #"(?<![A-Za-z0-9])AKIA[A-Z0-9]{16}(?![A-Za-z0-9])"#
    private static let cardCandidatePattern = #"[0-9][0-9 -]*[0-9]"#

    func detect(in text: String) -> SensitiveContentKind? {
        if contains(pattern: Self.privateKeyPattern, in: text) {
            return .privateKey
        }

        if contains(pattern: Self.prefixedTokenPattern, in: text)
            || contains(pattern: Self.awsAccessKeyPattern, in: text) {
            return .apiToken
        }

        if containsLuhnValidCardCandidate(in: text) {
            return .paymentCard
        }

        return nil
    }
}

private extension SensitiveContentDetector {
    func contains(pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    func containsLuhnValidCardCandidate(in text: String) -> Bool {
        guard let expression = try? NSRegularExpression(
            pattern: Self.cardCandidatePattern
        ) else {
            return false
        }

        let range = NSRange(text.startIndex..., in: text)
        var foundValidCandidate = false
        expression.enumerateMatches(in: text, range: range) { match, _, stop in
            guard let match else {
                return
            }
            guard let candidateRange = Range(match.range, in: text) else {
                return
            }
            let digits = text[candidateRange].compactMap(\.wholeNumberValue)
            guard (13...19).contains(digits.count) else {
                return
            }
            guard passesLuhn(digits) else {
                return
            }
            foundValidCandidate = true
            stop.pointee = true
        }
        return foundValidCandidate
    }

    func passesLuhn(_ digits: [Int]) -> Bool {
        let parity = digits.count % 2
        let sum = digits.enumerated().reduce(into: 0) { total, pair in
            let (index, digit) = pair
            var value = digit
            if index % 2 == parity {
                value *= 2
                if value > 9 {
                    value -= 9
                }
            }
            total += value
        }
        return sum % 10 == 0
    }
}
