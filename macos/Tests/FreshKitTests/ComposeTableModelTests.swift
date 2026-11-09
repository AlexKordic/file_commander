import XCTest
@testable import FreshKit

final class ComposeTableModelTests: XCTestCase {
  private func fixture() throws -> WireComposePane {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "compose-tables", withExtension: "pb", subdirectory: "Fixtures"))
    return try WireComposePane(serializedBytes: Data(contentsOf: url))
  }

  func testRealPluginCellsRetainAlignmentsUnicodeImagesAndDistinctEmptyAndMissingCells() throws {
    let pane = try fixture(), model = try XCTUnwrap(ComposeTableModel(pane: pane))
    XCTAssertEqual(model.tables.count, 2)
    let first = model.tables[0], bytes = Array(pane.text.utf8)
    XCTAssertEqual(first.alignments, [.left, .center, .right])
    XCTAssertEqual(first.rows.count, 6)
    XCTAssertTrue(first.rows[0].header)
    let title = try XCTUnwrap(first.rows[0].cells[0].display)
    XCTAssertEqual(String(decoding: bytes[title], as: UTF8.self), "Text")
    let text = try XCTUnwrap(first.rows[1].cells[0].display)
    XCTAssertTrue(String(decoding: bytes[text], as: UTF8.self).hasPrefix("café 👩🏽‍💻 and link"))
    let code = try XCTUnwrap(first.rows[1].cells[1].display)
    XCTAssertEqual(String(decoding: bytes[code], as: UTF8.self), "a|b &")
    let image = try XCTUnwrap(first.rows[1].cells[2].display)
    XCTAssertEqual(String(decoding: bytes[image], as: UTF8.self), "\u{fffc}")
    XCTAssertTrue(first.rows[2].cells[0].display?.isEmpty == true)
    XCTAssertFalse(first.rows[2].cells[0].source.isEmpty, "a real empty cell still owns its padding/source anchor")
    XCTAssertTrue(first.rows[3].cells[1...].allSatisfy { $0.missing && $0.source.isEmpty && $0.source.lowerBound == first.rows[3].contentEnd })
    XCTAssertTrue(first.rows[5].cells.allSatisfy { !$0.missing && $0.source.isEmpty && $0.display?.isEmpty == true }, "real zero-length cells retain an anchor independently of absent cells")
    XCTAssertEqual(model.tables[1].alignments, [.automatic, .automatic])
    XCTAssertTrue(first.rows.allSatisfy { !$0.raw })
    let roundTrip = try WireComposePane(serializedBytes: pane.serializedData())
    XCTAssertEqual(roundTrip.tables, pane.tables)
  }

  func testMalformedMetadataRefusesInvalidSourceCellsInsteadOfGuessingGeometry() throws {
    let original = try fixture()
    var bad = original
    bad.tables[0].alignments[0] = 99
    XCTAssertNil(ComposeTableModel(pane: bad))
    bad = original; bad.tables[0].rows[1].cells[0].missing = true
    XCTAssertNil(ComposeTableModel(pane: bad), "real text cannot be relabelled as an absent cell")
    bad = original; bad.tables[0].rows[1].cells[1].start = bad.tables[0].rows[1].cells[0].start
    XCTAssertNil(ComposeTableModel(pane: bad))
    bad = original; bad.tables[0].rows[0].contentEnd = bad.tables[0].rows[0].end
    XCTAssertNil(ComposeTableModel(pane: bad), "a row cannot absorb its EOL into cell content")
    bad = original
    let source = original.textContext.text
    let emoji = try XCTUnwrap(source.range(of: "👩🏽‍💻")).lowerBound
    bad.tables[0].rows[1].cells[0].start = UInt64(source[..<emoji].utf8.count + 1)
    XCTAssertNil(ComposeTableModel(pane: bad), "UTF-8 interior bytes cannot become cell boundaries")
    bad = original; bad.tables[0].rows[2].start = bad.tables[0].rows[1].start
    XCTAssertNil(ComposeTableModel(pane: bad))
  }

  func testBoundedRowsCanKeepTableOwnershipOutsideTheVisibleSourceWindow() throws {
    let original = try fixture(), row = original.tables[0].rows[3]
    let raw = Array(original.textContext.text.utf8), range = Int(row.start)..<Int(row.end)
    let text = String(decoding: raw[range], as: UTF8.self)
    let projection = try XCTUnwrap(ComposeProjection(source: range, text: text,
      segments: [.init(source: range, display: 0..<text.utf8.count, kind: .copy)]))
    var pane = original
    pane.tables = [original.tables[0]]; pane.tables[0].rows = [row]
    let model = try XCTUnwrap(ComposeTableModel(pane: pane, projection: projection))
    XCTAssertLessThan(model.tables[0].source.lowerBound, projection.source.lowerBound)
    XCTAssertEqual(model.tables[0].rows.count, 1)
    XCTAssertEqual(model.tables[0].rows[0].source, range)
    XCTAssertTrue(model.tables[0].rows[0].cells[1].missing)
    pane.tables = []
    XCTAssertTrue(try XCTUnwrap(ComposeTableModel(pane: pane, projection: projection)).tables.isEmpty)
  }
}
