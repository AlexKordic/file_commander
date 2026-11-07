import XCTest
import CoreText
@testable import FreshKit

final class ComposeShapingTests: XCTestCase {
  private let body = CTFontCreateUIFontForLanguage(.system, 16, nil)!
  private let code = CTFontCreateWithName("Menlo" as CFString, 16, nil)

  private func glyphs(_ line: CTLine, in range: NSRange, origin: Int = 0) -> [CGGlyph] {
    var result: [CGGlyph] = []
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
      let count = CTRunGetGlyphCount(run)
      var indices = [CFIndex](repeating: 0, count: count), glyphs = [CGGlyph](repeating: 0, count: count)
      CTRunGetStringIndices(run, CFRange(), &indices); CTRunGetGlyphs(run, CFRange(), &glyphs)
      result += indices.indices.filter { indices[$0] != kCFNotFound && NSLocationInRange(indices[$0]+origin, range) }.map { glyphs[$0] }
    }
    return result
  }

  private func glyphs(_ text: ComposeTextLayout, in range: NSRange) -> [CGGlyph] {
    text.fragments.filter { NSIntersectionRange($0.range, range).length > 0 }.flatMap { glyphs($0.line, in: range,origin:$0.indexOrigin) }
  }

  private func pane(_ source: String) -> WireComposePane {
    .with {
      $0.text = source; $0.sourceEnd = UInt64(source.utf8.count); $0.documentLen = $0.sourceEnd
      $0.segments = [.with { $0.sourceEnd = UInt64(source.utf8.count); $0.displayEnd = $0.sourceEnd }]
    }
  }

  func testLongProseKeepsJoinedEmojiAndSourceCoordinatesLikeCompleteShortParagraphs() throws {
    for cluster in ["👩🏽‍💻", "👨‍👩‍👧‍👦", "🇷🇸", "1️⃣", "☕️"] {
      let prefix = "café before ", paragraph = prefix + cluster + " after.\n"
      let source = String(repeating: paragraph, count: 1000)
      let projection = try XCTUnwrap(ComposeProjection(source: 0..<source.utf8.count, text: source,
        segments: [.init(source: 0..<source.utf8.count, display: 0..<source.utf8.count, kind: .copy)]))
      let layout = try XCTUnwrap(ComposeTextLayout(projection: projection, font: body, width: 1000))
      let reference = CTLineCreateWithAttributedString(NSAttributedString(string: paragraph,
        attributes: [NSAttributedString.Key(kCTFontAttributeName as String): body]))
      let expected = glyphs(reference, in: NSRange(location: prefix.utf16.count, length: cluster.utf16.count))
      XCTAssertFalse(expected.isEmpty)
      for index in [0, 499, 999] {
        let range = NSRange(location: paragraph.utf16.count * index + prefix.utf16.count, length: cluster.utf16.count)
        XCTAssertEqual(glyphs(layout, in: range), expected, "\(cluster), paragraph \(index): whole-document shaping must match complete paragraph shaping")
        let start = paragraph.utf8.count * index + prefix.utf8.count
        XCTAssertEqual(layout.sourceRange(forUTF16: range), start..<(start + cluster.utf8.count))
      }
      XCTAssertEqual(Array(layout.projection.text.utf8), Array(source.utf8))
    }
  }

  func testSemanticHeadingEmphasisAndCodeKeepContextualEmojiInLongDocuments() throws {
    let cluster = "👩🏽‍💻", paragraph = "café before \(cluster) after.\n"
    let source = String(repeating: paragraph, count: 1000)
    for (role, flags, base) in [(UInt32(1), UInt32(0), body), (0, 3, body), (7, 0, code)] {
      var wire = pane(source)
      wire.spans = [.with { $0.end = UInt64(paragraph.utf8.count); $0.role = role; $0.flags = flags }]
      let measured = try XCTUnwrap(ComposePaneLayout(pane: wire, body: body, monospace: code, width: 1000))
      let reference = CTLineCreateWithAttributedString(NSAttributedString(string: paragraph,
        attributes: [NSAttributedString.Key(kCTFontAttributeName as String): base]))
      let range = (paragraph as NSString).range(of: cluster, options: .literal)
      XCTAssertEqual(glyphs(measured.text, in: range).count, glyphs(reference, in: range).count, "role \(role), flags \(flags)")
      XCTAssertEqual(Array(measured.text.projection.text.utf8), Array(source.utf8))
    }
  }

  func testCompleteTableSamplesMeasureJoinedClustersInsteadOfComponentSymbols() throws {
    let cluster = "👩🏽‍💻"
    let text = NSAttributedString(string: String(repeating: cluster, count: 4000),
      attributes: [NSAttributedString.Key(kCTFontAttributeName as String): body])
    let reference = CTLineCreateWithAttributedString(NSAttributedString(string: cluster,
      attributes: [NSAttributedString.Key(kCTFontAttributeName as String): body]))
    var constraints = ComposeColumnConstraints(count: 1, font: body, available: 160)
    XCTAssertTrue(constraints.include(text, range: NSRange(location: 0, length: text.length), column: 0, preferred: true))
    XCTAssertEqual(constraints.glyphMinimum[0], CGFloat(CTLineGetTypographicBounds(reference, nil, nil, nil)), accuracy: 0.001)
  }

  func testLongPresentationLabelsRetainTheirJoinedGlyphsWithoutChangingText() throws {
    let cluster = "👩🏽‍💻", source = String(repeating: cluster, count: 4000)
    let text = NSAttributedString(string: source, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): body])
    let reference = CTLineCreateWithAttributedString(NSAttributedString(string: cluster,
      attributes: [NSAttributedString.Key(kCTFontAttributeName as String): body]))
    let expected = glyphs(reference, in: NSRange(location: 0, length: cluster.utf16.count))
    let line = try XCTUnwrap(ComposeShaping.line(text))
    for index in [0, 1999, 3999] {
      XCTAssertEqual(glyphs(line, in: NSRange(location: index * cluster.utf16.count, length: cluster.utf16.count)), expected)
    }
    XCTAssertEqual(Array(text.string.utf8), Array(source.utf8))
  }
}
