import Foundation
import Observation

/// A color from the scene: `#rrggbb`.
public struct SceneColor: Hashable, Sendable {
  public var red, green, blue: UInt8

  public init(red: UInt8, green: UInt8, blue: UInt8) {
    self.red = red
    self.green = green
    self.blue = blue
  }

  public init?(_ value: Any?) {
    guard let text = value as? String, text.count == 7, text.first == "#", let number = UInt32(text.dropFirst(), radix: 16) else {
      return nil
    }
    self.init(red: UInt8(number >> 16 & 0xFF), green: UInt8(number >> 8 & 0xFF), blue: UInt8(number & 0xFF))
  }
}

/// A run of cells with one style. Each `Character` of `text` fills one cell; a
/// wide character is followed by the blank cell it covers, as Fresh draws it.
public struct CellRun: Equatable, Sendable {
  public var text: String
  public var foreground, background: SceneColor?
  public var bold, italic, underline, reverse: Bool
  /// How many cells the run covers.
  public var cells: Int

  public init(text: String, foreground: SceneColor? = nil, background: SceneColor? = nil,
              bold: Bool = false, italic: Bool = false, underline: Bool = false, reverse: Bool = false) {
    self.text = text
    self.foreground = foreground
    self.background = background
    self.bold = bold
    self.italic = italic
    self.underline = underline
    self.reverse = reverse
    cells = text.count
  }

  init?(json: Any) {
    guard let run = json as? [String: Any], let text = run["t"] as? String else { return nil }
    self.init(text: text, foreground: SceneColor(run["fg"]), background: SceneColor(run["bg"]),
              bold: run["b"] as? Bool ?? false, italic: run["i"] as? Bool ?? false,
              underline: run["u"] as? Bool ?? false, reverse: run["r"] as? Bool ?? false)
  }

  /// Decodes one row: an array of runs.
  public static func row(_ json: Any?) -> [CellRun] {
    (json as? [Any] ?? []).compactMap { CellRun(json: $0) }
  }
}

/// A rectangle of cells.
public struct CellRect: Equatable, Sendable {
  public var x, y, width, height: Int

  public init(x: Int, y: Int, width: Int, height: Int) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  /// Reads `{x, y, w, h}`.
  public init?(_ json: Any?) {
    guard let rect = json as? [String: Any] else { return nil }
    x = rect["x"] as? Int ?? 0
    y = rect["y"] as? Int ?? 0
    width = rect["w"] as? Int ?? 0
    height = rect["h"] as? Int ?? 0
  }

  public func contains(column: Int, row: Int) -> Bool {
    column >= x && column < x + width && row >= y && row < y + height
  }
}

/// The colors of Fresh's theme that chrome is drawn with.
public struct SceneTheme: Equatable, Sendable {
  public var name = ""
  public var background, foreground, accent, muted, selection: SceneColor?
  public var menuBackground, menuForeground, menuHighlight, menuHighlightForeground: SceneColor?
  public var popupBackground, popupForeground, border: SceneColor?
  public var statusBackground, statusForeground, tabActiveBackground: SceneColor?

  public init() {}

  init(json: Any?) {
    guard let theme = json as? [String: Any] else { return }
    name = theme["name"] as? String ?? ""
    background = SceneColor(theme["bg"])
    foreground = SceneColor(theme["fg"])
    accent = SceneColor(theme["accent"])
    muted = SceneColor(theme["muted"])
    selection = SceneColor(theme["selectionBg"])
    menuBackground = SceneColor(theme["menuBg"])
    menuForeground = SceneColor(theme["menuFg"])
    menuHighlight = SceneColor(theme["menuHi"])
    menuHighlightForeground = SceneColor(theme["menuHighlightFg"])
    popupBackground = SceneColor(theme["popupBg"])
    popupForeground = SceneColor(theme["popupFg"])
    border = SceneColor(theme["border"])
    statusBackground = SceneColor(theme["statusBg"])
    statusForeground = SceneColor(theme["statusFg"])
    tabActiveBackground = SceneColor(theme["tabActiveBg"])
  }

  /// Whether text on the editor background should be light.
  public var isDark: Bool {
    guard let bg = background else { return true }
    return 0.299 * Double(bg.red) + 0.587 * Double(bg.green) + 0.114 * Double(bg.blue) < 128
  }
}

/// One message from the bridge, parsed off the main thread. A hello carries the
/// whole scene, flattened into the same paths a frame uses, so the store
/// applies both the same way.
public struct SceneMessage: @unchecked Sendable {
  public let isHello: Bool
  public let sequence: Int
  /// Changed top-level values (`w`, `h`, `theme`, `clipboard`, `windowId`) and
  /// regions (`regions.<key>`), except panes and grid rows.
  public let values: [String: Any]
  /// Changed grid rows, decoded, by row index.
  public let gridRows: [Int: [CellRun]]
  /// The new number of grid rows, when it changed.
  public let gridCount: Int?
  /// Changed panes by index, and the new pane count when it changed.
  public let panes: [Int: Any]
  public let paneCount: Int?

