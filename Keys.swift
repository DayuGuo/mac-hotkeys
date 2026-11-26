import Carbon
import Foundation

struct Modifiers: OptionSet, Hashable {
    let rawValue: UInt32

    static let control = Self(rawValue: UInt32(controlKey))
    static let option = Self(rawValue: UInt32(optionKey))
    static let shift = Self(rawValue: UInt32(shiftKey))
    static let command = Self(rawValue: UInt32(cmdKey))
    static let function = Self(rawValue: UInt32(kEventKeyModifierFnMask))

    static let standard: [Self] = [.control, .option, .shift, .command]
    static let standardMask = standard.reduce(Self()) { $0.union($1) }

    init(rawValue: UInt32) { self.rawValue = rawValue }

    init(cocoa flags: UInt32, explicitFunction: Bool = false) {
        self = []
        if flags & (1 << 18) != 0 { insert(.control) }
        if flags & (1 << 19) != 0 { insert(.option) }
        if flags & (1 << 17) != 0 { insert(.shift) }
        if flags & (1 << 20) != 0 { insert(.command) }
        if explicitFunction && flags & (1 << 23) != 0 { insert(.function) }
    }

    var symbols: String {
        let labels: [(Self, String)] = [(.function, "Fn "), (.control, "⌃"),
                                        (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return labels.compactMap { contains($0.0) ? $0.1 : nil }.joined()
    }
}

struct KeyCombo: Hashable {
    let code: UInt32
    let modifiers: Modifiers

    var label: String { modifiers.symbols + (Self.keyNames[code] ?? "Key(\(code))") }

    static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
        29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return", 37: "L",
        38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
        47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc", 57: "Caps Lock",
        64: "F17", 65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 71: "Clear", 75: "Keypad /",
        76: "Keypad Enter", 78: "Keypad -", 79: "F18", 80: "F19", 81: "Keypad =", 82: "Keypad 0",
        83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6",
        89: "Keypad 7", 90: "F20", 91: "Keypad 8", 92: "Keypad 9", 96: "F5", 97: "F6", 98: "F7",
        99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13", 106: "F16", 107: "F14",
        109: "F10", 111: "F12", 113: "F15", 114: "Help", 115: "Home", 116: "Page Up",
        117: "Forward Delete", 118: "F4", 119: "End", 120: "F2", 121: "Page Down", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑"
    ]

    static let keyCodes: [String: UInt32] = {
        var result = Dictionary(uniqueKeysWithValues: keyNames.map { ($0.value.lowercased(), $0.key) })
        let aliases: [String: UInt32] = ["enter": 36, "escape": 53, "backspace": 51, "grave": 50,
                                         "left": 123, "right": 124, "down": 125, "up": 126]
        result.merge(aliases) { original, _ in original }
        return result
    }()

    init(code: UInt32, modifiers: Modifiers) {
        self.code = code
        self.modifiers = modifiers
    }

    init?(argument: String) {
        let parts = argument.lowercased().split(separator: "+", omittingEmptySubsequences: false)
        guard parts.count > 1, let key = parts.last, let code = Self.keyCodes[String(key)] else { return nil }
        let names: [String: Modifiers] = ["cmd": .command, "command": .command, "ctrl": .control,
                                         "cmdorctrl": .command, "commandorcontrol": .command, "macctrl": .control,
                                         "control": .control, "opt": .option, "option": .option,
                                         "alt": .option, "shift": .shift]
        var modifiers: Modifiers = []
        for part in parts.dropLast() {
            guard let modifier = names[String(part)], !modifiers.contains(modifier) else { return nil }
            modifiers.insert(modifier)
        }
        self.init(code: code, modifiers: modifiers)
    }

    static var candidates: [Self] {
        let codes = keyNames.keys.sorted().filter { $0 != 57 && $0 != 114 }
        return codes.flatMap { code in
            (1..<(1 << Modifiers.standard.count)).map { bits in
                var modifiers: Modifiers = []
                for (index, modifier) in Modifiers.standard.enumerated() where bits & (1 << index) != 0 {
                    modifiers.insert(modifier)
                }
                return Self(code: code, modifiers: modifiers)
            }
        }
    }
}
