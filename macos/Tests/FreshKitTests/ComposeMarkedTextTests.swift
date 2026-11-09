import XCTest
import CoreText
import ImageIO
@testable import FreshKit

final class ComposeMarkedTextTests: XCTestCase {
  private func marked(_ source: String, range: NSRange, text: String, selected: NSRange? = nil) throws -> ComposeMarkedText {
    let context = try XCTUnwrap(ComposeTextContext(.with {
      $0.text = source; $0.selectionStart = UInt64(range.location); $0.selectionEnd = UInt64(NSMaxRange(range))
    }, documentLength: UInt64(source.utf8.count)))
    return try XCTUnwrap(ComposeMarkedText(context: context, range: range, source: context.sourceRange(forUTF16: range)!,
      text: NSAttributedString(string: text), selected: selected ?? NSRange(location: text.utf16.count, length: 0)))
  }

  func testPartialUpdatesKeepSurroundingDraftAndDocumentRelativeMarkedSelection() throws {
    var value = try marked("**café** tail", range: NSRange(location: 2, length: 4), text: "abc")
    XCTAssertTrue(value.update(NSAttributedString(string: "XY"), selected: NSRange(location: 1, length: 1), replacement: NSRange(location: 3, length: 1)))
    XCTAssertEqual(value.draft.string, "aXYc")
    XCTAssertEqual(value.markedRange, NSRange(location: 3, length: 2))
    XCTAssertEqual(value.selectedRange, NSRange(location: 4, length: 1))
    XCTAssertEqual(value.substring(for: NSRange(location: 0, length: 30))?.text.string, "**aXYc** tail")
    XCTAssertTrue(value.update(NSAttributedString(string: "日"), selected: NSRange(location: 1, length: 0), replacement: NSRange(location: NSNotFound, length: 0)))
    XCTAssertEqual(value.draft.string, "a日c")
    XCTAssertEqual(value.source, 2..<7)
    XCTAssertEqual(value.markedRange, NSRange(location: 3, length: 1))
  }

  func testReplacementCanExpandIntoKnownSourceAndStillCommitAsOneOriginalRange() throws {
    var value = try marked("before café after", range: NSRange(location: 7, length: 4), text: "日本")
    XCTAssertTrue(value.update(NSAttributedString(string: "東京"), selected: NSRange(location: 2, length: 0), replacement: NSRange(location: 5, length: 6)))
    XCTAssertEqual(value.originalRange, NSRange(location: 5, length: 8))
    XCTAssertEqual(value.source, 5..<14)
    XCTAssertEqual(value.draft.string, "東京")
    XCTAssertEqual(value.substring(for: NSRange(location: 0, length: 100))?.text.string, "befor東京fter")
  }

  func testInvalidUnicodeRangesAndUnknownContextLeaveThePreviousDraftIntact() throws {
    var value = try marked("before café after", range: NSRange(location: 7, length: 4), text: "👩🏽‍💻")
    XCTAssertFalse(value.update(NSAttributedString(string: "bad"), selected: NSRange(location: 0, length: 0), replacement: NSRange(location: 8, length: 1)))
    XCTAssertFalse(value.update(NSAttributedString(string: "👩🏽‍💻"), selected: NSRange(location: 1, length: 0), replacement: NSRange(location: NSNotFound, length: 0)))
    XCTAssertFalse(value.update(NSAttributedString(string: "bad"), selected: NSRange(location: 0, length: 0), replacement: NSRange(location: 7, length: Int.max)))
    XCTAssertFalse(value.update(NSAttributedString(string: "bad"), selected: NSRange(location: 0, length: 0), replacement: NSRange(location: 999, length: 1)))
    XCTAssertEqual(value.draft.string, "👩🏽‍💻")
    XCTAssertEqual(value.source, 7..<12)
    XCTAssertEqual(value.substring(for: NSRange(location: 8, length: 1))?.text.string, "👩🏽‍💻")
  }

  func testProvisionalProjectionReflowsUsingTheHeadingFontWithoutChangingSourceCoordinates() throws {
    let source = "# Heading café\n\nFollowing text.\n"
    let range = (source as NSString).range(of: "café")
    let draft = String(repeating: "日本語 ", count: 10)
    let value = try marked(source, range: range, text: draft, selected: NSRange(location: 2, length: 1))
    let pane = WireComposePane.with {
      $0.text = source; $0.sourceEnd = UInt64(source.utf8.count); $0.documentLen = $0.sourceEnd
      $0.segments = [.with { $0.sourceEnd = UInt64(source.utf8.count); $0.displayEnd = $0.sourceEnd }]
      $0.spans = [.with { $0.end = UInt64(source[..<source.firstIndex(of: "\n")!].utf8.count + 1); $0.role = 1 }]
    }
    let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
    let layout = try XCTUnwrap(ComposePaneLayout(pane: pane, body: font, monospace: font, width: 220, preedit: value))
    XCTAssertEqual(layout.text.projection.source, 0..<source.utf8.count)
    XCTAssertEqual(layout.pane.text, source)
    XCTAssertTrue(layout.text.projection.text.contains(draft))
    let display = try XCTUnwrap(layout.draftDisplayRange)
    XCTAssertGreaterThan(layout.text.selectionRects(forUTF16: display).count, 1)
    let caret = try XCTUnwrap(layout.text.caret(atUTF16: display.location + 3))
    XCTAssertGreaterThan(caret.height, 24)
    XCTAssertNotNil(layout.text.firstRect(forUTF16: NSRange(location: display.location + 2, length: 1)))
    XCTAssertGreaterThan(layout.text.size.height, 100)
    let height = Int(ceil(layout.text.size.height)) + 32
    let bitmap = try XCTUnwrap(CGContext(data: nil, width: 260, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    bitmap.translateBy(x: 0, y: CGFloat(height)); bitmap.scaleBy(x: 1, y: -1)
    let bounds = CGRect(x: 0, y: 0, width: 260, height: height)
    layout.draw(in: bitmap, origin: CGPoint(x: 16, y: 12), clip: bounds, dirty: bounds,
      foreground: CGColor(gray: 0.1, alpha: 1), background: CGColor(gray: 1, alpha: 1), selection: CGColor(red: 0.6, green: 0.8, blue: 1, alpha: 1))
    let image = try XCTUnwrap(bitmap.makeImage())
    if let output = ProcessInfo.processInfo.environment["FC_COMPOSE_PREEDIT_PREVIEW_PATH"] {
      let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, "public.png" as CFString, 1, nil))
      CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
  }

  func testASelectionExtendingOutsideTheProjectionCanBeReplacedProvisionally() throws {
    let source = String(repeating: "文", count: 4000) + "Tail"
    let value = try marked(source, range: NSRange(location: 0, length: 4004), text: "新")
    let tail = try XCTUnwrap(ComposeProjection(source: 12000..<12004, text: "Tail",
      segments: [.init(source: 12000..<12004, display: 0..<4, kind: .copy)]))
    let replaced = try XCTUnwrap(value.projection(over: tail))
    XCTAssertEqual(replaced.projection.text, "新")
    XCTAssertEqual(replaced.projection.source, 0..<12004)
    XCTAssertEqual(replaced.display, 0..<3)
  }
}
