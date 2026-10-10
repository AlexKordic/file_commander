import AppKit
import SwiftUI

/// A portable key description such as "F5", "Ctrl+T", "Shift+Cmd+P" or "+".
/// The same strings appear in the command catalog and in app_settings.json.
struct KeyChord: Hashable, Codable, CustomStringConvertible {
  struct Modifiers: OptionSet, Hashable, Codable {
    let rawValue: Int
    static let control = Modifiers(rawValue: 1)
    static let option = Modifiers(rawValue: 2)
    static let shift = Modifiers(rawValue: 4)
    static let command = Modifiers(rawValue: 8)
  }

  var modifiers: Modifiers
  var key: String  // "F5", "Enter", "Esc", "Tab", "Space", "Backspace", "Delete", "Up", ..., or one character (letters uppercase)

  init(modifiers: Modifiers = [], key: String) {
    self.modifiers = modifiers
    self.key = key.count == 1 ? key.uppercased() : key
  }

  /// Parses "Shift+Cmd+P"; returns nil for an empty or malformed chord.
  init?(_ text: String) {
    let text = text.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    var parts: [String]
    if text == "+" {
      parts = ["+"]
    } else if text.hasSuffix("++") {
      parts = text.dropLast(2).split(separator: "+").map(String.init) + ["+"]
    } else {
      parts = text.split(separator: "+").map(String.init)
    }
    guard let last = parts.popLast() else { return nil }
    var mods: Modifiers = []
    for part in parts {
      switch part.lowercased() {
      case "ctrl", "control": mods.insert(.control)
      case "opt", "option", "alt": mods.insert(.option)
      case "shift": mods.insert(.shift)
      case "cmd", "command": mods.insert(.command)
      default: return nil
      }
    }
    guard let key = KeyChord.canonicalKey(last) else { return nil }
    self.init(modifiers: mods, key: key)
  }

  private static let named = ["F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
                              "Enter", "Esc", "Tab", "Space", "Backspace", "Delete", "Up", "Down", "Left", "Right",
                              "Home", "End", "PageUp", "PageDown"]

  private static func canonicalKey(_ raw: String) -> String? {
    if raw.count == 1 { return raw.uppercased() }
    let aliases = ["return": "Enter", "escape": "Esc", "del": "Delete", "pgup": "PageUp", "pgdn": "PageDown"]
    if let alias = aliases[raw.lowercased()] { return alias }
    return named.first { $0.lowercased() == raw.lowercased() }
  }

  var description: String {
    var parts: [String] = []
    if modifiers.contains(.control) { parts.append("Ctrl") }
    if modifiers.contains(.option) { parts.append("Opt") }
    if modifiers.contains(.shift) { parts.append("Shift") }
    if modifiers.contains(.command) { parts.append("Cmd") }
    parts.append(key)
    return parts.joined(separator: "+")
  }

  /// The chord in Mac menu notation, such as ⇧⌘P or F5.
  var symbols: String {
    var s = ""
    if modifiers.contains(.control) { s += "⌃" }
    if modifiers.contains(.option) { s += "⌥" }
    if modifiers.contains(.shift) { s += "⇧" }
    if modifiers.contains(.command) { s += "⌘" }
    let glyphs = ["Enter": "↩", "Esc": "⎋", "Tab": "⇥", "Space": "Space", "Backspace": "⌫", "Delete": "⌦",
                  "Up": "↑", "Down": "↓", "Left": "←", "Right": "→", "Home": "↖", "End": "↘", "PageUp": "⇞", "PageDown": "⇟"]
    return s + (glyphs[key] ?? key)
  }

  var isFunctionKey: Bool { key.count >= 2 && key.hasPrefix("F") && Int(key.dropFirst()) != nil }
  /// Plain keys (no Cmd, Ctrl or F-key) are typed into text fields, so they never become menu shortcuts.
  var isMenuSafe: Bool { modifiers.contains(.command) || modifiers.contains(.control) || isFunctionKey }

  // MARK: Events

  private static let keyCodes: [UInt16: String] = [
    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    36: "Enter", 76: "Enter", 53: "Esc", 48: "Tab", 49: "Space", 51: "Backspace", 117: "Delete",
    126: "Up", 125: "Down", 123: "Left", 124: "Right", 115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
  ]

  /// The chord a key event represents.
  init?(event: NSEvent) {
    guard event.type == .keyDown else { return nil }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    var mods: Modifiers = []
    if flags.contains(.control) { mods.insert(.control) }
    if flags.contains(.option) { mods.insert(.option) }
    if flags.contains(.shift) { mods.insert(.shift) }
    if flags.contains(.command) { mods.insert(.command) }
    if let name = KeyChord.keyCodes[event.keyCode] {
      self.init(modifiers: mods, key: name)
      return
    }
    if mods.contains(.command) || mods.contains(.control) {
      guard let chars = event.charactersIgnoringModifiers, let c = chars.first else { return nil }
      // Shift is explicit for letters; for symbols it is part of the character.
      if !c.isLetter && !c.isNumber { mods.remove(.shift) }
      self.init(modifiers: mods, key: String(c))
      return
    }
    guard let chars = event.characters, let c = chars.first, !c.isNewline else { return nil }
    if !c.isLetter { mods.remove(.shift) }
    mods.remove(.option)
    self.init(modifiers: mods, key: String(c))
  }

  /// A SwiftUI shortcut for menus, when the chord can be one.
  var shortcut: KeyboardShortcut? {
    guard isMenuSafe else { return nil }
    var mods: EventModifiers = []
    if modifiers.contains(.control) { mods.insert(.control) }
    if modifiers.contains(.option) { mods.insert(.option) }
    if modifiers.contains(.shift) { mods.insert(.shift) }
    if modifiers.contains(.command) { mods.insert(.command) }
    let equivalent: KeyEquivalent
    switch key {
    case "Enter": equivalent = .return
    case "Esc": equivalent = .escape
    case "Tab": equivalent = .tab
    case "Space": equivalent = .space
    case "Backspace": equivalent = .delete
    case "Delete": equivalent = .deleteForward
    case "Up": equivalent = .upArrow
    case "Down": equivalent = .downArrow
    case "Left": equivalent = .leftArrow
    case "Right": equivalent = .rightArrow
    case "Home": equivalent = .home
    case "End": equivalent = .end
    case "PageUp": equivalent = .pageUp
    case "PageDown": equivalent = .pageDown
    default:
      if isFunctionKey, let n = Int(key.dropFirst()), let scalar = UnicodeScalar(NSF1FunctionKey + n - 1) {
        equivalent = KeyEquivalent(Character(scalar))
      } else if let c = key.lowercased().first {
        equivalent = KeyEquivalent(c)
      } else {
        return nil
      }
    }
    return KeyboardShortcut(equivalent, modifiers: mods)
  }
}
