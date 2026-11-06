import XCTest
import CoreText
@testable import FreshKit

final class ComposePendingTextTests: XCTestCase {
  private let unspecified = NSRange(location: NSNotFound, length: 0)

  private func pane(_ text: String, _ selections: [NSRange], newline: UInt32 = 1) -> WireComposePane {
    let source = text as NSString
    return .with {
      $0.nativeNewline = newline; $0.text = text
      $0.documentLen = UInt64(text.utf8.count); $0.sourceEnd = $0.documentLen
      $0.segments = [.with { $0.sourceEnd = UInt64(text.utf8.count); $0.displayEnd = $0.sourceEnd }]
      $0.cursors = selections.enumerated().map { index, range in
        .with {
          $0.id = UInt64(index + 1); $0.primary = index == selections.count - 1
          $0.position = UInt64(source.substring(to: NSMaxRange(range)).utf8.count)
          $0.utf16Position = UInt64(NSMaxRange(range))
          if range.length > 0 {
            $0.anchor = UInt64(source.substring(to: range.location).utf8.count); $0.utf16Anchor = UInt64(range.location)
          }
        }
      }
      $0.textContext = .with {
        $0.text = text; $0.selectionStart = UInt64(selections.last!.location); $0.selectionEnd = UInt64(NSMaxRange(selections.last!))
      }
    }
  }

  private func draft(_ pane: WireComposePane, _ text: String) throws -> ComposePendingText {
    try XCTUnwrap(ComposePendingText(pane: pane, text: NSAttributedString(string: text),
      selected: NSRange(location: text.utf16.count, length: 0), replacement: unspecified))
  }

  private func following(_ previous: ComposePendingText, pane: WireComposePane, text: String,
                         range: NSRange? = nil) throws -> ComposePendingText {
    try XCTUnwrap(ComposePendingText(following: previous, pane: pane, text: NSAttributedString(string: text),
      selected: NSRange(location: text.utf16.count, length: 0), replacement: range ?? unspecified))
  }

  func testCommittedPrefixIsVisibleAndQueryableBeforeReceiptAndIsSentOnlyOnce() throws {
    let source = pane("alpha Tail", [NSRange(location: 0, length: 5)])
    let first = try XCTUnwrap(try draft(source, "日本").committed(nativeNewline: 1))
    XCTAssertEqual(first.selectedRange, NSRange(location: 2, length: 0))
    XCTAssertEqual(first.markedRange, NSRange(location: 2, length: 0))
    XCTAssertEqual(first.substring(for: NSRange(location: 0, length: 100))?.text.string, "日本 Tail")
    let next = try following(first, pane: source, text: "語")
    XCTAssertEqual(next.markedRange, NSRange(location: 2, length: 1))
    XCTAssertEqual(next.selectedRange, NSRange(location: 3, length: 0))
    XCTAssertEqual(next.substring(for: NSRange(location: 0, length: 100))?.text.string, "日本語 Tail")
    XCTAssertNil(next.replacement(scope: .init(), epoch: 7), "virtual source ranges must never reach the wire")
    let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
    let layout = try XCTUnwrap(ComposePaneLayout(pane: source, body: font, monospace: font, width: 100,
      composition: next.presentation))
    XCTAssertEqual(layout.text.projection.text, "日本語 Tail")
    let receipt = pane("日本 Tail", [NSRange(location: 2, length: 0)])
    let resolved = try XCTUnwrap(next.resolved(pane: receipt, edited: [1]))
    let replacement = try XCTUnwrap(resolved.replacement(scope: .init(), epoch: 7)).input(id: 1)
    XCTAssertEqual(replacement.replacementStart, 6); XCTAssertEqual(replacement.replacementEnd, 6)
    XCTAssertEqual(try WirePaste(serializedBytes: replacement.payload).text, "語")
  }

