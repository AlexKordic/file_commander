import XCTest
@testable import FreshKit

final class ComposeAccessibleDocumentTests: XCTestCase {
  private func pane() -> WirePane {
    .with {
      $0.leaf = 2; $0.buffer = 3
      $0.compose = .with {
        $0.text = "Aé👩‍💻\u{fffc}Z!"; $0.sourceEnd = 33; $0.documentLen = 33
        $0.bufferRevision = 5; $0.selectionRevision = 6; $0.decorationRevision = 0; $0.viewport.epoch = 7
        $0.assetAuthority = 8; $0.assetDocument = 9
        $0.segments = [segment(0, 2, 0, 0, 1), segment(2, 16, 0, 14, 0),
          segment(16, 30, 14, 17, 2), segment(30, 32, 17, 17, 1), segment(32, 33, 17, 18, 0), segment(33, 33, 18, 19, 3)]
        $0.cursors = [.with { $0.primary = true; $0.id = 7; $0.anchor = 33; $0.position = 2 },
          .with { $0.id = 2; $0.position = 16 }]
      }
    }
  }

  private func segment(_ a: UInt64, _ b: UInt64, _ c: UInt64, _ d: UInt64, _ kind: UInt32) -> WireComposeSegment {
    .with { $0.sourceStart = a; $0.sourceEnd = b; $0.displayStart = c; $0.displayEnd = d; $0.kind = kind }
  }

  func testCompleteValueKeepsAllSelectionsAndMapsUnicodeImagesHiddenAndInsertedText() throws {
    let pane = pane(), doc = try XCTUnwrap(ComposeAccessibleDocument(window: 1, pane: pane))
    XCTAssertEqual(doc.characterCount, 10)
    XCTAssertEqual(doc.string(for: NSRange(location: 0, length: 10)), "Aé👩‍💻\u{fffc}Z!")
    XCTAssertEqual(doc.character(at: 4), NSRange(location: 2, length: 5))
    XCTAssertEqual(doc.character(at: 10), NSRange(location: 10, length: 0))
    XCTAssertNil(doc.character(at: 11))
    XCTAssertNil(doc.string(for: NSRange(location: 3, length: 1)), "a surrogate interior cannot become source")
    XCTAssertEqual(doc.sourceRange(for: NSRange(location: 2, length: 5)), 5..<16)
    XCTAssertEqual(doc.sourceRange(for: NSRange(location: 7, length: 1)), 16..<30, "the image owns its complete Markdown")
    XCTAssertEqual(doc.sourceRange(for: NSRange(location: 0, length: 0), insertion: 0), 0..<0)
    XCTAssertEqual(doc.sourceRange(for: NSRange(location: 0, length: 0)), 2..<2)
    XCTAssertEqual(doc.displayedRange(for: 33..<33), NSRange(location: 10, length: 0))
    XCTAssertEqual(doc.selectedRanges(window: 1, pane: pane), [NSRange(location: 0, length: 9), NSRange(location: 7, length: 0)])
    XCTAssertEqual(doc.range(of: 1, pane: pane), NSRange(location: 0, length: 10))
  }

  func testWindowMatchingCertifiesGlobalOffsetsAndDoesNotClipThePrimarySelection() throws {
    var window = pane(); let doc = try XCTUnwrap(ComposeAccessibleDocument(window: 1, pane: window))
    window.compose.sourceStart = 16; window.compose.sourceEnd = 30; window.compose.text = "\u{fffc}"
    window.compose.segments = [segment(16,30,0,3,2)]
    XCTAssertEqual(doc.range(of: 1, pane: window), NSRange(location: 7, length: 1))
    XCTAssertEqual(doc.selectedRanges(window: 1, pane: window)?.first, NSRange(location: 0, length: 9),
      "a complete document selection is independent of a drawing crop")
    window.compose.sourceStart = 1; window.compose.sourceEnd = 3; window.compose.text = "A"
    window.compose.segments = [segment(1,2,0,0,1),segment(2,3,0,1,0)]
    XCTAssertEqual(doc.range(of: 1, pane: window), NSRange(location: 0, length: 1))
    window.compose.sourceStart = 3; window.compose.sourceEnd = 16; window.compose.text = "é👩‍💻"
    window.compose.segments = [segment(3,5,0,2,0),segment(5,16,2,13,0)]
    XCTAssertEqual(doc.range(of: 1, pane: window), NSRange(location: 1, length: 6), "copied runs can split and coalesce")
  }

