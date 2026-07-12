import Combine
import Foundation

@MainActor
final class AppSettingsStore: ObservableObject {
    @Published private(set) var retentionPolicy: RetentionPolicy
    @Published private(set) var maxCaptureBytes: Int
    @Published private(set) var excludedBundleIDs: Set<String>
    @Published private(set) var sensitiveContentProtectionEnabled: Bool
    @Published private(set) var shortcut: ShortcutMapping
    @Published private(set) var aiProviderKind: AIProviderKind
    @Published private(set) var aiEndpoint: URL?
    @Published private(set) var aiModel: String
    @Published private(set) var aiConsentOrigin: AIConsentOrigin?

    private let userDefaults: UserDefaults
    private(set) var pendingLegacySettingsSnapshot: LegacySettingsSnapshot?

    var privacyConfiguration: PrivacyConfiguration {
        PrivacyConfiguration(
            excludedBundleIDs: excludedBundleIDs,
            maxUTF8Bytes: maxCaptureBytes,
            detectsSensitiveContent: sensitiveContentProtectionEnabled
        )
    }

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults

        let storedDays = userDefaults.object(forKey: Keys.retentionDays) as? Int
        let storesForever = userDefaults.bool(forKey: Keys.retentionForever)
        if storesForever {
            retentionPolicy = .forever
        } else if let storedDays, (1...365).contains(storedDays) {
            retentionPolicy = .days(storedDays)
        } else {
            retentionPolicy = .days(15)
        }

        let storedMaxCaptureBytes = userDefaults.object(forKey: Keys.maxCaptureBytes) as? Int
        maxCaptureBytes = storedMaxCaptureBytes.flatMap { $0 > 0 ? $0 : nil } ?? 1_048_576
        excludedBundleIDs = Set(userDefaults.stringArray(forKey: Keys.excludedBundleIDs) ?? [])
        if userDefaults.object(forKey: Keys.sensitiveContentProtectionEnabled) == nil {
            sensitiveContentProtectionEnabled = true
        } else {
            sensitiveContentProtectionEnabled = userDefaults.bool(
                forKey: Keys.sensitiveContentProtectionEnabled
            )
        }

        if let data = userDefaults.data(forKey: Keys.shortcut),
           let decoded = try? JSONDecoder().decode(ShortcutMapping.self, from: data) {
            shortcut = decoded
        } else {
            shortcut = .defaultShortcut
        }

        if let rawProvider = userDefaults.string(forKey: Keys.aiProviderKind),
           let provider = AIProviderKind(rawValue: rawProvider) {
            aiProviderKind = provider
        } else {
            aiProviderKind = .disabled
        }
        aiEndpoint = userDefaults.string(forKey: Keys.aiEndpoint).flatMap(URL.init(string:))
        aiModel = userDefaults.string(forKey: Keys.aiModel) ?? "qwen2.5:0.5b"
        pendingLegacySettingsSnapshot = Self.legacySnapshot(from: userDefaults)
        if let data = userDefaults.data(forKey: Keys.aiConsentOrigin),
           let decoded = try? JSONDecoder().decode(AIConsentOrigin.self, from: data),
           aiProviderKind == .remoteHTTPS,
           aiEndpoint?.scheme?.lowercased() == "https",
           decoded == aiEndpoint.flatMap(AIConsentOrigin.init(url:)) {
            aiConsentOrigin = decoded
        } else {
            aiConsentOrigin = nil
        }

        if aiProviderKind == .disabled {
            aiEndpoint = nil
            aiConsentOrigin = nil
        }
        if aiProviderKind != .remoteHTTPS {
            aiConsentOrigin = nil
        }
        persistAllCurrentValues()
    }

    func setRetentionDays(_ days: Int) throws {
        setRetentionPolicy(try RetentionPolicy.validatedDays(days))
    }

    func setRetentionPolicy(_ policy: RetentionPolicy) {
        retentionPolicy = policy
        persistRetentionPolicy(policy)
    }

    func setMaxCaptureBytes(_ bytes: Int) throws {
        guard bytes > 0 else {
            throw AppSettingsError.invalidMaxCaptureBytes(bytes)
        }
        maxCaptureBytes = bytes
        userDefaults.set(bytes, forKey: Keys.maxCaptureBytes)
    }

    func setExcludedBundleIDs(_ ids: Set<String>) {
        excludedBundleIDs = ids
        userDefaults.set(ids.sorted(), forKey: Keys.excludedBundleIDs)
    }

    func setSensitiveContentProtectionEnabled(_ enabled: Bool) {
        sensitiveContentProtectionEnabled = enabled
        userDefaults.set(enabled, forKey: Keys.sensitiveContentProtectionEnabled)
    }

    func commitShortcut(_ shortcut: ShortcutMapping) {
        self.shortcut = shortcut
        if let data = try? JSONEncoder().encode(shortcut) {
            userDefaults.set(data, forKey: Keys.shortcut)
        }
    }

    func setAIProvider(_ provider: AIProviderKind) {
        aiProviderKind = provider
        userDefaults.set(provider.rawValue, forKey: Keys.aiProviderKind)
        if provider == .disabled {
            aiEndpoint = nil
            revokeConsent()
            userDefaults.removeObject(forKey: Keys.aiEndpoint)
        } else if provider != .remoteHTTPS {
            revokeConsent()
        }
    }

    func setAIEndpoint(_ url: URL?) {
        let oldOrigin = aiConsentOrigin
        aiEndpoint = url
        if let url {
            userDefaults.set(url.absoluteString, forKey: Keys.aiEndpoint)
        } else {
            userDefaults.removeObject(forKey: Keys.aiEndpoint)
        }

        let newOrigin = url.flatMap(AIConsentOrigin.init(url:))
        if oldOrigin != nil && oldOrigin != newOrigin {
            revokeConsent()
        }
    }

    func setAIModel(_ model: String) {
        aiModel = model
        userDefaults.set(model, forKey: Keys.aiModel)
    }

    func requestRemoteConsent() throws -> AIConsentOrigin {
        guard aiProviderKind == .remoteHTTPS,
              let endpoint = aiEndpoint,
              endpoint.scheme?.lowercased() == "https",
              let origin = AIConsentOrigin(url: endpoint) else {
            throw AppSettingsError.invalidAIConsentOrigin
        }
        return origin
    }

    func grantConsent(for origin: AIConsentOrigin) throws {
        guard try requestRemoteConsent() == origin else {
            throw AppSettingsError.invalidAIConsentOrigin
        }
        aiConsentOrigin = origin
        if let data = try? JSONEncoder().encode(origin) {
            userDefaults.set(data, forKey: Keys.aiConsentOrigin)
        }
    }

    func revokeConsent() {
        aiConsentOrigin = nil
        userDefaults.removeObject(forKey: Keys.aiConsentOrigin)
    }

    func consumeLegacySettingsAfterSuccessfulMigration(_ snapshot: LegacySettingsSnapshot) {
        _ = snapshot
        pendingLegacySettingsSnapshot = nil
        userDefaults.removeObject(forKey: "custom_categories")
        userDefaults.removeObject(forKey: "api_usage_records")
        userDefaults.removeObject(forKey: "ai_integration_enabled")
        userDefaults.removeObject(forKey: "ollama_base_url")
        setAIProvider(.disabled)
    }

    func applyPrivacyConfiguration(_ configuration: PrivacyConfiguration) {
        maxCaptureBytes = configuration.maxUTF8Bytes
        excludedBundleIDs = configuration.excludedBundleIDs
        sensitiveContentProtectionEnabled = configuration.detectsSensitiveContent
        userDefaults.set(maxCaptureBytes, forKey: Keys.maxCaptureBytes)
        userDefaults.set(excludedBundleIDs.sorted(), forKey: Keys.excludedBundleIDs)
        userDefaults.set(
            sensitiveContentProtectionEnabled,
            forKey: Keys.sensitiveContentProtectionEnabled
        )
    }
}

