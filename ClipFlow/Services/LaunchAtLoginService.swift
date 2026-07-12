import Combine
import Foundation
import ServiceManagement

@MainActor
protocol LoginItemRegistering: AnyObject {
    var isRegistered: Bool { get }
    func register() throws
    func unregister() throws
}

enum LaunchAtLoginError: Error, Equatable, Sendable {
    case registrationFailed
    case unregistrationFailed
}

@MainActor
final class LaunchAtLoginService: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var lastError: LaunchAtLoginError?

    private let registrar: any LoginItemRegistering

    init(registrar: any LoginItemRegistering) {
        self.registrar = registrar
        isEnabled = registrar.isRegistered
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        lastError = nil
        guard enabled != isEnabled else { return true }
        let previous = isEnabled
        do {
            if enabled {
                try registrar.register()
            } else {
                try registrar.unregister()
            }
            isEnabled = registrar.isRegistered
            return true
        } catch {
            isEnabled = previous
            lastError = enabled ? .registrationFailed : .unregistrationFailed
            return false
        }
    }
}

@MainActor
final class SystemLoginItemRegistrar: LoginItemRegistering {
    var isRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}
