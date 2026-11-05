import XCTest
import CoreText
import ImageIO
@testable import FreshKit

final class ComposeCodeTests: XCTestCase {
  private func fixture() throws -> WireComposePane {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "compose-code", withExtension: "pb", subdirectory: "Fixtures"))
    return try WireComposePane(serializedBytes: Data(contentsOf: url))
  }

  private func layout(_ pane: WireComposePane, width: CGFloat, preedit: ComposeMarkedText? = nil) throws -> ComposePaneLayout {
    try XCTUnwrap(ComposePaneLayout(pane: pane,
      body: CTFontCreateWithName("Helvetica" as CFString, 18, nil),
      monospace: CTFontCreateWithName("Menlo" as CFString, 18, nil), width: width, preedit: preedit))
  }

  func testRealPluginCodeFramesUseMeasuredWrappingAndKeepListMarkersOutside() throws {
    let pane = try fixture(), source = pane.textContext.text
    XCTAssertEqual(pane.spans.filter { $0.role == 12 }.count, 6)
    XCTAssertFalse(pane.text.contains("```"))
    XCTAssertTrue(pane.text.contains("> literal greater-than\r\n"))
    let narrow = try layout(pane, width: 220), wide = try layout(pane, width: 620)
    XCTAssertEqual(narrow.codeFrames.count, 6); XCTAssertEqual(wide.codeFrames.count, 6)
    XCTAssertGreaterThan(narrow.codeFrames[0].rect.height, wide.codeFrames[0].rect.height)
    for value in [narrow, wide] {
      for frame in value.codeFrames {
        XCTAssertGreaterThanOrEqual(frame.rect.minY, 0)
        XCTAssertGreaterThan(frame.rect.height, 20)
        XCTAssertEqual(frame.rect.maxX, value.text.size.width, accuracy: 0.001)
      }
      for word in ["let long_value", "quoted code", "nested code", "first child code", "unterminated code"] {
        let index = source.range(of: word)!.lowerBound, byte = source[..<index].utf8.count
        let caret = try XCTUnwrap(value.text.caret(for: byte))
        let frame = try XCTUnwrap(value.codeFrames.first { $0.source.contains(byte) })
        XCTAssertEqual(caret.minX, frame.rect.minX + 8, accuracy: 0.01, "code uses its own inset instead of an item's hanging prefix")
        XCTAssertGreaterThanOrEqual(caret.minY, frame.rect.minY)
        XCTAssertLessThanOrEqual(caret.maxY, frame.rect.maxY)
        let hit = try XCTUnwrap(value.text.hit(at: CGPoint(x: caret.minX + 0.1, y: caret.midY)))
        XCTAssertEqual(hit.source, byte)
      }
      let marker = source.range(of: "- ```")!.lowerBound
      let code = source.range(of: "first child code")!.lowerBound
      let markerCaret = try XCTUnwrap(value.text.caret(for: source[..<marker].utf8.count))
      let codeFrame = try XCTUnwrap(value.codeFrames.first { $0.source.contains(source[..<code].utf8.count) })
      XCTAssertGreaterThanOrEqual(codeFrame.rect.minY, markerCaret.maxY, "a first-line list marker must not become part of a code box")
    }
  }

  func testCodeSelectionsAndNavigationUseTheInsetFontGeometry() throws {
    let pane = try fixture(), source = pane.textContext.text, value = try layout(pane, width: 280)
    let word = source.range(of: "café 👩🏽‍💻")!, start = source[..<word.lowerBound].utf8.count, end = source[..<word.upperBound].utf8.count
    let selected = value.text.selectionRects(for: start..<end)
    XCTAssertFalse(selected.isEmpty)
    let frame = try XCTUnwrap(value.codeFrames.first { $0.source.contains(start) })
    XCTAssertTrue(selected.allSatisfy { $0.minX >= frame.rect.minX + 8 - 0.01 && $0.maxX <= frame.rect.maxX - 8 + 0.01 })
    let feedback = try XCTUnwrap(value.text.navigation(id: 1, pageHeight: 300, documentLength: pane.documentLen, positions: [UInt64(start)]))
    let caret = try XCTUnwrap(value.text.caret(for: start))
    let stop = try XCTUnwrap(feedback.lines.flatMap(\.stops).first { $0.source == UInt64(start) })
    XCTAssertEqual(stop.x, caret.minX, accuracy: 0.01)
    let row = try XCTUnwrap(value.text.fragments.first { $0.rect.minY == caret.minY })
    let runs = CTLineGetGlyphRuns(row.line) as! [CTRun]
    XCTAssertTrue(runs.contains { run in
      let attributes = CTRunGetAttributes(run) as NSDictionary
      guard attributes[ComposeTextLayout.roleKey] as? UInt32 == 12,
            let font = attributes[kCTFontAttributeName] else { return false }
      return CTFontGetSymbolicTraits(font as! CTFont).contains(.traitMonoSpace)
    })
  }

  func testProvisionalCodeTextExpandsTheSameFrameWithoutChangingSourceTargets() throws {
    let pane = try fixture(), source = pane.textContext.text, range = (source as NSString).range(of: "café")
    let context = try XCTUnwrap(ComposeTextContext(pane.textContext, documentLength: pane.documentLen))
    let target = try XCTUnwrap(context.sourceRange(forUTF16: range))
    let draft = String(repeating: "日本語 code words\n", count: 20)
    let marked = try XCTUnwrap(ComposeMarkedText(context: context, range: range, source: target,
      text: NSAttributedString(string: draft), selected: NSRange(location: 2, length: 1)))
    let base = try layout(pane, width: 280), provisional = try layout(pane, width: 280, preedit: marked)
    XCTAssertGreaterThan(provisional.codeFrames[0].rect.height, base.codeFrames[0].rect.height)
    XCTAssertEqual(provisional.codeFrames.map(\.source), base.codeFrames.map(\.source))
    XCTAssertEqual(provisional.pane.text, pane.text)
    let display = try XCTUnwrap(provisional.draftDisplayRange)
    let caret = try XCTUnwrap(provisional.text.caret(atUTF16: display.location + 2))
    XCTAssertTrue(provisional.codeFrames[0].rect.contains(caret))
  }

  func testClippedCodeBlocksHaveOpenEdgesAndRenderThroughTheProductionPath() throws {
    let text = "let value = café;\r\n" + String(repeating: "a long code line that wraps in pixels. ", count: 8)
    var pane = WireComposePane.with {
      $0.sourceStart = 100; $0.sourceEnd = UInt64(100 + text.utf8.count); $0.documentLen = $0.sourceEnd + 100
      $0.text = text
      $0.segments = [.with { $0.sourceStart = 100; $0.sourceEnd = UInt64(100 + text.utf8.count); $0.displayEnd = UInt64(text.utf8.count) }]
      $0.spans = [.with { $0.end = UInt64(200 + text.utf8.count); $0.role = 12 }]
    }
    let clipped = try layout(pane, width: 230), frame = try XCTUnwrap(clipped.codeFrames.first)
    XCTAssertFalse(frame.hasStart); XCTAssertFalse(frame.hasEnd)
    XCTAssertEqual(frame.rect.minY, 0)
    XCTAssertEqual(frame.rect.maxY, clipped.text.size.height)
    let document = pane.documentLen
    pane.spans += (0..<12).map { _ in .with { $0.end = document; $0.role = 9 } }
    let nested = try layout(pane, width: 80)
    let nestedFrame = try XCTUnwrap(nested.codeFrames.first), caret = try XCTUnwrap(nested.text.caret(for: 100))
    XCTAssertEqual(caret.minX, nestedFrame.rect.minX + 8, accuracy: 0.01, "deep nesting keeps padding inside the indent cap")
    let complete = try layout(fixture(), width: 520)
    let height = Int(ceil(complete.text.size.height)) + 48
    let context = try XCTUnwrap(CGContext(data: nil, width: 568, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
    let bounds = CGRect(x: 0, y: 0, width: 568, height: height)
    complete.draw(in: context, origin: CGPoint(x: 24, y: 24), clip: bounds, dirty: bounds,
      foreground: CGColor(gray: 0.1, alpha: 1), background: CGColor(gray: 1, alpha: 1), selection: CGColor(gray: 0.7, alpha: 1))
    let image = try XCTUnwrap(context.makeImage())
    if let path = ProcessInfo.processInfo.environment["FC_COMPOSE_CODE_PREVIEW_FILE"] {
      let output = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil))
      CGImageDestinationAddImage(output, image, nil); XCTAssertTrue(CGImageDestinationFinalize(output))
    }
  }
}