enum AppSettingsError: Error, Equatable, Sendable {
    case invalidAIConsentOrigin
    case invalidMaxCaptureBytes(Int)
}

private extension AppSettingsStore {
    enum Keys {
        static let retentionDays = "clipflow.retention.days"
        static let retentionForever = "clipflow.retention.forever"
        static let maxCaptureBytes = "clipflow.privacy.maxCaptureBytes"
        static let excludedBundleIDs = "clipflow.privacy.excludedBundleIDs"
        static let sensitiveContentProtectionEnabled = "clipflow.privacy.sensitiveContent"
        static let shortcut = "clipflow.shortcut"
        static let aiProviderKind = "clipflow.ai.providerKind"
        static let aiEndpoint = "clipflow.ai.endpoint"
        static let aiModel = "clipflow.ai.model"
        static let aiConsentOrigin = "clipflow.ai.consentOrigin"
    }

    func persistAllCurrentValues() {
        persistRetentionPolicy(retentionPolicy)
        userDefaults.set(maxCaptureBytes, forKey: Keys.maxCaptureBytes)
        userDefaults.set(excludedBundleIDs.sorted(), forKey: Keys.excludedBundleIDs)
        userDefaults.set(
            sensitiveContentProtectionEnabled,
            forKey: Keys.sensitiveContentProtectionEnabled
        )
        commitShortcut(shortcut)
        userDefaults.set(aiProviderKind.rawValue, forKey: Keys.aiProviderKind)
        if let aiEndpoint {
            userDefaults.set(aiEndpoint.absoluteString, forKey: Keys.aiEndpoint)
        } else {
            userDefaults.removeObject(forKey: Keys.aiEndpoint)
        }
        userDefaults.set(aiModel, forKey: Keys.aiModel)
        if let aiConsentOrigin, let data = try? JSONEncoder().encode(aiConsentOrigin) {
            userDefaults.set(data, forKey: Keys.aiConsentOrigin)
        } else {
            userDefaults.removeObject(forKey: Keys.aiConsentOrigin)
        }
    }

    static func legacySnapshot(from userDefaults: UserDefaults) -> LegacySettingsSnapshot? {
        let categoryData = userDefaults.data(forKey: "custom_categories")
        let usageData = userDefaults.data(forKey: "api_usage_records")
        let hasAIEnabledKey = userDefaults.object(forKey: "ai_integration_enabled") != nil
        let hasOllamaURLKey = userDefaults.object(forKey: "ollama_base_url") != nil

        guard categoryData != nil || usageData != nil || hasAIEnabledKey || hasOllamaURLKey else {
            return nil
        }

        let categories = categoryData.flatMap {
            try? JSONDecoder().decode([LegacyCustomCategoryV1].self, from: $0)
        } ?? []
        return LegacySettingsSnapshot(
            categories: categories,
            hadAIEnabled: hasAIEnabledKey && userDefaults.bool(forKey: "ai_integration_enabled"),
            hadOllamaURL: hasOllamaURLKey,
            hadAPIUsageRecords: usageData != nil
        )
    }

    func persistRetentionPolicy(_ policy: RetentionPolicy) {
        switch policy {
        case .days(let days):
            userDefaults.set(false, forKey: Keys.retentionForever)
            userDefaults.set(days, forKey: Keys.retentionDays)
        case .forever:
            userDefaults.set(true, forKey: Keys.retentionForever)
            userDefaults.removeObject(forKey: Keys.retentionDays)
        }
    }
}
