import XCTest
import CoreText
@testable import FreshKit

final class ComposeTests: XCTestCase {
  private func copied(_ text: String, start: Int = 0) throws -> ComposeProjection {
    try XCTUnwrap(ComposeProjection(source: start..<(start + text.utf8.count), text: text,
      segments: text.isEmpty ? [] : [.init(source: start..<(start + text.utf8.count), display: 0..<text.utf8.count, kind: .copy)]))
  }

  private func font(_ size: CGFloat) -> CTFont { CTFontCreateWithName("Helvetica" as CFString, size, nil) }

  func testHiddenHeadingAndEmphasisRetainTheirSourceEdges() throws {
    // Same projection contract exercised by fresh-core's Rust tests.
    let text = "Héllo world\r\n"
    let p = try XCTUnwrap(ComposeProjection(source: 100..<121, text: text, segments: [
      .init(source: 100..<103, display: 0..<0, kind: .hidden),
      .init(source: 103..<110, display: 0..<7, kind: .copy),
      .init(source: 110..<112, display: 7..<7, kind: .hidden),
      .init(source: 112..<117, display: 7..<12, kind: .copy),
      .init(source: 117..<119, display: 12..<12, kind: .hidden),
      .init(source: 119..<121, display: 12..<14, kind: .copy),
    ]))
    XCTAssertEqual(p.sourcePosition(at: 0, affinity: .upstream), 100)
    XCTAssertEqual(p.sourcePosition(at: 0), 103)
    XCTAssertEqual(p.sourcePosition(at: 7, affinity: .upstream), 110)
    XCTAssertEqual(p.sourcePosition(at: 7), 112)
    XCTAssertNil(p.sourcePosition(at: 2)) // Middle of é.
    XCTAssertEqual(p.text, text)
  }

  func testMalformedProjectionCannotBeUsedToAddressTheBuffer() {
    XCTAssertNil(ComposeProjection(source: 10..<12, text: "é", segments: [
      .init(source: 10..<11, display: 0..<1, kind: .copy),
      .init(source: 11..<12, display: 1..<2, kind: .copy),
    ]))
    XCTAssertNil(ComposeProjection(source: 0..<3, text: "abc", segments: [
      .init(source: 0..<2, display: 0..<2, kind: .copy),
    ]))
    XCTAssertNil(ComposeProjection(source: 0..<3, text: "abc", segments: [
      .init(source: 0..<2, display: 0..<2, kind: .copy),
      .init(source: 1..<3, display: 2..<3, kind: .copy),
    ]))
  }

