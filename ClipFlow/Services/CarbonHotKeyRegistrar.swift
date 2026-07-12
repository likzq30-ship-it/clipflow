import Carbon
import Foundation

struct HotKeyToken: Hashable, Sendable {
    let rawID: UInt32
}

@MainActor
protocol HotKeyRegistrar: AnyObject {
    func register(
        _ shortcut: ShortcutMapping,
        id: UInt32,
        handler: @escaping @MainActor () -> Void
    ) throws -> HotKeyToken
    func unregister(_ token: HotKeyToken)
}

enum HotkeyError: Error, Equatable, Sendable {
    case invalidShortcut
    case registrationFailed(OSStatus)
}

@MainActor
final class CarbonHotKeyRegistrar: HotKeyRegistrar {
    private static let signature = OSType(0x43464C57) // CFLW
    @MainActor private static weak var activeRegistrar: CarbonHotKeyRegistrar?

    private var hotKeys: [HotKeyToken: EventHotKeyRef] = [:]
    private var handlers: [HotKeyToken: @MainActor () -> Void] = [:]
    private var eventHandler: EventHandlerRef?

    init() {
        Self.activeRegistrar = self
    }

    deinit {
        for hotKey in hotKeys.values {
            UnregisterEventHotKey(hotKey)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    func register(
        _ shortcut: ShortcutMapping,
        id: UInt32,
        handler: @escaping @MainActor () -> Void
    ) throws -> HotKeyToken {
        try installEventHandlerIfNeeded()
        let token = HotKeyToken(rawID: id)
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr, let hotKeyRef else {
            throw HotkeyError.registrationFailed(status)
        }
        hotKeys[token] = hotKeyRef
        handlers[token] = handler
        return token
    }

    func unregister(_ token: HotKeyToken) {
        if let hotKey = hotKeys.removeValue(forKey: token) {
            UnregisterEventHotKey(hotKey)
        }
        handlers.removeValue(forKey: token)
    }
}

private extension CarbonHotKeyRegistrar {
    func installEventHandlerIfNeeded() throws {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
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
                guard hotKeyID.signature == CarbonHotKeyRegistrar.signature else {
                    return noErr
                }
                let token = HotKeyToken(rawID: hotKeyID.id)
                DispatchQueue.main.async {
                    Task { @MainActor in
                        CarbonHotKeyRegistrar.activeRegistrar?.handle(token)
                    }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )
        guard status == noErr else {
            throw HotkeyError.registrationFailed(status)
        }
    }

    func handle(_ token: HotKeyToken) {
        handlers[token]?()
    }
}
