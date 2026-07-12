import Foundation
@testable import ClipFlow

final class StreamingURLProtocol: URLProtocol, @unchecked Sendable {
    enum Response {
        case chunks(statusCode: Int, headers: [String: String], chunks: [Data])
        case redirect(statusCode: Int, location: URL)
    }

    nonisolated(unsafe) private static var responses: [URL: Response] = [:]
    nonisolated(unsafe) private static var requested: [URL] = []
    nonisolated(unsafe) private static var emittedChunkCounts: [URL: Int] = [:]
    nonisolated(unsafe) private static var stoppedURLs: Set<URL> = []

    private var isStopped = false

    static func reset() {
        responses = [:]
        requested = []
        emittedChunkCounts = [:]
        stoppedURLs = []
    }

    static func register(_ response: Response, for url: URL) {
        responses[url] = response
    }

    static func requestCount(for url: URL) -> Int {
        requested.filter { $0 == url }.count
    }

    static func emittedChunkCount(for url: URL) -> Int {
        emittedChunkCounts[url] ?? 0
    }

    static func wasStopped(_ url: URL) -> Bool {
        stoppedURLs.contains(url)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: AIError.invalidEndpoint)
            return
        }
        Self.requested.append(url)
        guard let response = Self.responses[url] else {
            client?.urlProtocol(self, didFailWithError: AIError.invalidResponse)
            return
        }

        switch response {
        case .redirect(let statusCode, let location):
            let http = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": location.absoluteString]
            )!
            client?.urlProtocol(
                self,
                didReceive: http,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocolDidFinishLoading(self)
        case .chunks(let statusCode, let headers, let chunks):
            let http = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(
                self,
                didReceive: http,
                cacheStoragePolicy: .notAllowed
            )
            emit(chunks, for: url, index: 0)
        }
    }

    override func stopLoading() {
        isStopped = true
        if let url = request.url {
            Self.stoppedURLs.insert(url)
        }
    }

    private func emit(_ chunks: [Data], for url: URL, index: Int) {
        guard !isStopped else { return }
        guard index < chunks.count else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        Self.emittedChunkCounts[url, default: 0] += 1
        client?.urlProtocol(self, didLoad: chunks[index])
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { [weak self] in
            self?.emit(chunks, for: url, index: index + 1)
        }
    }
}
