import XCTest
import CoreText
import ImageIO
@testable import FreshKit

final class ComposeTableMeasurementTests: XCTestCase {
  private let body = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
  private let code = CTFontCreateWithName("Menlo" as CFString, 18, nil)
  func testCJKPreferredMinimumUsesNativeLineBreaksRatherThanDictionaryWords() {
    let text = NSAttributedString(string: "東京都", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): body])
    let glyph = CTLineCreateWithAttributedString(NSAttributedString(string: "東",
      attributes: [NSAttributedString.Key(kCTFontAttributeName as String): body]))
    let advance = CGFloat(CTLineGetTypographicBounds(glyph, nil, nil, nil))
    var constraints = ComposeColumnConstraints(count: 2, font: body, available: 240)
    constraints.include(text, range: NSRange(location: 0, length: text.length), column: 0, preferred: true)
    XCTAssertGreaterThanOrEqual(constraints.minimum[0], advance)
    XCTAssertLessThan(constraints.minimum[0], advance * 2,
      "native CJK wrapping can break between these characters without keeping a dictionary word together")
    let typesetter = CTTypesetterCreateWithAttributedString(text)
    XCTAssertEqual(CTTypesetterSuggestLineBreak(typesetter, 0, Double(constraints.minimum[0])), 1)
  }

  func testNonbreakingPhraseContributesItsWholeMeasuredPreferredMinimum() {
    let text = NSAttributedString(string: "one\u{00a0}two", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): body])
    let line = CTLineCreateWithAttributedString(text)
    let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    var constraints = ComposeColumnConstraints(count: 1, font: body, available: 400)
    constraints.include(text, range: NSRange(location: 0, length: text.length), column: 0, preferred: true)
    XCTAssertEqual(constraints.minimum[0], ceil(width) + 0.5, accuracy: 0.01,
      "a nonbreaking space retains one native break unit rather than separate linguistic words")
  }

  private func fixture() throws -> WireComposePane {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "compose-tables", withExtension: "pb", subdirectory: "Fixtures"))
    return try WireComposePane(serializedBytes: Data(contentsOf: url))
  }
  private func crop(_ pane: WireComposePane, row: WireComposeTableRow) throws -> WireComposePane {
    let bytes = Array(pane.text.utf8), source = row.start..<row.end
    var result = pane; result.sourceStart = row.start; result.sourceEnd = row.end
    result.text = ""; result.segments = []
    for segment in pane.segments {
      let a = max(source.lowerBound, segment.sourceStart), b = min(source.upperBound, segment.sourceEnd)
      guard a < b else { continue }
      let start = result.text.utf8.count
      switch segment.kind {
      case 0:
        let at = Int(segment.displayStart + a - segment.sourceStart)
        result.text += String(decoding: bytes[at..<(at + Int(b - a))], as: UTF8.self)
      case 1: break
      default:
        XCTAssertEqual(a, segment.sourceStart); XCTAssertEqual(b, segment.sourceEnd)
        result.text += String(decoding: bytes[Int(segment.displayStart)..<Int(segment.displayEnd)], as: UTF8.self)
      }
      result.segments.append(.with { $0.sourceStart = a; $0.sourceEnd = b; $0.displayStart = UInt64(start); $0.displayEnd = UInt64(result.text.utf8.count); $0.kind = segment.kind })
    }
    result.tables = [pane.tables[0]]; result.tables[0].rows = [row]
    result.images = pane.images.filter { source.contains($0.start) && $0.end <= source.upperBound }
    result.spans = pane.spans.filter { $0.start < source.upperBound && source.lowerBound < $0.end }
    result.topByte = row.start; result.viewport.position = row.start
    result.projectionRevision &+= row.start
    XCTAssertNotNil(ComposeProjection(result))
    return result
  }

  func testWholeTableMeasurementsKeepColumnsStableAcrossDisjointRowsAndReuseValidatedInputs() throws {
    let pane = try fixture()
    XCTAssertNotEqual(pane.tables[0].measurementID, 0)
    let first = try crop(pane, row: pane.tables[0].rows[0]), last = try crop(pane, row: pane.tables[0].rows[4])
    let top = try XCTUnwrap(ComposePaneLayout(pane: first, body: body, monospace: code, width: 320))
    let bottom = try XCTUnwrap(ComposePaneLayout(pane: last, body: body, monospace: code, width: 320, reuse: top))
    XCTAssertEqual(top.text.tables[0].columns, bottom.text.tables[0].columns)
    let wide = try XCTUnwrap(ComposePaneLayout(pane: last, body: body, monospace: code, width: 620, reuse: bottom))
    XCTAssertNotEqual(wide.text.tables[0].columns, bottom.text.tables[0].columns)
    let large = try XCTUnwrap(ComposePaneLayout(pane: last, body: CTFontCreateCopyWithAttributes(body, 26, nil, nil),
      monospace: CTFontCreateCopyWithAttributes(code, 26, nil, nil), width: 320, reuse: bottom))
    XCTAssertNotEqual(large.text.tables[0].columns, bottom.text.tables[0].columns)
    let topModel = try XCTUnwrap(ComposeTableModel(pane: first))
    let bottomModel = try XCTUnwrap(ComposeTableModel(pane: last, reuse: topModel))
    XCTAssertTrue(topModel.tables[0].measurement === bottomModel.tables[0].measurement)
    var oldFirst = first, oldLast = last
    oldFirst.tables[0].measurementID = 0; oldFirst.tables[0].clearMeasurement()
    oldLast.tables[0].measurementID = 0; oldLast.tables[0].clearMeasurement()
    let localA = try XCTUnwrap(ComposePaneLayout(pane: oldFirst, body: body, monospace: code, width: 320))
    let localB = try XCTUnwrap(ComposePaneLayout(pane: oldLast, body: body, monospace: code, width: 320))
    XCTAssertNotEqual(localA.text.tables[0].columns, localB.text.tables[0].columns,
      "the row subsets exercise the original width drift")
  }

  func testReferencesRetainOnlyMatchingDocumentAndTableInputsAndRejectMalformedStyles() throws {
    let full = try fixture()
    var reference = try crop(full, row: full.tables[0].rows[4])
    reference.tables[0].clearMeasurement()
    XCTAssertNil(ComposeTableModel(pane: reference), "an unknown measurement reference cannot invent column data")
    XCTAssertNotNil(ComposeTableModel(pane: reference.retainingTableMeasurements(from: full)))
    var foreign = full; foreign.assetDocument &+= 1
    XCTAssertNil(ComposeTableModel(pane: reference.retainingTableMeasurements(from: foreign)))
    foreign = full; foreign.tables[0].measurementID &+= 1
    XCTAssertNil(ComposeTableModel(pane: reference.retainingTableMeasurements(from: foreign)))
    var bad = full; bad.tables[0].measurement.columns.removeLast()
    XCTAssertNil(ComposeTableModel(pane: bad))
    bad = full
    bad.tables[0].measurement.columns[0].samples[0].text = "é"
    bad.tables[0].measurement.columns[0].samples[0].spans = [.with { $0.start = 1; $0.end = 2; $0.flags = 1 }]
    XCTAssertNil(ComposeTableModel(pane: bad), "styles cannot split UTF-8 scalars")
    bad = full; bad.tables[0].measurement.columns[0].samples[0].minimumOnly = true
    bad.tables[0].measurement.columns[0].samples[0].image = true
    XCTAssertNil(ComposeTableModel(pane: bad))
  }

  func testSourceRevealAndLateImageDimensionsKeepTheSameColumnConstraints() throws {
    let full = try fixture()
    let url = try XCTUnwrap(Bundle.module.url(forResource: "compose-table-image-source", withExtension: "pb", subdirectory: "Fixtures"))
    let source = try WireComposePane(serializedBytes: Data(contentsOf: url))
    XCTAssertEqual(full.tables[0].measurementID, source.tables[0].measurementID)
    let reading = try XCTUnwrap(ComposePaneLayout(pane: full, body: body, monospace: code, width: 360))
    let editing = try XCTUnwrap(ComposePaneLayout(pane: source, body: body, monospace: code, width: 360, reuse: reading))
    XCTAssertEqual(reading.text.tables[0].columns, editing.text.tables[0].columns)
    let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 160, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let bytes = NSMutableData()
    let output = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(output, try XCTUnwrap(context.makeImage()), nil); XCTAssertTrue(CGImageDestinationFinalize(output))
    let asset = try ComposeImageAsset.decode(bytes as Data)
    let loaded = try XCTUnwrap(ComposePaneLayout(pane: source, body: body, monospace: code, width: 360,
      images: [source.images[0].start: .ready(asset)], reuse: editing))
    XCTAssertEqual(loaded.text.tables[0].columns, editing.text.tables[0].columns)
    XCTAssertNotEqual(loaded.text.attachments.first?.rect.size, editing.text.attachments.first?.rect.size)
  }

  @MainActor
  func testSceneStoreRetainsMeasurementsOnlyForTheSamePaneAndDocument() throws {
    let full = try fixture()
    let original = WirePane.with { $0.leaf = 2; $0.buffer = 3; $0.compose = full }
    let store = SceneStore()
    func apply(_ pane: WirePane, window: UInt64 = 1) throws {
      let frame = WireFrame.with { $0.windowID = window; $0.paneLen = 1; $0.panes = [.with { $0.pane = pane }] }
      let bytes: [UInt8] = try frame.serializedBytes()
      store.apply(try XCTUnwrap(SceneMessage(kind: SceneWire.Kind.frame.rawValue, payload: bytes[...])))
    }
    try apply(original)
    var next = original
    next.compose = try crop(full, row: full.tables[0].rows[4]); next.compose.tables[0].clearMeasurement()
    try apply(next)
    XCTAssertNotNil(ComposeTableModel(pane: store.panes[0].compose))
    var other = next; other.buffer = 4
    try apply(other)
    XCTAssertNil(ComposeTableModel(pane: store.panes[0].compose))
    try apply(original)
    try apply(next, window: 2)
    XCTAssertNil(ComposeTableModel(pane: store.panes[0].compose))
  }

  func testMinimumGlyphConstraintsUseLogicalClustersAcrossBidiBoundariesAndFontRuns() throws {
    for value in ["iiii אבג ffi e\u{301} 👩🏽‍💻 W", "שלום אבג 👩🏽‍💻 e\u{301} ffi W", "سلام لا 👩🏽‍💻 e\u{301} ffi W"] {
      let text = NSMutableAttributedString(string: value,
        attributes: [NSAttributedString.Key(kCTFontAttributeName as String): body])
      let large = CTFontCreateWithName("Helvetica-Bold" as CFString, 24, nil)
      text.addAttribute(NSAttributedString.Key(kCTFontAttributeName as String), value: large,
        range: NSRange(location: text.length - 1, length: 1))
      var expected: CGFloat = 0, offset = 0
      for cluster in value {
        let count = String(cluster).utf16.count
        let sample = text.attributedSubstring(from: NSRange(location: offset, length: count))
        let line = CTLineCreateWithAttributedString(sample)
        expected = max(expected, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        offset += count
      }
      var constraints = ComposeColumnConstraints(count: 1, font: body, available: 200)
      constraints.include(text, range: NSRange(location: 0, length: text.length), column: 0, preferred: false)
      XCTAssertEqual(constraints.minimum[0], expected, accuracy: 0.01,
        "a primary-caret jump across an RTL run is not one glyph's width")
      let prefix = NSMutableAttributedString(string: "unmeasured prefix ", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): code])
      let start = prefix.length; prefix.append(text)
      var scoped = ComposeColumnConstraints(count: 1, font: body, available: 200)
      scoped.include(prefix, range: NSRange(location: start, length: text.length), column: 0, preferred: false)
      XCTAssertEqual(scoped.minimum[0], expected, accuracy: 0.01, "typesetter indices remain document-relative")
    }
  }

}
