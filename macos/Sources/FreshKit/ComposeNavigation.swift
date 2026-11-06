import Foundation
import CoreText
import CoreGraphics

private struct ComposeCellAxis: Hashable {
  let table, row: Int
  let column: Int?
  init(_ position: ComposeTextLayout.TablePosition) { table = position.table; row = position.row.lowerBound; column = position.column }
}
private struct ComposeRowAxis: Hashable { let table, row: Int }

extension ComposeTextLayout {
  /// Source-order numbers detect gaps between sparse regions. Cell part
  /// ordinals prove adjacency within a column, whose y may overlap siblings.
  public func navigation(id: UInt64, pageHeight: CGFloat, documentLength: UInt64,
                         positions: [UInt64], aroundY: CGFloat? = nil, styleRevision: UInt64 = 0) -> WireComposeLayout? {
    guard id != 0, pageHeight.isFinite, pageHeight > 0 else { return nil }
    var centers = positions.compactMap { Int(exactly: $0).flatMap { caret(for: $0)?.midY } }
    if let aroundY, aroundY.isFinite { centers.append(aroundY) }
    if centers.isEmpty { centers = [0] }
    let radius = max(120, pageHeight * 2)
    func nearby(_ rect: CGRect) -> Bool { centers.contains { $0 + radius >= rect.minY && $0 - radius <= rect.maxY } }
    var rows: [ComposeRowAxis: (table: Table, row: TableRow)] = [:]
    var selected: Set<ComposeRowAxis> = []
    var all = fragments
    let empty = CTLineCreateWithAttributedString(NSAttributedString(string: ""))
    for table in tables {
      for row in table.rows {
        let key = ComposeRowAxis(table: table.source.lowerBound, row: row.source.lowerBound)
        rows[key] = (table, row)
        if nearby(row.rect) { selected.insert(key) }
        // A missing cell addresses real structural source, just like a click
        // in its region. It does not manufacture an editable text character.
        for cell in row.cells where cell.missing {
          guard let index = utf16Position(for: row.contentEnd) else { return nil }
          all.append(Fragment(line: empty, range: NSRange(location: index, length: 0), rect: cell.content,
            baseline: cell.content.minY, contentEnd: index,
            table: TablePosition(table: table.source.lowerBound, row: row.source, column: cell.column, source: row.contentEnd..<row.contentEnd)))
        }
      }
    }
    all = all.enumerated().sorted { a, b in
      if a.element.range.location != b.element.range.location { return a.element.range.location < b.element.range.location }
      if a.element.table?.row == b.element.table?.row, a.element.table?.table == b.element.table?.table,
         a.element.table?.column != b.element.table?.column { return (a.element.table?.column ?? -1) < (b.element.table?.column ?? -1) }
      return a.offset < b.offset
    }.map(\.element)
    var counts: [ComposeCellAxis: Int] = [:], next: [ComposeCellAxis: Int] = [:]
    for fragment in all { if let position = fragment.table { counts[ComposeCellAxis(position), default: 0] += 1 } }
    var totalStops = 0, lines: [WireComposeLine] = []
    for (number, fragment) in all.enumerated() {
      let key = fragment.table.map(ComposeCellAxis.init)
      let part = key.map { next[$0, default: 0] } ?? 0
      if let key { next[key] = part + 1 }
      let parts = key.flatMap { counts[$0] } ?? 1
      let rowKey = fragment.table.map { ComposeRowAxis(table: $0.table, row: $0.row.lowerBound) }
      let edge = part == 0 || part + 1 == parts
      guard nearby(fragment.rect) || (edge && rowKey.map { selected.contains($0) } == true) else { continue }
      func sameFlow(_ other: Fragment) -> Bool { fragment.table.map(ComposeCellAxis.init) == other.table.map(ComposeCellAxis.init) }
      func source(_ index: Int, _ affinity: ComposeProjection.Affinity) -> Int? {
        guard let display = utf16ToByte[index] else { return nil }
        let candidate: Int
        if let position = fragment.table, fragment.range.length == 0 { candidate = position.source.lowerBound }
        else if let mapped = projection.sourcePosition(at: display, affinity: affinity) { candidate = mapped }
        else { return nil }
        let result = fragment.table.map { min($0.source.upperBound, max($0.source.lowerBound, candidate)) } ?? candidate
        return projection.displayPosition(for: result, affinity: affinity) == display ? result : nil
      }
      func stop(_ index: Int, _ affinity: ComposeProjection.Affinity) -> WireComposeStop? {
        guard let source = source(index, affinity) else { return nil }
        if affinity == .upstream, number > 0, sameFlow(all[number - 1]), index == fragment.range.location,
           all[number - 1].contentEnd == index { return nil }
        if affinity == .downstream, number + 1 < all.count, sameFlow(all[number + 1]), index == fragment.contentEnd,
           all[number + 1].range.location == index { return nil }
        return WireComposeStop.with {
          $0.source = UInt64(source)
          $0.x = Double(fragment.rect.minX + CTLineGetOffsetForStringIndex(fragment.line, index, nil))
          $0.affinity = affinity == .upstream ? 1 : 0
        }
      }
      var stops: [WireComposeStop] = [], index = fragment.range.location
      while index <= fragment.contentEnd {
        for affinity: ComposeProjection.Affinity in [.downstream, .upstream] {
          if let point = stop(index, affinity), !stops.suffix(2).contains(where: { $0.source == point.source && $0.x == point.x }) { stops.append(point) }
        }
        guard index < fragment.contentEnd else { break }
        let next = NSMaxRange(string.rangeOfComposedCharacterSequence(at: index))
        guard next > index else { return nil }
        index = min(next, fragment.contentEnd)
      }
      guard let first = stop(fragment.range.location, .downstream) ?? stop(fragment.range.location, .upstream) ?? stops.first,
            let last = stop(fragment.contentEnd, .upstream) ?? stop(fragment.contentEnd, .downstream) ?? stops.last,
            let a = utf16ToByte[fragment.range.location], let b = utf16ToByte[NSMaxRange(fragment.range)],
            let mappedStart = projection.sourcePosition(at: a, affinity: .upstream),
            let mappedEnd = projection.sourcePosition(at: b, affinity: .downstream) else { return nil }
      let sourceStart = fragment.table.map { min($0.source.upperBound, max($0.source.lowerBound, mappedStart)) } ?? mappedStart
      let sourceEnd = fragment.table.map { min($0.source.upperBound, max($0.source.lowerBound, mappedEnd)) } ?? mappedEnd
      if !stops.contains(first) { stops.append(first) }
      if !stops.contains(last) { stops.append(last) }
      totalStops += stops.count
      guard totalStops <= 100_000, lines.count < 16_384 else { return nil }
      var line = WireComposeLine.with {
        $0.number = UInt64(number); $0.y = Double(fragment.rect.minY); $0.height = Double(fragment.rect.height)
        $0.sourceStart = UInt64(sourceStart); $0.sourceEnd = UInt64(sourceEnd)
        $0.start = first; $0.end = last; $0.stops = stops
      }
      if let position = fragment.table, let rowKey, let geometry = rows[rowKey] {
        let content: CGRect
        if let column = position.column { content = geometry.row.cells[column].content }
        else { content = geometry.row.rect.insetBy(dx: ComposeMeasuredTable.padding, dy: ComposeMeasuredTable.padding) }
        line.cell = .with {
          $0.tableStart = UInt64(position.table); $0.rowStart = UInt64(position.row.lowerBound)
          if let column = position.column { $0.column = UInt32(column) }
          $0.part = UInt64(part); $0.parts = UInt64(parts)
          $0.x = Double(content.minX); $0.width = Double(content.width)
          $0.rowY = Double(geometry.row.rect.minY); $0.rowHeight = Double(geometry.row.rect.height)
        }
      }
      lines.append(line)
    }
    return WireComposeLayout.with {
      $0.id = id; $0.pageHeight = Double(pageHeight); $0.sourceStart = UInt64(projection.source.lowerBound)
      $0.sourceEnd = UInt64(projection.source.upperBound); $0.documentLen = documentLength
      $0.lines = lines; $0.totalLines = UInt64(all.count); $0.height = Double(size.height); $0.styleRevision = styleRevision
    }
  }
}
