import AppKit
import SwiftUI

/// A key combination as written in keybindings.json: modifiers (`cmd`, `ctrl`, `alt`,
/// `shift`) and one key, joined with `+`, such as `cmd+shift+n`.
nonisolated struct Shortcut: Hashable, Sendable {
    struct Modifiers: OptionSet, Hashable, Sendable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1 << 0)
        static let control = Modifiers(rawValue: 1 << 1)
        static let option = Modifiers(rawValue: 1 << 2)
        static let shift = Modifiers(rawValue: 1 << 3)
    }

    let modifiers: Modifiers
    /// One lowercase character, or a key name such as `tab`, `up`, `f5` or `plus`.
    let key: String

    /// Key names besides single characters, with how they are shown.
    static let namedKeys: [String: String] = {
        var names = [
            "tab": "⇥", "delete": "⌫", "return": "↩", "escape": "⎋", "space": "Space",
            "up": "↑", "down": "↓", "left": "←", "right": "→", "plus": "+",
        ]
        for number in 1...12 { names["f\(number)"] = "F\(number)" }
        return names
    }()

    private static let modifierWords: [String: Modifiers] = [
        "cmd": .command, "command": .command, "ctrl": .control, "control": .control,
        "alt": .option, "opt": .option, "option": .option, "shift": .shift,
    ]

    init(modifiers: Modifiers, key: String) {
        self.modifiers = modifiers
        self.key = key
    }

    /// Reads `text`, ignoring letter case; `nil` when it isn't a shortcut.
    init?(_ text: String) {
        var parts = text.lowercased().components(separatedBy: "+")
        // "cmd++": the key is the plus sign itself.
        if parts.count >= 3, parts[parts.count - 1].isEmpty, parts[parts.count - 2].isEmpty {
            parts.removeLast(2)
            parts.append("plus")
        }
        guard let key = parts.popLast() else { return nil }
        var modifiers: Modifiers = []
        for word in parts {
            guard let modifier = Self.modifierWords[word] else { return nil }
            modifiers.insert(modifier)
        }
        if Self.namedKeys[key] != nil {
            self.init(modifiers: modifiers, key: key)
        } else if key.count == 1, let character = key.first, !character.isWhitespace, Self.modifierWords[key] == nil {
            self.init(modifiers: modifiers, key: key)
        } else {
            return nil
        }
    }

    /// As written in the file: modifiers in a fixed order, then the key.
    var text: String {
        var words: [String] = []
        if modifiers.contains(.command) { words.append("cmd") }
        if modifiers.contains(.control) { words.append("ctrl") }
        if modifiers.contains(.option) { words.append("alt") }
        if modifiers.contains(.shift) { words.append("shift") }
        return (words + [key]).joined(separator: "+")
    }

    /// As menus show it: ⌃⌥⇧⌘ then the key.
    var display: String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols + (Self.namedKeys[key] ?? key.uppercased())
    }

    /// The SwiftUI shortcut a menu command uses.
    var keyboardShortcut: KeyboardShortcut {
        var eventModifiers: EventModifiers = []
        if modifiers.contains(.command) { eventModifiers.insert(.command) }
        if modifiers.contains(.control) { eventModifiers.insert(.control) }
        if modifiers.contains(.option) { eventModifiers.insert(.option) }
        if modifiers.contains(.shift) { eventModifiers.insert(.shift) }
        return KeyboardShortcut(keyEquivalent, modifiers: eventModifiers)
    }

    private var keyEquivalent: KeyEquivalent {
        switch key {
        case "tab": .tab
        case "delete": .delete
        case "return": .return
        case "escape": .escape
        case "space": .space
        case "up": .upArrow
        case "down": .downArrow
        case "left": .leftArrow
        case "right": .rightArrow
        case "plus": KeyEquivalent("+")
        default:
            if key.hasPrefix("f"), let number = Int(key.dropFirst()), (1...12).contains(number),
               let scalar = Unicode.Scalar(UInt32(NSF1FunctionKey + number - 1)) {
                KeyEquivalent(Character(scalar))
            } else {
                KeyEquivalent(Character(key))
            }
        }
    }
}
