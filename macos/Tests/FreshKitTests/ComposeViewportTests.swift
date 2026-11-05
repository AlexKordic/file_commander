import XCTest
import CoreText
import CoreGraphics
import ImageIO
@testable import FreshKit

final class ComposeViewportTests: XCTestCase {
  private let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)

  private func layout(_ value: String, start: Int = 0, width: CGFloat = 320) throws -> ComposeTextLayout {
    let end = start + value.utf8.count
    let projection = try XCTUnwrap(ComposeProjection(source: start..<end, text: value, segments:
      value.isEmpty ? [] : [.init(source: start..<end, display: 0..<value.utf8.count, kind: .copy)]))
    return try XCTUnwrap(ComposeTextLayout(projection: projection, font: font, width: width))
  }

  func testPointScrollingUsesMeasuredMixedHeightLinesAndWrapAffinity() throws {
    let value = "A large heading that wraps across several lines\n" + String(repeating: "Prose café 👩🏽‍💻 with several words.\n", count: 30)
    let base = try layout(value, width: 180)
    let heading = CTFontCreateWithName("Helvetica-Bold" as CFString, 38, nil)
    let text = try XCTUnwrap(ComposeTextLayout(projection: base.projection, font: font, width: 180,
      fonts: [.init(display: 0..<47, font: heading)]))
    XCTAssertGreaterThan(text.fragments[0].rect.height, text.fragments.last!.rect.height)
    let view = ComposeViewport(text: text, documentLength: UInt64(value.utf8.count), height: 130)
    let initial = WireComposeViewport.with { $0.epoch = 7 }
    let first = try XCTUnwrap(view.moved(initial, by: 11.25))
    XCTAssertEqual(try XCTUnwrap(view.requestedTop(first)), 11.25, accuracy: 0.001)
    let second = try XCTUnwrap(view.moved(first, by: 58.5))
    XCTAssertEqual(view.displayedTop(second), 69.75, accuracy: 0.001)
    let caret = try XCTUnwrap(text.caret(for: Int(second.position), affinity: second.affinity == 1 ? .upstream : .downstream))
    XCTAssertEqual(caret.minY - view.displayedTop(second), second.offset, accuracy: 0.001)
    XCTAssertEqual(second.epoch, 7)
  }

  func testSourceAnchorSurvivesReflowFontChangesAndLateImageDimensions() throws {
    let source = "Heading\n\n![picture](x.png)\n\n" + (0..<100).map { "Paragraph \($0) with prose that wraps at narrow widths.\n\n" }.joined()
    var pane = WireComposePane.with {
      $0.text = source; $0.sourceEnd = UInt64(source.utf8.count); $0.documentLen = $0.sourceEnd
      $0.segments = [.with { $0.sourceEnd = UInt64(source.utf8.count); $0.displayEnd = $0.sourceEnd }]
      $0.spans = [.with { $0.end = 7; $0.role = 1 }]
    }
    let start = source[..<source.range(of: "![picture]")!.lowerBound].utf8.count
    let end = start + "![picture](x.png)".utf8.count
    pane.images = [.with { $0.start = UInt64(start); $0.end = UInt64(end); $0.target = "x.png"; $0.block = true; $0.rendered = true }]
    let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 300, bitsPerComponent: 8, bytesPerRow: 400,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let bytes = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let asset = try ComposeImageAsset.decode(bytes as Data)
    let position = source[..<source.range(of: "Paragraph 25")!.lowerBound].utf8.count
    let anchor = WireComposeViewport.with { $0.position = UInt64(position); $0.offset = -5.25; $0.epoch = 7 }
    var measured: [CGFloat] = []
    for width: CGFloat in [420, 180] {
      for size: CGFloat in [16, 24] {
        for ready in [false, true] {
          let body = CTFontCreateWithName("Helvetica" as CFString, size, nil)
          let text = try XCTUnwrap(ComposePaneLayout(pane: pane, body: body, monospace: font, width: width,
            images: [UInt64(start): ready ? .ready(asset) : .loading])).text
          let view = ComposeViewport(text: text, documentLength: pane.documentLen, height: 240)
          let caret = try XCTUnwrap(text.caret(for: position))
          XCTAssertEqual(caret.minY - view.displayedTop(anchor), -5.25, accuracy: 0.001)
          measured.append(caret.minY)
        }
      }
    }
    XCTAssertGreaterThan(Set(measured).count, 4, "the test actually exercises different layouts, not a reused fixed-height grid")
  }

  func testPartialSourceWindowsContinueAtMeasuredEdgesWithoutMovingTheAnchor() throws {
    let text = try layout(String(repeating: "row\n", count: 100), start: 1000)
    let view = ComposeViewport(text: text, documentLength: 10_000, height: 180)
    let anchor = WireComposeViewport.with { $0.position = 1388; $0.offset = -5; $0.epoch = 7 }
    let pending = try XCTUnwrap(view.continuation(anchor))
    XCTAssertEqual(pending.position, 1400)
    XCTAssertEqual(try XCTUnwrap(view.requestedTop(pending)), try XCTUnwrap(view.requestedTop(anchor)), accuracy: 0.001)
    XCTAssertLessThanOrEqual(view.displayedTop(pending) + view.height, text.size.height + 0.001, "draw available text while requesting the adjacent window")
    let expanded = try layout(String(repeating: "row\n", count: 100), start: 1200)
    let next = ComposeViewport(text: expanded, documentLength: 10_000, height: 180)
    let caret = try XCTUnwrap(expanded.caret(for: 1388))
    XCTAssertEqual(caret.minY - next.displayedTop(pending), -5, accuracy: 0.001)
    XCTAssertNil(next.continuation(pending))
    let upward = try XCTUnwrap(next.moved(pending, by: -3000))
    XCTAssertEqual(upward.position, 1200)
    XCTAssertGreaterThan(upward.offset, 0, "negative top is retained as an edge intent, not rounded to a terminal row")
    XCTAssertEqual(next.displayedTop(upward), 0)
  }

  func testDocumentBoundsAndCaretRevealUseTheVisiblePixelHeight() throws {
    let text = try layout(String(repeating: "row\n", count: 100))
    let view = ComposeViewport(text: text, documentLength: 400, height: 180)
    let anchor = WireComposeViewport.with { $0.epoch = 7 }
    let top = try XCTUnwrap(view.moved(anchor, by: -10_000))
    XCTAssertEqual(view.displayedTop(top), 0)
    let bottom = try XCTUnwrap(view.moved(anchor, by: 10_000))
    XCTAssertEqual(view.displayedTop(bottom), text.size.height - 180, accuracy: 0.001)
    XCTAssertNil(view.continuation(bottom))
    XCTAssertNil(view.revealing(0, affinity: 0, from: anchor))
    let reveal = try XCTUnwrap(view.revealing(200, affinity: 0, from: anchor))
    let caret = try XCTUnwrap(text.caret(for: 200))
    XCTAssertEqual(caret.maxY - view.displayedTop(reveal), 180, accuracy: 0.001)
    XCTAssertNil(view.revealing(200, affinity: 0, from: reveal))
    let partial = ComposeViewport(text: try layout("row\n", start: 100), documentLength: 1000, height: 180)
    XCTAssertEqual(partial.revealing(800, affinity: 0, from: anchor)?.position, 800, "unmeasured carets request source instead of guessing pixel rows")
    XCTAssertNil(partial.revealing(1001, affinity: 0, from: anchor))
  }

  private func scope(_ leaf: UInt64 = 2, buffer: UInt64 = 3) -> WireComposeScope {
    .with { $0.windowID = 1; $0.leaf = leaf; $0.buffer = buffer; $0.bufferRevision = 4 }
  }
  private func pane(_ scope: WireComposeScope, anchor: WireComposeViewport) -> WirePane {
    .with {
      $0.leaf = scope.leaf; $0.buffer = scope.buffer
      $0.compose = .with { $0.bufferRevision = scope.bufferRevision; $0.viewport = anchor }
    }
  }

  @MainActor
  func testWheelBurstsCoalesceAndDelayedRepliesCannotRestoreAnOlderPosition() async throws {
    var sent: [WireComposeViewportRequest] = []
    let controller = ComposeViewportController { sent.append($0) }
    let a = scope(), b = scope(5, buffer: 6)
    let initial = WireComposeViewport.with { $0.epoch = 7 }
    func move(_ scope: WireComposeScope, _ position: UInt64) {
      let current = controller.value(scope: scope, remote: initial)
      var desired = current; desired.position = position
      controller.move(scope: scope, from: current, to: desired, user: true)
    }
    move(a, 10); move(a, 20); move(b, 30); move(a, 40)
    XCTAssertEqual(sent.map(\.id), [1])
    XCTAssertEqual(controller.value(scope: a, remote: initial).position, 40)
    XCTAssertEqual(controller.userScrollGeneration, 4)
    var remote = initial; remote.sequence = 1; remote.position = 10
    controller.observe(window: 1, panes: [pane(a, anchor: remote), pane(b, anchor: initial)], reply: .with { $0.id = 1; $0.accepted = true })
    XCTAssertEqual(sent.map(\.id), [1, 3], "interleaved panes retain their own latest intent")
    XCTAssertEqual(controller.value(scope: a, remote: remote).position, 40)
    controller.observe(window: 1, panes: [pane(a, anchor: remote), pane(b, anchor: initial)], reply: .with { $0.id = 1; $0.accepted = true })
    XCTAssertEqual(sent.count, 2, "an old acknowledgment cannot finish a newer request")
    controller.observe(window: 1, panes: [pane(a, anchor: remote), pane(b, anchor: initial)], reply: .with { $0.id = 3; $0.accepted = true })
    XCTAssertEqual(sent.map(\.id), [1, 3, 4])
    let payload = SceneInput.composeViewport(sent.last!).payload()
    XCTAssertEqual(SceneInput.composeViewport(sent.last!).kind.rawValue, 29)
    XCTAssertEqual(try WireComposeViewportRequest(serializedBytes: payload), sent.last)
    remote.sequence = 4; remote.position = 40
    controller.observe(window: 1, panes: [pane(a, anchor: remote), pane(b, anchor: initial)], reply: .with { $0.id = 4; $0.accepted = true })
    XCTAssertEqual(controller.value(scope: a, remote: remote), remote)
  }

  @MainActor
  func testConcurrentEditRetainsTheQueuedSourceIntentForBackendRebasingAndResetDropsIt() async throws {
    var sent: [WireComposeViewportRequest] = []
    let controller = ComposeViewportController { sent.append($0) }
    let original = scope(), initial = WireComposeViewport.with { $0.epoch = 7 }
    var first = initial; first.position = 10
    controller.move(scope: original, from: initial, to: first, user: true)
    var last = first; last.position = 40
    controller.move(scope: original, from: first, to: last, user: true)
    var edited = original; edited.bufferRevision = 5
    var remote = initial; remote.sequence = 1; remote.position = 12
    controller.observe(window: 1, panes: [pane(edited, anchor: remote)], reply: .with { $0.id = 1; $0.accepted = true })
    XCTAssertEqual(sent.map(\.position), [10, 40], "the server can rebase a pending scroll through source edits")
    XCTAssertEqual(sent[1].scope.bufferRevision, 4)
    XCTAssertEqual(controller.value(scope: edited, remote: remote), remote, "never draw stale source coordinates against edited text")
    var replacement = remote; replacement.epoch = 8; replacement.position = 0
    controller.observe(window: 1, panes: [pane(edited, anchor: replacement)], reply: .with { $0.id = 2 })
    XCTAssertEqual(controller.value(scope: edited, remote: replacement), replacement)
    controller.reset()
    XCTAssertEqual(controller.userScrollGeneration, 0)
    XCTAssertEqual(sent.count, 2)
  }
}
