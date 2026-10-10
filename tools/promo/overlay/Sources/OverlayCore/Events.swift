import Foundation

/// A rectangle of terminal cells, 0-based, as play.py reports it.
public struct CellRect: Equatable, Sendable {
  public var row: Int
  public var col: Int
  public var rows: Int
  public var cols: Int

  public init(row: Int, col: Int, rows: Int = 1, cols: Int = 1) {
    self.row = row
    self.col = col
    self.rows = rows
    self.cols = cols
  }
}

/// Cell metrics the terminal reported before FC started.
public struct TerminalGeometry: Equatable, Sendable {
  /// Cell size in points.
  public var cellWidth: Double?
  public var cellHeight: Double?
  /// Pixels per point.
  public var scale: Double?
  public var terminal: String?

  public init(cellWidth: Double? = nil, cellHeight: Double? = nil, scale: Double? = nil, terminal: String? = nil) {
    self.cellWidth = cellWidth
    self.cellHeight = cellHeight
    self.scale = scale
    self.terminal = terminal
  }
}

/// A calibration step. play.py reads the keys in the terminal, which keeps the
/// keyboard focus, and forwards them by name.
public enum CalibrationKey: Equatable, Sendable {
  case move(dx: Double, dy: Double)
  case cellWidth(Double)
  case cellHeight(Double)
  case save
  case cancel

  /// `big` is Shift: 10 pt moves and 0.5 pt size steps instead of 1 and 0.05.
  public init?(name: String, big: Bool) {
    let step = big ? 10.0 : 1.0
    let fine = big ? 0.5 : 0.05
    switch name {
    case "left": self = .move(dx: -step, dy: 0)
    case "right": self = .move(dx: step, dy: 0)
    case "up": self = .move(dx: 0, dy: -step)
    case "down": self = .move(dx: 0, dy: step)
    case "narrower": self = .cellWidth(-fine)
    case "wider": self = .cellWidth(fine)
    case "shorter": self = .cellHeight(-fine)
    case "taller": self = .cellHeight(fine)
    case "save": self = .save
    case "cancel": self = .cancel
    default: return nil
    }
  }
}

/// What play.py tells the overlay. The player owns the timeline; the overlay only draws.
public enum OverlayEvent: Equatable, Sendable {
  case start(cols: Int, rows: Int, title: String)
  case geometry(TerminalGeometry)
  case scene(id: String, title: String)
  case caption(text: String, sub: String)
  case uncaption
  case highlight(rect: CellRect, style: String, label: String)
  case unhighlight
  case pointer(rect: CellRect, milliseconds: Int, click: Bool)
  /// A mouse drag from one cell to another, as when selecting text.
  case drag(from: CellRect, to: CellRect, milliseconds: Int)
  case key(label: String)
  case type(text: String)
  case launch
  case crash
  case calibrate
  case calibrateKey(CalibrationKey)
  case end
}

public struct TimedEvent: Equatable, Sendable {
  /// Seconds since the player started.
  public var time: Double
  public var event: OverlayEvent

  public init(time: Double, event: OverlayEvent) {
    self.time = time
    self.event = event
  }
}

public enum EventDecoder {
  /// Decodes one JSON line from play.py. Unknown events and malformed lines
  /// return nil, so a newer player can add events without breaking the overlay.
  public static func decode(_ line: String) -> TimedEvent? {
    guard let data = line.data(using: .utf8),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let name = object["event"] as? String
    else { return nil }

    func string(_ key: String) -> String { object[key] as? String ?? "" }
    func int(_ key: String) -> Int? { (object[key] as? NSNumber)?.intValue }
    func double(_ key: String) -> Double? { (object[key] as? NSNumber)?.doubleValue }
    func rect(_ key: String = "rect") -> CellRect? {
      guard let fields = object[key] as? [String: Any],
            let row = (fields["row"] as? NSNumber)?.intValue,
            let col = (fields["col"] as? NSNumber)?.intValue
      else { return nil }
      let rows = (fields["rows"] as? NSNumber)?.intValue ?? 1
      let cols = (fields["cols"] as? NSNumber)?.intValue ?? 1
      return CellRect(row: row, col: col, rows: max(1, rows), cols: max(1, cols))
    }

    let event: OverlayEvent
    switch name {
    case "start":
      guard let cols = int("cols"), let rows = int("rows"), cols > 0, rows > 0 else { return nil }
      event = .start(cols: cols, rows: rows, title: string("title"))
    case "geometry":
      event = .geometry(TerminalGeometry(cellWidth: double("cell_w"), cellHeight: double("cell_h"),
                                         scale: double("scale"), terminal: object["terminal"] as? String))
    case "scene": event = .scene(id: string("id"), title: string("title"))
    case "caption": event = .caption(text: string("text"), sub: string("sub"))
    case "uncaption": event = .uncaption
    case "highlight":
      guard let rect = rect() else { return nil }
      event = .highlight(rect: rect, style: object["style"] as? String ?? "box", label: string("label"))
    case "unhighlight": event = .unhighlight
    case "pointer":
      guard let rect = rect() else { return nil }
      event = .pointer(rect: rect, milliseconds: int("ms") ?? 700, click: object["click"] as? Bool ?? false)
    case "drag":
      guard let from = rect(), let to = rect("to") else { return nil }
      event = .drag(from: from, to: to, milliseconds: int("ms") ?? 900)
    case "key": event = .key(label: string("label"))
    case "type": event = .type(text: string("text"))
    case "launch": event = .launch
    case "crash": event = .crash
    case "calibrate": event = .calibrate
    case "calibrate_key":
      guard let key = CalibrationKey(name: string("key"), big: object["big"] as? Bool ?? false) else { return nil }
      event = .calibrateKey(key)
    case "end": event = .end
    default: return nil
    }
    return TimedEvent(time: double("t") ?? 0, event: event)
  }
}
