import XCTest
@testable import ClipFlow

final class AIEndpointValidatorTests: XCTestCase {
    func testLocalProviderRejectsNonLoopbackHost() {
        XCTAssertThrowsError(
            try AIEndpointValidator.validateLocal(URL(string: "http://192.168.1.5:11434")!)
        )
    }

    func testLocalProviderAcceptsEveryLoopbackForm() {
        let values = [
            URL(string: "http://localhost:11434")!,
            URL(string: "http://127.0.0.1:11434")!,
            URL(string: "http://[::1]:11434")!
        ]
        for value in values {
            XCTAssertNoThrow(try AIEndpointValidator.validateLocal(value))
        }
    }

    func testEndpointValidatorRejectsAmbiguousOrCredentialedURLs() {
        let values = [
            "file://localhost",
            "http://localhost.evil:11434",
            "http://user:pass@localhost:11434",
            "http://localhost:11434/api/tags",
            "http://localhost:11434?token=secret",
            "http://localhost:11434#fragment"
        ]
        for value in values {
            XCTAssertThrowsError(try AIEndpointValidator.validateLocal(URL(string: value)!))
        }
    }

    func testRemoteProviderRequiresHTTPSAndMatchingConsent() {
        let url = URL(string: "https://ai.example.com:8443")!
        XCTAssertThrowsError(
            try AIEndpointValidator.validateRemote(url, consent: nil)
        )
        XCTAssertNoThrow(
            try AIEndpointValidator.validateRemote(
                url,
                consent: AIConsentOrigin(url: url)
            )
        )
        XCTAssertThrowsError(
            try AIEndpointValidator.validateRemote(
                URL(string: "http://ai.example.com:8443")!,
                consent: AIConsentOrigin(url: url)
            )
        )
    }

    func testOriginNormalizationUsesDefaultPortsAndIPv6() throws {
        XCTAssertEqual(
            AIConsentOrigin(url: URL(string: "https://AI.example.com")!),
            AIConsentOrigin(scheme: "https", host: "ai.example.com", port: 443)
        )
        XCTAssertEqual(
            AIConsentOrigin(url: URL(string: "http://[::1]:11434")!),
            AIConsentOrigin(scheme: "http", host: "::1", port: 11434)
        )
        let normalized = try AIEndpointValidator.validateLocal(
            URL(string: "http://localhost:11434/")!
        )
        XCTAssertEqual(normalized.absoluteString, "http://localhost:11434")
    }

    @MainActor
    func testSettingsBuildsValidatedProviderConfiguration() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = AppSettingsStore(userDefaults: defaults)
        XCTAssertEqual(try store.validatedAIProviderConfiguration(), .disabled)

        store.setAIProvider(.localOllama)
        store.setAIEndpoint(URL(string: "http://127.0.0.1:11434")!)
        store.setAIModel("fixture")
        XCTAssertEqual(
            try store.validatedAIProviderConfiguration(),
            .localOllama(baseURL: URL(string: "http://127.0.0.1:11434")!, model: "fixture")
        )
    }
}
