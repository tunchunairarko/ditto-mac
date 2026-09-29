import Foundation
import AppKit
import Carbon.HIToolbox

/// A key combination, and the packing Ditto stores in `Main.lShortCut`.
///
/// Windows Ditto packs a virtual key code and modifier bits into one integer.
/// The same idea works here, but with Carbon key codes and Cocoa modifiers -
/// key codes are not portable between the platforms, so a per-clip shortcut set
/// on Windows will not mean anything on a Mac, and vice versa. Everything else
/// in the database stays interchangeable.
struct HotKey: Equatable, CustomStringConvertible {

    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection([.command, .shift, .option, .control])
    }

    // MARK: - Packing

    private static let commandBit = 1 << 16
    private static let shiftBit = 1 << 17
    private static let optionBit = 1 << 18
    private static let controlBit = 1 << 19

    /// The integer that goes into `Main.lShortCut`.
    var packed: Int {
        var value = Int(keyCode) & 0xFFFF
        if modifiers.contains(.command) { value |= HotKey.commandBit }
        if modifiers.contains(.shift) { value |= HotKey.shiftBit }
        if modifiers.contains(.option) { value |= HotKey.optionBit }
        if modifiers.contains(.control) { value |= HotKey.controlBit }
        return value
    }

    init?(packed: Int) {
        guard packed > 0 else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if packed & HotKey.commandBit != 0 { flags.insert(.command) }
        if packed & HotKey.shiftBit != 0 { flags.insert(.shift) }
        if packed & HotKey.optionBit != 0 { flags.insert(.option) }
        if packed & HotKey.controlBit != 0 { flags.insert(.control) }
        self.init(keyCode: UInt32(packed & 0xFFFF), modifiers: flags)
    }

    // MARK: - Carbon

    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if modifiers.contains(.command) { value |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { value |= UInt32(shiftKey) }
        if modifiers.contains(.option) { value |= UInt32(optionKey) }
        if modifiers.contains(.control) { value |= UInt32(controlKey) }
        return value
    }

    // MARK: - Text form

    /// The stored form, e.g. "cmd+shift+v". Chosen over the packed integer for
    /// the app's own options so a user can read and edit them.
    var stringValue: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(HotKey.name(forKeyCode: keyCode))
        return parts.joined(separator: "+")
    }

    init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.isEmpty == false else { return nil }

        var flags: NSEvent.ModifierFlags = []
        var keyName = ""

        // Split on "+" but keep a trailing "+" that means the plus key itself.
        var parts = trimmed.components(separatedBy: "+")
        if trimmed.hasSuffix("++") {
            parts = Array(parts.dropLast())
            parts[parts.count - 1] = "+"
        }

        for part in parts {
            switch part {
            case "cmd", "command", "meta", "win": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "alt", "opt", "option": flags.insert(.option)
            case "ctrl", "control": flags.insert(.control)
            case "": continue
            default: keyName = part
            }
        }

        guard keyName.isEmpty == false,
              let code = HotKey.keyCode(forName: keyName) else { return nil }
        self.init(keyCode: code, modifiers: flags)
    }

    /// The form shown in menus and the options window.
    var description: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        text += HotKey.symbol(forKeyCode: keyCode)
        return text
    }

    /// The `keyEquivalent` string for an NSMenuItem. Only single characters
    /// make sense there, so named keys come back empty and the menu simply
    /// shows no shortcut.
    var menuKeyEquivalent: String {
        let name = HotKey.name(forKeyCode: keyCode)
        return name.count == 1 ? name : ""
    }

    // MARK: - Key tables

    private static let namesToCodes: [String: UInt32] = {
        let table: [String: UInt32] = [
            "a": UInt32(kVK_ANSI_A), "b": UInt32(kVK_ANSI_B), "c": UInt32(kVK_ANSI_C),
            "d": UInt32(kVK_ANSI_D), "e": UInt32(kVK_ANSI_E), "f": UInt32(kVK_ANSI_F),
            "g": UInt32(kVK_ANSI_G), "h": UInt32(kVK_ANSI_H), "i": UInt32(kVK_ANSI_I),
            "j": UInt32(kVK_ANSI_J), "k": UInt32(kVK_ANSI_K), "l": UInt32(kVK_ANSI_L),
            "m": UInt32(kVK_ANSI_M), "n": UInt32(kVK_ANSI_N), "o": UInt32(kVK_ANSI_O),
            "p": UInt32(kVK_ANSI_P), "q": UInt32(kVK_ANSI_Q), "r": UInt32(kVK_ANSI_R),
            "s": UInt32(kVK_ANSI_S), "t": UInt32(kVK_ANSI_T), "u": UInt32(kVK_ANSI_U),
            "v": UInt32(kVK_ANSI_V), "w": UInt32(kVK_ANSI_W), "x": UInt32(kVK_ANSI_X),
            "y": UInt32(kVK_ANSI_Y), "z": UInt32(kVK_ANSI_Z),

            "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2),
            "3": UInt32(kVK_ANSI_3), "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5),
            "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7), "8": UInt32(kVK_ANSI_8),
            "9": UInt32(kVK_ANSI_9),

            "`": UInt32(kVK_ANSI_Grave), "grave": UInt32(kVK_ANSI_Grave),
            "-": UInt32(kVK_ANSI_Minus), "=": UInt32(kVK_ANSI_Equal),
            "[": UInt32(kVK_ANSI_LeftBracket), "]": UInt32(kVK_ANSI_RightBracket),
            "\\": UInt32(kVK_ANSI_Backslash), ";": UInt32(kVK_ANSI_Semicolon),
            "'": UInt32(kVK_ANSI_Quote), ",": UInt32(kVK_ANSI_Comma),
            ".": UInt32(kVK_ANSI_Period), "/": UInt32(kVK_ANSI_Slash),

            "space": UInt32(kVK_Space), "return": UInt32(kVK_Return),
            "enter": UInt32(kVK_Return), "tab": UInt32(kVK_Tab),
            "escape": UInt32(kVK_Escape), "esc": UInt32(kVK_Escape),
            "delete": UInt32(kVK_Delete), "backspace": UInt32(kVK_Delete),
            "forwarddelete": UInt32(kVK_ForwardDelete),
            "home": UInt32(kVK_Home), "end": UInt32(kVK_End),
            "pageup": UInt32(kVK_PageUp), "pagedown": UInt32(kVK_PageDown),
            "left": UInt32(kVK_LeftArrow), "right": UInt32(kVK_RightArrow),
            "up": UInt32(kVK_UpArrow), "down": UInt32(kVK_DownArrow),

            "f1": UInt32(kVK_F1), "f2": UInt32(kVK_F2), "f3": UInt32(kVK_F3),
            "f4": UInt32(kVK_F4), "f5": UInt32(kVK_F5), "f6": UInt32(kVK_F6),
            "f7": UInt32(kVK_F7), "f8": UInt32(kVK_F8), "f9": UInt32(kVK_F9),
            "f10": UInt32(kVK_F10), "f11": UInt32(kVK_F11), "f12": UInt32(kVK_F12)
        ]
        return table
    }()

    /// Built from a fixed list rather than by walking `namesToCodes`, so the
    /// name a key round-trips to does not depend on dictionary ordering.
    private static let codesToNames: [UInt32: String] = {
        var table: [UInt32: String] = [:]
        let preferred = [
            "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
            "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
            "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
            "`", "-", "=", "[", "]", "\\", ";", "'", ",", ".", "/",
            "space", "return", "tab", "escape", "delete", "forwarddelete",
            "home", "end", "pageup", "pagedown", "left", "right", "up", "down",
            "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12"
        ]
        for name in preferred {
            guard let code = namesToCodes[name], table[code] == nil else { continue }
            table[code] = name
        }
        return table
    }()

    static func keyCode(forName name: String) -> UInt32? {
        return namesToCodes[name.lowercased()]
    }

    static func name(forKeyCode code: UInt32) -> String {
        return codesToNames[code] ?? "key\(code)"
    }

    static func symbol(forKeyCode code: UInt32) -> String {
        switch Int(code) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        default:
            return name(forKeyCode: code).uppercased()
        }
    }

    /// Build a hot key from a key-down event, for the "press a key" field in
    /// the options window.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.isEmpty == false else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: flags)
    }
}
