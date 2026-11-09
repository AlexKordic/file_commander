import XCTest
import CryptoKit
import FreshKit

final class ComposeAssetTests: XCTestCase {
  func testOpaqueResourceIdentityRetainsAllUnsignedBits() {
    var input = request()
    input.authority = UInt64.max; input.document = UInt64.max - 1
    var receiver = ComposeAssetReceiver(); XCTAssertTrue(receiver.register(input))
    let bytes = Data([0x89, 0x50, 0x4e, 0x47])
    let chunk = WireComposeAssetChunk.with {
      $0.id = input.id; $0.total = UInt64(bytes.count); $0.data = bytes; $0.done = true
      $0.digest = Data(SHA256.hash(data: bytes))
    }
    guard case .loaded(let original, let loaded, _, _) = receiver.receive(chunk) else {
      return XCTFail("opaque resource identities are not signed native counters")
    }
    XCTAssertEqual(original, input); XCTAssertEqual(loaded, bytes)
  }

  func testEmptyNonfinalChunksFailAndReleaseTheRequestSlot() {
    for partial in [false, true] {
      var receiver = ComposeAssetReceiver()
      let input = request()
      XCTAssertTrue(receiver.register(input))
      if partial {
        XCTAssertNil(receiver.receive(.with { $0.id = input.id; $0.total = 2; $0.data = Data([1]) }))
      }
      let empty = WireComposeAssetChunk.with {
        $0.id = input.id; $0.total = 2; $0.offset = partial ? 1 : 0
      }
      guard case .failed(let original, _, let retryable) = receiver.receive(empty) else {
        XCTFail("an image stream must make progress before its final chunk")
        continue
      }
      XCTAssertEqual(original, input); XCTAssertFalse(retryable)
      XCTAssertTrue(receiver.activeRequests.isEmpty)
      XCTAssertNil(receiver.receive(.with { $0.id = input.id; $0.error = "late"; $0.done = true }))
      XCTAssertTrue(receiver.register(request(2)))
    }
  }

  private func request(_ id: UInt64 = 1) -> WireComposeAssetRequest {
    .with {
      $0.id = id
      $0.scope = .with { $0.windowID = 1; $0.leaf = 2; $0.buffer = 3; $0.bufferRevision = 4 }
      $0.start = 10
      $0.end = 30
      $0.authority = 5
    }
  }

  func testBinaryChunksReconstructWithoutTextEncodingAndRetainSourceIdentity() throws {
    let input = request()
    let message = SceneInput.composeAsset(input)
    XCTAssertEqual(message.kind.rawValue, 28)
    XCTAssertEqual(try WireComposeAssetRequest(serializedBytes: message.payload()), input)
    var receiver = ComposeAssetReceiver()
    XCTAssertTrue(receiver.register(input))
    let bytes = Data((0..<(ComposeAssetReceiver.maximumChunkBytes + 17)).map { UInt8(truncatingIfNeeded: $0) })
    let a = WireComposeAssetChunk.with { $0.id = 1; $0.total = UInt64(bytes.count); $0.data = bytes.prefix(ComposeAssetReceiver.maximumChunkBytes) }
    let b = WireComposeAssetChunk.with {
      $0.id = 1; $0.total = UInt64(bytes.count); $0.offset = UInt64(a.data.count)
      $0.data = bytes.suffix(17); $0.done = true
      $0.version = Data(repeating: 7, count: 32); $0.digest = Data(repeating: 9, count: 32)
    }
    XCTAssertNil(receiver.receive(a))
    guard case .loaded(let original, let received, let version, let digest) = receiver.receive(b) else { return XCTFail("image did not complete") }
    XCTAssertEqual(original, input)
    XCTAssertEqual(received, bytes)
    XCTAssertEqual(version, b.version); XCTAssertEqual(digest, b.digest)
    XCTAssertTrue(receiver.activeRequests.isEmpty)
  }

  func testBadOffsetsSizesAndIncompleteStreamsReleaseTheirMemorySlot() {
    let cases: [WireComposeAssetChunk] = [
      .with { $0.id = 1; $0.total = 1; $0.offset = 1; $0.data = Data([0]); $0.done = true; $0.digest = Data(repeating: 1, count: 32) },
      .with { $0.id = 1; $0.total = UInt64(ComposeAssetReceiver.maximumBytes + 1) },
      .with { $0.id = 1; $0.total = 2; $0.data = Data([0]); $0.done = true; $0.digest = Data(repeating: 1, count: 32) },
      .with { $0.id = 1; $0.total = 1; $0.data = Data([0]) },
    ]
    for chunk in cases {
      var receiver = ComposeAssetReceiver()
      XCTAssertTrue(receiver.register(request()))
      guard case .failed = receiver.receive(chunk) else { return XCTFail("invalid response was accepted") }
      XCTAssertTrue(receiver.activeRequests.isEmpty)
    }
  }

  func testCancellationErrorsAndLimitsDoNotStrandAnImageRequest() {
    var receiver = ComposeAssetReceiver()
    for id in 1...4 { XCTAssertTrue(receiver.register(request(UInt64(id)))) }
    XCTAssertFalse(receiver.register(request(5)))
    XCTAssertEqual(receiver.retain { $0.id != 1 }, [1])
    XCTAssertFalse(receiver.register(request(1)), "a cancelled id cannot receive another resource's late response")
    XCTAssertNil(receiver.receive(.with { $0.id = 1; $0.done = true }))
    XCTAssertTrue(receiver.register(request(5)))
    XCTAssertNil(receiver.receive(.with { $0.id = 2; $0.total = 2; $0.data = Data([128]) }))
    guard case .failed(let original, let message, let retryable) = receiver.receive(.with { $0.id = 2; $0.error = "Authority changed"; $0.done = true }) else {
      return XCTFail("error after a partial response did not finish the request")
    }
    XCTAssertEqual(original.id, 2)
    XCTAssertEqual(message, "Authority changed")
    XCTAssertFalse(retryable)
    receiver.cancel(3)
    receiver.reset()
    XCTAssertTrue(receiver.activeRequests.isEmpty)
    XCTAssertTrue(receiver.register(request(1)), "a new connection has its own request namespace")
  }

  func testConditionalRepliesRequireTheCachedDigestAndContainNoImagePayload() {
    var input = request()
    input.knownVersion = Data(repeating: 1, count: 32)
    input.knownDigest = Data(repeating: 2, count: 32)
    let valid = WireComposeAssetChunk.with {
      $0.id = input.id; $0.done = true; $0.unchanged = true
      $0.version = Data(repeating: 3, count: 32); $0.digest = input.knownDigest
    }
    var receiver = ComposeAssetReceiver()
    XCTAssertTrue(receiver.register(input))
    guard case .unchanged(let original, let version, let digest) = receiver.receive(valid) else { return XCTFail("missing conditional reply") }
    XCTAssertEqual(original, input); XCTAssertEqual(version, valid.version); XCTAssertEqual(digest, input.knownDigest)
    for change: (inout WireComposeAssetChunk) -> Void in [
      { $0.digest = Data(repeating: 4, count: 32) },
      { $0.data = Data([0]) }, { $0.done = false }, { $0.version = Data([0]) },
    ] {
      receiver.reset(); XCTAssertTrue(receiver.register(input))
      var invalid = valid; change(&invalid)
      guard case .failed = receiver.receive(invalid) else { return XCTFail("invalid conditional reply accepted") }
      XCTAssertTrue(receiver.activeRequests.isEmpty)
    }
  }
}
