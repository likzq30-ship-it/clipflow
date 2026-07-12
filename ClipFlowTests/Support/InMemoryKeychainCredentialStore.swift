import Foundation
@testable import ClipFlow

actor InMemoryKeychainCredentialStore: KeychainCredentialStoring {
    private var values: [AIConsentOrigin: String] = [:]
    private(set) var readCount = 0
    private(set) var writeCount = 0
    private(set) var deleteCount = 0
    private(set) var readOrigins: [AIConsentOrigin] = []

    func credential(for origin: AIConsentOrigin) async throws -> String? {
        readCount += 1
        readOrigins.append(origin)
        return values[origin]
    }

    func setCredential(_ credential: String, for origin: AIConsentOrigin) async throws {
        writeCount += 1
        values[origin] = credential
    }

    func deleteCredential(for origin: AIConsentOrigin) async throws {
        deleteCount += 1
        values.removeValue(forKey: origin)
    }
}
