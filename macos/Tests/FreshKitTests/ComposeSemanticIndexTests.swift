import XCTest
@testable import FreshKit

final class ComposeSemanticIndexTests: XCTestCase {
  private let owner = WireComposeIndexOwner.with {
    $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 4; $0.revision = 5
    $0.authority = 6; $0.document = 7; $0.length = 8_000_000
  }

  private func chunk(_ labels: [(UInt32, String)], sequence: UInt64 = 0, done: Bool = true) -> WireComposeIndexChunk {
    .with {
      $0.id = 1; $0.owner = owner; $0.sequence = sequence; $0.done = done
      $0.totalEntries = UInt64(labels.count); $0.labelBytes = UInt64(labels.reduce(0) { $0 + $1.1.utf8.count })
      $0.parts = labels.enumerated().map { index, label in .with {
        $0.index = UInt64(index); $0.start = UInt64(index * 50); $0.end = $0.start + 25
        $0.kind = label.0; $0.label = label.1; $0.labelLength = UInt64(label.1.utf8.count); $0.labelDone = true
      } }
    }
  }

  @MainActor
  func testIndependentWireHasExplicitAckZeroAndNeverBecomesAFrame() throws {
    let request = SceneInput.composeIndex(.with { $0.id = 1; $0.appliedSequence = 0 })
    XCTAssertEqual(request.kind.rawValue, 31)
    XCTAssertEqual(request.payload(), [8, 1, 32, 0])
    let decoded = try WireComposeIndexRequest(serializedBytes: request.payload())
    XCTAssertTrue(decoded.hasAppliedSequence)
    XCTAssertNil(SceneMessage(kind: 4, payload: ArraySlice(try chunk([]).serializedData())))
    let hello = WireServerHello.with { $0.version = 1; $0.composeSemanticIndex = true }
    let store = SceneStore()
    store.apply(try XCTUnwrap(SceneMessage(kind: 1, payload: ArraySlice(try hello.serializedData()))))
    XCTAssertTrue(store.composeSemanticIndex)
    store.apply(try XCTUnwrap(SceneMessage(kind: 2, payload: [])))
    XCTAssertTrue(store.composeSemanticIndex)
    store.apply(try XCTUnwrap(SceneMessage(kind: 1, payload: [])))
    XCTAssertFalse(store.composeSemanticIndex)
  }

  func testSearchUsesCompleteParsedNamesInBothDirectionsIncludingUnicodeTails() throws {
    let parts: [(UInt32, String)] = [(1, "Café 東京"), (16, "same"), (2, "Second"), (17, "Image"), (1, "Last")]
    var receiver = ComposeSemanticReceiver(id: 1, owner: owner)
    let entries = try XCTUnwrap(receiver.receive(chunk(parts)))
    let index = try ComposeSemanticIndex(owner: owner, entries: entries)
    XCTAssertEqual(index.find(kind: 0, after: nil, forward: true), 0)
    XCTAssertEqual(index.find(kind: 0, after: 0, forward: true), 2)
    XCTAssertEqual(index.find(kind: 0, after: 2, forward: false), 0)
    XCTAssertEqual(index.find(kind: 0, after: nil, forward: false), 4)
    XCTAssertNil(index.find(kind: 0, after: 4, forward: true))
    XCTAssertNil(index.find(kind: 0, after: 0, forward: false))
    XCTAssertEqual(index.find(kind: 0, after: nil, forward: true, filter: "CAFE"), 0)
    XCTAssertEqual(index.find(kind: 0, after: nil, forward: true, filter: "東京"), 0)
    XCTAssertEqual(index.find(kind: 2, after: nil, forward: true), 2)
    XCTAssertEqual(index.find(kind: 16, after: nil, forward: true), 1)
    XCTAssertEqual(index.find(kind: 17, after: nil, forward: true), 3)
  }

  func testMultipartLabelRetainsItsTailAndNoPartialInventoryIsPublished() throws {
    let first = String(repeating: "e\u{301}東京👩🏽‍💻", count: 400)
    let tail = " TAIL café"
    var receiver = ComposeSemanticReceiver(id: 1, owner: owner)
    var start = chunk([(1, first)], done: false)
    start.labelBytes += UInt64(tail.utf8.count); start.parts[0].labelLength = start.labelBytes
    start.parts[0].labelDone = false
    XCTAssertNil(try receiver.receive(start))
    var end = start; end.sequence = 1; end.done = true
    end.parts[0].labelOffset = UInt64(first.utf8.count); end.parts[0].label = tail; end.parts[0].labelDone = true
    let entries = try XCTUnwrap(receiver.receive(end))
    XCTAssertEqual(entries[0].label.utf8.count, first.utf8.count + tail.utf8.count)
    let index = try ComposeSemanticIndex(owner: owner, entries: entries)
    XCTAssertEqual(index.find(kind: 0, after: nil, forward: true, filter: "TAIL CAFE"), 0)
    XCTAssertThrowsError(try receiver.receive(end), "completion cannot be appended to or replayed")
  }

