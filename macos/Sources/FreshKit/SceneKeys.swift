import Foundation

/// Turns Mac key presses into the scene channel's `Key` messages, which use
/// browser key names (`Enter`, `ArrowUp`, `F5`, single characters) with
/// modifier flags.
public enum SceneKeys {
  /// Named keys by virtual key code.
  static let named: [UInt16: String] = [
    36: "Enter", 76: "Enter", 48: "Tab", 51: "Backspace", 117: "Delete", 53: "Escape",
    123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp",
    115: "Home", 119: "End", 116: "PageUp", 121: "PageDown", 114: "Insert",
    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
    98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
  ]

  /// The digit-row keys, which the bridge reads digits from when Control is
  /// held (Ctrl+Shift+1 types "!", but bindings name the digit).
  static let digitRow: [UInt16: String] = [
    18: "Digit1", 19: "Digit2", 20: "Digit3", 21: "Digit4", 23: "Digit5",
    22: "Digit6", 26: "Digit7", 28: "Digit8", 25: "Digit9", 29: "Digit0",
  ]

  /// Whether the key is one the bridge names (arrows, F-keys, Enter, ...).
  public static func isNamed(keyCode: UInt16) -> Bool { named[keyCode] != nil }

  /// The key message for a press, or nil when the press is typing and should
  /// go through text input instead (so input methods and dead keys work).
  ///
  /// - Parameter optionAsAlt: Option sends Alt instead of typing its
  ///   character, for Fresh's Alt shortcuts.
  public static func message(keyCode: UInt16, charactersIgnoringModifiers: String?, command: Bool, control: Bool,
                             option: Bool, shift: Bool, optionAsAlt: Bool) -> WireKey? {
    let alt = option && optionAsAlt
    var key: String
    if let name = named[keyCode] {
      key = name
    } else if command || control || alt {
      guard let base = charactersIgnoringModifiers, base.count == 1 else { return nil }
      key = base
    } else {
      return nil
    }
    // A letter with Shift is sent uppercase, as a browser reports it.
    if shift, key.count == 1, key.first?.isLetter == true { key = key.uppercased() }
    return WireKey.with {
      $0.key = key
      $0.ctrl = control
      $0.alt = alt
      $0.meta = command
      $0.shift = shift
      if let code = digitRow[keyCode] { $0.code = code }
    }
  }

  /// Key messages that type `text`, one per character; newlines and tabs press
  /// Enter and Tab.
  public static func typing(_ text: String) -> [WireKey] {
    text.map { character in
      let key = character == "\n" || character == "\r\n" ? "Enter" : character == "\t" ? "Tab" : String(character)
      return WireKey.with { $0.key = key }
    }
  }
}
