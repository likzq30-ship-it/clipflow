import Foundation
@testable import ClipFlow

actor MockHTTPClient: HTTPClient {
    private(set) var requestCount = 0
    private(set) var lastRequest: URLRequest?
    private var queuedResults: [Result<(Data, HTTPURLResponse), Error>] = []

    func enqueue(_ result: Result<(Data, HTTPURLResponse), Error>) {
        queuedResults.append(result)
    }

    func enqueueJSON(
        _ object: [String: Any],
        statusCode: Int = 200,
        url: URL = URL(string: "http://127.0.0.1:11434/api/generate")!,
        headers: [String: String] = [:]
    ) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        enqueue(.success((data, response)))
    }

    func data(
        for request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        lastRequest = request
        guard !queuedResults.isEmpty else {
            throw AIError.invalidResponse
        }
        let result = queuedResults.removeFirst()
        return try result.get()
    }
}
