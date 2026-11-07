import AppKit
import CoreText
import XCTest
@testable import FreshKit
@testable import FileCommander

private actor PreviewGate {
  private var next = 0
  private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
  private var closed = false
  private(set) var peak = 0
  var started: Int { next }
  func hold() async {
    if closed { return }
    let id = next; next += 1
    await withCheckedContinuation { waiters[id] = $0; peak = max(peak, waiters.count) }
  }
  func release(_ id: Int) { waiters.removeValue(forKey: id)?.resume() }
  func releaseAll() {
    closed = true
    let remaining = Array(waiters.values); waiters.removeAll()
    for waiter in remaining { waiter.resume() }
  }
}

@MainActor
final class ComposePreviewTests: XCTestCase {
  private let body = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
  private let mono = CTFontCreateWithName("Menlo" as CFString, 18, nil)

  private func pane(_ source: String, revision: UInt64 = 4) -> WirePane {
    .with {
      $0.buffer = 3; $0.leaf = 2; $0.content.w = 80; $0.content.h = 20
      $0.compose = .with {
        $0.text = source; $0.sourceEnd = UInt64(source.utf8.count); $0.documentLen = $0.sourceEnd
        $0.bufferRevision = revision; $0.projectionRevision = revision; $0.selectionRevision = revision
        $0.assetAuthority = 11; $0.assetDocument = 22; $0.viewport.epoch = 7; $0.ready = true
        $0.focused = true; $0.keyboard = true
        $0.segments = [.with { $0.sourceEnd = UInt64(source.utf8.count); $0.displayEnd = $0.sourceEnd }]
        $0.textContext.text = source
        $0.cursors = [.with { $0.id = 1; $0.primary = true; $0.utf16Position = 0 }]
      }
    }
  }

  private func request(_ pane: WirePane, width: CGFloat = 420, composition: ComposeComposition? = nil,
                       images: [UInt64: ComposeImageState] = [:]) throws -> ComposePreviewRequest {
    try XCTUnwrap(ComposePreviewRequest(pane: pane.compose, body: body, monospace: mono, width: width,
      images: images, composition: composition))
  }

  private func eventually(_ condition: () async -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 8
    while !(await condition()), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
    let passed = await condition(); XCTAssertTrue(passed)
    if !passed { throw POSIXError(.ETIMEDOUT) }
  }

  private func controller(_ gate: PreviewGate) -> ComposePreviewController {
    ComposePreviewController { request in
      let result = try request.prepare()
      await gate.hold() // Deliberately ignores cancellation, as an in-progress platform operation may.
      return result
    }
  }

  private func show(_ pane: WirePane, in store: SceneStore) throws {
    let frame = WireFrame.with {
      $0.windowID = 99; $0.width = 80; $0.height = 20; $0.paneLen = 1; $0.panes = [.with { $0.pane = pane }]
    }
    let bytes: [UInt8] = try frame.serializedBytes()
    store.apply(try XCTUnwrap(SceneMessage(kind: SceneWire.Kind.frame.rawValue, payload: bytes[...])))
  }

  func testPreparedGeometryMatchesSynchronousFontsGlyphsAndImagesAndRefusesOtherInputs() async throws {
    let source = "Heading\n\ncafé 👩🏽‍💻 ![tiny](tiny.png) words.\n"
    var wire = pane(source)
    let image = try XCTUnwrap(source.range(of: "![tiny](tiny.png)"))
    let start = UInt64(source[..<image.lowerBound].utf8.count), end = UInt64(source[..<image.upperBound].utf8.count)
    wire.compose.spans = [.with { $0.end = 7; $0.role = 1 }, .with { $0.end = UInt64(source.utf8.count); $0.role = 9 }]
    wire.compose.images = [.with { $0.start = start; $0.end = end; $0.rendered = true; $0.target = "tiny.png"; $0.alt = "tiny" }]
    let images: [UInt64: ComposeImageState] = [start: .deferred(originalSize: CGSize(width: 80, height: 20))]
    let input = try request(wire, images: images)
    let prepared = try await Task.detached { try input.prepare() }.value
    let result = try XCTUnwrap(prepared.layout(matching: input))
    let reference = try XCTUnwrap(ComposePaneLayout(pane: wire.compose, body: body, monospace: mono, width: 420, images: images))
    XCTAssertEqual(result.text.projection.text, reference.text.projection.text)
    XCTAssertEqual(result.text.fragments.map(\.range), reference.text.fragments.map(\.range))
    XCTAssertEqual(result.text.fragments.map(\.rect), reference.text.fragments.map(\.rect))
    XCTAssertEqual(result.text.fragments.map { ComposeGlyphSignature.digest($0) }, reference.text.fragments.map { ComposeGlyphSignature.digest($0) })
    XCTAssertEqual(result.quoteRails, reference.quoteRails)
    XCTAssertEqual(result.text.attachments.map(\.rect), reference.text.attachments.map(\.rect))
    XCTAssertNil(prepared.layout(matching: try request(wire, width: 421, images: images)))
    var moved = wire; moved.compose.selectionRevision += 1; moved.compose.cursors[0].position = 1
    let movedInput = try request(moved, images: images)
    XCTAssertTrue(input.hasSameGeometry(as: movedInput)); XCTAssertFalse(input.isEquivalent(to: movedInput))
    XCTAssertNil(prepared.layout(matching: movedInput))
    let composed = try request(pane("é e\u{301}")), decomposed = try request(pane("e\u{301} é"))
    XCTAssertFalse(composed.hasSameGeometry(as: decomposed)); XCTAssertFalse(composed.isEquivalent(to: decomposed))
  }

