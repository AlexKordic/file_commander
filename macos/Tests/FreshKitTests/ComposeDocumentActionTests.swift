import XCTest
@testable import FreshKit

final class ComposeDocumentActionTests: XCTestCase {
  private var owner: WireComposeIndexOwner { .with {
    $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.revision = 4; $0.length = 4; $0.authority = 10; $0.document = 11
  } }
  private var scope: WireComposeScope { .with { $0.windowID = 1; $0.leaf = 2; $0.buffer = 3; $0.bufferRevision = 4 } }
  private func anchor(_ id: UInt64, before: Range<UInt64>, after: Range<UInt64>, text: String) -> WireComposeEditAnchor {
    .with { $0.cursor = id; $0.beforeStart = before.lowerBound; $0.beforeEnd = before.upperBound
      $0.start = after.lowerBound; $0.end = after.upperBound; $0.digest = ComposeAcceptedEdits.digest(text) }
  }
  private func receipt(_ anchors: [WireComposeEditAnchor], before: UInt64, length: UInt64, after: UInt64, resultLength: UInt64) -> WireComposeEditReceipt {
    .with {
      $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7
      if !anchors.isEmpty { $0.anchors = anchors; $0.cursors = anchors.map(\.cursor); $0.sourceRevision = before; $0.sourceLength = length }
      $0.pane.viewport.epoch = 7; $0.pane.bufferRevision = after; $0.pane.documentLen = resultLength; $0.pane.sourceEnd = resultLength
      $0.pane.assetAuthority = 10; $0.pane.assetDocument = 11
      $0.pane.cursors = anchors.enumerated().map { index, value in .with {
        $0.id = value.cursor; $0.primary = index == 0; $0.position = value.end
      } }
    }
  }
  private func pending(_ text: String, following first: ComposePendingText? = nil, replacement: NSRange? = nil) throws -> ComposePendingText {
    let pane = WireComposePane.with {
      $0.documentLen = 4; $0.bufferRevision = 4; $0.viewport.epoch = 7; $0.nativeNewline = 2
      $0.textContext.text = "Tail"; $0.cursors = [.with { $0.id = 1; $0.primary = true; $0.utf16Position = 0 }]
    }
    let attributed = NSAttributedString(string: text), range = replacement ?? NSRange(location: NSNotFound,length: 0)
    let next = first.map { ComposePendingText(following: $0,pane: pane,text: attributed,
      selected: NSRange(location: attributed.length,length: 0),replacement: range) }
      ?? ComposePendingText(pane: pane,text: attributed,selected: NSRange(location: attributed.length,length: 0),replacement: range)
    return try XCTUnwrap(next?.committed(nativeNewline: 2))
  }

  func testSelectionCanSpanAnEarlierRetainedPrefixAndALaterNormalizedInsertion() throws {
    let first = try pending("abc"), second = try pending("\nYZ",following: first,replacement: NSRange(location: 1,length: 1))
    XCTAssertEqual(second.presentation.primary.draft.string,"a\r\nYZc")
    guard case .inserted(let secondID,let selected)? = second.origin(atProvisionalUTF16: 3),
          case .before(let old)? = second.origin(atProvisionalUTF16: 6),
          case .inserted(let firstID,let retained)? = first.origin(atProvisionalUTF16: old) else { return XCTFail("origins must survive the later replacement") }
    XCTAssertEqual(old,3)
    let one = UUID(), two = UUID()
    let action = try XCTUnwrap(ComposeDocumentAction(owner: owner,scope: scope,bounds: [.init(
      start: .inserted(two,cursor: .known(secondID),position: selected,affinity: .downstream),
      end: .inserted(one,cursor: .known(firstID),position: retained,affinity: .upstream))],kind: .selection))
    XCTAssertNil(action.ready())
    let firstReceipt = receipt([anchor(1,before: 0..<0,after: 0..<3,text: "abc")],before: 4,length: 4,after: 5,resultLength: 7)
    let intermediate = try XCTUnwrap(action.resolving(firstReceipt,token: one)); XCTAssertNil(intermediate.ready())
    let secondReceipt = receipt([anchor(1,before: 1..<2,after: 1..<5,text: "\r\nYZ")],before: 5,length: 7,after: 6,resultLength: 10)
    let bound = try XCTUnwrap(intermediate.resolving(secondReceipt,token: two))
    guard case .selection(let change)? = bound.ready() else { return XCTFail("both points should now own real source") }
    let input = change.input(id: 9)
    XCTAssertEqual(input.sourceRevision,6); XCTAssertEqual(input.selectionTargets[0].anchor,3); XCTAssertEqual(input.selectionTargets[0].position,6)
    XCTAssertEqual(String(decoding: Array("a\r\nYZcTail".utf8)[3..<6],as: UTF8.self),"YZc")
  }

  func testProposedCursorOrdinalsBindOnlyFromTheActualSelectionReceipt() throws {
    let selector = UUID(), text = UUID()
    let a = try XCTUnwrap(ComposeAcceptedEdits.InsertedPosition(text: "X",offsetUTF16: 1))
    let action = try XCTUnwrap(ComposeDocumentAction(owner: owner,scope: scope,bounds: [
      .init(start: .inserted(text,cursor: .selectedGroup(selector,ordinal: 0),position: a,affinity: .downstream),
        end: .inserted(text,cursor: .selectedGroup(selector,ordinal: 0),position: a,affinity: .downstream)),
      .init(start: .inserted(text,cursor: .selectedGroup(selector,ordinal: 1),position: a,affinity: .downstream),
        end: .inserted(text,cursor: .selectedGroup(selector,ordinal: 1),position: a,affinity: .downstream))],kind: .selection))
    let selected = receipt([],before: 4,length: 4,after: 4,resultLength: 4)
    XCTAssertNil(action.resolving(selected,token: selector))
    XCTAssertNil(action.resolving(selected,token: selector,selectedIDs: [42,42]))
    let bound = try XCTUnwrap(action.resolving(selected,token: selector,selectedIDs: [42,107]))
    let edited = receipt([anchor(42,before: 0..<0,after: 0..<1,text: "X"),anchor(107,before: 4..<4,after: 5..<6,text: "X")],
      before: 4,length: 4,after: 5,resultLength: 6)
    let ready = try XCTUnwrap(bound.resolving(edited,token: text))
    guard case .selection(let change)? = ready.ready() else { return XCTFail("the genuine group must bind") }
    XCTAssertEqual(change.input(id: 8).selectionTargets.map(\.position),[1,6])
  }

