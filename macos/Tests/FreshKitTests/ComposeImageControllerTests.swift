import XCTest
import CoreGraphics
import ImageIO
@testable import FreshKit

final class ComposeImageControllerTests: XCTestCase {
  private func asset(_ width: Int = 16) throws -> ComposeImageAsset {
    let context = try XCTUnwrap(CGContext(data: nil, width: width, height: 16, bitsPerComponent: 8, bytesPerRow: width * 4,
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

  private func complete(_ request: WireComposeAssetRequest, value: UInt8 = 1) -> WireComposeAssetChunk {
    .with { $0.id = request.id; $0.total = 1; $0.data = Data([value]); $0.done = true
      $0.version = Data(repeating: value, count: 32); $0.digest = Data(repeating: value, count: 32) }
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
    controller.receive(sent.map { complete($0) })
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

  @MainActor
  private func eventually(_ condition: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertTrue(condition())
    if !condition() { throw POSIXError(.ETIMEDOUT) }
  }

  @MainActor
  func testAutomaticValidationKeepsThePreviewAndSkipsDecodeForUnchangedResources() async throws {
    let image = try asset(), automatic = expectation(description: "timer checks the visible image")
    let decoded = expectation(description: "decoded only once")
    var sent: [WireComposeAssetRequest] = [], time = 0.0
    let controller = ComposeImageController(now: { time }, decode: { _, _ in decoded.fulfill(); return image }, send: {
      sent.append($0); if $0.id == 2 && !$0.cancel { automatic.fulfill() }
    })
    defer { controller.reset() }
    let wanted = demand()
    controller.update([wanted]); controller.receive([complete(sent[0])])
    await fulfillment(of: [decoded], timeout: 3)
    try await eventually { controller.state(scope: wanted.scope, image: wanted.image, authority: 5, document: 7).asset != nil }
    time = 6 // No new scene/update call: the production timer must perform the check.
    await fulfillment(of: [automatic], timeout: 3)
    XCTAssertEqual(sent.count, 2)
    XCTAssertEqual(sent[1].knownVersion, Data(repeating: 1, count: 32))
    XCTAssertEqual(sent[1].knownDigest, Data(repeating: 1, count: 32))
    XCTAssertTrue(controller.state(scope: wanted.scope, image: wanted.image, authority: 5, document: 7).asset === image)
    controller.receive([.with { $0.id = sent[1].id; $0.done = true; $0.unchanged = true
      $0.version = Data(repeating: 2, count: 32); $0.digest = sent[1].knownDigest }])
    XCTAssertEqual(controller.outstandingCount, 0)
    XCTAssertTrue(controller.state(scope: wanted.scope, image: wanted.image, authority: 5, document: 7).asset === image)
    controller.update([]); time = 12
    controller.update([wanted])
    XCTAssertEqual(sent.last?.knownVersion, Data(repeating: 2, count: 32), "returning to an image validates its last resource version")
    controller.receive([.with { $0.id = sent.last!.id; $0.done = true; $0.unchanged = true
      $0.version = Data(repeating: 2, count: 32); $0.digest = sent.last!.knownDigest }])
    time = 70; controller.update([wanted])
    XCTAssertTrue(sent.last!.knownVersion.isEmpty, "periodic hashing also covers coarse/cached filesystem stamps")
    XCTAssertEqual(sent.last?.knownDigest, Data(repeating: 1, count: 32))
    controller.receive([.with { $0.id = sent.last!.id; $0.done = true; $0.unchanged = true
      $0.version = Data(repeating: 2, count: 32); $0.digest = sent.last!.knownDigest }])
  }

  @MainActor
  func testChangedImagesReplaceThePreviewAfterDecodeAndTransientFailuresRetainIt() async throws {
    let old = try asset(), replacement = try asset(32)
    var sent: [WireComposeAssetRequest] = [], time = 0.0
    let controller = ComposeImageController(now: { time }, decode: { bytes, _ in bytes.first == 1 ? old : replacement }, send: { sent.append($0) })
    defer { controller.reset() }
    let wanted = demand()
    func state() -> ComposeImageState { controller.state(scope: wanted.scope, image: wanted.image, authority: 5, document: 7) }
    controller.update([wanted]); controller.receive([complete(sent[0])])
    try await eventually { state().asset === old }
    time = 6; controller.update([wanted])
    XCTAssertTrue(state().asset === old, "refreshing never clears a valid preview")
    controller.receive([.with { $0.id = sent.last!.id; $0.error = "Connection interrupted"; $0.retryable = true; $0.done = true }])
    guard case .stale(let retained, let warning) = state() else { return XCTFail("transient failure discarded the last image") }
    XCTAssertTrue(retained === old); XCTAssertEqual(warning, "Connection interrupted")
    time = 12; controller.update([wanted])
    XCTAssertEqual(sent.last?.knownDigest, Data(repeating: 1, count: 32))
    controller.receive([.with { $0.id = sent.last!.id; $0.done = true; $0.unchanged = true
      $0.version = sent.last!.knownVersion; $0.digest = sent.last!.knownDigest }])
    guard case .ready = state() else { return XCTFail("successful validation did not clear the stale warning") }
    time = 18; controller.update([wanted])
    controller.receive([complete(sent.last!, value: 2)])
    try await eventually { state().asset === replacement }
    XCTAssertEqual(state().asset?.originalSize.width, 32)
    time = 24; controller.update([wanted])
    controller.receive([.with { $0.id = sent.last!.id; $0.error = "Image unavailable"; $0.done = true }])
    guard case .failed = state() else { return XCTFail("confirmed missing resource did not show its fallback") }
    time = 30; controller.update([wanted])
    XCTAssertTrue(sent.last!.knownDigest.isEmpty)
    controller.receive([complete(sent.last!, value: 1)])
    try await eventually { state().asset === old }
  }

  @MainActor
  func testInvalidDecodedContentIsRevalidatedWithoutRepeatedTransfersOrDecodes() async throws {
    let decoded = expectation(description: "invalid content decoded only once")
    var sent: [WireComposeAssetRequest] = [], time = 0.0
    let controller = ComposeImageController(now: { time }, decode: { _, _ in decoded.fulfill(); throw ComposeImageAsset.Failure.invalid },
      send: { sent.append($0) })
    defer { controller.reset() }
    let wanted = demand()
    controller.update([wanted]); controller.receive([complete(sent[0])])
    await fulfillment(of: [decoded], timeout: 3)
    try await eventually { controller.outstandingCount == 0 }
    time = 6; controller.update([wanted])
    XCTAssertEqual(sent.last?.knownDigest, Data(repeating: 1, count: 32))
    controller.receive([.with { $0.id = sent.last!.id; $0.done = true; $0.unchanged = true
      $0.version = sent.last!.knownVersion; $0.digest = sent.last!.knownDigest }])
    guard case .failed = controller.state(scope: wanted.scope, image: wanted.image, authority: 5, document: 7) else { return XCTFail("invalid image lost its explained fallback") }
    XCTAssertEqual(controller.outstandingCount, 0)
  }

  @MainActor
  func testReorderingVisibleDuplicateReferencesDoesNotCancelTheirSharedLoad() {
    var sent: [WireComposeAssetRequest] = [], time = 0.0
    let controller = ComposeImageController(now: { time }, send: { sent.append($0) })
    defer { controller.reset() }
    let first = demand()
    var second = first; second.scope.leaf = 9; second.image.start = 40; second.image.end = 60
    controller.update([first, second])
    for _ in 0..<20 { controller.update([second, first]); controller.update([first, second]) }
    XCTAssertEqual(sent.count, 1, "viewport tie ordering cannot starve an asset with repeated cancellation")
    controller.update([second])
    XCTAssertEqual(sent.filter(\.cancel).map(\.id), [1])
    time = 6; controller.update([second])
    XCTAssertEqual(sent.filter { !$0.cancel }.count, 2)
    XCTAssertEqual(sent.last?.scope.leaf, 9, "a closed reference is replaced with a still-visible source scope")
  }

  @MainActor
  func testTypingAndPendingFormattingCannotRestartAnImageRequestOnEveryCharacter() async throws {
    let image = try asset()
    var sent: [WireComposeAssetRequest] = [], time = 0.0
    let controller = ComposeImageController(now: { time }, decode: { _, _ in image }, send: { sent.append($0) })
    defer { controller.reset() }
    controller.update([demand()])
    for revision in 5..<30 {
      controller.update([]) // the current scene is waiting for formatting
      controller.update([demand(revision: UInt64(revision))])
    }
    XCTAssertEqual(sent.filter { !$0.cancel }.count, 1)
    time = 6; controller.update([demand(revision: 30)])
    XCTAssertEqual(sent.filter { !$0.cancel }.count, 2)
    controller.receive([complete(sent.last!)])
    try await eventually { controller.state(scope: self.demand().scope, image: self.demand().image, authority: 5, document: 7).asset != nil }
    time = 12; controller.update([demand(revision: 30)])
    XCTAssertEqual(sent.filter { !$0.cancel }.count, 3)
    for revision in 31..<100 {
      controller.update([])
      controller.update([demand(revision: UInt64(revision))])
    }
    XCTAssertEqual(sent.filter { !$0.cancel }.count, 3, "cancelled refreshes keep their backoff through source edits")
    XCTAssertTrue(controller.state(scope: demand().scope, image: demand().image, authority: 5, document: 7).asset === image)
    time = 18; controller.update([demand(revision: 100)])
    XCTAssertEqual(sent.last?.knownDigest, Data(repeating: 1, count: 32))
  }
}
