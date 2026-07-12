import Combine
import Foundation

@MainActor
final class AIJobCoordinator: ObservableObject {
    @Published var visibleItemID: UUID?
    @Published private(set) var states: [AIJobKey: AIJobState] = [:]

    private let ai: any AIServiceProtocol
    private let store: ClipboardStore
    private let now: () -> Date
    private var jobs: [AIJobKey: AIJob] = [:]

    init(
        ai: any AIServiceProtocol,
        store: ClipboardStore,
        now: @escaping () -> Date = Date.init
    ) {
        self.ai = ai
        self.store = store
        self.now = now
    }

    func start(
        _ request: AIRequest,
        provider: AIProviderConfiguration
    ) async {
        let key = AIJobKey(itemID: request.itemID, operation: request.operation)
        if let existing = jobs[key] {
            existing.task.cancel()
            await store.cancelAIJob(key, generation: existing.generation)
            await recordUsage(
                request: existing.request,
                provider: existing.provider,
                startedAt: existing.startedAt,
                succeeded: false,
                errorCode: AIError.cancelled.stableCode
            )
        }
        let generation = UUID()
        await store.activateAIJob(key, generation: generation)
        states[key] = .running

        let startedAt = now()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await ai.perform(request, provider: provider)
                try Task.checkCancellation()
                await self.complete(
                    result,
                    request: request,
                    key: key,
                    generation: generation,
                    provider: provider,
                    startedAt: startedAt
                )
            } catch is CancellationError {
                await self.finishCancellation(key: key, generation: generation)
            } catch let error as AIError {
                await self.finishFailure(
                    key: key,
                    generation: generation,
                    errorCode: Self.code(for: error),
                    provider: provider,
                    request: request,
                    startedAt: startedAt
                )
            } catch {
                await self.finishFailure(
                    key: key,
                    generation: generation,
                    errorCode: AppErrorCode.aiRequest.rawValue,
                    provider: provider,
                    request: request,
                    startedAt: startedAt
                )
            }
        }
        jobs[key] = AIJob(
            generation: generation,
            task: task,
            request: request,
            provider: provider,
            startedAt: startedAt
        )
    }

    func cancel(itemID: UUID, operation: AIOperation) async {
        let key = AIJobKey(itemID: itemID, operation: operation)
        guard let job = jobs.removeValue(forKey: key) else { return }
        job.task.cancel()
        await store.cancelAIJob(key, generation: job.generation)
        states[key] = .failure(code: AIError.cancelled.stableCode, message: AIError.cancelled.stableCode)
        await recordUsage(
            request: job.request,
            provider: job.provider,
            startedAt: job.startedAt,
            succeeded: false,
            errorCode: AIError.cancelled.stableCode
        )
    }

    func cancelAll(itemID: UUID) async {
        for key in Array(jobs.keys) where key.itemID == itemID {
            await cancel(itemID: key.itemID, operation: key.operation)
        }
    }

    func cancelAll() async {
        for key in Array(jobs.keys) {
            await cancel(itemID: key.itemID, operation: key.operation)
        }
    }

    func clearTransientResults(itemID: UUID) {
        states = states.filter { key, state in
            !(key.itemID == itemID && key.operation == .rewrite && state != .running)
        }
    }

    func clearAllTransientResults() {
        states = states.filter { key, state in
            !(key.operation == .rewrite && state != .running)
        }
    }

    func waitForIdle() async {
        while !jobs.isEmpty {
            let tasks = jobs.values.map(\.task)
            for task in tasks {
                await task.value
            }
            await Task.yield()
        }
    }
}

private extension AIJobCoordinator {
    struct AIJob {
        let generation: UUID
        let task: Task<Void, Never>
        let request: AIRequest
        let provider: AIProviderConfiguration
        let startedAt: Date
    }

