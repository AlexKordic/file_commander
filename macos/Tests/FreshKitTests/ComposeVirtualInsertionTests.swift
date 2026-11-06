import XCTest
import CoreText
@testable import FreshKit

final class ComposeVirtualInsertionTests: XCTestCase {
  private func prefix() throws -> ComposeComposition {
    let text = "aa BB cc"
    let context = try XCTUnwrap(ComposeTextContext(.with { $0.text = text }, documentLength: UInt64(text.utf8.count)))
    func value(_ at: Int) throws -> ComposeMarkedText {
      try XCTUnwrap(ComposeMarkedText(context: context, range: NSRange(location: at, length: 0), source: at..<at,
        text: NSAttributedString(string: "日本"), selected: NSRange(location: 2, length: 0)))
    }
    return try XCTUnwrap(ComposeComposition(primary: 1, values: [1: try value(0), 2: try value(3)]))
  }
  private func copied(_ text: String) throws -> ComposeProjection {
    try XCTUnwrap(ComposeProjection(source: 0..<text.utf8.count, text: text,
      segments: [.init(source: 0..<text.utf8.count, display: 0..<text.utf8.count, kind: .copy)]))
  }

  func testTwoActualCaretsCanInsertWithinOnePendingRegionAndUseMeasuredGeometry() throws {
    let base = try prefix()
    let original = try XCTUnwrap(ComposeVirtualSelections(prefix: base))
    let clicked = try XCTUnwrap(original.movingPrimary(to: 6, extend: false))
    let conversion = try XCTUnwrap(ComposeVirtualInsertion(selections: clicked,
      text: NSAttributedString(string: "X"), selected: NSRange(location: 1, length: 0)))
    let projected = try XCTUnwrap(conversion.project(over: copied("aa BB cc")))
    XCTAssertEqual(projected.projection.source, 0..<8)
    XCTAssertEqual(projected.projection.text, "日本aa 日X本XBB cc")
    XCTAssertEqual(conversion.cursors[1]?.position, 7); XCTAssertEqual(conversion.cursors[2]?.position, 9)
    XCTAssertEqual(conversion.marked[1], NSRange(location: 6, length: 1)); XCTAssertEqual(conversion.marked[2], NSRange(location: 8, length: 1))
    let bytes = Array(projected.projection.text.utf8)
    for id: UInt64 in [1, 2] {
      let range = try XCTUnwrap(projected.marked[id])
      XCTAssertEqual(String(decoding: bytes[range], as: UTF8.self), "X")
    }
    let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
    let narrow = try XCTUnwrap(ComposeTextLayout(projection: projected.projection, font: font, width: 90))
    let wide = try XCTUnwrap(ComposeTextLayout(projection: projected.projection, font: font, width: 500))
    XCTAssertGreaterThan(narrow.fragments.count, wide.fragments.count)
    XCTAssertNotNil(narrow.caret(atUTF16: 7)); XCTAssertNotNil(narrow.caret(atUTF16: 9))
    let partial = try XCTUnwrap(ComposeProjection(source: 3..<8, text: "BB cc",
      segments: [.init(source: 3..<8, display: 0..<5, kind: .copy)]))
    let window = try XCTUnwrap(conversion.project(over: partial))
    XCTAssertEqual(window.projection.source, 3..<8); XCTAssertEqual(window.projection.text, "日X本XBB cc")
    XCTAssertEqual(Set(window.marked.keys), [1, 2], "both moved carets can belong to one visible source region")
    XCTAssertEqual(base.values[1]?.draft.string, "日本"); XCTAssertEqual(base.values[2]?.draft.string, "日本")
    XCTAssertEqual(original.cursors[1]?.position, 2)
  }

  func testSelectionAcrossMultipleDraftsFoldsToOneOriginalSourceRange() throws {
    let base = try prefix()
    let selected = try XCTUnwrap(ComposeVirtualSelections(prefix: base, primary: 30,
      cursors: [30: .init(position: 6, anchor: 1)]))
    let conversion = try XCTUnwrap(ComposeVirtualInsertion(selections: selected,
      text: NSAttributedString(string: "X"), selected: NSRange(location: 0, length: 1)))
    let projected = try XCTUnwrap(conversion.project(over: copied("aa BB cc")))
    XCTAssertEqual(projected.projection.text, "日X本BB cc")
    XCTAssertEqual(conversion.regions.values.count, 1)
    XCTAssertEqual(conversion.regions.values.values.first?.source, 0..<3)
    XCTAssertEqual(conversion.cursors[30]?.selection, NSRange(location: 1, length: 1))
    XCTAssertEqual(conversion.marked[30], NSRange(location: 1, length: 1))
  }

  func testSelectionCanExpandFromADraftIntoOriginalSourceWithoutDuplicatingItsPrefix() throws {
    let base = try prefix()
    let selected = try XCTUnwrap(ComposeVirtualSelections(prefix: base, primary: 1,
      cursors: [1: .init(position: 9, anchor: 6)]))
    let conversion = try XCTUnwrap(ComposeVirtualInsertion(selections: selected,
      text: NSAttributedString(string: "X"), selected: NSRange(location: 1, length: 0)))
    XCTAssertEqual(try XCTUnwrap(conversion.project(over: copied("aa BB cc"))).projection.text, "日本aa 日X cc")
    XCTAssertEqual(conversion.cursors[1]?.position, 7)
    let conflicting = try XCTUnwrap(ComposeVirtualSelections(prefix: base, primary: 1,
      cursors: [1: .init(position: 7), 2: .init(position: 7)]))
    XCTAssertNil(ComposeVirtualInsertion(selections: conflicting, text: NSAttributedString(string: "X"), selected: NSRange(location: 1, length: 0)))
  }
}
