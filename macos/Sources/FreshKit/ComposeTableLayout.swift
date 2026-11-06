import Foundation
import CoreText
import CoreGraphics

extension ComposeTextLayout {
  public struct TableRun {
    public let table: ComposeTableModel.Table
    public let indent, before, after: CGFloat
    public init(table: ComposeTableModel.Table, indent: CGFloat = 0, before: CGFloat = 0, after: CGFloat = 0) {
      self.table = table; self.indent = indent; self.before = before; self.after = after
    }
  }

  public struct TablePosition: Equatable {
    public let table: Int
    public let row: Range<Int>
    /// nil identifies a structural source row spanning all columns.
    public let column: Int?
    public let source: Range<Int>
  }

  public struct TableCell {
    public let source: Range<Int>?
    public let display: NSRange?
    public let rect, content: CGRect
    public let column: Int
    public var missing: Bool { source == nil }
  }

  public struct TableRow {
    public let source: Range<Int>
    public let contentEnd: Int
    public let rect: CGRect
    public let header, raw: Bool
    public let cells: [TableCell]
  }

  public struct Table {
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

  init?(run: ComposeTextLayout.TableRun, attributed: NSAttributedString, font: CTFont,
        width: CGFloat, indices: [Int: Int], attachments: [ComposeTextLayout.Attachment]) {
    guard [run.indent, run.before, run.after].allSatisfy({ $0.isFinite && $0 >= 0 }),
          !run.table.alignments.isEmpty else { return nil }
    self.run = run
    indent = min(run.indent, width * 0.6)
    let available = max(1, width - indent)
    let string = attributed.string as NSString
    let typesetter = CTTypesetterCreateWithAttributedString(attributed)
    let blank = CTLineCreateWithAttributedString(NSAttributedString(string: " ", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
    let emptyWidth = max(1, CGFloat(CTLineGetTypographicBounds(blank, nil, nil, nil)))
    var minimum = Array(repeating: emptyWidth, count: run.table.alignments.count)
    var natural = minimum, rows: [Row] = []
    func range(_ bytes: Range<Int>) -> NSRange? {
      guard let a = indices[bytes.lowerBound], let b = indices[bytes.upperBound], a <= b else { return nil }
      return NSRange(location: a, length: b - a)
    }
    for row in run.table.rows {
      guard let span = range(row.display) else { return nil }
      var cells: [NSRange?] = []
      for (column, cell) in row.cells.enumerated() {
        guard column < natural.count else { return nil }
        guard let display = cell.display else { cells.append(nil); continue }
        guard let span = range(display) else { return nil }
        cells.append(span)
        guard !row.raw, span.length > 0 else { continue }
        let line = CTTypesetterCreateLine(typesetter, CFRange(location: span.location, length: span.length))
        var cellNatural = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        var at = span.location
        while at < NSMaxRange(span) {
          let cluster = string.rangeOfComposedCharacterSequence(at: at)
          guard cluster.location == at, NSMaxRange(cluster) <= NSMaxRange(span) else { return nil }
          let a = CTLineGetOffsetForStringIndex(line, at, nil), b = CTLineGetOffsetForStringIndex(line, NSMaxRange(cluster), nil)
          minimum[column] = max(minimum[column], abs(b - a))
          at = NSMaxRange(cluster)
        }
        do {
          // Keep short words readable before distributing spare space by
          // content. The bound is a pixel share, not a character count; an
          // unbroken long word can still wrap instead of forcing a huge grid.
          let share = max(emptyWidth, available / CGFloat(natural.count) - Self.padding * 2)
          string.enumerateSubstrings(in: span, options: [.byWords, .substringNotRequired]) { _, word, _, _ in
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: word.location, length: word.length))
            minimum[column] = max(minimum[column], min(share, ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))) + 0.5))
          }
        }
        for image in attachments where image.display.overlaps(display) {
          // The image is scalable. It contributes a preferred width, not an
          // unshrinkable minimum that would force a terminal-style grid.
          cellNatural = max(cellNatural, min(image.size.width, available * 0.35))
        }
        natural[column] = max(natural[column], min(available, cellNatural))
      }
      guard row.raw || cells.count == natural.count else { return nil }
      rows.append(.init(model: row, range: span, cells: cells))
    }
    self.rows = rows
    minimum = minimum.map { $0 + Self.padding * 2 }
    natural = zip(natural, minimum).map { max($0 + Self.padding * 2, $1) }
    let floor = minimum.reduce(0, +), desired = natural.reduce(0, +)
    if available >= desired {
      columns = natural.map { $0 + (available - desired) / CGFloat(natural.count) }
    } else if available > floor {
      columns = zip(minimum, natural).map { $0 + ($1 - $0) * (available - floor) / (desired - floor) }
    } else {
      // A cluster must remain intact. Expose the actual overflow extent so a
      // consumer can scroll it; never clip text or split it to fit a column.
      columns = minimum
    }
  }
}
