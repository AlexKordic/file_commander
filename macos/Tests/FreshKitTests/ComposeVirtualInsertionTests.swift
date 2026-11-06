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
  private func sourcePane(_ text: String = "aa BB cc", revision: UInt64 = 4) -> WireComposePane {
    .with {
      $0.bufferRevision = revision; $0.documentLen = UInt64(text.utf8.count); $0.viewport.epoch = 7; $0.nativeNewline = 1
      $0.textContext.text = text
      $0.cursors = [.with { $0.id = 1; $0.primary = true; $0.position = 0; $0.utf16Position = 0 },
        .with { $0.id = 2; $0.position = 3; $0.utf16Position = 3 }]
    }
  }
  private func scope(_ revision: UInt64) -> WireComposeScope {
    .with { $0.windowID = 1; $0.leaf = 2; $0.buffer = 3; $0.bufferRevision = revision }
  }

  func testVirtualActionIntentCannotBecomeWireCoordinatesBeforeItsMatchingResult() throws {
    let base = try prefix(), selections = try XCTUnwrap(ComposeVirtualSelections(prefix: base).flatMap { $0.movingPrimary(to: 6, extend: false) })
    let unspecified = NSRange(location: NSNotFound, length: 0)
    let basis = try XCTUnwrap(ComposePendingText(afterAction: selections, pane: sourcePane(), text: NSAttributedString(string: ""),
      selected: NSRange(location: 0, length: 0), replacement: unspecified))
    var text = try XCTUnwrap(ComposePendingText(afterAction: selections, pane: sourcePane(), text: NSAttributedString(string: "X"),
      selected: NSRange(location: 1, length: 0), replacement: unspecified))
    XCTAssertEqual(text.presentation.values[1]?.source, 12..<12, "UTF-8 starts are derived from the raw prefix, not its UTF-16 indices")
    XCTAssertEqual(text.presentation.values[2]?.source, 15..<15)
    XCTAssertNil(text.replacement(scope: scope(4), epoch: 7))
    XCTAssertNil(try XCTUnwrap(text.committed(nativeNewline: 1)).replacement(scope: scope(4), epoch: 7))
    XCTAssertTrue(text.update(NSAttributedString(string: "YZ"), selected: NSRange(location: 1, length: 0),
      replacement: NSRange(location: 5, length: 2)))
    let projected = try XCTUnwrap(text.virtualInsertion(over: selections)?.project(over: copied("aa BB cc")))
    XCTAssertEqual(projected.projection.text, "日本aa YZYZBB cc")
    var actual = sourcePane("日本aa 日本BB cc", revision: 5)
    actual.cursors = [.with { $0.id = 1; $0.primary = true; $0.position = 12; $0.utf16Position = 6 },
      .with { $0.id = 2; $0.position = 15; $0.utf16Position = 7 }]
    actual.textContext.selectionStart = 6; actual.textContext.selectionEnd = 6
    let bound = try XCTUnwrap(text.afterAction(basis, pane: actual)?.committed(nativeNewline: 1))
    let input = try XCTUnwrap(bound.replacement(scope: scope(5), epoch: 7)).input(id: 3)
    XCTAssertEqual(input.sourceRevision, 5); XCTAssertEqual(input.replacementStart, 9); XCTAssertEqual(input.replacementEnd, 12)
    XCTAssertEqual(input.replacements.first?.start, 12); XCTAssertEqual(input.replacements.first?.end, 15)
  }

  func testFollowingVirtualConversionWaitsForARealTextReceiptAndPreservesTheFirstPreview() throws {
    let base = try prefix(), selections = try XCTUnwrap(ComposeVirtualSelections(prefix: base).flatMap { $0.movingPrimary(to: 6, extend: false) })
    let unspecified = NSRange(location: NSNotFound, length: 0)
    let first = try XCTUnwrap(ComposePendingText(afterAction: selections, pane: sourcePane(), text: NSAttributedString(string: "X"),
      selected: NSRange(location: 1, length: 0), replacement: unspecified)?.committed(nativeNewline: 1))
    let next = try XCTUnwrap(ComposePendingText(following: first, pane: sourcePane(), text: NSAttributedString(string: "Y"),
      selected: NSRange(location: 1, length: 0), replacement: unspecified)?.committed(nativeNewline: 1))
    XCTAssertNil(next.replacement(scope: scope(4), epoch: 7))
    XCTAssertEqual(try XCTUnwrap(next.virtualInsertion(over: selections)?.project(over: copied("aa BB cc"))).projection.text,
      "日本aa 日XY本XYBB cc")
    var actual = sourcePane("日本aa 日X本XBB cc", revision: 6)
    actual.cursors = [.with { $0.id = 1; $0.primary = true; $0.position = 13; $0.utf16Position = 7 },
      .with { $0.id = 2; $0.position = 17; $0.utf16Position = 9 }]
    actual.textContext.selectionStart = 7; actual.textContext.selectionEnd = 7
    let bound = try XCTUnwrap(next.resolved(pane: actual, edited: [1, 2]))
    let input = try XCTUnwrap(bound.replacement(scope: scope(6), epoch: 7)).input(id: 4)
    XCTAssertEqual(input.replacementStart, 13); XCTAssertEqual(input.replacements.first?.start, 17)
    XCTAssertEqual(try WirePaste(serializedBytes: input.payload).text, "Y")
  }

  func testExplicitVirtualPrimaryConversionRetainsTheSecondaryForAFollowingBroadcast() throws {
    let base = try prefix(), selections = try XCTUnwrap(ComposeVirtualSelections(prefix: base).flatMap { $0.movingPrimary(to: 6, extend: false) })
    let unspecified = NSRange(location: NSNotFound, length: 0)
    let basis = try XCTUnwrap(ComposePendingText(afterAction: selections, pane: sourcePane(), text: NSAttributedString(string: ""),
      selected: NSRange(location: 0, length: 0), replacement: unspecified))
    let first = try XCTUnwrap(ComposePendingText(afterAction: selections, pane: sourcePane(), text: NSAttributedString(string: "X"),
      selected: NSRange(location: 1, length: 0), replacement: selections.selection)?.committed(nativeNewline: 1))
    var actual = sourcePane("日本aa 日本BB cc", revision: 5)
    actual.cursors = [.with { $0.id = 1; $0.primary = true; $0.position = 12; $0.utf16Position = 6 },
      .with { $0.id = 2; $0.position = 15; $0.utf16Position = 7 }]
    actual.textContext.selectionStart = 6; actual.textContext.selectionEnd = 6
    let real = try XCTUnwrap(first.afterAction(basis, pane: actual))
    let input = try XCTUnwrap(real.replacement(scope: scope(5), epoch: 7)).input(id: 3)
    XCTAssertTrue(input.replacements.isEmpty)
    XCTAssertEqual(Set(input.observedCursors.map(\.id)), [1, 2])
    let next = try XCTUnwrap(ComposePendingText(following: first, pane: sourcePane(), text: NSAttributedString(string: "Y"),
      selected: NSRange(location: 1, length: 0), replacement: unspecified, virtualBase: selections)?.committed(nativeNewline: 1))
    XCTAssertEqual(try XCTUnwrap(next.virtualInsertion(over: selections)?.project(over: copied("aa BB cc"))).projection.text,
      "日本aa 日XY本YBB cc")
    actual = sourcePane("日本aa 日X本BB cc", revision: 6)
    actual.cursors = [.with { $0.id = 1; $0.primary = true; $0.position = 13; $0.utf16Position = 7 },
      .with { $0.id = 2; $0.position = 16; $0.utf16Position = 8 }]
    actual.textContext.selectionStart = 7; actual.textContext.selectionEnd = 7
    let bound = try XCTUnwrap(next.resolved(pane: actual, edited: [1], preserved: [2]))
    let following = try XCTUnwrap(bound.replacement(scope: scope(6), epoch: 7)).input(id: 4)
    XCTAssertEqual(following.replacementStart, 13); XCTAssertEqual(following.replacements.first?.start, 16)
    XCTAssertEqual(try WirePaste(serializedBytes: following.payload).text, "Y")
  }

}
