import XCTest
import CoreText
@testable import FreshKit

final class ComposePointerTests: XCTestCase {
  private func copied(_ value: String) throws -> ComposeProjection {
    try XCTUnwrap(ComposeProjection(source: 0..<value.utf8.count, text: value, segments: [
      .init(source: 0..<value.utf8.count, display: 0..<value.utf8.count, kind: .copy)
    ]))
  }

  func testCapturedClickKeepsItsSourceIntentAfterReflowAndScrolling() throws {
    let source = String(repeating: "Proportional words café 👩🏽‍💻 that wrap across the page.\n", count: 30)
    let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
    let original = try XCTUnwrap(ComposeTextLayout(projection: try copied(source), font: font, width: 440))
    let point = CGPoint(x: 220, y: original.fragments[2].rect.midY)
    let hit = try XCTUnwrap(original.hit(at: point))
    let scope = WireComposeScope.with {
      $0.windowID = 1; $0.leaf = 2; $0.buffer = 3
      $0.bufferRevision = 4; $0.projectionRevision = 5; $0.selectionRevision = 6
    }
    let pointer = try XCTUnwrap(ComposePointer(scope: scope, epoch: 7, hit: hit, extend: false, count: 1))
    let reflowed = try XCTUnwrap(ComposeTextLayout(projection: try copied(source), font: font, width: 100))
    XCTAssertNotEqual(reflowed.hit(at: point)?.source, hit.source, "the regression requires a screen point whose source target changed")
    XCTAssertNotEqual(original.hit(at: CGPoint(x: point.x, y: point.y + 120))?.source, hit.source)
    let request = pointer.input(id: 9)
    XCTAssertEqual(request.position, UInt64(hit.source))
    XCTAssertEqual(request.scope, scope)
    XCTAssertTrue(request.hasSourceRevision)
    XCTAssertEqual(request.sourceRevision, 4)
    XCTAssertEqual(request.bufferEpoch, 7)
    XCTAssertEqual(request.id, 9)
    XCTAssertEqual(pointer.input(id: 10).position, request.position)
    XCTAssertEqual(pointer.input(id: 10).sourceRevision, 4, "retrying cannot relabel an old coordinate as belonging to newer source")
    let bytes = SceneInput.composeInput(request).payload()
    XCTAssertEqual(try WireComposeInput(serializedBytes: bytes), request)
    XCTAssertNil(ComposePointer(scope: scope, epoch: 0, hit: hit, extend: false, count: 1), "a buffer lifetime is required")
  }

  func testImageClickCapturesTheWholeSourceObjectAndSelectionExtensionStaysTextual() throws {
    let source = "Before ![image](x.png) after."
    var pane = WireComposePane.with {
      $0.text = source; $0.sourceEnd = UInt64(source.utf8.count); $0.documentLen = $0.sourceEnd
      $0.segments = [.with { $0.sourceEnd = UInt64(source.utf8.count); $0.displayEnd = $0.sourceEnd }]
    }
    let start = UInt64("Before ".utf8.count), end = start + UInt64("![image](x.png)".utf8.count)
    pane.images = [.with { $0.start = start; $0.end = end; $0.target = "x.png"; $0.rendered = true }]
    let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
    let layout = try XCTUnwrap(ComposePaneLayout(pane: pane, body: font, monospace: font, width: 440))
    let image = try XCTUnwrap(layout.text.attachments.first)
    let hit = try XCTUnwrap(layout.text.hit(at: CGPoint(x: image.rect.maxX - 1, y: image.rect.midY)))
    let scope = WireComposeScope.with { $0.windowID = 1; $0.leaf = 2; $0.buffer = 3; $0.bufferRevision = 4 }
    let click = try XCTUnwrap(ComposePointer(scope: scope, epoch: 7, hit: hit, extend: false, count: 1)).input(id: 1)
    XCTAssertEqual(click.attachmentStart, start)
    XCTAssertEqual(click.position, end)
    let double = try XCTUnwrap(ComposePointer(scope: scope, epoch: 7, hit: hit, extend: false, count: 2)).input(id: 2)
    XCTAssertEqual(double.attachmentStart, start)
    XCTAssertEqual(double.clickCount, 2)
    let extending = try XCTUnwrap(ComposePointer(scope: scope, epoch: 7, hit: hit, extend: true, count: 1)).input(id: 3)
    XCTAssertTrue(extending.extend)
    XCTAssertFalse(extending.hasAttachmentStart)
    XCTAssertEqual(extending.position, UInt64(hit.source))
  }
}
