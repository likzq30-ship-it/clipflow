import Foundation
import Security

protocol KeychainCredentialStoring: Sendable {
    func credential(for origin: AIConsentOrigin) async throws -> String?
    func setCredential(_ credential: String, for origin: AIConsentOrigin) async throws
    func deleteCredential(for origin: AIConsentOrigin) async throws
}

enum CredentialError: Error, Equatable, Sendable {
    case unexpectedStatus(OSStatus)
    case invalidEncoding
}

actor KeychainCredentialStore: KeychainCredentialStoring {
    private static let service = "com.clipflow.v12.ai"
    private let client: any SecurityItemClient

    init(client: any SecurityItemClient = SystemSecurityItemClient()) {
        self.client = client
    }

    func credential(for origin: AIConsentOrigin) async throws -> String? {
        let (status, data) = await client.execute(request(origin: origin, operation: .read))
        switch status {
        case errSecSuccess:
            guard let data, let value = String(data: data, encoding: .utf8) else {
                throw CredentialError.invalidEncoding
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialError.unexpectedStatus(status)
        }
    }

    func setCredential(_ credential: String, for origin: AIConsentOrigin) async throws {
        guard let data = credential.data(using: .utf8) else {
            throw CredentialError.invalidEncoding
        }
        let add = await client.execute(request(origin: origin, operation: .add(data)))
        switch add.0 {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update = await client.execute(request(origin: origin, operation: .update(data)))
            guard update.0 == errSecSuccess else {
                throw CredentialError.unexpectedStatus(update.0)
            }
        default:
            throw CredentialError.unexpectedStatus(add.0)
        }
    }

    func deleteCredential(for origin: AIConsentOrigin) async throws {
        let (status, _) = await client.execute(request(origin: origin, operation: .delete))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialError.unexpectedStatus(status)
        }
    }

    private func request(
        origin: AIConsentOrigin,
        operation: SecurityItemOperation
    ) -> SecurityItemRequest {
        SecurityItemRequest(
            service: Self.service,
            account: "\(origin.scheme)://\(origin.host):\(origin.port)",
            accessibleWhenUnlocked: true,
            synchronizable: false,
            operation: operation
        )
    }
}
