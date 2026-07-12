import Carbon
import Combine
import Foundation

@MainActor
final class HotkeyService: ObservableObject {
    @MainActor
    static let shared = HotkeyService(
        registrar: CarbonHotKeyRegistrar(),
        settings: AppSettingsStore(userDefaults: .standard)
    )

    @Published private(set) var currentShortcut: ShortcutMapping
    @Published private(set) var lastError: HotkeyError?

    var onHotkeyPressed: (@MainActor () -> Void)?

    private let registrar: any HotKeyRegistrar
    private let settings: AppSettingsStore
    private let initialOnPressed: @MainActor () -> Void
    private var activeToken: HotKeyToken?
    private var nextID: UInt32 = 1

    init(
        registrar: any HotKeyRegistrar,
        settings: AppSettingsStore,
        onPressed: @escaping @MainActor () -> Void = {}
    ) {
        self.registrar = registrar
        self.settings = settings
        self.initialOnPressed = onPressed

        let initial = Self.isValid(settings.shortcut) ? settings.shortcut : .defaultShortcut
        if initial != settings.shortcut {
            settings.commitShortcut(initial)
        }
        currentShortcut = initial
        registerInitialShortcut()
    }

    deinit {
        if let activeToken {
            MainActor.assumeIsolated {
                registrar.unregister(activeToken)
            }
        }
    }

    @discardableResult
    func updateShortcut(_ candidate: ShortcutMapping) -> Bool {
        lastError = nil
        guard candidate != currentShortcut else { return true }
        guard Self.isValid(candidate) else {
            lastError = .invalidShortcut
            return false
        }

        do {
            let token = try registrar.register(
                candidate,
                id: allocateID(),
                handler: { [weak self] in
                    self?.handlePressed()
                }
            )
            let oldToken = activeToken
            settings.commitShortcut(candidate)
            currentShortcut = candidate
            activeToken = token
            if let oldToken {
                registrar.unregister(oldToken)
            }
            return true
        } catch let error as HotkeyError {
            lastError = error
            return false
        } catch {
            lastError = .registrationFailed(OSStatus(-1))
            return false
        }
    }

    @discardableResult
    func resetToDefault() -> Bool {
        updateShortcut(.defaultShortcut)
    }
}

private extension HotkeyService {
    static func isValid(_ shortcut: ShortcutMapping) -> Bool {
        shortcut.modifiers != 0 && ShortcutMapping.knownKeyCodes.contains(shortcut.keyCode)
    }

    func registerInitialShortcut() {
        do {
            activeToken = try registrar.register(
                currentShortcut,
                id: allocateID(),
                handler: { [weak self] in
                    self?.handlePressed()
                }
            )
        } catch let error as HotkeyError {
            lastError = error
        } catch {
            lastError = .registrationFailed(OSStatus(-1))
        }
    }

    func allocateID() -> UInt32 {
        defer {
            nextID = nextID == UInt32.max ? 1 : nextID + 1
        }
        return nextID
    }

    func handlePressed() {
        if let onHotkeyPressed {
            onHotkeyPressed()
        } else {
            initialOnPressed()
        }
    }
}