  func testSearchFoldingMatchesFoundationAtCombiningAndCaseExpansionBoundaries() throws {
    let cases = ["Café e\u{301} Straße ﬃ İ ΟΣ ς \u{0345} a\u{0345}",
      "👩🏽‍💻 🇷🇸 東京 देवनागरी 한글 가 א\u{05B0} ك\u{064E}",
      String(repeating: "e\u{301}東京👩🏽‍💻", count: 1600),
      "a" + String(repeating: "\u{301}\u{0345}", count: 16000) + " TAIL",
      "क" + String(repeating: "\u{0344}", count: 200) + " TAIL"]
    for source in cases {
      let expected = Data(source.folding(options: [.caseInsensitive, .diacriticInsensitive],
        locale: Locale(identifier: "en_US_POSIX")).utf8)
      for runBytes in [1, 3, 17, 16 << 10] {
        XCTAssertEqual(try ComposeSemanticIndex.fold(source, runBytes: runBytes), expected)
      }
    }
    XCTAssertThrowsError(try ComposeSemanticIndex.fold("ß", maximumBytes: 1))
  }

  func testMalformedOrOverbudgetChunksFailTheWholeGeneration() throws {
    let valid = chunk([(1, "Heading")])
    let edits: [(inout WireComposeIndexChunk) -> Void] = [
      { $0.owner.revision += 1 }, { $0.sequence = 1 }, { $0.totalEntries = 262_145 },
      { $0.labelBytes = 33 << 20 }, { $0.parts[0].end = self.owner.length + 1 },
      { $0.parts[0].kind = 7 }, { $0.parts[0].labelOffset = 1 }, { $0.parts[0].labelDone = false },
      { $0.parts[0].labelLength += 1 }, { $0.parts[0].index = 1 }, { $0.error = "source changed" },
      { $0.done = false }, { $0.parts = [] }, { $0.parts += $0.parts },
    ]
    for edit in edits {
      var receiver = ComposeSemanticReceiver(id: 1, owner: owner), invalid = valid
      edit(&invalid)
      XCTAssertThrowsError(try receiver.receive(invalid))
      XCTAssertThrowsError(try receiver.receive(valid), "a failed prefix cannot later look complete")
    }
    var empty = ComposeSemanticReceiver(id: 1, owner: owner)
    XCTAssertEqual(try empty.receive(chunk([]))?.count, 0)
  }

  @MainActor
  func testControllerWaitsForAccessibilityUseAndRetiresFocusSourceAndConnectionGenerations() async throws {
    var sent: [WireComposeIndexRequest] = []
    let controller = ComposeSemanticController { sent.append($0) }
    controller.update(owner: owner, supported: true)
    XCTAssertEqual(controller.status, .idle); XCTAssertTrue(sent.isEmpty)
    controller.activate(); XCTAssertEqual(sent.count, 1); XCTAssertEqual(controller.status, .loading)
    let generation = controller.generation
    controller.receive(chunk([(1, "Heading")]))
    XCTAssertEqual(sent.last?.appliedSequence, 0); XCTAssertEqual(sent.last?.hasAppliedSequence, true)
    for _ in 0..<100 where controller.index == nil { try await Task.sleep(nanoseconds: 5_000_000) }
    XCTAssertEqual(controller.status, .ready)
    XCTAssertEqual(controller.index?.entries.count, 1)
    controller.update(owner: nil, supported: true)
    XCTAssertNil(controller.index); XCTAssertNotEqual(controller.generation, generation)
    controller.update(owner: owner, supported: true)
    XCTAssertEqual(sent.last?.id, 2); XCTAssertEqual(controller.status, .loading)
    controller.receive(chunk([(1, "obsolete id")]))
    XCTAssertNil(controller.index)
    controller.reset(); XCTAssertEqual(sent.last?.cancel, true); XCTAssertNil(controller.index)
    controller.update(owner: owner, supported: true)
    XCTAssertEqual(controller.status, .idle, "a new connection waits for assistive use")
  }

  @MainActor
  func testMultiMegabyteUnicodeLabelKeepsItsFullSearchTailAcrossHundredsOfChunks() async throws {
    let controller = ComposeSemanticController { _ in }
    controller.update(owner: owner, supported: true); controller.activate()
    let piece = String(repeating: "e\u{301}東京👩🏽‍💻", count: 600), tail = " FINAL café"
    let repeats = 370, size = UInt64(piece.utf8.count * repeats + tail.utf8.count)
    XCTAssertGreaterThan(size, 5 << 20)
    for sequence in 0...repeats {
      controller.receive(.with {
        $0.id = 1; $0.owner = owner; $0.totalEntries = 1; $0.labelBytes = size
        $0.sequence = UInt64(sequence); $0.done = sequence == repeats
        $0.parts = [.with {
          $0.start = 0; $0.end = size; $0.kind = 1; $0.labelLength = size
          $0.labelOffset = UInt64(sequence * piece.utf8.count)
          $0.label = sequence == repeats ? tail : piece; $0.labelDone = sequence == repeats
        }]
      })
      if sequence < repeats { XCTAssertNil(controller.index) }
    }
    for _ in 0..<500 where controller.index == nil { try await Task.sleep(nanoseconds: 10_000_000) }
    let index = try XCTUnwrap(controller.index)
    XCTAssertEqual(index.entries[0].label.utf8.count, Int(size))
    XCTAssertEqual(index.find(kind: 0, after: nil, forward: true, filter: "FINAL CAFE"), 0)
    XCTAssertNil(index.find(kind: 16, after: nil, forward: true, filter: "FINAL CAFE"))
  }
}
