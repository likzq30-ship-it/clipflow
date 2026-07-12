import Foundation
import LocalAuthentication
import Security

enum SecurityItemOperation: Equatable, Sendable {
    case read
    case add(Data)
    case update(Data)
    case delete
}

struct SecurityItemRequest: Equatable, Sendable {
    let service: String
    let account: String
    let accessibleWhenUnlocked: Bool
    let synchronizable: Bool
    let operation: SecurityItemOperation
}

protocol SecurityItemClient: Sendable {
    func execute(_ request: SecurityItemRequest) async -> (OSStatus, Data?)
}

actor SystemSecurityItemClient: SecurityItemClient {
    func execute(_ request: SecurityItemRequest) async -> (OSStatus, Data?) {
        var query = baseQuery(for: request)

        switch request.operation {
        case .read:
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        case .add(let data):
            query[kSecValueData as String] = data
            return (SecItemAdd(query as CFDictionary, nil), nil)
        case .update(let data):
            let attributes = [kSecValueData as String: data]
            return (SecItemUpdate(query as CFDictionary, attributes as CFDictionary), nil)
        case .delete:
            return (SecItemDelete(query as CFDictionary), nil)
        }
    }

    private func baseQuery(for request: SecurityItemRequest) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: request.service,
            kSecAttrAccount as String: request.account,
            kSecAttrSynchronizable as String: request.synchronizable ? kCFBooleanTrue as Any : kCFBooleanFalse as Any,
            kSecUseAuthenticationContext as String: context
        ]
        if request.accessibleWhenUnlocked {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        }
        return query
    }
}
