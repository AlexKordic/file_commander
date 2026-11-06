import XCTest
import CoreText
@testable import FreshKit

final class ComposeTableNavigationTests: XCTestCase {
  private func fixture(_ name: String = "compose-tables") throws -> WireComposePane {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "pb", subdirectory: "Fixtures"))
    return try WireComposePane(serializedBytes: Data(contentsOf: url))
  }
  private func layout(_ pane: WireComposePane, width: CGFloat = 320) throws -> ComposePaneLayout {
    try XCTUnwrap(ComposePaneLayout(pane: pane, body: CTFontCreateWithName("Helvetica" as CFString, 18, nil),
      monospace: CTFontCreateWithName("Menlo" as CFString, 18, nil), width: width))
  }

  func testNativeCellFeedbackRetainsSourceOwnershipAndSharedCaretGeometry() throws {
    let pane = try fixture(), value = try layout(pane)
    let feedback = try XCTUnwrap(value.text.navigation(id: 17, pageHeight: 10_000, documentLength: pane.documentLen, positions: [0], styleRevision: 7))
    XCTAssertGreaterThan(feedback.totalLines, UInt64(value.text.fragments.count), "missing cells address structural source through their shared click region")
    XCTAssertEqual(feedback.lines.count, Int(feedback.totalLines))
    var previous: UInt64? = nil, axes: [String: [WireComposeLine]] = [:]
    for line in feedback.lines {
      if let previous { XCTAssertGreaterThan(line.number, previous) }; previous = line.number
      guard line.hasCell else { continue }
      let cell = line.cell
      let table = try XCTUnwrap(value.text.tables.first { $0.source.lowerBound == Int(cell.tableStart) })
      let row = try XCTUnwrap(table.rows.first { $0.source.lowerBound == Int(cell.rowStart) })
      XCTAssertEqual(cell.rowY, Double(row.rect.minY), accuracy: 0.01)
      XCTAssertEqual(cell.rowHeight, Double(row.rect.height), accuracy: 0.01)
      let key = "\(cell.tableStart):\(cell.rowStart):\(cell.hasColumn ? Int(cell.column) : -1)"
      axes[key, default: []].append(line)
      guard cell.hasColumn else { continue }
      let placed = row.cells[Int(cell.column)]
      XCTAssertEqual(cell.x, Double(placed.content.minX), accuracy: 0.01)
      XCTAssertEqual(cell.width, Double(placed.content.width), accuracy: 0.01)
      if placed.missing {
        XCTAssertEqual(line.sourceStart, UInt64(row.contentEnd)); XCTAssertEqual(line.sourceEnd, line.sourceStart)
        XCTAssertTrue(line.stops.allSatisfy { $0.source == UInt64(row.contentEnd) })
      } else {
        let source = try XCTUnwrap(placed.source)
        XCTAssertGreaterThanOrEqual(line.sourceStart, UInt64(source.lowerBound))
        XCTAssertLessThanOrEqual(line.sourceEnd, UInt64(source.upperBound))
        for stop in line.stops {
          let caret = try XCTUnwrap(value.text.caret(for: Int(stop.source), affinity: stop.affinity == 1 ? .upstream : .downstream))
          XCTAssertEqual(stop.x, Double(caret.minX), accuracy: 0.01)
          XCTAssertEqual(line.y, Double(caret.minY), accuracy: 0.01)
        }
      }
    }
    for lines in axes.values {
      XCTAssertEqual(lines.map(\.cell.part), (0..<UInt64(lines.count)).map { $0 })
      XCTAssertTrue(lines.allSatisfy { $0.cell.parts == UInt64(lines.count) })
    }
    XCTAssertTrue(zip(feedback.lines, feedback.lines.dropFirst()).contains { $0.y > $1.y }, "source order can return to a sibling column's first y")
    if let path = ProcessInfo.processInfo.environment["FC_COMPOSE_TABLE_LAYOUT_FILE"] {
      try feedback.serializedData().write(to: URL(fileURLWithPath: path))
    }
  }

  func testSparseTallCellsIncludeColumnEdgesAndPreservePartGaps() throws {
    let text = "Head\n" + String(repeating: "wrapped word ", count: 1200), end = UInt64(text.utf8.count)
    let pane = WireComposePane.with {
      $0.text = text; $0.sourceEnd = end; $0.documentLen = end
      $0.segments = [.with { $0.sourceEnd = end; $0.displayEnd = end }]
      $0.tables = [.with {
        $0.end = end; $0.alignments = [0]
        $0.rows = [
          .with { $0.end = 5; $0.contentEnd = 4; $0.header = true; $0.cells = [.with { $0.end = 4 }] },
          .with { $0.start = 5; $0.end = end; $0.contentEnd = end; $0.cells = [.with { $0.start = 5; $0.end = end }] },
        ]
      }]
    }
    let value = try layout(pane, width: 180)
    let sparse = try XCTUnwrap(value.text.navigation(id: 2, pageHeight: 60, documentLength: end, positions: [end / 2]))
    let body = sparse.lines.filter { $0.hasCell && $0.cell.rowStart == 5 }
    XCTAssertEqual(body.first?.cell.part, 0)
    XCTAssertEqual(body.last?.cell.part, (try XCTUnwrap(body.last)).cell.parts - 1)
    XCTAssertTrue(zip(body, body.dropFirst()).contains { $0.cell.part + 1 < $1.cell.part })
    XCTAssertLessThan(sparse.lines.count, Int(sparse.totalLines))
    XCTAssertTrue(body.contains { $0.cell.part > 0 && $0.cell.part + 1 < $0.cell.parts })
  }

  func testARevealedStructuralRowExportsFullWidthSourceGeometry() throws {
    let pane = try fixture("compose-tables-missing-source"), value = try layout(pane)
    let source = pane.tables[0].rows[3]
    XCTAssertTrue(source.source)
    let feedback = try XCTUnwrap(value.text.navigation(id: 18, pageHeight: 10_000, documentLength: pane.documentLen, positions: [0], styleRevision: 8))
    let row = feedback.lines.filter { $0.hasCell && $0.cell.rowStart == source.start }
    XCTAssertFalse(row.isEmpty)
    XCTAssertTrue(row.allSatisfy { !$0.cell.hasColumn })
    XCTAssertEqual(row.first?.start.source, source.start)
    XCTAssertEqual(row.last?.end.source, source.contentEnd)
    for line in row {
      XCTAssertGreaterThanOrEqual(line.sourceStart, source.start); XCTAssertLessThanOrEqual(line.sourceEnd, source.end)
      XCTAssertEqual(line.cell.width, Double(value.text.tables[0].rect.width - 16), accuracy: 0.01)
    }
    if let path = ProcessInfo.processInfo.environment["FC_COMPOSE_TABLE_SOURCE_LAYOUT_FILE"] {
      try feedback.serializedData().write(to: URL(fileURLWithPath: path))
    }
  }
}
