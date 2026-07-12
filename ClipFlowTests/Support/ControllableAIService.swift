import Foundation
@testable import ClipFlow

actor ControllableAIService: AIServiceProtocol {
    private var continuations: [CheckedContinuation<AIResult, Error>] = []
    private(set) var providers: [AIProviderConfiguration] = []
    private(set) var requests: [AIRequest] = []

    func perform(
        _ request: AIRequest,
        provider: AIProviderConfiguration
    ) async throws -> AIResult {
        requests.append(request)
        providers.append(provider)
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func checkAvailability(provider: AIProviderConfiguration) async -> AIAvailability {
        .available
    }

    func complete(with result: AIResult) {
        continuations.removeFirst().resume(returning: result)
    }

    func fail(with error: Error) {
        continuations.removeFirst().resume(throwing: error)
    }

    func pendingCount() -> Int {
        continuations.count
    }

    func recordedRequests() -> [AIRequest] {
        requests
    }

    func recordedProviders() -> [AIProviderConfiguration] {
        providers
    }
}
