import CoreGraphics
import Foundation

/// Where terminal cells are, in the overlay's coordinates: points, origin at the
/// terminal window's top-left corner, y growing downwards.
public struct CellGrid: Equatable, Sendable {
  public var originX: Double
  public var originY: Double
  public var cellWidth: Double
  public var cellHeight: Double
  public var cols: Int
  public var rows: Int

  public init(originX: Double, originY: Double, cellWidth: Double, cellHeight: Double, cols: Int, rows: Int) {
    self.originX = originX
    self.originY = originY
    self.cellWidth = cellWidth
    self.cellHeight = cellHeight
    self.cols = cols
    self.rows = rows
  }

  public func rect(_ cells: CellRect, padding: Double = 0) -> CGRect {
    CGRect(x: originX + Double(cells.col) * cellWidth - padding,
           y: originY + Double(cells.row) * cellHeight - padding,
           width: Double(cells.cols) * cellWidth + 2 * padding,
           height: Double(cells.rows) * cellHeight + 2 * padding)
  }

  public func center(_ cells: CellRect) -> CGPoint {
    let r = rect(cells)
    return CGPoint(x: r.midX, y: r.midY)
  }

  /// The whole text area.
  public var textArea: CGRect {
    CGRect(x: originX, y: originY, width: Double(cols) * cellWidth, height: Double(rows) * cellHeight)
  }
}

/// The text area's offset inside the terminal window and, when set by hand, the cell size.
public struct Calibration: Codable, Equatable, Sendable {
  public var left: Double
  public var top: Double
  public var cellWidth: Double?
  public var cellHeight: Double?

  public init(left: Double, top: Double, cellWidth: Double? = nil, cellHeight: Double? = nil) {
    self.left = left
    self.top = top
    self.cellWidth = cellWidth
    self.cellHeight = cellHeight
  }
}

public enum GridSolver {
  /// Where iTerm2 3.7 on macOS 26 starts the text with default margins: 5 pt
  /// from the left, and 35 pt from the top, under the title bar.
  public static let iTermDefault = Calibration(left: 5, top: 35)

  /// Cell size comes from a hand calibration first, then from the terminal's
  /// report, and last from dividing the window by the grid.
  public static func grid(window: CGSize, cols: Int, rows: Int, terminal: TerminalGeometry?,
                          calibration: Calibration?) -> CellGrid {
    let base = calibration ?? iTermDefault
    let usableWidth = max(1, Double(window.width) - 2 * base.left)
    let usableHeight = max(1, Double(window.height) - base.top - 2)
    let cellWidth = base.cellWidth ?? terminal?.cellWidth ?? usableWidth / Double(max(cols, 1))
    let cellHeight = base.cellHeight ?? terminal?.cellHeight ?? usableHeight / Double(max(rows, 1))
    return CellGrid(originX: base.left, originY: base.top, cellWidth: cellWidth, cellHeight: cellHeight,
                    cols: cols, rows: rows)
  }
}

/// Calibrations saved per terminal app, as JSON.
public struct CalibrationStore: Sendable {
  public var url: URL

  public init(url: URL) { self.url = url }

  public static var defaultURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/fc-promo-overlay/calibration.json")
  }

  public func load(terminal: String) -> Calibration? {
    all()[terminal]
  }

  public func save(_ calibration: Calibration, terminal: String) throws {
    var entries = all()
    entries[terminal] = calibration
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(entries).write(to: url, options: .atomic)
  }

  private func all() -> [String: Calibration] {
    guard let data = try? Data(contentsOf: url) else { return [:] }
    return (try? JSONDecoder().decode([String: Calibration].self, from: data)) ?? [:]
  }
}