  func testRequestDoesNotRetainMutableOrArbitraryAttributedValues() async throws {
    weak var marker: NSObject?
    let wire = pane("source café 👩🏽‍💻")
    let input: ComposePreviewRequest = try autoreleasepool {
      let object = NSObject(); marker = object
      let text = NSMutableAttributedString(string: "日本", attributes: [NSAttributedString.Key("main-only-marker"): object])
      let composition = try XCTUnwrap(ComposeComposition(pane: wire.compose, text: text,
        selected: NSRange(location: 2, length: 0), replacement: NSRange(location: NSNotFound, length: 0)))
      let input = try request(wire, composition: composition)
      text.setAttributedString(NSAttributedString(string: "changed"))
      return input
    }
    XCTAssertNil(marker, "worker capture retains plain text/context, not arbitrary AppKit attribute values")
    let prepared = try await Task.detached { try input.prepare() }.value
    XCTAssertEqual(prepared.layout(matching: input)?.text.projection.text, "日本source café 👩🏽‍💻")
  }

  func testReuseOnlyMissCannotShapeAndAHitRebindsCurrentHeaders() throws {
    let wire = pane("café source 👩🏽‍💻")
    let base = try XCTUnwrap(ComposePaneLayout(pane: wire.compose, body: body, monospace: mono, width: 420))
    var shaped = 0
    XCTAssertNil(ComposePaneLayout(pane: wire.compose, body: body, monospace: mono, width: 421, reuse: base,
      record: { _ in shaped += 1; return true }, reusingOnly: true))
    XCTAssertEqual(shaped, 0, "the input call must not fall through to shaping after a cache miss")
    var moved = wire; moved.compose.selectionRevision += 1; moved.compose.cursors[0].position = 1
    let reused = try XCTUnwrap(ComposePaneLayout(pane: moved.compose, body: body, monospace: mono, width: 420, reuse: base,
      record: { _ in shaped += 1; return true }, reusingOnly: true))
    XCTAssertTrue(reused.text === base.text); XCTAssertEqual(reused.pane.selectionRevision, moved.compose.selectionRevision)
    XCTAssertEqual(shaped, 0)
  }

  func testOneWorkerCoalescesAndResetWithReusedOwnerRejectsLateSuccess() async throws {
    let gate = PreviewGate(), previews = controller(gate), wire = pane("first")
    addTeardownBlock { await gate.releaseAll() }
    let owner = ComposePreviewController.Owner(window: 99, pane: wire), original = try request(wire)
    XCTAssertNil(previews.result(owner: owner, request: original))
    try await eventually { await gate.started == 1 }
    _ = previews.result(owner: owner, request: try request(pane("second")))
    _ = previews.result(owner: owner, request: try request(pane("third")))
    XCTAssertEqual(previews.workerCount, 1); XCTAssertEqual(previews.retainedRequestCount, 1)
    previews.reset()
    XCTAssertEqual(previews.workerCount, 1); XCTAssertEqual(previews.retainedRequestCount, 0)
    _ = previews.result(owner: owner, request: original) // Same numeric owner AND bytes after reset.
    let startsBeforeRelease = await gate.started; XCTAssertEqual(startsBeforeRelease, 1)
    await gate.release(0)
    try await eventually { await gate.started == 2 }
    XCTAssertNil(previews.result(owner: owner, request: original), "late original success cannot satisfy the new lifetime")
    await gate.release(1)
    try await eventually { previews.status(owner: owner) == .ready }
    XCTAssertNotNil(previews.result(owner: owner, request: original))
    let peak = await gate.peak; XCTAssertEqual(peak, 1); XCTAssertEqual(previews.workerCount, 0)
    previews.retain(owners: [])
    XCTAssertEqual(previews.retainedRequestCount, 0)
  }

