import XCTest
import CoreGraphics
import ImageIO
@testable import FreshKit

final class ComposeImageControllerTests: XCTestCase {
  private func asset() throws -> ComposeImageAsset {
    let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return try ComposeImageAsset.decode(data as Data)
  }

  private func demand(target: String = "x.png", authority: UInt64 = 5, revision: UInt64 = 4) -> ComposeImageController.Demand {
    .init(scope: .with { $0.windowID = 1; $0.leaf = 2; $0.buffer = 3; $0.bufferRevision = revision },
      image: .with { $0.start = 10; $0.end = 30; $0.target = target; $0.rendered = true },
      authority: authority, document: 7, maximumDimension: 256)
  }

  private func complete(_ request: WireComposeAssetRequest) -> WireComposeAssetChunk {
    .with { $0.id = request.id; $0.total = 1; $0.data = Data([255]); $0.done = true }
  }

  @MainActor
  func testDecodesOffMainThreadDeduplicatesReferencesAndKeepsSourceAuthoritySeparate() async throws {
    let decoded = try asset(), changed = expectation(description: "decoded image")
    var sent: [WireComposeAssetRequest] = []
    let controller = ComposeImageController(decode: { _, _ in
      XCTAssertFalse(Thread.isMainThread)
      return decoded
    }, send: { sent.append($0) })
    controller.onChange = { changed.fulfill() }
    let original = demand()
    var duplicate = original; duplicate.image.start = 40; duplicate.image.end = 60
    controller.update([original, duplicate])
    XCTAssertEqual(sent.count, 1, "same resource in two places shares its read")
    controller.receive([complete(sent[0])])
    await fulfillment(of: [changed], timeout: 3)
    guard case .ready(let result) = controller.state(scope: original.scope, image: original.image, authority: 5, document: 7) else {
      return XCTFail("image did not enter the decoded cache")
    }
    XCTAssertTrue(result === decoded)
    controller.update([demand(revision: 6)])
    XCTAssertEqual(sent.count, 1, "typing reuses an unchanged resource")
    controller.update([demand(authority: 8, revision: 6)])
    XCTAssertEqual(sent.count, 2, "another authority cannot use the old resource")
    XCTAssertEqual(sent[1].authority, 8)
    controller.receive([complete(sent[0])]) // late duplicate from the old authority
    if case .ready = controller.state(scope: original.scope, image: original.image, authority: 8, document: 7) {
      XCTFail("late data crossed authorities")
    }
    var savedAs = demand(authority: 8, revision: 6); savedAs.document = 9
    controller.update([savedAs])
    XCTAssertEqual(sent.filter { !$0.cancel }.count, 3, "Save As changes relative-image resolution")
    XCTAssertEqual(sent.last?.document, 9)
    controller.reset()
  }

  @MainActor
  func testCancelledDecodesRetainTheirSlotsAcrossRepeatedSourceChanges() async throws {
    let decoded = try asset(), release = DispatchSemaphore(value: 0)
    defer { for _ in 0..<8 { release.signal() } }
    let resumed = expectation(description: "new resource starts after an old decode frees its slot")
    var sent: [WireComposeAssetRequest] = []
    let controller = ComposeImageController(decode: { _, _ in release.wait(); return decoded }, send: {
      sent.append($0)
      if $0.id == 5 && !$0.cancel { resumed.fulfill() }
    })
    controller.update((0..<5).map { demand(target: "\($0).png") })
    XCTAssertEqual(sent.count, 4)
    controller.receive(sent.map(complete))
    XCTAssertEqual(controller.outstandingCount, 4)
    for authority in 10..<110 { controller.update([demand(authority: UInt64(authority))]) }
    XCTAssertEqual(sent.count, 4, "cancelled Image I/O jobs cannot accumulate more compressed payloads")
    XCTAssertEqual(controller.outstandingCount, 4)
    for _ in 0..<4 { release.signal() }
    await fulfillment(of: [resumed], timeout: 3)
    XCTAssertLessThanOrEqual(controller.outstandingCount, 4)
    controller.reset()
  }

  @MainActor
  func testCacheEvictionIsBoundedAndDoesNotContinuouslyReloadVisibleImages() async throws {
    let decoded = try asset(), changed = expectation(description: "bounded cache result")
    var sent: [WireComposeAssetRequest] = []
    let controller = ComposeImageController(maximumCacheBytes: 0, decode: { _, _ in decoded }, send: { sent.append($0) })
    controller.onChange = { changed.fulfill() }
    let original = demand()
    controller.update([original]); controller.receive([complete(sent[0])])
    await fulfillment(of: [changed], timeout: 3)
    XCTAssertEqual(controller.decodedBytes, 0)
    controller.update([original])
    XCTAssertEqual(sent.count, 1, "eviction cannot create a read/decode/reflow loop")
    if case .failed = controller.state(scope: original.scope, image: original.image, authority: 5, document: 7) {} else {
      XCTFail("a bounded-cache fallback is missing")
    }
    controller.reset()
  }
}
