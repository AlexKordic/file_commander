import XCTest
@testable import FreshKit

final class ComposeDocumentReceiverTests: XCTestCase {
  private let owner = WireComposeIndexOwner.with {
    $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.revision = 5
    $0.authority = 10; $0.document = 11; $0.length = 114_000
  }
  private func pane() -> WireComposePane {
    .with {
      $0.text = String(repeating: "é👩🏽‍💻\r\n", count: 6000)
      $0.documentLen = UInt64($0.text.utf8.count); $0.sourceEnd = $0.documentLen
      $0.bufferRevision = owner.revision; $0.selectionRevision = 6; $0.decorationRevision = 0
      $0.assetAuthority = owner.authority; $0.assetDocument = owner.document; $0.viewport.epoch = owner.epoch
      $0.ready = true; $0.currentProjection = true
      $0.segments = [.with { $0.sourceEnd = owner.length; $0.displayEnd = owner.length }]
      $0.cursors = [.with { $0.id = 1; $0.primary = true }]
    }
  }
  private func chunk(_ data: Data, sequence: UInt64 = 0, done: Bool = true, length: Int? = nil) -> WireComposeDocumentChunk {
    .with {
      $0.id = 1; $0.owner = owner; $0.selection = 6; $0.sequence = sequence
      $0.length = UInt64(length ?? data.count); $0.data = data; $0.done = done; $0.decorationRevision = 0
    }
  }

  func testBinaryPartsMaySplitProtobufOrUtf8ButOnlyACompleteOwnedProjectionIsPublished() async throws {
    let original = pane(), bytes = try original.serializedData()
    XCTAssertEqual(original.documentLen, owner.length)
    var receiver = ComposeDocumentReceiver(id: 1, owner: owner, selection: 6)
    var at = 0, sequence: UInt64 = 0, result: Data?
    while at < bytes.count {
      let end = min(bytes.count, at + (sequence == 0 ? 1 : 64 << 10))
      result = try receiver.receive(chunk(bytes.subdata(in: at..<end), sequence: sequence, done: end == bytes.count, length: bytes.count))
      if end < bytes.count { XCTAssertNil(result) }
      at = end; sequence += 1
    }
    XCTAssertGreaterThan(sequence, 2)
    XCTAssertEqual(result, bytes); XCTAssertEqual(receiver.decorationRevision, 0)
    let complete = try XCTUnwrap(result), owner = owner
    let document = try await Task.detached { try ComposeDocumentReceiver.decode(complete, owner: owner, selection: 6, decoration: 0) }.value
    XCTAssertEqual(document.text.utf8.count, Int(owner.length)); XCTAssertEqual(document.characterCount, original.text.utf16.count)
    XCTAssertEqual(document.decorationRevision, 0)
    XCTAssertThrowsError(try receiver.receive(chunk(bytes)), "a completed body cannot be appended to or replayed")
  }

  func testMalformedPrefixesAndRetiredOwnershipDiscardTheWholeTransfer() throws {
    let valid = chunk(Data([1, 2, 3]))
    let edits: [(inout WireComposeDocumentChunk) -> Void] = [
      {$0.sequence = 1}, {$0.owner.revision += 1}, {$0.selection += 1}, {$0.length = 0},
      {$0.length = UInt64(ComposeDocumentReceiver.maximumEncoded)+1}, {$0.data = Data()}, {$0.done = false},
      {$0.length = 2}, {$0.error = "source changed"}, {$0.data = Data(repeating: 0,count: (64 << 10)+1)},
    ]
    for edit in edits {
      var receiver = ComposeDocumentReceiver(id: 1, owner: owner, selection: 6), bad = valid
      edit(&bad); XCTAssertThrowsError(try receiver.receive(bad)); XCTAssertThrowsError(try receiver.receive(valid))
    }
    var receiver = ComposeDocumentReceiver(id: 1, owner: owner, selection: 6)
    XCTAssertNil(try receiver.receive(chunk(Data([1]), done: false, length: 2)))
    var tail = chunk(Data([2]), sequence: 1, length: 2); tail.decorationRevision = 1
    XCTAssertThrowsError(try receiver.receive(tail), "formatting ownership cannot change halfway through a binary snapshot")
  }

  func testDecodedBodyMustProveItsHeaderAndCompleteMap() throws {
    let source = pane()
    let edits: [(inout WireComposePane) -> Void] = [
      {$0.clearDecorationRevision()}, {$0.decorationRevision = 1}, {$0.selectionRevision += 1}, {$0.bufferRevision += 1},
      {$0.assetAuthority += 1}, {$0.assetDocument += 1}, {$0.viewport.epoch += 1}, {$0.sourceStart = 1},
      {$0.sourceEnd -= 1}, {$0.documentLen += 1}, {$0.ready = false; $0.currentProjection = false},
      {$0.segments[0].displayEnd -= 1},
    ]
    for edit in edits {
      var changed = source; edit(&changed)
      XCTAssertThrowsError(try ComposeDocumentReceiver.decode(changed.serializedData(), owner: owner, selection: 6, decoration: 0))
    }
    XCTAssertThrowsError(try ComposeDocumentReceiver.decode(Data(), owner: owner, selection: 6, decoration: 0))
  }

  @MainActor
  func testCapabilityAndAcknowledgmentRemainSeparateFromSceneMessages() throws {
    let input = SceneInput.composeDocument(.with { $0.id = 1; $0.appliedSequence = 0 })
    XCTAssertEqual(input.kind.rawValue, 32); XCTAssertEqual(input.payload(), [8,1,32,0])
    XCTAssertTrue(try WireComposeDocumentRequest(serializedBytes: input.payload()).hasAppliedSequence)
    XCTAssertNil(SceneMessage(kind: 5, payload: ArraySlice(try chunk(Data([1])).serializedData())))
    let store = SceneStore()
    let hello = try WireServerHello.with { $0.composeDocumentText = true; $0.composeDocumentUpdates = true }.serializedData()
    store.apply(try XCTUnwrap(SceneMessage(kind: 1, payload: ArraySlice(hello))))
    XCTAssertTrue(store.composeDocumentText)
    XCTAssertTrue(store.composeDocumentUpdates)
    store.apply(try XCTUnwrap(SceneMessage(kind: 2, payload: []))); XCTAssertTrue(store.composeDocumentText)
    store.apply(try XCTUnwrap(SceneMessage(kind: 1, payload: []))); XCTAssertFalse(store.composeDocumentText)
    XCTAssertFalse(store.composeDocumentUpdates)
    let retained = SceneInput.composeDocument(.with { $0.id = 1; $0.baseID = 0 })
    XCTAssertEqual(retained.payload(),[8,1,48,0])
    XCTAssertTrue(try WireComposeDocumentRequest(serializedBytes: retained.payload()).hasBaseID)
  }
}