  func testFailureDoesNotLoopAndANewRequestCanRecover() async throws {
    let previews = ComposePreviewController(), wire = pane("valid")
    let owner = ComposePreviewController.Owner(window: 99, pane: wire)
    var broken = wire; broken.compose.segments = []
    let bad = try request(broken), good = try request(wire)
    var failures = 0; previews.onFailure = { _ in failures += 1 }
    _ = previews.result(owner: owner, request: bad)
    try await eventually { previews.status(owner: owner) == .failed }
    for _ in 0..<10 { XCTAssertNil(previews.result(owner: owner, request: bad)) }
    XCTAssertEqual(failures, 1); XCTAssertEqual(previews.workerCount, 0)
    _ = previews.result(owner: owner, request: good)
    try await eventually { previews.status(owner: owner) == .ready }
    XCTAssertNotNil(previews.result(owner: owner, request: good)); XCTAssertEqual(failures, 1)
  }

  func testLogicalDraftSurvivesHeldGeometryAndSameScopeDraftChangesCannotBorrowPixels() async throws {
    _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
    let gate = PreviewGate(), previews = controller(gate), store = SceneStore(), grid = CellGridView(store: store)
    addTeardownBlock { await gate.releaseAll() }
    grid.installComposePreviewController(previews)
    store.onChange = { [weak grid] in grid?.apply($0) }
    let wire = pane("café source 👩🏽‍💻")
    try show(wire, in: store)
    try await eventually { await gate.started == 1 }
    XCTAssertNil(grid.focusedCompose); XCTAssertNotNil(grid.focusedComposeLogical)
    grid.setMarkedText("日", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    grid.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(grid.hasMarkedText()); XCTAssertEqual(grid.selectedRange(), NSRange(location: 2, length: 0))
    var actual = NSRange(location: NSNotFound, length: 0)
    XCTAssertEqual(grid.attributedSubstring(forProposedRange: NSRange(location: 0, length: 2), actualRange: &actual)?.string, "日本")
    XCTAssertEqual(previews.workerCount, 1); XCTAssertEqual(previews.retainedRequestCount, 1)
    await gate.release(0)
    try await eventually { await gate.started == 2 }
    XCTAssertNil(grid.focusedCompose)
    await gate.release(1)
    try await eventually { grid.focusedCompose?.layout.text.projection.text == "日本café source 👩🏽‍💻" }
    let shown = try XCTUnwrap(grid.focusedCompose)
    XCTAssertTrue(grid.textServiceGeometry === shown)
    grid.setMarkedText("日本語", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    try await eventually { await gate.started == 3 }
    XCTAssertTrue(grid.focusedCompose === shown); XCTAssertTrue(grid.hasMarkedText())
    XCTAssertEqual(grid.selectedRange(), NSRange(location: 3, length: 0)); XCTAssertNil(grid.textServiceGeometry)
    var resized = wire; resized.content.w = 100
    try show(resized, in: store)
    var preferences = ComposePreferences(); preferences.bodySize = 21
    grid.setComposePreferences(preferences, zoom: 1)
    var replacement = resized; replacement.compose.assetDocument += 1
    try show(replacement, in: store)
    XCTAssertFalse(grid.hasMarkedText()); XCTAssertNil(grid.focusedCompose)
    await gate.release(2)
    try await eventually { await gate.started == 4 }
    XCTAssertNil(grid.focusedCompose, "retired document result must not publish")
    await gate.release(3)
    try await eventually { grid.focusedCompose?.pane.compose.assetDocument == replacement.compose.assetDocument }
    XCTAssertEqual(grid.focusedCompose?.layout.text.projection.text, wire.compose.text)
    XCTAssertEqual(grid.focusedCompose?.layout.width, CGFloat(100) * grid.cellWidth - 32)
    XCTAssertEqual(grid.focusedCompose.map { CTFontGetSize($0.body) }, 21)
    let peak = await gate.peak; XCTAssertEqual(peak, 1)
    grid.setComposePreviewsActive(false)
    XCTAssertNil(grid.focusedCompose); XCTAssertNil(grid.focusedComposeLogical)
  }
}
