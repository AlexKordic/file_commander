import CoreText
import CryptoKit
import XCTest
@testable import FreshKit

final class ComposeFlowTextIndexTests: XCTestCase {
  private let body = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
  private let code = CTFontCreateWithName("Menlo" as CFString, 18, nil)

  private func snapshot(_ value: WireComposePane) throws -> ComposeDocumentSnapshot {
    var value = value
    value.bufferRevision = 1; value.selectionRevision = 2; value.decorationRevision = 3
    value.viewport.epoch = 4; value.assetAuthority = 5; value.assetDocument = 6
    value.ready = true; value.currentProjection = true
    let pane = WirePane.with { $0.leaf = 2; $0.buffer = 3; $0.compose = value }
    let document = try XCTUnwrap(ComposeAccessibleDocument(window: 1, pane: pane))
    let data = try value.serializedData()
    return .init(document: document, pane: value,
      baseline: .init(id: 1, owner: document.owner, data: data, digest: Data(SHA256.hash(data: data))))
  }
  private func plain(_ text: String) throws -> ComposeDocumentSnapshot {
    try snapshot(.with {
      $0.text = text; $0.sourceEnd = UInt64(text.utf8.count); $0.documentLen = $0.sourceEnd
      if !text.isEmpty { $0.segments = [.with { $0.sourceEnd = UInt64(text.utf8.count); $0.displayEnd = $0.sourceEnd }] }
    })
  }
  private func fixture() throws -> ComposeDocumentSnapshot {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "compose-tables", withExtension: "pb", subdirectory: "Fixtures"))
    return try snapshot(WireComposePane(serializedBytes: Data(contentsOf: url)))
  }
  private func measure(_ snapshot: ComposeDocumentSnapshot, width: CGFloat = 320) throws -> ComposeFlowMeasurement {
    try ComposeFlowMeasurement.measure(snapshot, environment: .init(body: body, monospace: code, width: width))
  }

  func testActualTableLinesCoverEveryCharacterIncludingSeparatorsAndEmptyCells() throws {
    let flow = try measure(fixture()), index = flow.textIndex, text = flow.document.text as NSString
    XCTAssertEqual(index.lineCount, flow.lines.count)
    var position = 0, reconstructed = ""
    for number in 0..<index.lineCount {
      let range = try XCTUnwrap(index.range(forLine: number))
      XCTAssertEqual(range.location, position)
      reconstructed += text.substring(with: range); position = NSMaxRange(range)
      for unit in range.location..<NSMaxRange(range) {
        XCTAssertEqual(index.line(atUTF16: unit), number)
      }
    }
    XCTAssertEqual(position, text.length); XCTAssertEqual(Array(reconstructed.utf8), Array(flow.document.text.utf8))
    XCTAssertTrue(flow.lines.contains { $0.table != nil && $0.range.length == 0 })
    for match in [text.range(of: "\t"), text.range(of: "\tempty\t\r\n")] {
      let line = try XCTUnwrap(index.line(atUTF16: match.location)), range = try XCTUnwrap(index.range(forLine: line))
      XCTAssertTrue(NSLocationInRange(match.location, range))
      XCTAssertNotNil(flow.bounds(for: NSRange(location: match.location, length: 1)))
    }
    XCTAssertNil(index.line(atUTF16: -1)); XCTAssertNil(index.line(atUTF16: text.length + 1))
    XCTAssertNil(index.range(forLine: -1)); XCTAssertNil(index.range(forLine: index.lineCount))
    XCTAssertNil(index.lines(intersecting: NSRange(location: Int.max, length: 1)))
  }

  func testSoftWrapAffinityDiffersFromConsumedUnicodeLineBreaksAndCellBoundaries() throws {
    let source = "ordinary words with café 👩🏽‍💻 that wrap across several measured lines\r\n"
      + "second\u{2028}third\u{2029}fourth\nlast"
    let flow = try measure(plain(source), width: 120)
    var soft = 0, hard = 0
    for i in 1..<flow.lines.count {
      let before = flow.lines[i - 1], current = flow.lines[i], at = current.range.location
      if before.endsInHardBreak {
        hard += 1
        XCTAssertEqual(flow.textIndex.line(atUTF16: at, affinity: .upstream), i)
        XCTAssertEqual(flow.textIndex.line(atUTF16: at, affinity: .downstream), i)
      } else if current.range.length > 0 {
        soft += 1
        XCTAssertEqual(flow.textIndex.line(atUTF16: at, affinity: .upstream), i - 1)
        XCTAssertEqual(flow.textIndex.line(atUTF16: at, affinity: .downstream), i)
      }
    }
    XCTAssertGreaterThan(soft, 1); XCTAssertGreaterThanOrEqual(hard, 4)
    let table = try measure(fixture())
    for i in 1..<table.lines.count where table.lines[i].table != nil && table.lines[i - 1].table != table.lines[i].table {
      XCTAssertEqual(table.textIndex.line(atUTF16: table.lines[i].range.location, affinity: .upstream), i)
    }
  }

  func testEOFAndEmptyDocumentsHaveOnlyExistingMeasuredOwners() throws {
    for text in ["", "abc", "abc\n", "abc\r\n", "👩🏽‍💻\n\n"] {
      let flow = try measure(plain(text)), count = text.utf16.count, index = flow.textIndex
      let last = index.lineCount - 1
      for affinity: ComposeProjection.Affinity in [.upstream, .downstream] {
        XCTAssertEqual(index.line(atUTF16: count, affinity: affinity), last)
      }
      XCTAssertEqual(index.lines(intersecting: NSRange(location: count, length: 0)), last..<(last + 1))
      XCTAssertEqual(NSMaxRange(try XCTUnwrap(index.range(forLine: last))), count)
      XCTAssertNotNil(flow.bounds(for: NSRange(location: count, length: 0)))
      XCTAssertNil(index.style(atUTF16: count)); XCTAssertEqual(index.styles(intersecting: NSRange(location: count, length: 0))?.count, 0)
    }
  }

  func testCompleteStylesMatchActualShapedFontsAndKeepImageIdentitySeparate() throws {
    let snapshot = try fixture(), flow = try measure(snapshot)
    let drawing = try XCTUnwrap(ComposePaneLayout(pane: snapshot.pane, body: body, monospace: code, width: 320))
    let text = snapshot.document.text as NSString
    let runs = drawing.text.fragments.flatMap { fragment in
      (CTLineGetGlyphRuns(fragment.line) as! [CTRun]).map { (fragment.shaped.range(of: $0),
        (CTRunGetAttributes($0) as NSDictionary)[kCTFontAttributeName] as! CTFont) }
    }
    for position in 0..<text.length {
      let style = try XCTUnwrap(flow.textIndex.style(atUTF16: position))
      XCTAssertTrue(NSLocationInRange(position, style.range))
      let expected = runs.first { NSLocationInRange(position, $0.0) }?.1 ?? body
      let font = flow.fonts[style.font]
      XCTAssertEqual(font.name, CTFontCopyPostScriptName(expected) as String)
      XCTAssertEqual(font.size, CTFontGetSize(expected))
    }
    for placed in flow.attachments where !placed.attachment.preview {
      let range = try XCTUnwrap(snapshot.document.displayedRange(for: placed.attachment.source))
      let style = try XCTUnwrap(flow.textIndex.style(atUTF16: range.location))
      XCTAssertEqual(style.range, range); XCTAssertEqual(style.attachment, placed.attachment.source)
    }
    let tab = text.range(of: "\t")
    XCTAssertNil(flow.textIndex.style(atUTF16: tab.location)?.attachment)
    let selected = NSRange(location: 3, length: text.length - 7)
    let clipped = try XCTUnwrap(flow.textIndex.styles(intersecting: selected))
    XCTAssertEqual(clipped.first?.range, flow.textIndex.style(atUTF16: selected.location)?.range)
    XCTAssertEqual(clipped.last?.range, flow.textIndex.style(atUTF16: NSMaxRange(selected) - 1)?.range)
    XCTAssertNil(flow.textIndex.styles(intersecting: NSRange(location: -1, length: 1)))
  }

  func testUnpaintedTableSeparatorsAndEmptyCellsUseActualEdgeCaretsForBounds() throws {
    let snapshot = try fixture(), flow = try measure(snapshot)
    let drawing = try XCTUnwrap(ComposePaneLayout(pane: snapshot.pane, body: body, monospace: code, width: 320))
    let text = snapshot.document.text as NSString
    for token in ["\t", "\r\ncafé", "\tempty\t\r\n"] {
      let match = text.range(of: token), line = try XCTUnwrap(flow.textIndex.line(atUTF16: match.location))
      XCTAssertNotEqual(match.location, NSNotFound)
      let fragment = drawing.text.fragments[line]
      let edge = CGRect(x: fragment.rect.minX + fragment.shaped.offset(for: fragment.contentEnd),
        y: fragment.rect.minY, width: 1, height: fragment.rect.height)
      XCTAssertEqual(flow.bounds(for: NSRange(location: match.location, length: 1)), edge)
      XCTAssertEqual(flow.bounds(for: NSRange(location: match.location, length: 0)), edge)
    }
    let rowBreak = text.range(of: "\r\ncafé")
    XCTAssertEqual(flow.bounds(for: NSRange(location: rowBreak.location + 1, length: 0)),
      flow.bounds(for: NSRange(location: rowBreak.location, length: 0)))
  }

  func testDistantQueriesUseCompleteMeasuredLinesAndStylesWithoutAPrefixLayout() throws {
    let text = String(repeating: "café 👩🏽‍💻 العربية words\r\n", count: 5000) + "final tail"
    let flow = try measure(plain(text)), end = text.utf16.count
    XCTAssertGreaterThan(flow.textIndex.lineCount, 4000)
    let last = try XCTUnwrap(flow.textIndex.line(atUTF16: end - 1))
    XCTAssertEqual(last, flow.textIndex.lineCount - 1)
    let range = NSRange(location: end - 4, length: 4)
    XCTAssertEqual(flow.textIndex.lines(intersecting: range), last..<(last + 1))
    XCTAssertNotNil(flow.bounds(for: range)); XCTAssertNotNil(flow.textIndex.style(atUTF16: end - 1))
    XCTAssertFalse(flow.usage.retainedGlyphs)
  }
}
