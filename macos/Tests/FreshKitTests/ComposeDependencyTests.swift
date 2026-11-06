import XCTest
@testable import FreshKit

final class ComposeDependencyTests: XCTestCase {
  private func pane(_ text: String, _ selections: [UInt64: Range<Int>], primary: UInt64) -> WireComposePane {
    func units(_ byte: Int) -> UInt64 { UInt64(String(decoding: text.utf8.prefix(byte), as: UTF8.self).utf16.count) }
    return .with {
      $0.documentLen = UInt64(text.utf8.count); $0.sourceEnd = $0.documentLen; $0.text = text
      $0.segments = [.with { $0.sourceEnd = UInt64(text.utf8.count); $0.displayEnd = $0.sourceEnd }]
      $0.textContext = .with {
        $0.text = text; $0.selectionStart = units(selections[primary]!.lowerBound); $0.selectionEnd = units(selections[primary]!.upperBound)
      }
      $0.cursors = selections.sorted { $0.key < $1.key }.map { id, range in .with {
        $0.id = id; $0.primary = id == primary; $0.position = UInt64(range.upperBound); $0.utf16Position = units(range.upperBound)
        if !range.isEmpty { $0.anchor = UInt64(range.lowerBound); $0.utf16Anchor = units(range.lowerBound) }
      } }
    }
  }
  private func composition(_ pane: WireComposePane, _ text: String = "語") throws -> ComposeComposition {
    try XCTUnwrap(ComposeComposition(pane: pane, text: NSAttributedString(string: text),
      selected: NSRange(location: text.utf16.count, length: 0), replacement: NSRange(location: NSNotFound, length: 0)))
  }

  func testPredecessorReplacingASelectionMakesTheNextConversionAnInsertionWithItsPartialMarkIntact() throws {
    let initial = try composition(pane("alpha beta", [1: 0..<5], primary: 1), "gH")
    var current = initial
    XCTAssertTrue(current.update(NSAttributedString(string: "語"), selected: NSRange(location: 1, length: 0),
      replacement: NSRange(location: 1, length: 1)))
    let next = try XCTUnwrap(current.following(initial, pane: pane("日本 beta", [1: 6..<6], primary: 1), edited: [1]))
    XCTAssertEqual(next.primary.source, 6..<6)
    XCTAssertEqual(next.primary.originalRange, NSRange(location: 2, length: 0))
    XCTAssertEqual(next.primary.draft.string, "g語")
    XCTAssertEqual(next.markedRange, NSRange(location: 3, length: 1))
    XCTAssertEqual(next.selectedRange, NSRange(location: 4, length: 0))
    XCTAssertEqual(try XCTUnwrap(next.substring(for: NSRange(location: 0, length: 9))).text.string, "日本g語 beta")
  }

  func testAllCapturedCaretsKeepTheirOwnReceiptCoordinatesAndUnknownOrRetiredOwnersRefuseTheGroup() throws {
    let initial = try composition(pane("alpha beta", [1: 0..<5, 2: 6..<10], primary: 2))
    let accepted = pane("日本 日本", [1: 6..<6, 2: 13..<13], primary: 2)
    let next = try XCTUnwrap(initial.following(initial, pane: accepted, edited: [1, 2]))
    XCTAssertEqual(next.values[1]?.source, 6..<6); XCTAssertEqual(next.values[2]?.source, 13..<13)
    XCTAssertEqual(next.markedRange, NSRange(location: 6, length: 1), "the first provisional phrase shifts the second virtual UTF-16 position")
    XCTAssertNil(initial.following(initial, pane: accepted, edited: [1]))
    XCTAssertNil(initial.following(initial, pane: accepted, edited: [1, 2, 2]))
    var malformed = accepted; malformed.cursors[0].utf16Position = 1
    XCTAssertNil(initial.following(initial, pane: malformed, edited: [1, 2]), "source and UTF-16 anchors must describe the same receipt position")
    XCTAssertNil(initial.following(initial, pane: pane("日本 日本", [1: 6..<6], primary: 1), edited: [1, 2]))
    XCTAssertNil(initial.following(initial, pane: pane("日本 日本", [1: 0..<6, 2: 13..<13], primary: 2), edited: [1, 2]))
  }

  func testExpandedUnchangedSuffixKeepsItsSourceButChangedSurroundingsCannotBeResurrected() throws {
    let initial = try composition(pane("alpha tail", [1: 0..<5], primary: 1))
    var suffix = initial
    XCTAssertTrue(suffix.update(NSAttributedString(string: "Q"), selected: NSRange(location: 1, length: 0),
      replacement: NSRange(location: 1, length: 1)))
    let next = try XCTUnwrap(suffix.following(initial, pane: pane("日本 tail", [1: 6..<6], primary: 1), edited: [1]))
    XCTAssertEqual(next.primary.source, 6..<7); XCTAssertEqual(next.primary.draft.string, "語Q")
    XCTAssertEqual(next.primary.originalRange, NSRange(location: 2, length: 1))
    XCTAssertNil(suffix.following(initial, pane: pane("日本Xtail", [1: 6..<6], primary: 1), edited: [1]))
  }

  func testReceiptRequiresTheExactViewAndBufferLifetimeAndCannotGoBackwards() {
    let scope = WireComposeScope.with { $0.windowID = 1; $0.leaf = 2; $0.buffer = 3; $0.bufferRevision = 4 }
    let value = WireComposeEditReceipt.with {
      $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7
      $0.pane = pane("日本 tail", [1: 6..<6], primary: 1); $0.pane.bufferRevision = 5; $0.pane.viewport.epoch = 7; $0.cursors = [1]
    }
    XCTAssertTrue(value.matches(scope, epoch: 7))
    for invalid in [
      WireComposeEditReceipt.with { $0 = value; $0.window = 2 },
      .with { $0 = value; $0.leaf = 3 }, .with { $0 = value; $0.buffer = 4 },
      .with { $0 = value; $0.epoch = 8 }, .with { $0 = value; $0.pane.viewport.epoch = 8 },
      .with { $0 = value; $0.pane.bufferRevision = 3 },
    ] { XCTAssertFalse(invalid.matches(scope, epoch: 7)) }
  }
}
