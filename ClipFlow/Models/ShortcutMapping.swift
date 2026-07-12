import Foundation
import Carbon

struct ShortcutMapping: Codable, Equatable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    init(keyCode: UInt32 = 9, modifiers: UInt32 = UInt32(cmdKey | shiftKey)) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    static let defaultShortcut = ShortcutMapping(keyCode: 9, modifiers: UInt32(cmdKey | shiftKey))

    static let knownKeyCodes: Set<UInt32> = Set(keyChars.keys)

    var displayString: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }

        let key = Self.keyChars[keyCode] ?? "?"
        return parts.joined() + key
    }

    // Carbon key codes (kVK_*) — physical ANSI positions.
    private static let keyChars: [UInt32: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G",
        0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V",
        0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R",
        0x10: "Y", 0x11: "T",
        0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5",
        0x18: "=", 0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0",
        0x1E: "]", 0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P",
        0x24: "↩", 0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K",
        0x29: ";", 0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M",
        0x2F: ".", 0x30: "⇥", 0x31: "␣", 0x32: "`",
        0x33: "⌫", 0x35: "⎋",
        0x60: "F5", 0x61: "F6", 0x62: "F7", 0x63: "F3",
        0x64: "F8", 0x65: "F9", 0x67: "F11",
        0x69: "F13", 0x6A: "F16", 0x6B: "F14",
        0x6D: "F10", 0x6F: "F12",
        0x71: "F15", 0x72: "F4",
        0x73: "F2", 0x74: "F1", 0x75: "F17",
        0x7A: "F18", 0x7B: "F19", 0x7C: "F20",
    ]
}
