import Carbon
import XCTest
@testable import ClipFlow

@MainActor
final class HotkeyServiceTests: XCTestCase {
    func testFailedCandidateKeepsOldRegistrationAndPreference() {
        let registrar = FakeHotKeyRegistrar()
        let settings = makeSettings(shortcut: .defaultShortcut)
        let service = HotkeyService(registrar: registrar, settings: settings)
        registrar.failNextRegistration = true
        let candidate = ShortcutMapping(keyCode: 0, modifiers: UInt32(cmdKey | optionKey))

        XCTAssertFalse(service.updateShortcut(candidate))
        XCTAssertEqual(service.currentShortcut, .defaultShortcut)
        XCTAssertEqual(settings.shortcut, .defaultShortcut)
        XCTAssertEqual(registrar.activeShortcuts, [.defaultShortcut])
        XCTAssertEqual(service.lastError, .registrationFailed(OSStatus(eventHotKeyExistsErr)))
    }

    func testSuccessfulCandidateRegistersBeforeRemovingOldToken() {
        let registrar = FakeHotKeyRegistrar()
        let service = makeService(registrar: registrar)
        let candidate = ShortcutMapping(keyCode: 0, modifiers: UInt32(cmdKey | optionKey))

        XCTAssertTrue(service.updateShortcut(candidate))

        XCTAssertEqual(service.currentShortcut, candidate)
        XCTAssertEqual(registrar.activeShortcuts, [candidate])
        XCTAssertEqual(registrar.events, [
            .registered(.defaultShortcut),
            .registered(candidate),
            .unregistered(.defaultShortcut)
        ])
    }

    func testSameShortcutIsNoop() {
        let registrar = FakeHotKeyRegistrar()
        let service = makeService(registrar: registrar)

        XCTAssertTrue(service.updateShortcut(.defaultShortcut))

        XCTAssertEqual(registrar.events, [.registered(.defaultShortcut)])
        XCTAssertEqual(registrar.activeShortcuts, [.defaultShortcut])
    }

    func testResetToDefaultUsesTransactionalRegistration() {
        let registrar = FakeHotKeyRegistrar()
        let settings = makeSettings(shortcut: ShortcutMapping(keyCode: 0, modifiers: UInt32(cmdKey | optionKey)))
        let service = HotkeyService(registrar: registrar, settings: settings)

        XCTAssertTrue(service.resetToDefault())

        XCTAssertEqual(settings.shortcut, .defaultShortcut)
        XCTAssertEqual(registrar.activeShortcuts, [.defaultShortcut])
        XCTAssertEqual(registrar.events, [
            .registered(ShortcutMapping(keyCode: 0, modifiers: UInt32(cmdKey | optionKey))),
            .registered(.defaultShortcut),
            .unregistered(ShortcutMapping(keyCode: 0, modifiers: UInt32(cmdKey | optionKey)))
        ])
    }

    func testInvalidShortcutNeverTouchesRegistrarOrPreference() {
        let registrar = FakeHotKeyRegistrar()
        let settings = makeSettings(shortcut: .defaultShortcut)
        let service = HotkeyService(registrar: registrar, settings: settings)
        let invalid = ShortcutMapping(keyCode: 0, modifiers: 0)

        XCTAssertFalse(service.updateShortcut(invalid))

        XCTAssertEqual(settings.shortcut, .defaultShortcut)
        XCTAssertEqual(registrar.activeShortcuts, [.defaultShortcut])
        XCTAssertEqual(registrar.events, [.registered(.defaultShortcut)])
        XCTAssertEqual(service.lastError, .invalidShortcut)
    }

    func testOnlyActiveTokenForwardsPressedEvent() {
        let registrar = FakeHotKeyRegistrar()
        var pressCount = 0
        let service = HotkeyService(
            registrar: registrar,
            settings: makeSettings(shortcut: .defaultShortcut),
            onPressed: { pressCount += 1 }
        )
        let oldToken = registrar.token(for: .defaultShortcut)!
        let candidate = ShortcutMapping(keyCode: 0, modifiers: UInt32(cmdKey | optionKey))

        XCTAssertTrue(service.updateShortcut(candidate))
        let newToken = registrar.token(for: candidate)!
        registrar.trigger(oldToken)
        registrar.trigger(newToken)

        XCTAssertEqual(pressCount, 1)
    }
}

@MainActor
private func makeService(registrar: FakeHotKeyRegistrar) -> HotkeyService {
    HotkeyService(registrar: registrar, settings: makeSettings(shortcut: .defaultShortcut))
}

@MainActor
private func makeSettings(shortcut: ShortcutMapping) -> AppSettingsStore {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let settings = AppSettingsStore(userDefaults: defaults)
    settings.commitShortcut(shortcut)
    return settings
}
