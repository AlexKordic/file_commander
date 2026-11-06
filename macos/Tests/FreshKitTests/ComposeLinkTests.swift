import XCTest
import CoreText
@testable import FreshKit

final class ComposeLinkTests: XCTestCase {
  private func pane(_ text: String) -> WireComposePane {
    let count = UInt64(text.utf8.count)
    return .with {
      $0.text = text; $0.sourceEnd = count; $0.documentLen = count
      $0.segments = [.with { $0.sourceEnd = count; $0.displayEnd = count }]
    }
  }

  private func link(_ source: Range<Int>, target: String? = "docs/café.md") -> WireComposeSpan {
    .with {
      $0.start = UInt64(source.lowerBound); $0.end = UInt64(source.upperBound); $0.flags = 4 | 16
      if let target { $0.linkTarget = target }
    }
  }

  private func layout(_ pane: WireComposePane, reuse: ComposePaneLayout? = nil,
                      preedit: ComposeMarkedText? = nil) throws -> ComposePaneLayout {
    let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
    return try XCTUnwrap(ComposePaneLayout(pane: pane, body: font, monospace: font, width: 95, reuse: reuse, preedit: preedit))
  }

  func testLinksUseConcealMapsUnicodeAndCroppedSourceWithoutParsingMarkdown() throws {
    let label = "café 東京 👩🏽‍💻", source = "[\(label)](docs/a.md) after"
    let labelEnd = 1 + label.utf8.count, close = labelEnd + "](docs/a.md)".utf8.count
    var value = pane(source)
    value.text = label + " after"
    value.segments = [
      .with { $0.sourceEnd = 1; $0.kind = 1 },
      .with { $0.sourceStart = 1; $0.sourceEnd = UInt64(labelEnd); $0.displayEnd = UInt64(label.utf8.count) },
      .with { $0.sourceStart = UInt64(labelEnd); $0.sourceEnd = UInt64(close); $0.displayStart = UInt64(label.utf8.count); $0.displayEnd = $0.displayStart; $0.kind = 1 },
      .with { $0.sourceStart = UInt64(close); $0.sourceEnd = UInt64(source.utf8.count); $0.displayStart = UInt64(label.utf8.count); $0.displayEnd = UInt64(value.text.utf8.count) },
    ]
    value.spans = [link(0..<close)]
    let shown = try layout(value), item = try XCTUnwrap(shown.links.first)
    XCTAssertEqual(item.source, 0..<close)
    XCTAssertEqual(item.range, NSRange(location: 0, length: label.utf16.count))
    XCTAssertEqual(item.target, "docs/café.md")
    XCTAssertEqual(shown.link(atUTF16: 0), item)
    XCTAssertNil(shown.link(atUTF16: label.utf16.count))
    XCTAssertGreaterThan(shown.text.fragments.count, 1)

    value.sourceStart = 2; value.sourceEnd = UInt64(labelEnd)
    value.text = String(label.dropFirst())
    value.segments = [.with { $0.sourceStart = 2; $0.sourceEnd = UInt64(labelEnd); $0.displayEnd = UInt64(value.text.utf8.count) }]
    let cropped = try layout(value)
    XCTAssertEqual(cropped.links.first?.source, 0..<close)
    XCTAssertEqual(cropped.links.first?.range, NSRange(location: 0, length: value.text.utf16.count))
  }

  func testAbsentInvalidAndAmbiguousMetadataNeverInventsADestinationButEmptyTargetsSurvive() throws {
    var value = pane("label")
    value.spans = [link(0..<5, target: nil), .with { $0.end = 5; $0.linkTarget = "not a link" },
      .with { $0.end = 99; $0.flags = 16; $0.linkTarget = "invalid range" }]
    XCTAssertTrue(try layout(value).links.isEmpty)
    value.spans = [link(0..<5, target: "")]
    XCTAssertEqual(try layout(value).link(atUTF16: 2)?.target, "")
    value.spans.append(link(0..<5, target: "different"))
    XCTAssertNil(try layout(value).link(atUTF16: 2))
  }

  func testReusedGeometryKeepsTheNewLiteralDestinationDespiteCanonicalUnicodeEquality() throws {
    var value = pane("label"); value.documentLen = 100
    value.spans = [link(0..<60, target: "docs/café.md")]
    let first = try layout(value)
    value.bufferRevision += 1
    value.spans[0].linkTarget = "docs/cafe\u{301}.md"
    let second = try layout(value, reuse: first)
    XCTAssertTrue(second.text === first.text, "destination metadata does not require reshaping unchanged glyphs")
    XCTAssertNotEqual(second.links, first.links, "a literal path is not Unicode-normalized")
    XCTAssertTrue(second.links[0].target.utf8.elementsEqual(value.spans[0].linkTarget.utf8))
  }

  func testChangingOnlyTheDestinationDoesNotReshapeUnchangedDisplayText() throws {
    var value = pane("label"); value.documentLen = 100
    value.spans = [link(0..<60, target: "docs/first.md")]
    let first = try layout(value)
    value.bufferRevision += 1; value.spans[0].linkTarget = "docs/other.md"
    let second = try layout(value, reuse: first)
    XCTAssertTrue(second.text === first.text)
    XCTAssertEqual(second.links[0].target, "docs/other.md")
    value.spans[0].flags |= 1
    XCTAssertFalse(try layout(value, reuse: second).text === second.text, "font-affecting metadata must still invalidate layout")
  }

  func testProvisionalSourceSuppressesOnlyTheLinkBeingEdited() throws {
    let source = "[one](first.md) [two](second.md) tail"
    var value = pane(source)
    value.spans = [link(0..<15, target: "first.md"), link(16..<32, target: "second.md")]
    let range = (source as NSString).range(of: "first")
    let context = try XCTUnwrap(ComposeTextContext(.with {
      $0.text = source; $0.selectionStart = UInt64(range.location); $0.selectionEnd = UInt64(NSMaxRange(range))
    }, documentLength: value.documentLen))
    let draft = try XCTUnwrap(ComposeMarkedText(context: context, range: range, source: context.sourceRange(forUTF16: range)!,
      text: NSAttributedString(string: "changed"), selected: NSRange(location: 7, length: 0)))
    let shown = try layout(value, preedit: draft)
    XCTAssertTrue(shown.text.projection.text.contains("changed.md"))
    XCTAssertEqual(shown.links.map(\.target), ["second.md"])
    XCTAssertEqual(shown.links[0].range.location, 18, "unrelated links follow provisional reflow")
  }
}
