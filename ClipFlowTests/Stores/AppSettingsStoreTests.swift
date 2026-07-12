import XCTest
@testable import ClipFlow

@MainActor
final class AppSettingsStoreTests: XCTestCase {
    func testDefaultsMatchSpecification() {
        let store = makeSettingsStore()

        XCTAssertEqual(store.retentionPolicy, .days(15))
        XCTAssertEqual(store.maxCaptureBytes, 1_048_576)
        XCTAssertEqual(store.aiProviderKind, .disabled)
        XCTAssertTrue(store.sensitiveContentProtectionEnabled)
        XCTAssertEqual(store.privacyConfiguration, .standard)
    }

    func testRetentionRejectsOutOfRangeDays() {
        let store = makeSettingsStore()

        XCTAssertThrowsError(try store.setRetentionDays(0))
        XCTAssertThrowsError(try store.setRetentionDays(366))
    }

    func testPrivacySettingsPersistAndBuildConfiguration() throws {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = AppSettingsStore(userDefaults: defaults)

        try store.setRetentionDays(30)
        try store.setMaxCaptureBytes(4_096)
        store.setExcludedBundleIDs(["com.example.private"])
        store.setSensitiveContentProtectionEnabled(false)

        let reloaded = AppSettingsStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.retentionPolicy, .days(30))
        XCTAssertEqual(reloaded.maxCaptureBytes, 4_096)
        XCTAssertEqual(reloaded.excludedBundleIDs, ["com.example.private"])
        XCTAssertFalse(reloaded.sensitiveContentProtectionEnabled)
        XCTAssertEqual(
            reloaded.privacyConfiguration,
            PrivacyConfiguration(
                excludedBundleIDs: ["com.example.private"],
                maxUTF8Bytes: 4_096,
                detectsSensitiveContent: false
            )
        )
    }

    func testRemoteConsentIsNormalizedGrantedAndRevokedByOriginChanges() throws {
        let store = makeSettingsStore()
        store.setAIProvider(.remoteHTTPS)
        store.setAIEndpoint(URL(string: "https://EXAMPLE.com:8443/v1/chat")!)

        let origin = try store.requestRemoteConsent()
        XCTAssertEqual(origin.scheme, "https")
        XCTAssertEqual(origin.host, "example.com")
        XCTAssertEqual(origin.port, 8443)
        XCTAssertNil(store.aiConsentOrigin)

        try store.grantConsent(for: origin)
        XCTAssertEqual(store.aiConsentOrigin, origin)

        store.setAIEndpoint(URL(string: "https://example.com:8443/other")!)
        XCTAssertEqual(store.aiConsentOrigin, origin)

        store.setAIEndpoint(URL(string: "https://example.com/v1/chat")!)
        XCTAssertNil(store.aiConsentOrigin)
        XCTAssertThrowsError(try store.grantConsent(for: origin))
    }

    func testRemoteConsentRequiresRemoteHTTPSProviderAndEndpoint() {
        let store = makeSettingsStore()

        XCTAssertThrowsError(try store.requestRemoteConsent())

        store.setAIProvider(.localOllama)
        store.setAIEndpoint(URL(string: "http://localhost:11434")!)
        XCTAssertThrowsError(try store.requestRemoteConsent())

        store.setAIProvider(.remoteHTTPS)
        store.setAIEndpoint(URL(string: "http://example.com")!)
        XCTAssertThrowsError(try store.requestRemoteConsent())
    }

    func testPersistedConsentIsDroppedForLocalProvider() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let endpoint = URL(string: "http://localhost:11434")!
        let origin = try XCTUnwrap(AIConsentOrigin(url: endpoint))
        defaults.set(AIProviderKind.localOllama.rawValue, forKey: "clipflow.ai.providerKind")
        defaults.set(endpoint.absoluteString, forKey: "clipflow.ai.endpoint")
        defaults.set(try JSONEncoder().encode(origin), forKey: "clipflow.ai.consentOrigin")

        let store = AppSettingsStore(userDefaults: defaults)

        XCTAssertEqual(store.aiProviderKind, .localOllama)
        XCTAssertNil(store.aiConsentOrigin)
        XCTAssertNil(defaults.object(forKey: "clipflow.ai.consentOrigin"))
    }

    func testDisabledProviderDropsStaleEndpointAndConsentOnStartup() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let endpoint = URL(string: "https://example.com/v1/chat")!
        let origin = try XCTUnwrap(AIConsentOrigin(url: endpoint))
        defaults.set(AIProviderKind.disabled.rawValue, forKey: "clipflow.ai.providerKind")
        defaults.set(endpoint.absoluteString, forKey: "clipflow.ai.endpoint")
        defaults.set(try JSONEncoder().encode(origin), forKey: "clipflow.ai.consentOrigin")

        let store = AppSettingsStore(userDefaults: defaults)

        XCTAssertEqual(store.aiProviderKind, .disabled)
        XCTAssertNil(store.aiEndpoint)
        XCTAssertNil(store.aiConsentOrigin)
        XCTAssertNil(defaults.object(forKey: "clipflow.ai.endpoint"))
        XCTAssertNil(defaults.object(forKey: "clipflow.ai.consentOrigin"))
    }

    func testLegacySettingsAreConsumedOnlyAfterSuccessfulMigration() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(true, forKey: "ai_integration_enabled")
        defaults.set("http://localhost:11434", forKey: "ollama_base_url")
        defaults.set(Data("usage".utf8), forKey: "api_usage_records")
        defaults.set(Data("categories".utf8), forKey: "custom_categories")
        let store = AppSettingsStore(userDefaults: defaults)

        store.consumeLegacySettingsAfterSuccessfulMigration(
            LegacySettingsSnapshot(
                categories: [],
                hadAIEnabled: true,
                hadOllamaURL: true,
                hadAPIUsageRecords: true
            )
        )

        XCTAssertNil(defaults.object(forKey: "ai_integration_enabled"))
        XCTAssertNil(defaults.object(forKey: "ollama_base_url"))
        XCTAssertNil(defaults.object(forKey: "api_usage_records"))
        XCTAssertNil(defaults.object(forKey: "custom_categories"))
        XCTAssertEqual(store.aiProviderKind, .disabled)
        XCTAssertNil(store.aiConsentOrigin)
    }
}

private extension AppSettingsStoreTests {
    func makeSettingsStore() -> AppSettingsStore {
        AppSettingsStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    }
}
