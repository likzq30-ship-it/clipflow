import XCTest
@testable import ClipFlow

final class AIServiceTests: XCTestCase {
    func testDisabledProviderMakesNoHTTPOrKeychainCall() async {
        let http = MockHTTPClient()
        let keychain = InMemoryKeychainCredentialStore()
        let service = AIService(http: http, keychain: keychain, localRules: LocalRulesService())

        do {
            _ = try await service.perform(.fixture(), provider: .disabled)
            XCTFail("disabled provider must reject work")
        } catch {
            XCTAssertEqual(error as? AIError, .disabled)
        }
        let availability = await service.checkAvailability(provider: .disabled)
        let requestCount = await http.requestCount
        let keychainReadCount = await keychain.readCount
        XCTAssertEqual(availability, .disabled)
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(keychainReadCount, 0)
    }

    func testHTTPStatusContentLengthAndEmptyResponseAreTypedErrors() async {
        let http = MockHTTPClient()
        let service = AIService(
            http: http,
            keychain: InMemoryKeychainCredentialStore(),
            localRules: LocalRulesService()
        )
        await http.enqueueJSON([:], statusCode: 503)
        await http.enqueueJSON(["response": "too large"], headers: ["Content-Length": "1048577"])
        await http.enqueueJSON(["response": "   "])
        let provider = AIProviderConfiguration.localOllama(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            model: "fixture"
        )

        await XCTAssertThrowsAIError(.httpStatus(503)) {
            _ = try await service.perform(.fixture(), provider: provider)
        }
        await XCTAssertThrowsAIError(.responseTooLarge) {
            _ = try await service.perform(.fixture(), provider: provider)
        }
        await XCTAssertThrowsAIError(.emptyResponse) {
            _ = try await service.perform(.fixture(), provider: provider)
        }
    }

    func testCategorizeRejectsResponseOutsideAllowedCategories() async {
        let http = MockHTTPClient()
        let service = AIService(
            http: http,
            keychain: InMemoryKeychainCredentialStore(),
            localRules: LocalRulesService()
        )
        await http.enqueueJSON(["response": "Finance"])
        let request = AIRequest(
            itemID: UUID(),
            operation: .categorize,
            text: "legal contract",
            allowedCategories: [.fixture(name: "Legal", sortOrder: 0)]
        )
        let provider = AIProviderConfiguration.localOllama(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            model: "fixture"
        )

        await XCTAssertThrowsAIError(.invalidCategory) {
            _ = try await service.perform(request, provider: provider)
        }
    }

    func testRemoteProviderReadsKeychainOnlyAfterConsentAndAddsAuthorization() async throws {
        let http = MockHTTPClient()
        let keychain = InMemoryKeychainCredentialStore()
        let url = URL(string: "https://ai.example.com")!
        let origin = try XCTUnwrap(AIConsentOrigin(url: url))
        try await keychain.setCredential("token-canary", for: origin)
        let service = AIService(http: http, keychain: keychain, localRules: LocalRulesService())
        await http.enqueueJSON(["response": "summary"])

        _ = try await service.perform(
            .fixture(),
            provider: .remoteHTTPS(baseURL: url, model: "fixture", consent: origin)
        )

        let readOrigins = await keychain.readOrigins
        let authorization = await http.lastRequest?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(readOrigins, [origin])
        XCTAssertEqual(authorization, "Bearer token-canary")
    }

    func testRemoteAvailabilityReadsKeychainOnlyAfterConsentAndAddsAuthorization() async throws {
        let http = MockHTTPClient()
        let keychain = InMemoryKeychainCredentialStore()
        let url = URL(string: "https://ai.example.com")!
        let origin = try XCTUnwrap(AIConsentOrigin(url: url))
        try await keychain.setCredential("availability-token", for: origin)
        let service = AIService(http: http, keychain: keychain, localRules: LocalRulesService())
        await http.enqueueJSON(["models": []])

        let availability = await service.checkAvailability(
            provider: .remoteHTTPS(baseURL: url, model: "fixture", consent: origin)
        )

        let readOrigins = await keychain.readOrigins
        let authorization = await http.lastRequest?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(availability, .available)
        XCTAssertEqual(readOrigins, [origin])
        XCTAssertEqual(authorization, "Bearer availability-token")
    }

    func testRemoteAvailabilityRejectsMismatchedConsentBeforeReadingKeychain() async {
        let http = MockHTTPClient()
        let keychain = InMemoryKeychainCredentialStore()
        let url = URL(string: "https://ai.example.com")!
        let wrongOrigin = AIConsentOrigin(scheme: "https", host: "other.example.com", port: 443)
        let service = AIService(http: http, keychain: keychain, localRules: LocalRulesService())

        let availability = await service.checkAvailability(
            provider: .remoteHTTPS(baseURL: url, model: "fixture", consent: wrongOrigin)
        )

        let requestCount = await http.requestCount
        let readCount = await keychain.readCount
        XCTAssertEqual(availability, .unavailable(code: .aiEndpoint))
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(readCount, 0)
    }

    func testLocalProviderDoesNotReadKeychainOrSendAuthorization() async throws {
        let http = MockHTTPClient()
        let keychain = InMemoryKeychainCredentialStore()
        let service = AIService(http: http, keychain: keychain, localRules: LocalRulesService())
        await http.enqueueJSON(["response": "summary"])

        _ = try await service.perform(
            .fixture(),
            provider: .localOllama(baseURL: URL(string: "http://127.0.0.1:11434")!, model: "fixture")
        )

        let readCount = await keychain.readCount
        let authorization = await http.lastRequest?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(readCount, 0)
        XCTAssertNil(authorization)
    }

    func testTimeoutAndCancellationAreSeparateErrors() async {
        let http = MockHTTPClient()
        let service = AIService(http: http, keychain: InMemoryKeychainCredentialStore(), localRules: LocalRulesService())
        let provider = AIProviderConfiguration.localOllama(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            model: "fixture"
        )
        await http.enqueue(.failure(URLError(.timedOut)))
        await http.enqueue(.failure(CancellationError()))

        await XCTAssertThrowsAIError(.timedOut) {
            _ = try await service.perform(.fixture(), provider: provider)
        }
        await XCTAssertThrowsAIError(.cancelled) {
            _ = try await service.perform(.fixture(), provider: provider)
        }
    }

    func testLocalRulesUseWordBoundariesAndSortOrderTieBreak() {
        let rules = LocalRulesService()
        let project = PersistedCustomCategory.fixture(name: "Project", sortOrder: 1)
        let code = PersistedCustomCategory.fixture(name: "Code", sortOrder: 0)

        XCTAssertNil(rules.categorize("projector lamp", categories: [project]))
        XCTAssertEqual(
            rules.categorize("API project handoff", categories: [project, code])?.id,
            code.id
        )
        XCTAssertEqual(rules.rewrite("ship it")?.contains("Expanded draft"), true)
    }

    func testLocalRulesMatchCJKTokensButIgnoreSingleCharacterCJKTokens() {
        let rules = LocalRulesService()
        let meeting = PersistedCustomCategory.fixture(name: "会议 纪要", sortOrder: 0)
        let singleCharacter = PersistedCustomCategory.fixture(name: "项", sortOrder: 0)

        XCTAssertEqual(
            rules.categorize("请整理会议纪要并发给团队", categories: [meeting])?.id,
            meeting.id
        )
        XCTAssertNil(rules.categorize("项目排期", categories: [singleCharacter]))
    }
}

func XCTAssertThrowsAIError(
    _ expected: AIError,
    operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? AIError, expected, file: file, line: line)
    }
}
