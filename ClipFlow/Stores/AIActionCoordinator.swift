import Foundation

@MainActor
protocol RemoteConsentPresenting: AnyObject {
    func confirmFirstSend(to origin: AIConsentOrigin) async -> Bool
}

@MainActor
final class AIActionCoordinator {
    private let settings: AppSettingsStore
    private let jobs: AIJobCoordinator
    private let consentPresenter: any RemoteConsentPresenting

    init(
        settings: AppSettingsStore,
        jobs: AIJobCoordinator,
        consentPresenter: any RemoteConsentPresenting
    ) {
        self.settings = settings
        self.jobs = jobs
        self.consentPresenter = consentPresenter
    }

    func start(
        item: ClipboardItem,
        operation: AIOperation,
        allowedCategories: [PersistedCustomCategory]
    ) async {
        guard let provider = await providerConfiguration() else { return }
        let request = AIRequest(
            itemID: item.id,
            operation: operation,
            text: item.content,
            allowedCategories: allowedCategories.filter(\.isEnabled)
        )
        await jobs.start(request, provider: provider)
    }
}

private extension AIActionCoordinator {
    func providerConfiguration() async -> AIProviderConfiguration? {
        switch settings.aiProviderKind {
        case .disabled:
            return nil
        case .localOllama:
            return try? settings.validatedAIProviderConfiguration()
        case .remoteHTTPS:
            guard await confirmRemoteConsentIfNeeded() else { return nil }
            return try? settings.validatedAIProviderConfiguration()
        }
    }

    func confirmRemoteConsentIfNeeded() async -> Bool {
        guard let origin = try? settings.requestRemoteConsent() else { return false }
        if settings.aiConsentOrigin == origin {
            return true
        }
        guard await consentPresenter.confirmFirstSend(to: origin) else {
            return false
        }
        do {
            try settings.grantConsent(for: origin)
            return true
        } catch {
            return false
        }
    }
}
