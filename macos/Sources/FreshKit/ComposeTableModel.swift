import Foundation

/// Fresh supplies table ownership. The native view resolves these validated
/// source/display ranges into font measurements; it never parses Markdown.
public struct ComposeTableModel {
  public enum Alignment: UInt32 { case automatic = 0, left, center, right }
  public struct Cell {
    public let source: Range<Int>
    public let display: Range<Int>?
    public let revealed: Bool
    public var missing: Bool { display == nil }
  }
  public struct Row {
    public let source: Range<Int>
    public let display: Range<Int>
    public let contentEnd: Int
    public let header, raw: Bool
    public let cells: [Cell]
  }
  public struct Table {
    public let source: Range<Int>
    public let alignments: [Alignment]
    public let rows: [Row]
  }
  public let tables: [Table]

  public init?(pane: WireComposePane, projection: ComposeProjection? = nil) {
    guard let projection = projection ?? ComposeProjection(pane), let document = Int(exactly: pane.documentLen),
          projection.source.upperBound <= document else { return nil }
    let bytes = Array(projection.text.utf8)
    func bounds(_ start: UInt64, _ end: UInt64) -> Range<Int>? {
      guard let a = Int(exactly: start), let b = Int(exactly: end), a <= b, b <= document else { return nil }
      return a..<b
    }
    func display(_ source: Range<Int>) -> Range<Int>? {
      guard let a = projection.displayPosition(for: source.lowerBound, affinity: .downstream),
            let b = projection.displayPosition(for: source.upperBound, affinity: .upstream), a <= b,
            a >= 0, b <= bytes.count,
            [a, b].allSatisfy({ $0 == bytes.count || bytes[$0] & 0xc0 != 0x80 }) else { return nil }
      return a..<b
    }
    var result: [Table] = [], previousTableEnd = 0
    for table in pane.tables {
      guard let source = bounds(table.start, table.end), !source.isEmpty,
            source.lowerBound >= previousTableEnd, !table.alignments.isEmpty, !table.rows.isEmpty else { return nil }
      let alignments = table.alignments.compactMap(Alignment.init(rawValue:))
      guard alignments.count == table.alignments.count else { return nil }
      var rows: [Row] = [], previousRowEnd = source.lowerBound
      for row in table.rows {
        guard let range = bounds(row.start, row.end), !range.isEmpty,
              range.lowerBound >= previousRowEnd, range.upperBound <= source.upperBound,
              range.lowerBound >= projection.source.lowerBound, range.upperBound <= projection.source.upperBound,
              let end = Int(exactly: row.contentEnd), range.lowerBound <= end, end <= range.upperBound,
              let text = display(range), let eol = display(end..<range.upperBound),
              ["\n", "\r", "\r\n"].contains(String(decoding: bytes[eol], as: UTF8.self)) || (eol.isEmpty && range.upperBound == document),
              row.cells.count == alignments.count || (row.source && row.cells.isEmpty) else { return nil }
        var cells: [Cell] = [], previousCellEnd = range.lowerBound, sawMissing = false
        for cell in row.cells {
          guard let cellSource = bounds(cell.start, cell.end), cellSource.lowerBound >= previousCellEnd,
                cellSource.upperBound <= end else { return nil }
          if cell.missing {
            guard cellSource.isEmpty, cellSource.lowerBound == end, !cell.revealed else { return nil }
            sawMissing = true
            cells.append(.init(source: cellSource, display: nil, revealed: false))
          } else {
            guard !sawMissing, let display = display(cellSource) else { return nil }
            cells.append(.init(source: cellSource, display: display, revealed: cell.revealed))
          }
          previousCellEnd = cellSource.upperBound
        }
        rows.append(.init(source: range, display: text, contentEnd: end, header: row.header, raw: row.source, cells: cells))
        previousRowEnd = range.upperBound
      }
      result.append(.init(source: source, alignments: alignments, rows: rows))
      previousTableEnd = source.upperBound
    }
    tables = result
  }
}
