import XCTest
@testable import FreshKit

final class ComposeAcceptedEditsTests: XCTestCase {
  private var scope: WireComposeScope { .with { $0.windowID = 1; $0.leaf = 2; $0.buffer = 3; $0.bufferRevision = 4 } }
  private func anchor(_ cursor: UInt64, _ before: Range<UInt64>, _ after: Range<UInt64>, _ text: String) -> WireComposeEditAnchor {
    .with {
      $0.cursor = cursor; $0.beforeStart = before.lowerBound; $0.beforeEnd = before.upperBound
      $0.start = after.lowerBound; $0.end = after.upperBound; $0.digest = ComposeAcceptedEdits.digest(text)
    }
  }
  private func receipt(_ anchors: [WireComposeEditAnchor], before: UInt64, after: UInt64) -> WireComposeEditReceipt {
    .with {
      $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.sourceRevision = 4; $0.sourceLength = before
      $0.anchors = anchors; $0.cursors = anchors.map(\.cursor)
      $0.pane.bufferRevision = 5; $0.pane.documentLen = after; $0.pane.sourceEnd = after; $0.pane.viewport.epoch = 7
      $0.pane.cursors = anchors.enumerated().map { index, anchor in .with {
        $0.id = anchor.cursor; $0.position = anchor.end; $0.primary = index == 0
      } }
    }
  }
  private func replacementReceipt() -> WireComposeEditReceipt {
    receipt([anchor(1,0..<5,0..<6,"日本"),anchor(2,6..<11,7..<9,"é"),anchor(3,12..<17,10..<10,"")],before: 17,after: 10)
  }

  func testAcceptedBatchRebasesOriginalEndpointsAndMapsInsertedUnicodeWithoutRawContext() throws {
    let proof = try XCTUnwrap(ComposeAcceptedEdits(replacementReceipt(),original: scope,epoch: 7))
    for (old,new) in [(0,0),(5,6),(6,7),(11,9),(12,10),(17,10)] {
      XCTAssertEqual(proof.rebased(old,from: 4),new)
    }
    for inside in [1,4,7,10,13,16] { XCTAssertNil(proof.rebased(inside,from: 4)) }
    XCTAssertNil(proof.rebased(0,from: 3)); XCTAssertNil(proof.rebased(18,from: 4))
    let inserted = try XCTUnwrap(ComposeAcceptedEdits.InsertedPosition(text: "日本",offsetUTF16: 1))
    XCTAssertEqual(proof.position(inserted,cursor: 1),3)
    XCTAssertNil(proof.position(inserted,cursor: 2)); XCTAssertNil(proof.position(inserted,cursor: 99))
  }

  func testInsertionAffinityAndAdjacentDeletionBoundaryUseTheWholeBatch() throws {
    let inserts = receipt([anchor(1,0..<0,0..<3,"abc"),anchor(2,4..<4,7..<9,"XY")],before: 4,after: 9)
    let proof = try XCTUnwrap(ComposeAcceptedEdits(inserts,original: scope,epoch: 7))
    XCTAssertEqual(proof.rebased(0,from: 4,affinity: .upstream),0)
    XCTAssertEqual(proof.rebased(0,from: 4),3)
    XCTAssertEqual(proof.rebased(4,from: 4,affinity: .upstream),7)
    XCTAssertEqual(proof.rebased(4,from: 4),9)
    let adjacent = receipt([anchor(1,0..<2,0..<0,""),anchor(2,2..<2,0..<3,"abc")],before: 4,after: 5)
    let next = try XCTUnwrap(ComposeAcceptedEdits(adjacent,original: scope,epoch: 7))
    XCTAssertEqual(next.rebased(2,from: 4,affinity: .upstream),0)
    XCTAssertEqual(next.rebased(2,from: 4),3)
    XCTAssertEqual(next.rebased(4,from: 4),5)
  }

  func testMalformedPartialOrRetiredProofsCannotBecomeSourceCoordinates() {
    let valid = replacementReceipt()
    let mutations: [(inout WireComposeEditReceipt) -> Void] = [
      { $0.clearSourceRevision() },{ $0.clearSourceLength() },{ $0.sourceRevision = 3 },{ $0.sourceRevision = 6 },
      { $0.sourceLength = 18 },{ $0.pane.documentLen = 11; $0.pane.sourceEnd = 11 },
      { $0.anchors.removeLast() },{ $0.cursors.removeLast() },{ $0.anchors[1].cursor = 1 },
      { $0.anchors.reverse() },{ $0.anchors[1].beforeStart = 4 },{ $0.anchors[1].beforeEnd = 18 },
      { $0.anchors[1].start = 6 },{ $0.anchors[1].end = 6 },{ $0.anchors[1].digest = Data([0]) },
      { $0.pane.cursors[1].position = 8 },{ $0.pane.cursors[1].anchor = 7 },{ $0.pane.cursors[1].id = 1 },
      { $0.epoch = 8 },{ $0.window = 2 },{ $0.leaf = 9 },{ $0.buffer = 9 },
    ]
    for (index, mutation) in mutations.enumerated() {
      var invalid = valid; mutation(&invalid)
      XCTAssertNil(ComposeAcceptedEdits(invalid,original: scope,epoch: 7),"mutation \(index)")
    }
    var duplicateStart = receipt([anchor(1,0..<0,0..<1,"a"),anchor(2,0..<0,1..<2,"b")],before: 4,after: 6)
    XCTAssertNil(ComposeAcceptedEdits(duplicateStart,original: scope,epoch: 7))
    duplicateStart.anchors = []; duplicateStart.cursors = []
    XCTAssertNil(ComposeAcceptedEdits(duplicateStart,original: scope,epoch: 7))
  }

  func testLiteralDigestScalarBoundariesAndPayloadLengthAreRequiredForAnInsertedPosition() throws {
    let proof = try XCTUnwrap(ComposeAcceptedEdits(replacementReceipt(),original: scope,epoch: 7))
    let canonical = try XCTUnwrap(ComposeAcceptedEdits.InsertedPosition(text: "e\u{301}",offsetUTF16: 1))
    XCTAssertEqual("é","e\u{301}"); XCTAssertNil(proof.position(canonical,cursor: 2))
    let changed = try XCTUnwrap(ComposeAcceptedEdits.InsertedPosition(text: "ab",offsetUTF16: 1))
    XCTAssertNil(proof.position(changed,cursor: 2))
    XCTAssertNil(ComposeAcceptedEdits.InsertedPosition(text: "👩🏽‍💻",offsetUTF16: 1))
    XCTAssertNil(ComposeAcceptedEdits.InsertedPosition(text: "abc",offsetUTF16: -1))
    XCTAssertNil(ComposeAcceptedEdits.InsertedPosition(text: "abc",offsetUTF16: 4))
  }
}
