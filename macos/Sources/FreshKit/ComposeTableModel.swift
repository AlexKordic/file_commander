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
    public let measurement: ComposeTableMeasurement?
  }
  public let tables: [Table]
  private let documentLength: Int
  private let authority, document: UInt64

  /// Remap an already validated model after presentation-only replacements.
  /// A draft spanning cells uses shared text flow instead of losing or
  /// repeating that draft in independently shaped cells.
  func remapping(to projection: ComposeProjection,
                 drafts: [(source: Range<Int>, display: Range<Int>)] = []) -> [Table]? {
    func mapped(_ source: Range<Int>, including owned: [(source: Range<Int>, display: Range<Int>)]) -> Range<Int>? {
      guard let a = projection.displayPosition(for: source.lowerBound, affinity: .downstream),
            let b = projection.displayPosition(for: source.upperBound, affinity: .upstream) else { return nil }
      return min(a, owned.map(\.display.lowerBound).min() ?? a)..<max(b, owned.map(\.display.upperBound).max() ?? b)
    }
    func contains(_ outer: Range<Int>, _ inner: Range<Int>) -> Bool {
      outer.lowerBound <= inner.lowerBound && inner.upperBound <= outer.upperBound
    }
    func owns(_ outer: Range<Int>, _ inner: Range<Int>) -> Bool {
      if inner.isEmpty {
        return outer.contains(inner.lowerBound) || (inner.lowerBound == documentLength && outer.upperBound == documentLength)
      }
      return contains(outer, inner)
    }
    var result: [Table] = []
    for table in tables {
      let relevant = drafts.filter { $0.source.overlaps(table.source) || ($0.source.isEmpty && owns(table.source, $0.source)) }
      guard relevant.allSatisfy({ draft in table.rows.contains { row in
        owns(row.source, draft.source) && (row.raw || row.cells.contains { !$0.missing && contains($0.source, draft.source) })
      } }) else { continue }
      var rows: [Row] = []
      for row in table.rows {
        let owned = relevant.filter { owns(row.source, $0.source) }
        guard let display = mapped(row.source, including: owned) else { return nil }
        var cells: [Cell] = []
        if !row.raw {
          for cell in row.cells {
            let display = cell.missing ? nil : mapped(cell.source, including: owned.filter { contains(cell.source, $0.source) })
            guard cell.missing || display != nil else { return nil }
            cells.append(.init(source: cell.source, display: display, revealed: cell.revealed))
          }
        }
        rows.append(.init(source: row.source, display: display, contentEnd: row.contentEnd,
          header: row.header, raw: row.raw, cells: cells))
      }
      result.append(.init(source: table.source, alignments: table.alignments, rows: rows, measurement: table.measurement))
    }
    return result
  }

  public init?(pane: WireComposePane, projection: ComposeProjection? = nil, reuse: ComposeTableModel? = nil,
               sharingMeasurementsWith peers: [ComposeTableModel] = []) {
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
    var cached: [UInt64: [ComposeTableMeasurement]] = [:]
    var seen: Set<ObjectIdentifier> = []
    for model in (reuse.map { [$0] } ?? []) + peers
      where model.authority == pane.assetAuthority && model.document == pane.assetDocument {
      for measurement in model.tables.compactMap(\.measurement) where seen.insert(ObjectIdentifier(measurement)).inserted {
        cached[measurement.id, default: []].append(measurement)
      }
    }
    for table in pane.tables {
      guard let source = bounds(table.start, table.end), !source.isEmpty,
            source.lowerBound >= previousTableEnd, !table.alignments.isEmpty, !table.rows.isEmpty else { return nil }
      let alignments = table.alignments.compactMap(Alignment.init(rawValue:))
      guard alignments.count == table.alignments.count else { return nil }
      let measurement: ComposeTableMeasurement?
      if table.measurementID == 0 {
        guard !table.hasMeasurement else { return nil }; measurement = nil
      } else {
        guard table.hasMeasurement, table.measurement.columns.count == alignments.count else { return nil }
        if let old = cached[table.measurementID]?.first(where: { $0.matches(table.measurement) }) { measurement = old }
        else { measurement = ComposeTableMeasurement(id: table.measurementID, wire: table.measurement, columns: alignments.count) }
        guard measurement != nil else { return nil }
      }
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
      result.append(.init(source: source, alignments: alignments, rows: rows, measurement: measurement))
      previousTableEnd = source.upperBound
    }
    tables = result; documentLength = document
    authority = pane.assetAuthority; self.document = pane.assetDocument
  }
}
