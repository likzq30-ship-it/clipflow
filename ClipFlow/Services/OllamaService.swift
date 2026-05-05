import Foundation

class OllamaService: ObservableObject {
    static let shared = OllamaService()

    @Published var isAvailable: Bool = false
    @Published var isGenerating: Bool = false

    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: "ollama_base_url") }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "ollama_model") }
    }

    private init() {
        self.baseURL = UserDefaults.standard.string(forKey: "ollama_base_url") ?? "http://localhost:11434"
        self.model = UserDefaults.standard.string(forKey: "ollama_model") ?? "qwen2.5:0.5b"
        checkAvailability()
    }

    func checkAvailability() {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isAvailable = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
            }
        }.resume()
    }

    private func ensureAvailable() async -> Bool {
        if isAvailable { return true }

        // Try launching ollama serve
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ollama", "serve"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()

        // Wait for Ollama to start (up to 5s)
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            checkAvailability()
            if isAvailable { return true }
        }

        return false
    }

    func summarize(_ text: String) async -> String? {
        guard await ensureAvailable(), !isGenerating else { return nil }

        DispatchQueue.main.async {
            self.isGenerating = true
        }

        defer {
            DispatchQueue.main.async {
                self.isGenerating = false
            }
        }

        let prompt = """
        请用一句话简洁地总结以下内容，不超过50个字：
        \(text)
        """

        let requestBody: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": [
                "temperature": 0.3,
                "num_predict": 100
            ]
        ]

        guard let url = URL(string: "\(baseURL)/api/generate"),
              let jsonData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 30

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let response = json["response"] as? String {
                let result = response.trimmingCharacters(in: .whitespacesAndNewlines)
                logUsage(type: "summarize", content: text, result: result)
                return result
            }
        } catch {
            print("Ollama error: \(error)")
        }

        return nil
    }

    func categorizeContent(_ text: String, customCategories: [CustomCategory]) async -> String? {
        guard await ensureAvailable(), !isGenerating, !customCategories.isEmpty else { return nil }

        DispatchQueue.main.async { self.isGenerating = true }
        defer { DispatchQueue.main.async { self.isGenerating = false } }

        let catDescriptions = customCategories.map { "「\($0.name)」: \($0.prompt)" }.joined(separator: "\n")

        let prompt = """
        根据以下分类规则，判断内容属于哪个分类。只需回复分类名称，不要其他文字。

        分类规则：
        \(catDescriptions)

        内容：
        \(String(text.prefix(500)))

        回复格式：只输出分类名称，例如"工作文档"
        """

        let requestBody: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": ["temperature": 0.1, "num_predict": 20]
        ]

        guard let url = URL(string: "\(baseURL)/api/generate"),
              let jsonData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 15

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let response = (json["response"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                logUsage(type: "categorize", content: text, result: response)
                return response
            }
        } catch {
            print("Ollama categorize error: \(error)")
        }

        return nil
    }

    private func logUsage(type: String, content: String, result: String) {
        let record = APIUsageRecord(
            timestamp: Date(),
            type: type,
            contentPreview: String(content.prefix(100)),
            result: result,
            model: model
        )
        APIUsageStore.shared.add(record)
    }
}
