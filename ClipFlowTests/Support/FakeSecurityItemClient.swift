import Foundation
@testable import ClipFlow

actor FakeSecurityItemClient: SecurityItemClient {
    private(set) var requests: [SecurityItemRequest] = []
    var responses: [(OSStatus, Data?)] = []

    func enqueue(status: OSStatus, data: Data? = nil) {
        responses.append((status, data))
    }

    func execute(_ request: SecurityItemRequest) async -> (OSStatus, Data?) {
        requests.append(request)
        guard !responses.isEmpty else {
            return (errSecItemNotFound, nil)
        }
        return responses.removeFirst()
    }
}
