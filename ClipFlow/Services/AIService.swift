import Foundation

protocol AIServiceProtocol: Sendable {
    func perform(
        _ request: AIRequest,
        provider: AIProviderConfiguration
    ) async throws -> AIResult
    func checkAvailability(provider: AIProviderConfiguration) async -> AIAvailability
}

actor AIService: AIServiceProtocol {
    private static let maximumResponseBytes = 1_048_576

    private let http: any HTTPClient
    private let keychain: any KeychainCredentialStoring
    private let localRules: LocalRulesService

    init(
        http: any HTTPClient,
        keychain: any KeychainCredentialStoring,
        localRules: LocalRulesService
    ) {
        self.http = http
        self.keychain = keychain
        self.localRules = localRules
    }

    func perform(
        _ request: AIRequest,
        provider: AIProviderConfiguration
    ) async throws -> AIResult {
        let context = try await context(for: provider)
        try Task.checkCancellation()

        if request.operation == .rewrite, let rewritten = localRules.rewrite(request.text) {
            return AIResult(
                itemID: request.itemID,
                operation: request.operation,
                text: rewritten,
                providerLabel: LocalRulesService.providerLabel
            )
        }

        var urlRequest = URLRequest(url: context.baseURL.appendingPathComponent("api/generate"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 30
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let credential = context.credential {
            urlRequest.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = try JSONEncoder().encode(OllamaGenerateRequest(
            model: context.model,
            prompt: prompt(for: request),
            stream: false
        ))

        let (data, response) = try await boundedData(for: urlRequest)
        guard (200...299).contains(response.statusCode) else {
            throw AIError.httpStatus(response.statusCode)
        }
        let decoded: OllamaGenerateResponse
        do {
            decoded = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
        } catch {
            throw AIError.invalidResponse
        }
        let text = decoded.response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AIError.emptyResponse
        }
        if request.operation == .categorize {
            guard request.allowedCategories.contains(where: { $0.name == text }) else {
                throw AIError.invalidCategory
            }
        }
        try Task.checkCancellation()
        return AIResult(
            itemID: request.itemID,
            operation: request.operation,
            text: text,
            providerLabel: context.providerLabel
        )
    }

    func checkAvailability(provider: AIProviderConfiguration) async -> AIAvailability {
        do {
            let context = try await context(for: provider)
            var request = URLRequest(url: context.baseURL.appendingPathComponent("api/tags"))
            request.timeoutInterval = 3
            if let credential = context.credential {
                request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            }
            let (_, response) = try await http.data(
                for: request,
                maximumResponseBytes: Self.maximumResponseBytes
            )
            return (200...299).contains(response.statusCode)
                ? .available
                : .unavailable(code: .aiEndpoint)
        } catch AIError.disabled {
            return .disabled
        } catch {
            return .unavailable(code: .aiEndpoint)
        }
    }
}

private extension AIService {
    struct ProviderContext {
        let baseURL: URL
        let model: String
        let providerLabel: String
        let credential: String?
    }

    struct OllamaGenerateRequest: Encodable {
        let model: String
        let prompt: String
        let stream: Bool
    }

    struct OllamaGenerateResponse: Decodable {
        let response: String
    }

    func context(
        for provider: AIProviderConfiguration
    ) async throws -> ProviderContext {
        switch provider {
        case .disabled:
            throw AIError.disabled
        case .localOllama(let baseURL, let model):
            return ProviderContext(
                baseURL: try AIEndpointValidator.validateLocal(baseURL),
                model: model,
                providerLabel: "Ollama",
                credential: nil
            )
        case .remoteHTTPS(let baseURL, let model, let consent):
            let origin = try AIEndpointValidator.validateRemote(baseURL, consent: consent)
            let credential = try await keychain.credential(for: origin)
            return ProviderContext(
                baseURL: AIEndpointValidator.originURL(from: baseURL),
                model: model,
                providerLabel: "Remote HTTPS",
                credential: credential
            )
        }
    }

    func boundedData(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await http.data(
                for: request,
                maximumResponseBytes: Self.maximumResponseBytes
            )
            if let length = response.value(forHTTPHeaderField: "Content-Length")
                .flatMap(Int.init),
               length > Self.maximumResponseBytes {
                throw AIError.responseTooLarge
            }
            guard data.count <= Self.maximumResponseBytes else {
                throw AIError.responseTooLarge
            }
            return (data, response)
        } catch let error as AIError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw AIError.timedOut
        } catch is CancellationError {
            throw AIError.cancelled
        } catch {
            throw AIError.invalidResponse
        }
    }

    func prompt(for request: AIRequest) -> String {
        switch request.operation {
        case .summarize:
            return "Summarize the following text concisely:\n\(request.text)"
        case .categorize:
            let categories = request.allowedCategories
                .map { "\($0.name): \($0.prompt)" }
                .joined(separator: "\n")
            return """
            Pick exactly one category name from this list:
            \(categories)

            Text:
            \(request.text)
            """
        case .rewrite:
            return "Rewrite the following text clearly:\n\(request.text)"
        }
    }
}