  func testSameLookingTextCannotCertifyAnotherAtomicMapOrRetiredSourceOwner() throws {
    var window = pane(); let doc = try XCTUnwrap(ComposeAccessibleDocument(window: 1, pane: window))
    window.compose.sourceStart = 16; window.compose.sourceEnd = 30; window.compose.text = "\u{fffc}"
    window.compose.segments = [segment(16,29,0,3,2), segment(29,30,3,3,1)]
    XCTAssertNil(doc.range(of: 1, pane: window), "identical object text cannot own a different source range")
    window.compose.sourceEnd = 19; window.compose.segments = [segment(16,19,0,3,0)]
    XCTAssertNil(doc.range(of: 1, pane: window), "an atomic replacement cannot become copied raw source")
    window.compose.sourceStart = 32; window.compose.sourceEnd = 33; window.compose.text = "Z"
    window.compose.segments = [segment(32,33,0,1,2)]
    XCTAssertNil(doc.range(of: 1, pane: window), "equal lengths do not make copied and atomic text equivalent")
    let changes: [(inout WirePane) -> Void] = [
      {$0.leaf += 1}, {$0.buffer += 1}, {$0.compose.bufferRevision += 1}, {$0.compose.viewport.epoch += 1},
      {$0.compose.selectionRevision += 1}, {$0.compose.assetAuthority += 1}, {$0.compose.assetDocument += 1},
      {$0.compose.decorationRevision += 1}, {$0.compose.clearDecorationRevision()},
      {$0.compose.documentLen += 1}, {$0.clearBuffer()}, {$0.clearCompose()},
    ]
    for change in changes {
      var other = pane(); change(&other)
      XCTAssertFalse(doc.owns(window: 1, pane: other)); XCTAssertNil(doc.range(of: 1, pane: other))
      XCTAssertNil(doc.selectedRanges(window: 1, pane: other))
    }
    XCTAssertFalse(doc.owns(window: 2, pane: pane()))
    var crop = pane(); crop.compose.sourceEnd = 32
    XCTAssertNil(ComposeAccessibleDocument(window: 1, pane: crop), "a partial source cannot be called a complete value")
    crop = pane(); crop.compose.ready = false
    XCTAssertNil(ComposeAccessibleDocument(window: 1, pane: crop))
  }

  func testMultiMegabyteValueUsesSparseCoordinatesWithoutWholeDocumentLayout() throws {
    let text = String(repeating: "e\u{301}東京👩🏽‍💻\r\n", count: 210_000) + " FINAL"
    XCTAssertGreaterThan(text.utf8.count, 5 << 20)
    var pane = pane()
    pane.compose.text = text; pane.compose.sourceEnd = UInt64(text.utf8.count); pane.compose.documentLen = pane.compose.sourceEnd
    pane.compose.segments = [segment(0, pane.compose.sourceEnd, 0, pane.compose.sourceEnd, 0)]
    let doc = try XCTUnwrap(ComposeAccessibleDocument(window: 1, pane: pane))
    let end = text.utf16.count
    XCTAssertEqual(doc.characterCount, end)
    XCTAssertEqual(doc.string(for: NSRange(location: end-6, length: 6)), " FINAL")
    XCTAssertEqual(doc.sourceRange(for: NSRange(location: end-6, length: 6)), (text.utf8.count-6)..<text.utf8.count)
    XCTAssertLessThanOrEqual(doc.projection.textIndex.checkpointCount, text.utf8.count / ComposeTextIndex.stride + 2)
    XCTAssertLessThan(doc.projection.textIndex.checkpointCount * 500, text.utf16.count)
  }

  func testSparseCoordinatesAgreeAtEveryScalarBoundaryAndRejectSurrogateOrUtf8Interiors() {
    let text = String(repeating: "Aé e\u{301} 東京 👩🏽‍💻\r\n", count: 150)
    let index = ComposeTextIndex(text)
    var byte = 0, unit = 0
    for scalar in text.unicodeScalars {
      XCTAssertEqual(index.byte(forUnit: unit), byte); XCTAssertEqual(index.unit(forByte: byte), unit)
      for interior in 1..<scalar.utf8.count { XCTAssertNil(index.unit(forByte: byte+interior)) }
      if scalar.utf16.count == 2 { XCTAssertNil(index.byte(forUnit: unit+1)) }
      byte += scalar.utf8.count; unit += scalar.utf16.count
    }
    XCTAssertEqual(index.byte(forUnit: unit), byte); XCTAssertEqual(index.unit(forByte: byte), unit)
    XCTAssertNil(index.byte(forUnit: -1)); XCTAssertNil(index.unit(forByte: byte+1))
    XCTAssertNil(index.bytes(for: NSRange(location: .max, length: .max)))
    let empty = ComposeTextIndex("")
    XCTAssertEqual(empty.byte(forUnit: 0), 0); XCTAssertEqual(empty.unit(forByte: 0), 0)
  }

  func testCanonicallyEqualWindowTextMustStillHaveIdenticalUtf8AndCompleteCursorOwnership() throws {
    let before = "é e\u{301}", after = "e\u{301} é"
    XCTAssertEqual(before, after); XCTAssertEqual(before.utf8.count, after.utf8.count)
    var full = pane(); full.compose.text = before; full.compose.sourceEnd = 6; full.compose.documentLen = 6
    full.compose.segments = [segment(0,6,0,6,0)]
    let doc = try XCTUnwrap(ComposeAccessibleDocument(window: 1, pane: full))
    var foreign = full; foreign.compose.text = after
    XCTAssertNil(doc.range(of: 1, pane: foreign), "String equality cannot certify literal displayed positions")
    full.compose.cursors[0].primary = false
    XCTAssertNil(doc.selectedRanges(window: 1, pane: full), "missing primary ownership cannot promote another cursor")
    full.compose.cursors[0].primary = true; full.compose.cursors[1].id = full.compose.cursors[0].id
    XCTAssertNil(doc.selectedRanges(window: 1, pane: full))
  }
}
