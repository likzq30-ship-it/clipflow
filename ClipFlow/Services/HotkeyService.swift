import Foundation
import HotKey
import AppKit
import Carbon

class HotkeyService: ObservableObject {
    static let shared = HotkeyService()

    @Published var shortcutManager = ShortcutManager()

    private var hotKey: HotKey?

    var onHotkeyPressed: (() -> Void)?

    private init() {
        setupHotKey()
    }

    func setupHotKey() {
        hotKey = nil

        let shortcut = shortcutManager.currentShortcut

        guard let key = Key(carbonKeyCode: shortcut.keyCode) else { return }

        var modifiers: NSEvent.ModifierFlags = []

        if shortcut.modifiers & UInt32(controlKey) != 0 { modifiers.insert(.control) }
        if shortcut.modifiers & UInt32(optionKey) != 0 { modifiers.insert(.option) }
        if shortcut.modifiers & UInt32(shiftKey) != 0 { modifiers.insert(.shift) }
        if shortcut.modifiers & UInt32(cmdKey) != 0 { modifiers.insert(.command) }

        hotKey = HotKey(key: key, modifiers: modifiers)
        hotKey?.keyDownHandler = { [weak self] in
            self?.onHotkeyPressed?()
        }
    }

    func updateShortcut(_ shortcut: ShortcutMapping) {
        shortcutManager.currentShortcut = shortcut
        setupHotKey()
    }

    func resetToDefault() {
        shortcutManager.reset()
        setupHotKey()
    }
}
