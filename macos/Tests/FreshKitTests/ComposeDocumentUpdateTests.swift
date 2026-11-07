import CryptoKit
import XCTest
@testable import FreshKit

struct DocumentUpdateFixture {
  var pane: WirePane = .with {
    $0.leaf = 2; $0.buffer = 3
    $0.compose = .with {
      $0.text = String(repeating: "é café 👩🏽‍💻\r\n", count: 6000)
      $0.sourceEnd = UInt64($0.text.utf8.count); $0.documentLen = $0.sourceEnd
      $0.bufferRevision = 5; $0.selectionRevision = 6; $0.decorationRevision = 7; $0.viewport.epoch = 9
      $0.assetAuthority = 10; $0.assetDocument = 11; $0.ready = true; $0.currentProjection = true; $0.editable = true
      $0.segments = [.init()]
      $0.cursors = [.with { $0.id = 1; $0.primary = true }]
      $0.spans = [.with { $0.start = 0; $0.end = 2; $0.role = 1 }]
    }
  }
  init() {
    // The inner segment closure's $0 is a segment rather than the pane.
    pane.compose.segments[0].sourceEnd = pane.compose.documentLen
    pane.compose.segments[0].displayEnd = pane.compose.documentLen
  }
  var owner: WireComposeIndexOwner { .with {
    $0.window = 1; $0.leaf = pane.leaf; $0.buffer = pane.buffer; $0.epoch = pane.compose.viewport.epoch
    $0.revision = pane.compose.bufferRevision; $0.authority = pane.compose.assetAuthority
    $0.document = pane.compose.assetDocument; $0.length = pane.compose.documentLen
  } }
  var bytes: Data { get throws { try pane.compose.serializedData() } }
  func chunk(id: UInt64, base: ComposeDocumentBaseline? = nil) throws -> WireComposeDocumentChunk {
    let body = try bytes
    let delta = try base.map { try Self.delta($0.data, body) }
    let payload = delta ?? body
    return .with {
      $0.id = id; $0.owner = owner; $0.selection = pane.compose.selectionRevision
      $0.decorationRevision = pane.compose.decorationRevision
      $0.length = UInt64(payload.count); $0.resultLength = UInt64(body.count)
      $0.resultDigest = Data(SHA256.hash(data: body)); $0.data = payload; $0.done = true
      if let base { $0.baseID = base.id; $0.baseDigest = base.digest; $0.encoding = 1 }
    }
  }
  // An independently generated protobuf fixture. Correctness tests need not
  // reproduce the producer's field-group optimization.
  static func delta(_ before: Data, _ after: Data) throws -> Data {
    let a = Array(before), b = Array(after)
    let prefix = zip(a,b).prefix(while: { $0.0 == $0.1 }).count
    let suffix = zip(a.dropFirst(prefix).reversed(),b.dropFirst(prefix).reversed()).prefix(while: { $0.0 == $0.1 }).count
    return try WireComposeDocumentDelta.with {
      $0.baseLength = UInt64(a.count)
      if a != b { $0.edits = [.with {
        $0.offset = UInt64(prefix); $0.remove = UInt64(a.count-prefix-suffix)
        $0.insert = Data(b[prefix..<(b.count-suffix)])
      }] }
    }.serializedData()
  }
  static func parts(_ whole: WireComposeDocumentChunk) -> [WireComposeDocumentChunk] {
    stride(from: 0, to: whole.data.count, by: 64 << 10).enumerated().map { sequence, at in
      var part = whole; let end = min(whole.data.count,at+(64 << 10))
      part.sequence = UInt64(sequence); part.data = whole.data.subdata(in: at..<end); part.done = end == whole.data.count
      return part
    }
  }
  func snapshot(id: UInt64 = 1) throws -> ComposeDocumentSnapshot {
    var receiver = ComposeDocumentUpdateReceiver(id: id, owner: owner, selection: pane.compose.selectionRevision, base: nil)
    var job: ComposeDocumentDecode?
    for part in Self.parts(try chunk(id: id)) { job = try receiver.receive(part) }
    return try XCTUnwrap(job).decode()
  }
}