  func testExplicitReplacementCanAddressPendingPrefixAndKeepsTheWholeConversionCaret() throws {
    let source = pane("alpha Tail", [NSRange(location: 0, length: 5)])
    let first = try XCTUnwrap(try draft(source, "beta").committed(nativeNewline: 1))
    let next = try following(first, pane: source, text: "theta", range: NSRange(location: 0, length: 4))
    XCTAssertEqual(next.substring(for: NSRange(location: 0, length: 100))?.text.string, "theta Tail")
    let committed = try XCTUnwrap(next.committed(nativeNewline: 1))
    let resolved = try XCTUnwrap(committed.resolved(pane: pane("beta Tail", [NSRange(location: 4, length: 0)]), edited: [1]))
    XCTAssertEqual(resolved.presentation.primary.source, 0..<4)
    XCTAssertEqual(resolved.presentation.primary.draft.string, "theta", "common suffix must not move the caret before the final a")
    XCTAssertEqual(resolved.selectedRange, NSRange(location: 5, length: 0))
    XCTAssertEqual(committed.recoveryTexts, ["theta"])
  }

  func testPartialPreeditRetainsUnmarkedSidesButNotThePreviouslyCommittedPrefix() throws {
    let source = pane("Tail", [NSRange(location: 0, length: 0)])
    let first = try XCTUnwrap(try draft(source, "日本").committed(nativeNewline: 1))
    var next = try following(first, pane: source, text: "abc")
    XCTAssertTrue(next.update(NSAttributedString(string: "日"), selected: NSRange(location: 1, length: 0),
      replacement: NSRange(location: 3, length: 1)))
    XCTAssertEqual(next.markedRange, NSRange(location: 3, length: 1))
    XCTAssertEqual(next.substring(for: NSRange(location: 0, length: 100))?.text.string, "日本a日cTail")
    let resolved = try XCTUnwrap(next.resolved(pane: pane("日本Tail", [NSRange(location: 2, length: 0)]), edited: [1]))
    XCTAssertEqual(resolved.presentation.primary.draft.string, "a日c")
    XCTAssertEqual(resolved.markedRange, NSRange(location: 3, length: 1))
    XCTAssertEqual(resolved.selectedRange, NSRange(location: 4, length: 0))
    XCTAssertEqual(next.recoveryTexts, ["a日c"])
  }

  func testSeveralCaretsKeepIndependentPrefixCoordinatesAndReceiptOwnership() throws {
    let source = pane("cat dog", [NSRange(location: 0, length: 3), NSRange(location: 4, length: 3)])
    let first = try XCTUnwrap(try draft(source, "日").committed(nativeNewline: 1))
    let next = try following(first, pane: source, text: "本")
    XCTAssertEqual(next.substring(for: NSRange(location: 0, length: 100))?.text.string, "日本 日本")
    XCTAssertEqual(next.selectedRange, NSRange(location: 5, length: 0))
    let receipt = pane("日 日", [NSRange(location: 1, length: 0), NSRange(location: 3, length: 0)])
    XCTAssertNil(next.resolved(pane: receipt, edited: [2]))
    let resolved = try XCTUnwrap(next.resolved(pane: receipt, edited: [1, 2]))
    XCTAssertEqual(resolved.presentation.values[1]?.source, 3..<3)
    XCTAssertEqual(resolved.presentation.values[2]?.source, 7..<7)
    XCTAssertEqual(resolved.selectedRange, NSRange(location: 5, length: 0))
  }

  func testDeclaredCRLFPolicyNormalizesOnlyTheCurrentPhraseBeforeTheNextConversion() throws {
    let source = pane("tail\r\n", [NSRange(location: 0, length: 0)], newline: 2)
    let first = try XCTUnwrap(try draft(source, "🙂\n").committed(nativeNewline: 2))
    XCTAssertEqual(first.selectedRange.location, 4)
    let next = try following(first, pane: source, text: "A\rB\n")
    let committed = try XCTUnwrap(next.committed(nativeNewline: 2))
    XCTAssertEqual(committed.substring(for: NSRange(location: 0, length: 100))?.text.string, "🙂\r\nA\r\nB\r\ntail\r\n")
    XCTAssertEqual(committed.selectedRange.location, 10)
    let resolved = try XCTUnwrap(committed.resolved(pane: pane("🙂\r\ntail\r\n", [NSRange(location: 4, length: 0)], newline: 2), edited: [1]))
    XCTAssertEqual(resolved.presentation.primary.source, 6..<6)
    XCTAssertEqual(resolved.presentation.primary.draft.string, "A\r\nB\r\n")
    XCTAssertNil(try draft(source, "\n").committed(nativeNewline: 0))
  }

