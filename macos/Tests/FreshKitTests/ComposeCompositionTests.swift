import XCTest
import CoreText
@testable import FreshKit

final class ComposeCompositionTests: XCTestCase {
  private let unspecified = NSRange(location: NSNotFound, length: 0)

  private func pane(_ source: String, targets: [(UInt64, String)], primary: UInt64) -> WireComposePane {
    let value = source as NSString
    return .with {
      $0.text = source; $0.documentLen = UInt64(source.utf8.count); $0.sourceEnd = $0.documentLen
      $0.segments = [.with { $0.sourceEnd = UInt64(source.utf8.count); $0.displayEnd = $0.sourceEnd }]
      $0.cursors = targets.map { id, word in
        let range = value.range(of: word)
        let a = value.substring(to: range.location)
        return .with {
          $0.id = id; $0.primary = id == primary; $0.anchor = UInt64(a.utf8.count)
          $0.position = $0.anchor + UInt64(word.utf8.count)
          $0.utf16Anchor = UInt64(range.location); $0.utf16Position = UInt64(NSMaxRange(range))
        }
      }
      let selection = value.range(of: targets.first { $0.0 == primary }!.1)
      $0.textContext = .with {
        $0.text = source; $0.selectionStart = UInt64(selection.location); $0.selectionEnd = UInt64(NSMaxRange(selection))
      }
    }
  }

  private func capture(_ pane: WireComposePane, draft: String = "abc", replacement: NSRange? = nil) throws -> ComposeComposition {
    try XCTUnwrap(ComposeComposition(pane: pane, text: NSAttributedString(string: draft),
      selected: NSRange(location: draft.utf16.count, length: 0), replacement: replacement ?? unspecified))
  }

  func testBroadcastKeepsIndependentRangesAndPrimaryCoordinatesAfterAnEarlierCaret() throws {
    let source = "aa café xx\nbb Tail yy\n", pane = pane(source, targets: [(1, "café"), (2, "Tail")], primary: 2)
    var group = try capture(pane)
    let primary = (source as NSString).range(of: "Tail")
    XCTAssertEqual(group.ordered, [1, 2])
    XCTAssertEqual(group.markedRange, NSRange(location: primary.location - 1, length: 3))
    XCTAssertEqual(group.selectedRange.location, primary.location + 2)
    XCTAssertEqual(group.substring(for: NSRange(location: 0, length: 100))?.text.string, "aa abc xx\nbb abc yy\n")
    XCTAssertTrue(group.update(NSAttributedString(string: "日"), selected: NSRange(location: 1, length: 0),
      replacement: NSRange(location: group.virtualStart(for: 2) + 1, length: 1)))
    XCTAssertEqual(group.values[1]?.draft.string, "a日c")
    XCTAssertEqual(group.values[2]?.draft.string, "a日c")
    XCTAssertEqual(group.markedRange, NSRange(location: primary.location, length: 1))
    let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
    let layout = try XCTUnwrap(ComposePaneLayout(pane: pane, body: font, monospace: font, width: 150, composition: group))
    XCTAssertEqual(layout.text.projection.text, "aa a日c xx\nbb a日c yy\n")
    XCTAssertEqual(layout.draftDisplayRanges.count, 2)
    for range in layout.draftDisplayRanges.values {
      XCTAssertNotNil(layout.text.caret(atUTF16: range.location + 2))
      XCTAssertFalse(layout.text.selectionRects(forUTF16: range).isEmpty)
    }
    let input = try XCTUnwrap(ComposeReplacement(scope: .init(), epoch: 7, composition: group)).input(id: 1)
    XCTAssertEqual(input.replacementCursor, 2)
    XCTAssertEqual(input.replacements.map(\.cursor), [1])
    XCTAssertFalse(input.replacements[0].hasText)
  }