  init?(json data: [UInt8]) {
    guard let object = try? JSONSerialization.jsonObject(with: Data(data)) as? [String: Any], let type = object["type"] as? String else {
      return nil
    }
    sequence = object["seq"] as? Int ?? 0
    var values: [String: Any] = [:]
    var rows: [Int: [CellRun]] = [:]
    var panes: [Int: Any] = [:]
    var gridCount: Int?
    var paneCount: Int?
    switch type {
    case "hello":
      isHello = true
      let scene = object["scene"] as? [String: Any] ?? [:]
      for (key, value) in scene where key != "regions" { values[key] = value }
      for (key, value) in scene["regions"] as? [String: Any] ?? [:] {
        switch key {
        case "grid":
          let all = value as? [Any] ?? []
          for (index, row) in all.enumerated() { rows[index] = CellRun.row(row) }
          gridCount = all.count
        case "panes":
          let all = value as? [Any] ?? []
          for (index, pane) in all.enumerated() { panes[index] = pane }
          paneCount = all.count
        default:
          values["regions." + key] = value
        }
      }
      gridCount = gridCount ?? 0
      paneCount = paneCount ?? 0
    case "frame":
      isHello = false
      for (key, value) in object["changed"] as? [String: Any] ?? [:] {
        if key.hasPrefix("regions.grid.") {
          let rest = key.dropFirst("regions.grid.".count)
          if rest == "len" { gridCount = value as? Int } else if let index = Int(rest) { rows[index] = CellRun.row(value) }
        } else if key.hasPrefix("regions.panes.") {
          let rest = key.dropFirst("regions.panes.".count)
          if rest == "len" { paneCount = value as? Int } else if let index = Int(rest) { panes[index] = value }
        } else {
          values[key] = value
        }
      }
    default:
      return nil
    }
    self.values = values
    self.gridRows = rows
    self.gridCount = gridCount
    self.panes = panes
    self.paneCount = paneCount
  }
}

/// What one applied message changed, for views that redraw selectively.
public struct SceneChange: Sendable {
  public var rows = IndexSet()
  public var sizeChanged = false
  public var cursorChanged = false
  public var themeChanged = false
  public var regions = Set<String>()
  public var isHello = false
}

/// The scene as last sent, kept current by applying the bridge's messages.
@MainActor
@Observable
public final class SceneStore {
  public private(set) var width = 0
  public private(set) var height = 0
  public private(set) var theme = SceneTheme()
  public private(set) var cursor: (column: Int, row: Int)?
  public private(set) var windowID = 0
  /// Raises with every applied message.
  public private(set) var revision = 0
  /// The editor's latest copy: its sequence number and text.
  public private(set) var clipboard: (sequence: Int, text: String)?

  /// Every row of the frame, when the client asked for the grid.
  @ObservationIgnored public private(set) var grid: [[CellRun]] = []
  /// The panes, as raw JSON objects.
  @ObservationIgnored public private(set) var panes: [[String: Any]] = []
  /// Every other region, as raw JSON, by key (`menus`, `statusbar`, `palette`, ...).
  @ObservationIgnored public private(set) var regions: [String: Any] = [:]
  /// Raises when the region named by the key changes.
  public private(set) var regionRevisions: [String: Int] = [:]

  /// Called after each message with what it changed.
  @ObservationIgnored public var onChange: ((SceneChange) -> Void)?

  public init() {}

  public func apply(_ message: SceneMessage) {
    var change = SceneChange()
    change.isHello = message.isHello
    if message.isHello {
      regions = [:]
      grid = []
      panes = []
    }
    if let w = message.values["w"] as? Int, w != width { width = w; change.sizeChanged = true }
    if let h = message.values["h"] as? Int, h != height { height = h; change.sizeChanged = true }
    if let id = message.values["windowId"] as? Int { windowID = id }
    if message.values.keys.contains("theme") {
      theme = SceneTheme(json: message.values["theme"])
      change.themeChanged = true
    }
    if let copy = message.values["clipboard"] as? [String: Any], let text = copy["text"] as? String {
      clipboard = (copy["seq"] as? Int ?? 0, text)
    }
    if let count = message.gridCount {
      if count < grid.count { grid.removeLast(grid.count - count) }
      while grid.count < count { grid.append([]) }
      change.sizeChanged = change.sizeChanged || message.isHello
    }
    for (index, row) in message.gridRows where index < grid.count {
      grid[index] = row
      change.rows.insert(index)
    }
    if let count = message.paneCount {
      if count < panes.count { panes.removeLast(panes.count - count) }
      while panes.count < count { panes.append([:]) }
    }
    for (index, pane) in message.panes where index < panes.count {
      panes[index] = pane as? [String: Any] ?? [:]
    }
    if message.paneCount != nil || !message.panes.isEmpty { change.regions.insert("panes") }
    for (key, value) in message.values where key.hasPrefix("regions.") {
      let name = String(key.dropFirst("regions.".count))
      regions[name] = value
      change.regions.insert(name)
      if name == "cursor" {
        let point = value as? [String: Any]
        let next = point.flatMap { p in (p["x"] as? Int).flatMap { x in (p["y"] as? Int).map { (x, $0) } } }
        if next?.0 != cursor?.column || next?.1 != cursor?.row {
          change.cursorChanged = true
          if let old = cursor { change.rows.insert(old.row) }
          if let new = next { change.rows.insert(new.1) }
        }
        cursor = next.map { (column: $0.0, row: $0.1) }
      }
    }
    for name in change.regions { regionRevisions[name, default: 0] += 1 }
    revision += 1
    onChange?(change)
  }

  /// The text of one grid row.
  public func text(row: Int) -> String {
    guard row >= 0, row < grid.count else { return "" }
    return grid[row].map(\.text).joined()
  }

  /// Every grid row as text.
  public var lines: [String] { (0..<grid.count).map { text(row: $0) } }
}