  func testReplacementRejectsChangedReceiptContextAndSplitSurrogates() throws {
    let source = pane("tail", [NSRange(location: 0, length: 0)])
    let first = try XCTUnwrap(try draft(source, "🙂").committed(nativeNewline: 1))
    XCTAssertNil(ComposePendingText(following: first, pane: source, text: NSAttributedString(string: "x"),
      selected: NSRange(location: 1, length: 0), replacement: NSRange(location: 1, length: 1)))
    let next = try following(first, pane: source, text: "x", range: NSRange(location: 0, length: 2))
    XCTAssertNil(next.resolved(pane: pane("🙃tail", [NSRange(location: 2, length: 0)]), edited: [1]))
    let resolved = try XCTUnwrap(next.resolved(pane: pane("🙂tail", [NSRange(location: 2, length: 0)]), edited: [1]))
    XCTAssertEqual(resolved.presentation.primary.source, 0..<4)
  }

  func testFollowingAnEntireLargeSelectionDoesNotRequireItsRemovedSourceInTheContextChunk() throws {
    let text = String(repeating: "x", count: 20_000) + " Tail"
    var source = pane(text, [NSRange(location: 0, length: 20_000)])
    source.textContext.text = "xxx Tail"; source.textContext.sourceStart = 19_997; source.textContext.utf16Start = 19_997
    let first = try XCTUnwrap(try draft(source, "first").committed(nativeNewline: 1))
    let next = try following(first, pane: source, text: "next")
    XCTAssertEqual(next.recoveryTexts, ["next"])
    let committed = try XCTUnwrap(next.committed(nativeNewline: 1))
    let resolved = try XCTUnwrap(committed.resolved(pane: pane("first Tail", [NSRange(location: 5, length: 0)]), edited: [1]))
    XCTAssertEqual(resolved.presentation.primary.source, 5..<5)
    XCTAssertEqual(resolved.presentation.primary.draft.string, "next")
  }

  func testExplicitPrimaryEditThenBroadcastIncludesOnlyProvenUnchangedSecondarySelections() throws {
    let source = pane("cat dog", [NSRange(location: 0, length: 3), NSRange(location: 4, length: 3)])
    let initial = try XCTUnwrap(ComposePendingText(pane: source, text: NSAttributedString(string: "日"),
      selected: NSRange(location: 1, length: 0), replacement: NSRange(location: 4, length: 3)))
    let first = try XCTUnwrap(initial.committed(nativeNewline: 1))
    let next = try following(first, pane: source, text: "本")
    XCTAssertEqual(next.substring(for: NSRange(location: 0, length: 100))?.text.string, "本 日本")
    XCTAssertEqual(next.selectedRange, NSRange(location: 4, length: 0))
    let receipt = pane("cat 日", [NSRange(location: 0, length: 3), NSRange(location: 5, length: 0)])
    XCTAssertNil(next.resolved(pane: receipt, edited: [2]), "a live but unproven ID is insufficient")
    XCTAssertNil(next.resolved(pane: receipt, edited: [2], preserved: [1, 1]))
    var malformed = receipt
    malformed.cursors[0].utf16Position = 4; malformed.cursors[0].utf16Anchor = 1
    XCTAssertNil(next.resolved(pane: malformed, edited: [2], preserved: [1]), "source bytes and UTF-16 anchors must describe the same caret")
    let resolved = try XCTUnwrap(next.resolved(pane: receipt, edited: [2], preserved: [1]))
    XCTAssertEqual(resolved.presentation.values[1]?.source, 0..<3)
    XCTAssertEqual(resolved.presentation.values[2]?.source, 7..<7)
    let committed = try XCTUnwrap(resolved.committed(nativeNewline: 1))
    let replacement = try XCTUnwrap(committed.replacement(scope: .init(), epoch: 7)).input(id: 2)
    XCTAssertEqual(replacement.replacementStart, 7); XCTAssertEqual(replacement.replacements.first?.end, 3)
    XCTAssertEqual(replacement.observedCursors.map(\.id), [1, 2])
    XCTAssertEqual(try WirePaste(serializedBytes: replacement.payload).text, "本")
  }

