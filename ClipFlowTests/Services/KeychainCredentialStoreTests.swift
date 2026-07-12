import Security
import XCTest
@testable import ClipFlow

final class KeychainCredentialStoreTests: XCTestCase {
    func testReadUsesNormalizedOriginScopedAccountAndNonSynchronizingUnlockedRequest() async throws {
        let client = FakeSecurityItemClient()
        await client.enqueue(status: errSecSuccess, data: Data("secret-token".utf8))
        let store = KeychainCredentialStore(client: client)

        let credential = try await store.credential(
            for: AIConsentOrigin(scheme: "HTTPS", host: "AI.EXAMPLE.COM", port: 443)
        )

        XCTAssertEqual(credential, "secret-token")
        let requests = await client.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.service, "com.clipflow.v12.ai")
        XCTAssertEqual(request.account, "https://ai.example.com:443")
        XCTAssertEqual(request.operation, .read)
        XCTAssertTrue(request.accessibleWhenUnlocked)
        XCTAssertFalse(request.synchronizable)
    }

    func testReadMissingCredentialReturnsNil() async throws {
        let client = FakeSecurityItemClient()
        await client.enqueue(status: errSecItemNotFound)
        let store = KeychainCredentialStore(client: client)

        let credential = try await store.credential(
            for: AIConsentOrigin(scheme: "https", host: "ai.example.com", port: 443)
        )

        XCTAssertNil(credential)
    }

    func testSetCredentialUpdatesDuplicateItemWithoutChangingAccountScope() async throws {
        let client = FakeSecurityItemClient()
        await client.enqueue(status: errSecDuplicateItem)
        await client.enqueue(status: errSecSuccess)
        let store = KeychainCredentialStore(client: client)

        try await store.setCredential(
            "rotated-token",
            for: AIConsentOrigin(scheme: "https", host: "ai.example.com", port: 443)
        )

        let requests = await client.requests
        XCTAssertEqual(requests.map(\.account), [
            "https://ai.example.com:443",
            "https://ai.example.com:443"
        ])
        XCTAssertEqual(requests.map(\.operation), [
            .add(Data("rotated-token".utf8)),
            .update(Data("rotated-token".utf8))
        ])
    }

    func testDeleteTreatsAlreadyMissingCredentialAsSuccess() async throws {
        let client = FakeSecurityItemClient()
        await client.enqueue(status: errSecItemNotFound)
        let store = KeychainCredentialStore(client: client)

        try await store.deleteCredential(
            for: AIConsentOrigin(scheme: "https", host: "ai.example.com", port: 443)
        )

        let requests = await client.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.operation, .delete)
    }

    func testUnexpectedSecurityStatusIsTypedCredentialError() async {
        let client = FakeSecurityItemClient()
        await client.enqueue(status: errSecInteractionNotAllowed)
        let store = KeychainCredentialStore(client: client)

        do {
            _ = try await store.credential(
                for: AIConsentOrigin(scheme: "https", host: "ai.example.com", port: 443)
            )
            XCTFail("Expected unexpectedStatus")
        } catch {
            XCTAssertEqual(error as? CredentialError, .unexpectedStatus(errSecInteractionNotAllowed))
        }
    }
}
