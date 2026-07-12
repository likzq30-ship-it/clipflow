import XCTest
@testable import ClipFlow

final class URLSessionHTTPClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StreamingURLProtocol.reset()
    }

    func testChunkedResponseCancelsAsSoonAsLimitIsExceeded() async {
        let url = URL(string: "https://ai.example.com/api/generate")!
        StreamingURLProtocol.register(
            .chunks(
                statusCode: 200,
                headers: [:],
                chunks: [
                    Data(repeating: 1, count: 1_048_576),
                    Data([2]),
                    Data([3])
                ]
            ),
            for: url
        )
        let client = URLSessionHTTPClient(configuration: Self.streamingConfiguration())

        await XCTAssertThrowsAIError(.responseTooLarge) {
            _ = try await client.data(for: URLRequest(url: url), maximumResponseBytes: 1_048_576)
        }

        XCTAssertLessThanOrEqual(StreamingURLProtocol.emittedChunkCount(for: url), 2)
    }

    func testRedirectIsRejectedAndDestinationReceivesNoRequest() async {
        let source = URL(string: "https://ai.example.com/api/generate")!
        let destination = URL(string: "http://evil.example.com/api/generate")!
        StreamingURLProtocol.register(.redirect(statusCode: 307, location: destination), for: source)
        StreamingURLProtocol.register(.chunks(statusCode: 200, headers: [:], chunks: [Data()]), for: destination)
        let client = URLSessionHTTPClient(configuration: Self.streamingConfiguration())
        var request = URLRequest(url: source)
        request.httpMethod = "POST"
        request.setValue("Bearer canary", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("secret-body".utf8)

        await XCTAssertThrowsAIError(.redirectRejected) {
            _ = try await client.data(for: request, maximumResponseBytes: 1_048_576)
        }

        XCTAssertEqual(StreamingURLProtocol.requestCount(for: destination), 0)
    }

    func testEveryRedirectShapeIsRejectedWithoutReplayingRequest() async {
        let cases: [(source: URL, destination: URL, statusCode: Int)] = [
            (
                URL(string: "https://ai.example.com/api/generate?case=same-origin")!,
                URL(string: "https://ai.example.com/api/generate-v2")!,
                307
            ),
            (
                URL(string: "https://ai.example.com/api/generate?case=port")!,
                URL(string: "https://ai.example.com:8443/api/generate")!,
                308
            ),
            (
                URL(string: "https://ai.example.com/api/generate?case=host")!,
                URL(string: "https://other.example.com/api/generate")!,
                307
            )
        ]

        for testCase in cases {
            StreamingURLProtocol.register(
                .redirect(statusCode: testCase.statusCode, location: testCase.destination),
                for: testCase.source
            )
            StreamingURLProtocol.register(
                .chunks(statusCode: 200, headers: [:], chunks: [Data("replayed".utf8)]),
                for: testCase.destination
            )
            let client = URLSessionHTTPClient(configuration: Self.streamingConfiguration())
            var request = URLRequest(url: testCase.source)
            request.httpMethod = "POST"
            request.setValue("Bearer canary", forHTTPHeaderField: "Authorization")
            request.httpBody = Data("secret-body".utf8)

            await XCTAssertThrowsAIError(.redirectRejected) {
                _ = try await client.data(for: request, maximumResponseBytes: 1_048_576)
            }

            XCTAssertEqual(StreamingURLProtocol.requestCount(for: testCase.destination), 0)
        }
    }

    func testInitializerCopiesConfigurationInsteadOfMutatingCaller() {
        let configuration = URLSessionConfiguration.ephemeral
        let cache = URLCache(memoryCapacity: 1_024, diskCapacity: 0, diskPath: nil)
        configuration.urlCache = cache
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.timeoutIntervalForRequest = 123
        configuration.timeoutIntervalForResource = 456

        _ = URLSessionHTTPClient(configuration: configuration)

        XCTAssertTrue(configuration.urlCache === cache)
        XCTAssertEqual(configuration.requestCachePolicy, .useProtocolCachePolicy)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 123)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 456)
    }

    private static func streamingConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingURLProtocol.self]
        return configuration
    }
}
