import Foundation
@testable import ClipFlow

@MainActor
final class FakeLoginItemRegistrar: LoginItemRegistering {
    enum InjectedFailure: Error {
        case register
        case unregister
    }

    var isRegistered: Bool
    var failRegister = false
    var failUnregister = false
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(isRegistered: Bool = false) {
        self.isRegistered = isRegistered
    }

    func register() throws {
        registerCount += 1
        if failRegister {
            failRegister = false
            throw InjectedFailure.register
        }
        isRegistered = true
    }

    func unregister() throws {
        unregisterCount += 1
        if failUnregister {
            failUnregister = false
            throw InjectedFailure.unregister
        }
        isRegistered = false
    }
}