  func testExpansionRetainsDifferentSurroundingSourceInEachCapturedReplacement() throws {
    let pane = pane("aXcat\nbYdog\n", targets: [(1, "cat"), (2, "dog")], primary: 2)
    var group = try capture(pane, draft: "日")
    XCTAssertTrue(group.update(NSAttributedString(string: "!"), selected: NSRange(location: 1, length: 0),
      replacement: NSRange(location: group.virtualStart(for: 2) - 2, length: 1)))
    XCTAssertEqual(group.values[1]?.draft.string, "!X日")
    XCTAssertEqual(group.values[2]?.draft.string, "!Y日")
    XCTAssertEqual(group.values[1]?.source, 0..<5)
    XCTAssertEqual(group.values[2]?.source, 6..<11)
    let replacement = try XCTUnwrap(ComposeReplacement(scope: .init(), epoch: 7, composition: group))
    XCTAssertEqual(Set(replacement.texts), Set(["!X日", "!Y日"]))
    let input = replacement.input(id: 1)
    XCTAssertEqual(input.replacements[0].text, "!X日")
    XCTAssertEqual(try WirePaste(serializedBytes: input.payload).text, "!Y日")
    XCTAssertEqual(group.substring(for: NSRange(location: 0, length: 100))?.text.string, "!X日\n!Y日\n")
  }

  func testOverlappingExpansionOrInvalidUnicodeRejectsTheWholeUpdate() throws {
    let pane = pane("ab cd", targets: [(1, "ab"), (2, "cd")], primary: 2)
    var group = try capture(pane, draft: "x")
    XCTAssertFalse(group.update(NSAttributedString(string: "!"), selected: NSRange(location: 1, length: 0),
      replacement: NSRange(location: group.virtualStart(for: 2) - 2, length: 1)))
    XCTAssertEqual(group.values[1]?.source, 0..<2); XCTAssertEqual(group.values[2]?.source, 3..<5)
    XCTAssertEqual(group.values[1]?.draft.string, "x"); XCTAssertEqual(group.values[2]?.draft.string, "x")
    XCTAssertFalse(group.update(NSAttributedString(string: "👩🏽‍💻"), selected: NSRange(location: 1, length: 0), replacement: unspecified))
    XCTAssertEqual(group.primary.draft.string, "x")
  }

  func testExplicitInitialReplacementAddressesOnlyPrimary() throws {
    let source = "café Tail", pane = pane(source, targets: [(1, "café"), (2, "Tail")], primary: 2)
    let group = try capture(pane, replacement: (source as NSString).range(of: "Tail"))
    XCTAssertEqual(group.ordered, [2])
    XCTAssertEqual(group.substring(for: NSRange(location: 0, length: 100))?.text.string, "café abc")
  }

  func testOffscreenCaretUsesItsRawChunkAndShiftsThePrimaryDocumentIndices() throws {
    let middle = String(repeating: "文", count: 10000), source = "first " + middle + " Tail"
    var pane = pane(source, targets: [(1, "first"), (2, "Tail")], primary: 2)
    let start = source.utf8.count - 4, base = source.utf16.count - 4
    pane.textContext.text = "Tail"; pane.textContext.sourceStart = UInt64(start); pane.textContext.utf16Start = UInt64(base)
    pane.textChunks = [.with { $0.text = "first " }]
    pane.text = "Tail"; pane.sourceStart = UInt64(start)
    pane.segments = [.with { $0.sourceStart = UInt64(start); $0.sourceEnd = UInt64(source.utf8.count); $0.displayEnd = 4 }]
    let group = try capture(pane, draft: "日")
    XCTAssertEqual(group.markedRange, NSRange(location: base - 4, length: 1))
    XCTAssertEqual(group.substring(for: group.markedRange)?.text.string, "日")
    let projection = try XCTUnwrap(ComposeProjection(pane))
    let display = try XCTUnwrap(group.project(over: projection))
    XCTAssertEqual(display.projection.text, "日"); XCTAssertEqual(display.displays.count, 1)
    XCTAssertEqual(group.virtualPosition(for: source.utf8.count), base - 3)
  }
}