    func complete(
        _ result: AIResult,
        request: AIRequest,
        key: AIJobKey,
        generation: UUID,
        provider: AIProviderConfiguration,
        startedAt: Date
    ) async {
        guard jobs[key]?.generation == generation, !Task.isCancelled else { return }
        let application: AIResultApplication
        switch request.operation {
        case .summarize:
            application = await store.applyAISummary(
                itemID: request.itemID,
                summary: result.text,
                key: key,
                generation: generation
            )
        case .categorize:
            let categoryID = request.allowedCategories.first { $0.name == result.text }?.id
            application = await store.applyAICategory(
                itemID: request.itemID,
                categoryID: categoryID,
                key: key,
                generation: generation
            )
        case .rewrite:
            application = .applied(ClipboardItem(content: result.text))
        }

        guard jobs[key]?.generation == generation else { return }
        jobs.removeValue(forKey: key)

        switch application {
        case .applied:
            states[key] = .success(result)
            await recordUsage(
                request: request,
                provider: provider,
                startedAt: startedAt,
                succeeded: true,
                errorCode: nil
            )
        case .staleGeneration:
            states[key] = .failure(code: "ai.staleGeneration", message: "ai.staleGeneration")
            await recordUsage(
                request: request,
                provider: provider,
                startedAt: startedAt,
                succeeded: false,
                errorCode: "ai.staleGeneration"
            )
        case .targetMissing:
            states[key] = .failure(code: "ai.targetMissing", message: "ai.targetMissing")
            await recordUsage(
                request: request,
                provider: provider,
                startedAt: startedAt,
                succeeded: false,
                errorCode: "ai.targetMissing"
            )
        case .failed(let code):
            states[key] = .failure(code: code.rawValue, message: code.rawValue)
            await recordUsage(
                request: request,
                provider: provider,
                startedAt: startedAt,
                succeeded: false,
                errorCode: code.rawValue
            )
        }
    }

    func finishCancellation(key: AIJobKey, generation: UUID) async {
        guard let job = jobs[key],
              job.generation == generation else { return }
        jobs.removeValue(forKey: key)
        await store.cancelAIJob(key, generation: generation)
        states[key] = .failure(code: AIError.cancelled.stableCode, message: AIError.cancelled.stableCode)
        await recordUsage(
            request: job.request,
            provider: job.provider,
            startedAt: job.startedAt,
            succeeded: false,
            errorCode: AIError.cancelled.stableCode
        )
    }

    func finishFailure(
        key: AIJobKey,
        generation: UUID,
        errorCode: String,
        provider: AIProviderConfiguration,
        request: AIRequest,
        startedAt: Date
    ) async {
        guard jobs[key]?.generation == generation else { return }
        jobs.removeValue(forKey: key)
        states[key] = .failure(code: errorCode, message: errorCode)
        await store.cancelAIJob(key, generation: generation)
        await recordUsage(
            request: request,
            provider: provider,
            startedAt: startedAt,
            succeeded: false,
            errorCode: errorCode
        )
    }

    func recordUsage(
        request: AIRequest,
        provider: AIProviderConfiguration,
        startedAt: Date,
        succeeded: Bool,
        errorCode: String?
    ) async {
        let duration = max(0, Int(now().timeIntervalSince(startedAt) * 1000))
        await store.addAIUsage(AIUsageRecord(
            id: UUID(),
            operation: request.operation,
            timestamp: now(),
            provider: provider.label,
            model: provider.modelLabel,
            durationMilliseconds: duration,
            succeeded: succeeded,
            errorCode: errorCode
        ))
    }

    static func code(for error: AIError) -> String {
        error.stableCode
    }
}

private extension AIError {
    var stableCode: String {
        switch self {
        case .disabled: return "ai.disabled"
        case .invalidEndpoint: return "ai.invalidEndpoint"
        case .missingConsent: return "ai.missingConsent"
        case .httpStatus(let status): return "ai.httpStatus.\(status)"
        case .responseTooLarge: return "ai.responseTooLarge"
        case .invalidResponse: return "ai.invalidResponse"
        case .emptyResponse: return "ai.emptyResponse"
        case .invalidCategory: return "ai.invalidCategory"
        case .redirectRejected: return "ai.redirectRejected"
        case .timedOut: return "ai.timedOut"
        case .cancelled: return "ai.cancelled"
        }
    }
}

private extension AIProviderConfiguration {
    var label: String {
        switch self {
        case .disabled: return "disabled"
        case .localOllama: return "local"
        case .remoteHTTPS: return "remote"
        }
    }

    var modelLabel: String {
        switch self {
        case .disabled: return ""
        case .localOllama(_, let model): return model
        case .remoteHTTPS(_, let model, _): return model
        }
    }
}