final class ComposeDocumentUpdateTests: XCTestCase {
  func testFullAndDeltaBodiesAreVerifiedAndPreserveFreshStyleMetadata() async throws {
    var fixture = DocumentUpdateFixture(), old = try fixture.snapshot()
    XCTAssertEqual(old.pane.spans,fixture.pane.compose.spans)
    for mode in 0..<3 {
      fixture.pane.compose.selectionRevision += 1; fixture.pane.compose.cursors[0].position += 2
      if mode == 1 { fixture.pane.compose.text = "東京"+fixture.pane.compose.text; fixture.pane.compose.bufferRevision += 1
        fixture.pane.compose.sourceEnd += 6; fixture.pane.compose.documentLen += 6
        fixture.pane.compose.segments[0].sourceEnd += 6; fixture.pane.compose.segments[0].displayEnd += 6
        fixture.pane.compose.spans[0].start += 6; fixture.pane.compose.spans[0].end += 6
        fixture.pane.compose.cursors[0].position += 6 }
      let id = UInt64(mode+2)
      var receiver = ComposeDocumentUpdateReceiver(id: id, owner: fixture.owner, selection: fixture.pane.compose.selectionRevision, base: old.baseline)
      var job: ComposeDocumentDecode?
      for part in DocumentUpdateFixture.parts(try fixture.chunk(id: id,base: old.baseline)) { job = try receiver.receive(part) }
      let complete = try XCTUnwrap(job)
      old = try await Task.detached { try complete.decode() }.value
      XCTAssertEqual(old.document.text.utf8.count,fixture.pane.compose.text.utf8.count)
      XCTAssertEqual(old.baseline.data,try fixture.bytes); XCTAssertEqual(old.pane,fixture.pane.compose)
    }
  }

  func testCorruptionAndInconsistentBaselineHeadersCannotProduceAValue() throws {
    var fixture = DocumentUpdateFixture(); let base = try fixture.snapshot().baseline
    fixture.pane.compose.selectionRevision += 1
    let good = try fixture.chunk(id:2,base:base)
    let mutations: [(inout WireComposeDocumentChunk)->Void] = [
      {$0.encoding = 2}, {$0.baseID += 1}, {$0.baseDigest = Data(repeating:0,count:32)},
      {$0.resultLength = 0}, {$0.resultDigest = Data()}, {$0.owner.authority += 1}, {$0.selection += 1},
    ]
    for mutation in mutations {
      var bad = good; mutation(&bad)
      var receiver = ComposeDocumentUpdateReceiver(id:2,owner:fixture.owner,selection:fixture.pane.compose.selectionRevision,base:base)
      XCTAssertThrowsError(try receiver.receive(bad))
      XCTAssertThrowsError(try receiver.receive(good),"failure retires the entire receiver")
    }
    for mutation in [0,1,2] {
      var bad = good
      if mutation == 0 {bad.resultDigest = Data(repeating:0,count:32)}
      if mutation == 1 {bad.resultLength += 1}
      if mutation == 2 {bad.data = Data([16,0]);bad.length = 2}
      var receiver = ComposeDocumentUpdateReceiver(id:2,owner:fixture.owner,selection:fixture.pane.compose.selectionRevision,base:base)
      let job = try XCTUnwrap(receiver.receive(bad))
      XCTAssertThrowsError(try job.decode())
    }
    var receiver = ComposeDocumentUpdateReceiver(id:2,owner:fixture.owner,selection:fixture.pane.compose.selectionRevision,base:base)
    var full = try fixture.chunk(id:2);full.baseID = 1
    XCTAssertThrowsError(try receiver.receive(DocumentUpdateFixture.parts(full)[0]))
  }

  func testBinarySpliceAdmissionRejectsOverlapOverflowAndExcessItemsBeforePublication() throws {
    let base=Data("abcdefghij".utf8)
    func encoded(_ edits:[WireComposeDocumentSplice], length:UInt64=10) throws -> Data {
      try WireComposeDocumentDelta.with {$0.baseLength=length;$0.edits=edits}.serializedData()
    }
    let bad:[Data] = try [
      encoded([.with {$0.offset=11}]), encoded([.with {$0.offset=9;$0.remove=2}]),
      encoded([.with {$0.offset=3;$0.remove=3},.with {$0.offset=5;$0.remove=1}]),
      encoded(Array(repeating:.init(),count:65)), encoded([],length:9),
      Data([16,0x8a,0]), Data([16,10,16,10]), Data([10,4,8,1,8,2,16,10]),
    ]
    for delta in bad {XCTAssertThrowsError(try BinaryProjectionDelta.apply(delta,to:base,length:10))}
    let replacement=try encoded([.with {$0.insert=Data("ABCDEFGHIJ".utf8)},.with {$0.remove=10}])
    XCTAssertEqual(try BinaryProjectionDelta.apply(replacement,to:base,length:10),Data("ABCDEFGHIJ".utf8),
      "final output admission must not count yet-to-be-removed base bytes as retained output")
  }
}
