import XCTest
@testable import FreshKit

final class ComposePendingPointerTests: XCTestCase {
  private var scope: WireComposeScope {
    .with { $0.windowID = 1; $0.leaf = 2; $0.buffer = 3; $0.bufferRevision = 4 }
  }
  private func pane(_ text: String, cursor: UInt64 = 1, position: Int, unit: Int) -> WireComposePane {
    .with {
      $0.bufferRevision = 5; $0.documentLen = UInt64(text.utf8.count); $0.sourceEnd = $0.documentLen
      $0.viewport.epoch = 7; $0.nativeNewline = 1; $0.textContext.text = text
      $0.textContext.selectionStart = UInt64(unit); $0.textContext.selectionEnd = UInt64(unit)
      $0.cursors = [.with { $0.id = cursor; $0.primary = true; $0.position = UInt64(position); $0.utf16Position = UInt64(unit) }]
    }
  }
  private func receipt(_ pane: WireComposePane, edited: [UInt64]) -> WireComposeEditReceipt {
    .with { $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.cursors = edited; $0.pane = pane }
  }

  func testReceiptMapsASecondaryDraftPointUsingProvenOwnerAndExactUTF16Text() throws {
    let pending = try XCTUnwrap(ComposePendingPointer(scope: scope, epoch: 7, cursor: 2,
      text: "café", caretOffset: 4, offset: 2, affinity: .upstream, extend: true, count: 2))
    var current = pane("Xcafé Tail", cursor: 2, position: 6, unit: 5)
    current.cursors[0].primary = false
    current.cursors.insert(.with { $0.id = 1; $0.primary = true; $0.position = 0; $0.utf16Position = 0 }, at: 0)
    let result = receipt(current, edited: [2])
    let pointer = try XCTUnwrap(pending.resolved(result)).input(id: 9)
    XCTAssertEqual(pointer.position, 3); XCTAssertEqual(pointer.sourceRevision, 5)
    XCTAssertEqual(pointer.affinity, 1); XCTAssertTrue(pointer.extend); XCTAssertEqual(pointer.clickCount, 2)
    var invalid = result; invalid.cursors = [1]
    XCTAssertNil(pending.resolved(invalid))
    invalid.preservedCursors = [2]
    XCTAssertNotNil(pending.resolved(invalid), "a later prefix can prove an unchanged earlier draft owner")
    invalid = result; invalid.epoch = 8
    XCTAssertNil(pending.resolved(invalid))
    invalid = result; invalid.pane.textContext.text = "XcafE Tail"
    XCTAssertNil(pending.resolved(invalid), "a receipt cannot silently substitute different inserted text")
    invalid = result; invalid.pane.textContext.text = " Tail"; invalid.pane.textContext.sourceStart = 6; invalid.pane.textContext.utf16Start = 5
    XCTAssertNil(pending.resolved(invalid), "insufficient source evidence cannot manufacture a pointer coordinate")
  }

  func testNearbyPointInALargeInsertUsesOnlyTheBoundedSourceBetweenPointAndCaret() throws {
    let prefix = String(repeating: "x", count: 5_000), inserted = prefix + "café"
    let close = try XCTUnwrap(ComposePendingPointer(scope: scope, epoch: 7, cursor: 1,
      text: inserted, caretOffset: inserted.utf16.count, offset: inserted.utf16.count - 1,
      affinity: .downstream, extend: false, count: 1))
    var current = pane("Q" + inserted + "Tail", position: 1 + inserted.utf8.count, unit: 1 + inserted.utf16.count)
    current.textContext.text = "caféTail"; current.textContext.sourceStart = 5_001; current.textContext.utf16Start = 5_001
    let result = receipt(current, edited: [1])
    XCTAssertEqual(try XCTUnwrap(close.resolved(result)).input(id: 2).position, 5_004)
    let far = try XCTUnwrap(ComposePendingPointer(scope: scope, epoch: 7, cursor: 1,
      text: inserted, caretOffset: inserted.utf16.count, offset: 0, affinity: .downstream, extend: false, count: 1))
    XCTAssertNil(far.resolved(result), "missing intervening source cannot be guessed")
  }

  func testCaptureNormalizesTheDisplayedOffsetUsingTheDeclaredCRLFPolicy() throws {
    var initial = pane("Tail", position: 0, unit: 0); initial.bufferRevision = 4; initial.nativeNewline = 2
    let draft = try XCTUnwrap(ComposePendingText(pane: initial, text: NSAttributedString(string: "\n café"),
      selected: NSRange(location: 6, length: 0), replacement: NSRange(location: NSNotFound, length: 0)))
    let committed = try XCTUnwrap(draft.committed(nativeNewline: 2))
    let pointer = try XCTUnwrap(committed.pointer(scope: scope, epoch: 7, displayed: draft.presentation,
      cursor: 1, offset: 1, affinity: .downstream, extend: false, count: 1, nativeNewline: 2))
    let inserted = "\r\n café"
    let result = receipt(pane(inserted + "Tail", position: inserted.utf8.count, unit: inserted.utf16.count), edited: [1])
    XCTAssertEqual(try XCTUnwrap(pointer.resolved(result)).input(id: 2).position, 2)
  }

  func testPointInAChainedPrefixUsesTheLastEditCaretInsteadOfTheWholeDraftEnd() throws {
    var initial = pane("Tail", position: 0, unit: 0); initial.bufferRevision = 4
    let first = try XCTUnwrap(ComposePendingText(pane: initial, text: NSAttributedString(string: "abcd"),
      selected: NSRange(location: 4, length: 0), replacement: NSRange(location: NSNotFound, length: 0)))
    let prefix = try XCTUnwrap(first.committed(nativeNewline: 1))
    let second = try XCTUnwrap(ComposePendingText(following: prefix, pane: initial, text: NSAttributedString(string: "XY"),
      selected: NSRange(location: 2, length: 0), replacement: NSRange(location: 1, length: 1)))
    let committed = try XCTUnwrap(second.committed(nativeNewline: 1))
    let pointer = try XCTUnwrap(committed.pointer(scope: scope, epoch: 7, displayed: committed.presentation,
      cursor: 1, offset: 4, affinity: .downstream, extend: false, count: 1, nativeNewline: 1))
    XCTAssertEqual(committed.presentation.primary.draft.string, "aXYcd")
    let result = receipt(pane("aXYcdTail", position: 3, unit: 3), edited: [1])
    XCTAssertEqual(try XCTUnwrap(pointer.resolved(result)).input(id: 3).position, 4)
  }
}
