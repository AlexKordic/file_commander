import Foundation
import CoreText
import CoreGraphics

extension ComposeTextLayout {
  public struct TableRun {
    public let table: ComposeTableModel.Table
    public let indent, before, after: CGFloat
    public let columns: [CGFloat]?
    public let adaptiveMinimum: Bool
    public init(table: ComposeTableModel.Table, indent: CGFloat = 0, before: CGFloat = 0, after: CGFloat = 0, columns: [CGFloat]? = nil, adaptiveMinimum: Bool = false) {
      self.table = table; self.indent = indent; self.before = before; self.after = after
      self.columns = columns; self.adaptiveMinimum = adaptiveMinimum
    }
  }

  public struct TablePosition: Equatable, Sendable {
    public let table: Int
    public let row: Range<Int>
    /// nil identifies a structural source row spanning all columns.
    public let column: Int?
    public let source: Range<Int>
  }

  public struct TableCell: Sendable {
    public let source: Range<Int>?
    public let display: NSRange?
    public let rect, content: CGRect
    public let column: Int
    public var missing: Bool { source == nil }
  }

  public struct TableRow: Sendable {
    public let source: Range<Int>
    public let contentEnd: Int
    public let rect: CGRect
    public let header, raw: Bool
    public let cells: [TableCell]
  }

  public struct Table: Sendable {
    public let source: Range<Int>
    public let rect: CGRect
    public let columns: [CGFloat]
    public let rows: [TableRow]
  }
}

/// Measured content constraints, before image run delegates are installed.
/// UTF-16 ranges continue to address the complete projection, not cell copies.
struct ComposeMeasuredTable {
  struct Row {
    let model: ComposeTableModel.Row
    let range: NSRange
    let cells: [NSRange?]
  }
  static let padding: CGFloat = 8
  let run: ComposeTextLayout.TableRun
  let rows: [Row]
  let columns: [CGFloat]
  let indent: CGFloat
  var width: CGFloat { columns.reduce(0, +) }

  init?(run: ComposeTextLayout.TableRun, attributed: NSAttributedString, typesetter: ComposeShapingContexts?, font: CTFont,
        width: CGFloat, indices: [Int: Int], attachments: [ComposeTextLayout.Attachment]) {
    guard [run.indent, run.before, run.after].allSatisfy({ $0.isFinite && $0 >= 0 }),
          !run.table.alignments.isEmpty else { return nil }
    self.run = run
    indent = min(run.indent, width * 0.6)
    let available = max(1, width - indent)
    var constraints = ComposeColumnConstraints(count: run.table.alignments.count, font: font, available: available)
    if let columns = run.columns {
      guard columns.count == run.table.alignments.count, columns.allSatisfy({ $0.isFinite && $0 > Self.padding * 2 }) else { return nil }
    }
    var rows: [Row] = []
    func range(_ bytes: Range<Int>) -> NSRange? {
      guard let a = indices[bytes.lowerBound], let b = indices[bytes.upperBound], a <= b else { return nil }
      return NSRange(location: a, length: b - a)
    }
    for row in run.table.rows {
      guard let span = range(row.display) else { return nil }
      var cells: [NSRange?] = []
      for (column, cell) in row.cells.enumerated() {
        guard column < run.table.alignments.count else { return nil }
        guard let display = cell.display else { cells.append(nil); continue }
        guard let span = range(display) else { return nil }
        cells.append(span)
        if !row.raw, run.columns == nil || run.adaptiveMinimum {
          let imageWidth = attachments.filter { $0.display.overlaps(display) }.map { min($0.size.width, available * 0.35) }.max() ?? 0
          guard let typesetter, constraints.include(attributed, range: span, column: column, preferred: run.columns == nil,
            imageWidth: imageWidth, typesetter: typesetter) else { return nil }
        }
      }
      guard row.raw || cells.count == run.table.alignments.count else { return nil }
      rows.append(.init(model: row, range: span, cells: cells))
    }
    self.rows = rows
    if let fixed = run.columns {
      columns = run.adaptiveMinimum ? zip(fixed, constraints.minimum).map { max($0, $1 + Self.padding * 2) } : fixed
    } else { columns = constraints.widths }
  }
}
