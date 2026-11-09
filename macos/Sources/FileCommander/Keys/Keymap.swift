import FCKit
import Foundation

/// Which chord runs which command, for the active preset plus the user's overrides.
struct Keymap {
  var preset: AppPreferences.KeyPreset
  var overrides: [String: String]  // Command ID to chord string for this preset; "" unbinds.
  var commands: [CommandInfo]

  /// Keys the system or the app keeps for itself.
  static let reserved: Set<KeyChord> = [
    KeyChord("Cmd+Q")!, KeyChord("Cmd+H")!, KeyChord("Cmd+M")!, KeyChord("Cmd+,")!, KeyChord("Cmd+Tab")!,
    KeyChord("Cmd+Space")!, KeyChord("Cmd+`")!, KeyChord("Opt+Cmd+Esc")!,
  ]

  func defaultChord(_ command: CommandInfo) -> KeyChord? {
    KeyChord(preset == .commander ? command.commanderKey : command.macKey)
  }

  func chord(for id: String) -> KeyChord? {
    if let override = overrides[id] { return KeyChord(override) }
    guard let command = commands.first(where: { $0.id == id }) else { return nil }
    return defaultChord(command)
  }

  func command(for chord: KeyChord) -> String? {
    for command in commands where !command.hidden {
      if self.chord(for: command.id) == chord { return command.id }
    }
    return nil
  }

  /// Validates a rebinding; returns why it can't be used, or nil.
  func conflict(binding chord: KeyChord, to id: String) -> String? {
    if Keymap.reserved.contains(chord) { return "\(chord.symbols) is reserved by macOS" }
    if let other = command(for: chord), other != id {
      let title = commands.first { $0.id == other }?.title ?? other
      return "\(chord.symbols) already runs “\(title)”"
    }
    return nil
  }
}