  func testUnmodelledSourceChangesAndRetiredOwnersRefuseTheEntireAction() throws {
    let action = try XCTUnwrap(ComposeDocumentAction(owner: owner,scope: scope,bounds: [
      .init(start: .source(1,affinity: .downstream),end: .source(4,affinity: .upstream))],
      kind: .replacement("retained text",cursor: .known(1))))
    XCTAssertEqual(action.recoveryTexts,["retained text"])
    let overwrite = receipt([anchor(1,before: 0..<2,after: 0..<1,text: "X")],before: 4,length: 4,after: 5,resultLength: 3)
    XCTAssertNil(action.resolving(overwrite,token: UUID()),"a replaced interior has no exact correspondence")
    let opaque = receipt([],before: 4,length: 4,after: 5,resultLength: 4)
    XCTAssertNil(action.resolving(opaque,token: UUID()))
    var replaced = receipt([],before: 4,length: 4,after: 4,resultLength: 4); replaced.pane.assetDocument = 12
    XCTAssertNil(action.resolving(replaced,token: UUID()))
    replaced.pane.assetDocument = 11; replaced.epoch = 8
    XCTAssertNil(action.resolving(replaced,token: UUID()))
    let unchanged = receipt([],before: 4,length: 4,after: 4,resultLength: 4)
    guard case .replacement(let replacement)? = action.resolving(unchanged,token: UUID())?.ready() else { return XCTFail("unchanged source survives a selection-only result") }
    XCTAssertEqual(replacement.input(id: 2).replacementStart,1); XCTAssertEqual(replacement.input(id: 2).replacementEnd,4)
  }

  func testOriginBoundariesAndOriginalContextNeverInventMissingRawText() throws {
    let inserted = try pending("日本")
    guard case .inserted(let id,let point)? = inserted.origin(atProvisionalUTF16: 1) else { return XCTFail("scalar point owns its insertion") }
    XCTAssertEqual(id,1)
    XCTAssertNil(inserted.origin(atProvisionalUTF16: -1))
    XCTAssertEqual(inserted.sourcePosition(beforePendingAtUTF16: 2,documentLength: 4),2)
    XCTAssertNil(inserted.sourcePosition(beforePendingAtUTF16: 5,documentLength: 4))
    XCTAssertNil(inserted.sourcePosition(beforePendingAtUTF16: 2,documentLength: 5))
    let token = UUID(), root = try XCTUnwrap(ComposeDocumentAction(owner: owner,scope: scope,bounds: [.init(
      start: .inserted(token,cursor: .known(id),position: point,affinity: .downstream),
      end: .source(4,affinity: .upstream))],kind: .selection))
    let receipt = receipt([anchor(1,before: 0..<0,after: 0..<6,text: "日本")],before: 4,length: 4,after: 5,resultLength: 10)
    guard case .selection(let change)? = root.resolving(receipt,token: token)?.ready() else { return XCTFail("a copied endpoint rebases through an insertion it does not own") }
    XCTAssertEqual(change.input(id: 2).selectionTargets[0].anchor,3)
    XCTAssertEqual(change.input(id: 2).selectionTargets[0].position,10)
  }

  func testPointNormalizationChangesOnlyTheCurrentDeltaAndKeepsRetainedMixedEndings() throws {
    let pane = WireComposePane.with {
      $0.documentLen = 6; $0.bufferRevision = 4; $0.viewport.epoch = 7; $0.nativeNewline = 2
      $0.textContext.text = "L\nTail"; $0.textContext.selectionStart = 2; $0.textContext.selectionEnd = 2
      $0.cursors = [.with { $0.id = 1; $0.primary = true; $0.position = 2; $0.utf16Position = 2 }]
    }
    let first = try XCTUnwrap(ComposePendingText(pane: pane,text: NSAttributedString(string: "P"),
      selected: NSRange(location: 1,length: 0),replacement: NSRange(location: NSNotFound,length: 0))?.committed(nativeNewline: 2))
    let second = try XCTUnwrap(ComposePendingText(following: first,pane: pane,text: NSAttributedString(string: "X\n"),
      selected: NSRange(location: 2,length: 0),replacement: NSRange(location: 0,length: 0)))
    let committed = try XCTUnwrap(second.committed(nativeNewline: 2))
    XCTAssertEqual(second.presentation.primary.draft.string,"X\nL\nP")
    XCTAssertEqual(committed.presentation.primary.draft.string,"X\r\nL\nP")
    XCTAssertEqual(committed.normalizedPosition(4,displayed: second.presentation,nativeNewline: 2),5)
    XCTAssertEqual(committed.normalizedPosition(5,displayed: committed.presentation,nativeNewline: 2),5)
    guard case .before(let earlier)? = committed.origin(atProvisionalUTF16: 5),
          case .inserted(let cursor,_)? = first.origin(atProvisionalUTF16: earlier) else { return XCTFail("the retained prefix keeps its original owner") }
    XCTAssertEqual(earlier,2); XCTAssertEqual(cursor,1)
  }
}
