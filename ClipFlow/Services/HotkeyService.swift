import Foundation
import AppKit
import Carbon

class HotkeyService: ObservableObject {
    static let shared = HotkeyService()

    @Published var shortcutManager = ShortcutManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private static weak var activeService: HotkeyService?

    var onHotkeyPressed: (() -> Void)?

    private init() {
        Self.activeService = self
        setupHotKey()
    }

    deinit {
        unregisterHotKey()
    }

    func setupHotKey() {
        unregisterHotKey()
        let shortcut = shortcutManager.currentShortcut
        let hotKeyID = EventHotKeyID(signature: OSType(0x43464C57), id: 1)

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard hotKeyID.signature == OSType(0x43464C57), hotKeyID.id == 1 else {
                return noErr
            }
            DispatchQueue.main.async {
                HotkeyService.activeService?.onHotkeyPressed?()
            }
            return noErr
        }, 1, &eventType, nil, &eventHandler)

        RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func updateShortcut(_ shortcut: ShortcutMapping) {
        shortcutManager.currentShortcut = shortcut
        setupHotKey()
    }

    func resetToDefault() {
        shortcutManager.reset()
        setupHotKey()
    }

    private func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
}