  func testLargerHeadingUsesMeasuredHeightAndWrapsAtItsOwnFontSize() throws {
    let text = "A heading with enough words to wrap over several lines"
    let projection = try copied(text)
    let body = try XCTUnwrap(ComposeTextLayout(projection: projection, font: font(14), width: 180))
    let heading = try XCTUnwrap(ComposeTextLayout(projection: projection, font: font(28), width: 180))
    XCTAssertGreaterThan(heading.fragments.count, body.fragments.count)
    XCTAssertGreaterThan(heading.fragments[0].rect.height, body.fragments[0].rect.height)
    XCTAssertGreaterThan(heading.size.height, body.size.height)
    for fragment in heading.fragments {
      XCTAssertGreaterThan(fragment.rect.height, 28)
      let width = CTLineGetTypographicBounds(fragment.line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(fragment.line)
      XCTAssertLessThanOrEqual(width, 181)
    }
  }

  func testProportionalHitTestingReturnsSourceBytesAtDifferentFontSizes() throws {
    let projection = try copied("Wi Wi café", start: 40)
    for size: CGFloat in [14, 28] {
      let layout = try XCTUnwrap(ComposeTextLayout(projection: projection, font: font(size), width: 400))
      let afterW = try XCTUnwrap(layout.caret(for: 41))
      let afterI = try XCTUnwrap(layout.caret(for: 42))
      XCTAssertGreaterThan(afterW.minX, afterI.minX - afterW.minX)
      for byte in [40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 51] {
        let caret = try XCTUnwrap(layout.caret(for: byte))
        XCTAssertEqual(layout.sourcePosition(at: CGPoint(x: caret.minX, y: caret.midY)), byte)
      }
    }
  }

  func testWrappingAffinitiesHaveDifferentGeometryForTheSameSourceCaret() throws {
    let projection = try copied("A long heading that wraps to several lines")
    let layout = try XCTUnwrap(ComposeTextLayout(projection: projection, font: font(24), width: 150))
    XCTAssertGreaterThan(layout.fragments.count, 1)
    let boundary = layout.fragments[1].range.location // ASCII: UTF-16 equals UTF-8.
    let before = try XCTUnwrap(layout.caret(for: boundary, affinity: .upstream))
    let after = try XCTUnwrap(layout.caret(for: boundary, affinity: .downstream))
    XCTAssertGreaterThan(after.minY, before.minY)
    XCTAssertLessThan(after.minX, before.minX)
  }

  func testCRLFAndTrailingEmptyLineHaveDistinctCaretPositions() throws {
    let projection = try copied("one\r\ntwo\r\n", start: 12)
    let layout = try XCTUnwrap(ComposeTextLayout(projection: projection, font: font(16), width: 300))
    XCTAssertEqual(layout.fragments.count, 3)
    XCTAssertEqual(layout.fragments.map(\.contentEnd), [3, 8, 10])
    XCTAssertEqual(layout.sourcePosition(at: CGPoint(x: 250, y: layout.fragments[0].rect.midY)), 15)
    let final = try XCTUnwrap(layout.caret(for: 22))
    XCTAssertEqual(final.minY, layout.fragments[2].rect.minY)
    XCTAssertEqual(layout.sourcePosition(at: CGPoint(x: 0, y: final.midY)), 22)
  }

  func testEmojiAndCombiningSequencesNeverProduceAnInteriorCaretOnHit() throws {
    let text = "a 👩🏽‍💻 e\u{301} z"
    let layout = try XCTUnwrap(ComposeTextLayout(projection: try copied(text), font: font(18), width: 400))
    var boundaries: Set<Int> = [0]
    var byte = 0
    for grapheme in text {
      byte += grapheme.utf8.count
      boundaries.insert(byte)
    }
    let end = try XCTUnwrap(layout.caret(for: text.utf8.count)).minX
    for x in stride(from: CGFloat(0), through: end, by: 0.5) {
      let hit = try XCTUnwrap(layout.sourcePosition(at: CGPoint(x: x, y: 5)))
      XCTAssertTrue(boundaries.contains(hit), "Interior grapheme caret at byte \(hit), x=\(x)")
    }
  }

  func testEmptyParagraphStillHasAnEditableLine() throws {
    let layout = try XCTUnwrap(ComposeTextLayout(projection: try copied("", start: 90), font: font(16), width: 300))
    XCTAssertEqual(layout.fragments.count, 1)
    XCTAssertGreaterThan(layout.size.height, 0)
    XCTAssertEqual(layout.sourcePosition(at: CGPoint(x: 10, y: 4)), 90)
    XCTAssertNotNil(layout.caret(for: 90))
  }

  func testMixedFontRunsUseUTF8RangesAndAffectTheMeasuredLine() throws {
    let text = "é BIG text"
    let projection = try copied(text)
    let body = try XCTUnwrap(ComposeTextLayout(projection: projection, font: font(14), width: 400))
    let mixed = try XCTUnwrap(ComposeTextLayout(projection: projection, font: font(14), width: 400,
      fonts: [.init(display: 3..<6, font: font(30))]))
    XCTAssertGreaterThan(mixed.size.height, body.size.height)
    XCTAssertGreaterThan(try XCTUnwrap(mixed.caret(for: 6)).minX, try XCTUnwrap(body.caret(for: 6)).minX)
    XCTAssertNil(ComposeTextLayout(projection: projection, font: font(14), width: 400,
      fonts: [.init(display: 1..<3, font: font(30))]))
  }

  func testNarrowWrappingNeverSplitsAComposedCharacter() throws {
    let text = "👩🏽‍💻e\u{301}z"
    let projection = try copied(text)
    let layout = try XCTUnwrap(ComposeTextLayout(projection: projection, font: font(18), width: 1))
    var valid: Set<Int> = [0]
    var offset = 0
    for grapheme in text {
      offset += grapheme.utf16.count
      valid.insert(offset)
    }
    for fragment in layout.fragments {
      XCTAssertTrue(valid.contains(fragment.range.location))
      XCTAssertTrue(valid.contains(NSMaxRange(fragment.range)))
    }
    XCTAssertNotNil(layout.caret(for: projection.source.upperBound))
  }
}