  func testProvenanceSurvivesAChainWithoutRenewingAFailedCursorFromALaterPane() throws {
    let source = pane("cat dog", [NSRange(location: 0, length: 3), NSRange(location: 4, length: 3)])
    let initial = try XCTUnwrap(ComposePendingText(pane: source, text: NSAttributedString(string: "日"),
      selected: NSRange(location: 1, length: 0), replacement: NSRange(location: 4, length: 3)))
    let first = try XCTUnwrap(initial.committed(nativeNewline: 1))
    let second = try following(first, pane: source, text: "本", range: NSRange(location: 5, length: 0))
    let receipt = pane("cat 日", [NSRange(location: 0, length: 3), NSRange(location: 5, length: 0)])
    let resolved = try XCTUnwrap(second.resolved(pane: receipt, edited: [2]))
    XCTAssertEqual(resolved.observedCursors.map(\.id), [2], "the pane's unrelated secondary cannot renew a missing witness")
  }

  func testUneditedLargeSelectionCanJoinBroadcastUsingBoundedContextAndItsProvenReceipt() throws {
    let text = String(repeating: "x", count: 20_000) + " dog"
    var source = pane(text, [NSRange(location: 0, length: 20_000), NSRange(location: 20_001, length: 3)])
    source.textContext.text = " dog"; source.textContext.sourceStart = 20_000; source.textContext.utf16Start = 20_000
    source.textChunks = [.with { $0.text = "xxx "; $0.sourceStart = 19_997; $0.utf16Start = 19_997 }]
    let initial = try XCTUnwrap(ComposePendingText(pane: source, text: NSAttributedString(string: "日"),
      selected: NSRange(location: 1, length: 0), replacement: NSRange(location: 20_001, length: 3)))
    let first = try XCTUnwrap(initial.committed(nativeNewline: 1))
    let next = try following(first, pane: source, text: "!")
    let receiptText = String(repeating: "x", count: 20_000) + " 日"
    var receipt = pane(receiptText, [NSRange(location: 0, length: 20_000), NSRange(location: 20_002, length: 0)])
    receipt.textContext.text = " 日"; receipt.textContext.sourceStart = 20_000; receipt.textContext.utf16Start = 20_000
    receipt.textChunks = source.textChunks
    let resolved = try XCTUnwrap(next.resolved(pane: receipt, edited: [2], preserved: [1]))
    XCTAssertEqual(resolved.presentation.values[1]?.source, 0..<20_000)
    XCTAssertEqual(resolved.presentation.values[1]?.draft.string, "!")
    XCTAssertEqual(resolved.presentation.values[2]?.source, 20_004..<20_004)
    XCTAssertEqual(resolved.presentation.values[2]?.draft.string, "!")
  }

  func testExpansionAroundAnUnchangedSelectionRequiresExactUnicodeSource() throws {
    let source = pane("Åcat dog", [NSRange(location: 1, length: 3), NSRange(location: 5, length: 3)])
    let initial = try XCTUnwrap(ComposePendingText(pane: source, text: NSAttributedString(string: "日"),
      selected: NSRange(location: 1, length: 0), replacement: NSRange(location: 5, length: 3)))
    let first = try XCTUnwrap(initial.committed(nativeNewline: 1))
    var next = try following(first, pane: source, text: "本")
    XCTAssertTrue(next.update(NSAttributedString(string: "X"), selected: NSRange(location: 1, length: 0),
      replacement: NSRange(location: next.markedRange.location - 1, length: 1)))
    XCTAssertEqual(next.substring(for: NSRange(location: 0, length: 100))?.text.string, "X本 X本")
    XCTAssertNotNil(next.resolved(pane: pane("Åcat 日", [NSRange(location: 1, length: 3), NSRange(location: 6, length: 0)]), edited: [2], preserved: [1]))
    XCTAssertNil(next.resolved(pane: pane("Åcat 日", [NSRange(location: 1, length: 3), NSRange(location: 6, length: 0)]), edited: [2], preserved: [1]),
      "canonical equivalence cannot authorize deleting different surrounding source bytes")
  }
}
