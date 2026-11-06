import XCTest
@testable import FreshKit

final class ComposeVirtualSelectionsTests: XCTestCase {
  private var scope: WireComposeScope { .with { $0.windowID = 1; $0.leaf = 2; $0.buffer = 3; $0.bufferRevision = 4 } }
  private func context(_ text: String, start: Int = 0, document: Int? = nil) throws -> ComposeTextContext {
    try XCTUnwrap(ComposeTextContext(.with {
      $0.text = text; $0.sourceStart = UInt64(start); $0.utf16Start = UInt64(start)
      $0.selectionStart = UInt64(start); $0.selectionEnd = UInt64(start)
    }, documentLength: UInt64(document ?? start + text.utf8.count)))
  }
  private func value(_ text: String, context: ComposeTextContext, at: Int) throws -> ComposeMarkedText {
    try XCTUnwrap(ComposeMarkedText(context: context, range: NSRange(location: at, length: 0), source: at..<at,
      text: NSAttributedString(string: text), selected: NSRange(location: text.utf16.count, length: 0)))
  }

  func testPrimaryCanSelectInsideAnotherDraftWithoutMovingItsOwnerOrChangingSource() throws {
    let raw = try context("aa BB cc")
    let prefix = try XCTUnwrap(ComposeComposition(primary: 1, values: [
      1: try value("日本", context: raw, at: 0), 2: try value("日本", context: raw, at: 3)
    ]))
    let original = try XCTUnwrap(ComposeVirtualSelections(prefix: prefix))
    XCTAssertEqual(original.cursors[1]?.position, 2); XCTAssertEqual(original.cursors[2]?.position, 7)
    let pointer = try XCTUnwrap(ComposePendingPointer(scope: scope, epoch: 7, cursor: 2,
      text: "日本", caretOffset: 2, offset: 1, affinity: .downstream, extend: false, count: 1))
    let clicked = try XCTUnwrap(pointer.preview(in: prefix, selections: original))
    XCTAssertEqual(clicked.cursors[1]?.position, 6); XCTAssertEqual(clicked.cursors[2], original.cursors[2])
    XCTAssertEqual(clicked.selection, NSRange(location: 6, length: 0))
    let dragged = try XCTUnwrap(clicked.movingPrimary(to: 8, extend: true))
    XCTAssertEqual(dragged.selection, NSRange(location: 6, length: 2))
    XCTAssertEqual(dragged.substring(for: dragged.selection)?.string, "本B")
    let reversed = try XCTUnwrap(dragged.movingPrimary(to: 5, extend: true))
    XCTAssertEqual(reversed.cursors[1]?.anchor, 6); XCTAssertEqual(reversed.selection, NSRange(location: 5, length: 1))
    XCTAssertEqual(original.cursors[1]?.position, 2)
    XCTAssertEqual(prefix.values[1]?.source, 0..<0); XCTAssertEqual(prefix.values[2]?.source, 3..<3)
    XCTAssertEqual(prefix.values[1]?.context.text, "aa BB cc")
  }

  func testSelectionsKeepUTF16ScalarBoundariesAndActualIDsIndependentOfDraftOwners() throws {
    let raw = try context("Tail")
    let prefix = try XCTUnwrap(ComposeComposition(primary: 1, values: [1: try value("👩🏽‍💻", context: raw, at: 0)]))
    let selections = try XCTUnwrap(ComposeVirtualSelections(prefix: prefix, primary: 20,
      cursors: [20: .init(position: 0), 30: .init(position: 7)]))
    XCTAssertNil(selections.movingPrimary(to: 1, extend: false), "a surrogate pair cannot be split")
    XCTAssertNotNil(selections.movingPrimary(to: 2, extend: false))
    XCTAssertEqual(selections.substring(for: NSRange(location: 0, length: 7))?.string, "👩🏽‍💻")
    XCTAssertNil(selections.substring(for: NSRange(location: 1, length: 1)))
    XCTAssertEqual(selections.cursors[30]?.position, 7); XCTAssertNil(selections.cursors[1])
  }

  func testAReboundPrefixPreservesTheEarlierCapturedPointAndRejectsChangedInterveningText() throws {
    let raw = try context("abTail")
    let current = try XCTUnwrap(ComposeComposition(primary: 1, values: [1: try value("cd", context: raw, at: 2)]))
    let selection = try XCTUnwrap(ComposeVirtualSelections(prefix: current))
    let pointer = try XCTUnwrap(ComposePendingPointer(scope: scope, epoch: 7, cursor: 1,
      text: "abcd", caretOffset: 4, offset: 1, affinity: .downstream, extend: false, count: 1))
    XCTAssertEqual(try XCTUnwrap(pointer.preview(in: current, selections: selection)).selection.location, 1)
    let changedRaw = try context("axTail")
    let changed = try XCTUnwrap(ComposeComposition(primary: 1, values: [1: try value("cd", context: changedRaw, at: 2)]))
    XCTAssertNil(pointer.preview(in: changed, selections: try XCTUnwrap(ComposeVirtualSelections(prefix: changed))))
  }

  func testDistantContextsDoNotInventTextAndContradictoryOverlapsAreRejected() throws {
    let first = try context("left", document: 105), last = try context("right", start: 100)
    let prefix = try XCTUnwrap(ComposeComposition(primary: 1, values: [
      1: try value("X", context: first, at: 0), 2: try value("Y", context: last, at: 100)
    ]))
    let selections = try XCTUnwrap(ComposeVirtualSelections(prefix: prefix))
    XCTAssertNil(selections.movingPrimary(to: 50, extend: false))
    XCTAssertNil(selections.substring(for: NSRange(location: 3, length: 100)))
    XCTAssertNotNil(selections.movingPrimary(to: 103, extend: false))
    let one = try context("abcd"), two = try context("abXd")
    let conflicting = try XCTUnwrap(ComposeComposition(primary: 1, values: [
      1: try value("1", context: one, at: 0), 2: try value("2", context: two, at: 3)
    ]))
    XCTAssertNil(ComposeVirtualSelections(prefix: conflicting))
  }
}
