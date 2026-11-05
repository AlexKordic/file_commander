import XCTest
import FreshKit

final class ComposeAssetTests: XCTestCase {
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
    }
    XCTAssertNil(receiver.receive(a))
    guard case .loaded(let original, let received) = receiver.receive(b) else { return XCTFail("image did not complete") }
    XCTAssertEqual(original, input)
    XCTAssertEqual(received, bytes)
    XCTAssertTrue(receiver.activeRequests.isEmpty)
  }

  func testBadOffsetsSizesAndIncompleteStreamsReleaseTheirMemorySlot() {
    let cases: [WireComposeAssetChunk] = [
      .with { $0.id = 1; $0.total = 1; $0.offset = 1; $0.data = Data([0]); $0.done = true },
      .with { $0.id = 1; $0.total = UInt64(ComposeAssetReceiver.maximumBytes + 1) },
      .with { $0.id = 1; $0.total = 2; $0.data = Data([0]); $0.done = true },
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
    guard case .failed(let original, let message) = receiver.receive(.with { $0.id = 2; $0.error = "Authority changed"; $0.done = true }) else {
      return XCTFail("error after a partial response did not finish the request")
    }
    XCTAssertEqual(original.id, 2)
    XCTAssertEqual(message, "Authority changed")
    receiver.cancel(3)
    receiver.reset()
    XCTAssertTrue(receiver.activeRequests.isEmpty)
    XCTAssertTrue(receiver.register(request(1)), "a new connection has its own request namespace")
  }
}
