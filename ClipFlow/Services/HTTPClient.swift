import Foundation

protocol HTTPClient: Sendable {
    func data(
        for request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> (Data, HTTPURLResponse)
}

actor URLSessionHTTPClient: HTTPClient {
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        let copy = configuration.copy() as! URLSessionConfiguration
        copy.urlCache = nil
        copy.requestCachePolicy = .reloadIgnoringLocalCacheData
        copy.timeoutIntervalForRequest = 30
        copy.timeoutIntervalForResource = 30
        self.configuration = copy
    }

    func data(
        for request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        let delegate = BoundedHTTPDelegate(maximumResponseBytes: maximumResponseBytes)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await delegate.load(request, session: session)
    }
}

private final class BoundedHTTPDelegate: NSObject,
    URLSessionDataDelegate,
    URLSessionTaskDelegate,
    @unchecked Sendable {
    private let maximumResponseBytes: Int
    private var data = Data()
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var completed = false

    init(maximumResponseBytes: Int) {
        self.maximumResponseBytes = maximumResponseBytes
    }

    func load(
        _ request: URLRequest,
        session: URLSession
    ) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        finish(.failure(AIError.redirectRejected), task: task)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(AIError.invalidResponse), task: dataTask)
            return
        }
        if (300...399).contains(http.statusCode) {
            completionHandler(.cancel)
            finish(.failure(AIError.redirectRejected), task: dataTask)
            return
        }
        if let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
           length > maximumResponseBytes {
            completionHandler(.cancel)
            finish(.failure(AIError.responseTooLarge), task: dataTask)
            return
        }
        self.response = http
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard self.data.count + data.count <= maximumResponseBytes else {
            let remainingBytes = max(0, maximumResponseBytes - self.data.count)
            if remainingBytes > 0 {
                self.data.append(data.prefix(remainingBytes))
            }
            finish(.failure(AIError.responseTooLarge), task: dataTask)
            return
        }
        self.data.append(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            if completed { return }
            if let aiError = error as? AIError {
                finish(.failure(aiError), task: task)
            } else if let urlError = error as? URLError, urlError.code == .timedOut {
                finish(.failure(AIError.timedOut), task: task)
            } else if (error as? URLError)?.code == .cancelled {
                finish(.failure(AIError.cancelled), task: task)
            } else {
                finish(.failure(error), task: task)
            }
            return
        }
        guard let response else {
            finish(.failure(AIError.invalidResponse), task: task)
            return
        }
        finish(.success((data, response)), task: task)
    }

    private func finish(
        _ result: Result<(Data, HTTPURLResponse), Error>,
        task: URLSessionTask
    ) {
        guard !completed else { return }
        completed = true
        task.cancel()
        continuation?.resume(with: result)
        continuation = nil
    }
}
