import Carbon
import Foundation
@testable import ClipFlow

enum FakeHotKeyEvent: Equatable {
    case registered(ShortcutMapping)
    case unregistered(ShortcutMapping)
}

@MainActor
final class FakeHotKeyRegistrar: HotKeyRegistrar {
    var failNextRegistration = false
    var failureStatus: OSStatus = OSStatus(eventHotKeyExistsErr)
    private(set) var events: [FakeHotKeyEvent] = []

    private var active: [HotKeyToken: (shortcut: ShortcutMapping, handler: @MainActor () -> Void)] = [:]
    private var activeOrder: [HotKeyToken] = []

    var activeShortcuts: [ShortcutMapping] {
        activeOrder.compactMap { active[$0]?.shortcut }
    }

    func register(
        _ shortcut: ShortcutMapping,
        id: UInt32,
        handler: @escaping @MainActor () -> Void
    ) throws -> HotKeyToken {
        if failNextRegistration {
            failNextRegistration = false
            throw HotkeyError.registrationFailed(failureStatus)
        }
        let token = HotKeyToken(rawID: id)
        active[token] = (shortcut, handler)
        activeOrder.append(token)
        events.append(.registered(shortcut))
        return token
    }

    func unregister(_ token: HotKeyToken) {
        guard let entry = active.removeValue(forKey: token) else { return }
        activeOrder.removeAll { $0 == token }
        events.append(.unregistered(entry.shortcut))
    }

    func trigger(_ token: HotKeyToken) {
        active[token]?.handler()
    }

    func token(for shortcut: ShortcutMapping) -> HotKeyToken? {
        active.first { $0.value.shortcut == shortcut }?.key
    }
}
