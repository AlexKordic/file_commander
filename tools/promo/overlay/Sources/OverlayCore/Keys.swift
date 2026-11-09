/// How a key name from the storyboard appears on a badge.
public enum KeyLabel {
  static let glyphs = ["Up": "↑", "Down": "↓", "Left": "←", "Right": "→"]

  public static func pretty(_ key: String) -> String {
    if let glyph = glyphs[key] { return glyph }
    if key.hasPrefix("Ctrl+") { return "Ctrl+" + pretty(String(key.dropFirst(5))) }
    return key
  }
}

/// Merges quick repeats of one key into a single badge ("↓ ×3").
public struct KeyCoalescer: Sendable {
  public var window: Double
  private var last: (label: String, time: Double, count: Int)?

  public init(window: Double = 0.9) { self.window = window }

  /// The badge text, and whether it replaces the previous badge.
  public mutating func add(_ label: String, at time: Double) -> (text: String, merges: Bool) {
    if let previous = last, previous.label == label, time - previous.time <= window {
      let count = previous.count + 1
      last = (label, time, count)
      return ("\(KeyLabel.pretty(label)) ×\(count)", true)
    }
    last = (label, time, 1)
    return (KeyLabel.pretty(label), false)
  }

  public mutating func reset() { last = nil }
}
