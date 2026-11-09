import Foundation

/// A colour parsed from #RRGGBB or #RRGGBBAA.
public struct RGBA: Equatable, Sendable {
  public var r: Double
  public var g: Double
  public var b: Double
  public var a: Double

  public init(r: Double, g: Double, b: Double, a: Double = 1) {
    self.r = r
    self.g = g
    self.b = b
    self.a = a
  }

  public init?(hex: String) {
    var digits = hex.trimmingCharacters(in: .whitespaces)
    if digits.hasPrefix("#") { digits.removeFirst() }
    guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
    let alpha = digits.count == 8 ? Double(value & 0xFF) / 255 : 1
    let rgb = digits.count == 8 ? value >> 8 : value
    self.init(r: Double((rgb >> 16) & 0xFF) / 255, g: Double((rgb >> 8) & 0xFF) / 255,
              b: Double(rgb & 0xFF) / 255, a: alpha)
  }
}

/// Every look-and-feel value. A theme file only lists the values it changes.
public struct Theme: Codable, Equatable, Sendable {
  public var accent = "#4C9AFF"

  public var captionBackground = "#0E1116F2"
  public var captionBorder = "#FFFFFF2E"
  public var captionTitleColor = "#FFFFFF"
  public var captionSubColor = "#C9D1D9"
  public var captionTitleSize = 30.0
  public var captionSubSize = 18.0
  /// Widest caption, as a fraction of the terminal window's width.
  public var captionMaxWidth = 0.62
  /// Gap between the card and the window's bottom edge, as a fraction of its height.
  public var captionBottom = 0.09
  public var captionCornerRadius = 18.0
  public var captionIn = 0.38
  public var captionOut = 0.22

  public var highlightPadding = 4.0
  public var highlightLineWidth = 3.0
  public var highlightIn = 0.3
  public var highlightMove = 0.35
  /// Seconds a highlight stays when nothing replaces it.
  public var highlightLinger = 3.0
  /// Darkness outside a `spotlight` highlight, 0...1.
  public var spotlightDim = 0.45

  public var pointerSize = 28.0
  /// Seconds the pointer stays after its last move.
  public var pointerLinger = 2.5

  public var badgeSize = 20.0
  public var badgeBackground = "#1B2230E6"
  public var badgeTextColor = "#FFFFFF"
  public var badgeIn = 0.25
  public var badgeOut = 0.3
  public var badgeLinger = 1.4
  public var badgeMax = 3

  public var crashColor = "#FF3B30"
  public var crashText = "KILLED"

  /// "chip" shows each scene's title briefly in the top-left corner; "off" hides it.
  public var sceneTitles = "off"

  public init() {}

  public enum LoadError: Error, CustomStringConvertible {
    case notAnObject
    case unknownKey(String)

    public var description: String {
      switch self {
      case .notAnObject: "a theme file must contain a JSON object"
      case let .unknownKey(key): "unknown theme key: \(key)"
      }
    }
  }

  /// Applies a partial theme over the defaults. Unknown keys are errors, so a
  /// misspelt key doesn't silently do nothing.
  public static func load(_ data: Data) throws -> Theme {
    guard var merged = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Theme())) as? [String: Any],
          let overrides = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw LoadError.notAnObject }
    for (key, value) in overrides {
      guard merged[key] != nil else { throw LoadError.unknownKey(key) }
      merged[key] = value
    }
    return try JSONDecoder().decode(Theme.self, from: JSONSerialization.data(withJSONObject: merged))
  }
}
