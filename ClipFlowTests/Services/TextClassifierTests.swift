import XCTest
@testable import ClipFlow

final class TextClassifierTests: XCTestCase {
    func testClassifiesExistingTextCategoriesDeterministically() async {
        let classifier = TextClassifier()
        let cases: [(String, ClipboardItem.Category)] = [
            ("", .other),
            ("🌟✨", .other),
            ("你好世界", .chinese),
            ("plain English sentence", .english),
            ("你好 Swift", .mixed),
            ("Contact me at a.b+tag@example.co.uk", .email),
            ("https://example.com/path?q=1", .url),
            ("docs.example.xyz/guide", .url),
            ("localhost:3000/api", .url),
            ("127.0.0.1:8000/api", .url),
            ("npm install sqlite3", .code),
            ("git commit -m fix", .code),
            ("SELECT * FROM users WHERE id = 1", .code),
            ("let value = makeValue()", .code),
            ("+86 138 0013 8000", .number),
            ("2026-06-30 12:30", .number),
            ("192.168.1.1", .number),
            ("hello (world)", .english),
            ("see [attachment]", .english),
            ("constellation; stars", .english)
        ]

        for (text, expected) in cases {
            let actual = await classifier.classify(text)
            XCTAssertEqual(actual, expected, text)
        }
    }

    func testAPIKeywordUsesWordBoundary() async {
        let classifier = TextClassifier()

        let api = await classifier.classify("API")
        let capital = await classifier.classify("capital expenditure")

        XCTAssertEqual(api, .code)
        XCTAssertEqual(capital, .english)
    }

    func testConcurrentCallsRemainValueOnlyAndDeterministic() async {
        let classifier = TextClassifier()

        async let chinese = classifier.classify("文本")
        async let english = classifier.classify("text")
        async let code = classifier.classify("func make() {}")

        let values = await [chinese, english, code]
        XCTAssertEqual(values, [.chinese, .english, .code])
    }
}
