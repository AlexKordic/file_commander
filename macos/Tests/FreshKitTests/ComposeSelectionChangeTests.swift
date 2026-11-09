import XCTest
@testable import FreshKit

final class ComposeSelectionChangeTests: XCTestCase {
  func testWireCapturesAbsoluteSourceRangesAndRetainsExplicitZeroWithoutGeometry() throws {
    let scope = WireComposeScope.with { $0.windowID = 1; $0.leaf = 2; $0.buffer = 3 }
    let change = try XCTUnwrap(ComposeSelectionChange(scope: scope, epoch: 7, ranges: [0..<5, 9..<9]))
    let input = change.input(id: 8)
    XCTAssertEqual(input.scope, scope); XCTAssertEqual(input.id, 8)
    XCTAssertTrue(input.hasSourceRevision); XCTAssertEqual(input.sourceRevision, 0)
    XCTAssertEqual(input.bufferEpoch, 7); XCTAssertEqual(input.kind, 0); XCTAssertTrue(input.payload.isEmpty)
    XCTAssertFalse(input.hasLayout); XCTAssertFalse(input.hasPosition); XCTAssertFalse(input.hasReplacementStart)
    XCTAssertEqual(input.selectionTargets.map(\.position), [5, 9])
    XCTAssertTrue(input.selectionTargets[0].hasAnchor); XCTAssertEqual(input.selectionTargets[0].anchor, 0)
    XCTAssertFalse(input.selectionTargets[1].hasAnchor)
    XCTAssertEqual(try input.selectionTargets[0].serializedData(), Data([8, 5, 16, 0]))
  }

  func testInvalidAndOverlappingGroupsCannotBecomeSelectionCommands() {
    let scope = WireComposeScope()
    for ranges in [[Range<Int>](), [0..<0, 0..<0], [0..<5, 3..<8], [0..<5, 5..<5], [-1..<0], Array(repeating: 0..<1, count: 1025)] {
      XCTAssertNil(ComposeSelectionChange(scope: scope, epoch: 7, ranges: ranges))
    }
    XCTAssertNil(ComposeSelectionChange(scope: scope, epoch: 0, ranges: [0..<0]))
  }

  func testPreviewPreservesPrimaryIdentityAndOnlyTheReceiptCanSupplyNewSecondaryIds() throws {
    let text = "alpha café 👩🏽‍💻"
    let pane = WireComposePane.with {
      $0.bufferRevision = 4; $0.viewport.epoch = 7
      $0.text = text; $0.documentLen = UInt64(text.utf8.count)
      $0.textContext = .with { $0.text = text }
      $0.cursors = [.with { $0.primary = true; $0.id = 8 }, .with { $0.id = 90; $0.position = 2 }]
    }
    let scope = WireComposeScope.with { $0.bufferRevision = 4 }
    let change = try XCTUnwrap(ComposeSelectionChange(scope: scope, epoch: 7, ranges: [6..<11, 0..<0]))
    let shown = try XCTUnwrap(change.preview(in: pane))
    XCTAssertEqual(shown.cursors[0].id, 8); XCTAssertTrue(shown.cursors[0].primary)
    XCTAssertEqual(shown.cursors[0].utf16Position, 10); XCTAssertEqual(shown.cursors[0].utf16Anchor, 6)
    XCTAssertEqual(shown.cursors[1].id, 91)
    XCTAssertEqual(shown.textContext.selectionStart, 6); XCTAssertEqual(shown.textContext.selectionEnd, 10)
    XCTAssertEqual(shown.text, text); XCTAssertEqual(pane.cursors.count, 2)
    XCTAssertEqual(change.input(id: 1).selectionTargets.count, 2)
    var changed = pane; changed.bufferRevision += 1
    XCTAssertNil(change.preview(in: changed))
    changed = pane; changed.viewport.epoch += 1
    XCTAssertNil(change.preview(in: changed))
  }

  func testReceiptTextReplacementNeedsNoRawContextAndUsesOnlyRealReturnedCursorIds() throws {
    let pane = WireComposePane.with {
      $0.documentLen = 100000
      $0.cursors = [.with { $0.primary = true; $0.id = 8; $0.position = 90000; $0.anchor = 5 },
        .with { $0.id = 451; $0.position = 95000 }]
    }
    let replacement = try XCTUnwrap(ComposeReplacement(scope: .init(), epoch: 7, pane: pane, text: "new"))
    let input = replacement.input(id: 1)
    XCTAssertEqual(input.replacementCursor, 8); XCTAssertEqual(input.replacementStart, 5); XCTAssertEqual(input.replacementEnd, 90000)
    XCTAssertEqual(input.replacements.map(\.cursor), [451]); XCTAssertEqual(input.replacements[0].start, 95000)
    XCTAssertEqual(try WirePaste(serializedBytes: input.payload).text, "new")
    var wrong = pane; wrong.bufferRevision = 1
    XCTAssertNil(ComposeReplacement(scope: .init(), epoch: 7, pane: wrong, text: "new"))
    wrong = pane; wrong.cursors[1].primary = true
    XCTAssertNil(ComposeReplacement(scope: .init(), epoch: 7, pane: wrong, text: "new"))
  }
}
