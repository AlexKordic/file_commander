import XCTest
import CoreText
import ImageIO
@testable import FreshKit

final class ComposeTableLayoutTests: XCTestCase {
  private func fixture() throws -> WireComposePane {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "compose-tables", withExtension: "pb", subdirectory: "Fixtures"))
    return try WireComposePane(serializedBytes: Data(contentsOf: url))
  }
  private func layout(_ pane: WireComposePane, width: CGFloat = 620, composition: ComposeComposition? = nil) throws -> ComposePaneLayout {
    try XCTUnwrap(ComposePaneLayout(pane: pane,
      body: CTFontCreateWithName("Helvetica" as CFString, 18, nil),
      monospace: CTFontCreateWithName("Menlo" as CFString, 18, nil), width: width, composition: composition))
  }
  private func marked(_ pane: WireComposePane, range: NSRange, text: String) throws -> ComposeMarkedText {
    let context = try XCTUnwrap(ComposeTextContext(pane.textContext, documentLength: pane.documentLen))
    let source = try XCTUnwrap(context.sourceRange(forUTF16: range))
    return try XCTUnwrap(ComposeMarkedText(context: context, range: range, source: source,
      text: NSAttributedString(string: text), selected: NSRange(location: 1, length: 0)))
  }
  private func sourcePane() throws -> WireComposePane {
    var pane = try fixture()
    let source = pane.textContext.text, count = source.utf8.count
    pane.text = source; pane.sourceStart = 0; pane.sourceEnd = UInt64(count); pane.documentLen = UInt64(count)
    pane.segments = [.with { $0.sourceEnd = UInt64(count); $0.displayEnd = UInt64(count) }]
    pane.images = []
    for i in pane.tables.indices {
      for j in pane.tables[i].rows.indices { pane.tables[i].rows[j].source = true; pane.tables[i].rows[j].cells = [] }
    }
    return pane
  }

  func testRealPluginTablesUseProportionalPixelMeasuresAndConstrainImagesToCells() throws {
    let pane = try fixture(), wide = try layout(pane), narrow = try layout(pane, width: 320)
    XCTAssertEqual(wide.text.tables.count, 2)
    XCTAssertEqual(wide.text.tables[0].rows.count, 6)
    XCTAssertGreaterThan(narrow.text.tables[0].rect.height, wide.text.tables[0].rect.height)
    for value in [wide, narrow] {
      for table in value.text.tables { XCTAssertEqual(table.rect.maxX, value.text.size.width, accuracy: 0.01) }
      XCTAssertGreaterThan(value.text.tables[1].rect.minX, 0, "quoted table retains a measured inset")
      let first = value.text.tables[0], body = first.rows[1]
      XCTAssertNotEqual(first.columns[0], first.columns[1], "column widths follow measured content")
      let image = try XCTUnwrap(value.text.attachments.first)
      XCTAssertTrue(body.cells[2].content.insetBy(dx: -0.01, dy: -0.01).contains(image.rect))
      let start = Int(pane.tables[0].rows[1].cells[0].start)
      let prose = try XCTUnwrap(value.text.fragments.first { $0.table?.source.lowerBound == start })
      let run = try XCTUnwrap((CTLineGetGlyphRuns(prose.line) as! [CTRun]).first)
      let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
      XCTAssertFalse(CTFontGetSymbolicTraits(font).contains(.traitMonoSpace))
      let header = first.rows[0].cells[1]
      let line = try XCTUnwrap(value.text.fragments.first { $0.table?.row == first.rows[0].source && $0.table?.column == 1 })
      let natural = CGFloat(CTLineGetTypographicBounds(line.line, nil, nil, nil))
      XCTAssertEqual(line.rect.minX, header.content.minX + max(0, header.content.width - natural) / 2, accuracy: 0.01)
      for empty in value.text.fragments where empty.table != nil && empty.range.length == 0 {
        XCTAssertEqual(CTLineGetGlyphCount(empty.line), 0, "zero-length ranges must not draw the rest of the projection")
      }
      let selected = value.text.selectionRects(for: body.source)
      XCTAssertFalse(selected.isEmpty)
      XCTAssertTrue(selected.allSatisfy { rect in body.cells.contains { $0.content.insetBy(dx: -1, dy: -1).contains(rect) } })
    }
    XCTAssertEqual(wide.pane.text, pane.text)
    XCTAssertTrue(wide.text.projection.text.contains(String(repeating: "🚀", count: 50)))
  }

  func testHitsAndTextServiceRectanglesRemainInTheCorrectCellOfATallRow() throws {
    let pane = try fixture(), value = try layout(pane, width: 320), source = pane.textContext.text
    let table = value.text.tables[0], row = table.rows[1]
    for word in ["café", "a\\|b"] {
      let range = try XCTUnwrap(source.range(of: word)), byte = source[..<range.lowerBound].utf8.count
      let caret = try XCTUnwrap(value.text.caret(for: byte))
      let hit = try XCTUnwrap(value.text.hit(at: CGPoint(x: caret.minX + 0.1, y: caret.midY)))
      XCTAssertEqual(hit.source, byte)
      let index = try XCTUnwrap(value.text.utf16Position(for: byte))
      let rect = try XCTUnwrap(value.text.firstRect(forUTF16: NSRange(location: index, length: 1)))
      let cell = try XCTUnwrap(row.cells.first { $0.source?.contains(byte) == true })
      XCTAssertTrue(cell.content.insetBy(dx: -1, dy: -1).contains(rect.rect), "equal y coordinates must not select a neighboring cell")
    }
    let short = row.cells[1]
    let lowHit = try XCTUnwrap(value.text.hit(at: CGPoint(x: short.content.minX, y: row.rect.maxY - 2)))
    XCTAssertTrue(try XCTUnwrap(short.source).contains(lowHit.source) || lowHit.source == short.source?.upperBound)
    for index in [2, 5] {
      for cell in table.rows[index].cells where cell.display?.length == 0 {
        let anchor = try XCTUnwrap(cell.source).lowerBound
        let point = CGPoint(x: cell.rect.midX, y: cell.rect.midY)
        XCTAssertEqual(value.text.hit(at: point)?.source, anchor)
        XCTAssertEqual(value.text.sourcePosition(at: point), anchor)
        let caret = try XCTUnwrap(value.text.caret(for: anchor))
        XCTAssertTrue(cell.content.insetBy(dx: -1, dy: -1).contains(caret))
      }
    }
    let missingRow = table.rows[3]
    for cell in missingRow.cells where cell.missing {
      XCTAssertEqual(value.text.hit(at: CGPoint(x: cell.rect.midX, y: cell.rect.midY))?.source, missingRow.contentEnd)
    }
  }

  func testMarkedTextReflowsWithinItsCellAndCrossCellDraftUsesSharedFlowOnce() throws {
    let pane = try fixture(), raw = pane.textContext.text as NSString
    let draft = String(repeating: "日本語 marked words\n", count: 15)
    let first = try marked(pane, range: raw.range(of: "café"), text: draft)
    let code = raw.range(of: "a\\|b")
    let second = try marked(pane, range: NSRange(location: code.location, length: 1), text: "第二の変換")
    let group = try XCTUnwrap(ComposeComposition(primary: 1, values: [1: first, 2: second]))
    let base = try layout(pane, width: 320), provisional = try layout(pane, width: 320, composition: group)
    XCTAssertEqual(provisional.text.tables.count, 2)
    XCTAssertGreaterThan(provisional.text.tables[0].rows[1].rect.height, base.text.tables[0].rows[1].rect.height)
    for (id, column) in [(UInt64(1), 0), (UInt64(2), 1)] {
      let display = try XCTUnwrap(provisional.draftDisplayRanges[id])
      let cell = provisional.text.tables[0].rows[1].cells[column]
      XCTAssertLessThanOrEqual(try XCTUnwrap(cell.display).location, display.location)
      XCTAssertGreaterThanOrEqual(NSMaxRange(try XCTUnwrap(cell.display)), NSMaxRange(display))
      let caret = try XCTUnwrap(provisional.text.caret(atUTF16: display.location + 1))
      XCTAssertTrue(cell.content.insetBy(dx: -1, dy: -1).contains(caret))
    }
    let beginning = Int(pane.tables[0].rows[1].cells[0].start)
    let context = try XCTUnwrap(ComposeTextContext(pane.textContext, documentLength: pane.documentLen))
    let index = try XCTUnwrap(context.utf16Position(for: beginning))
    let insertion = try marked(pane, range: NSRange(location: index, length: 0), text: "BOUNDARY")
    let inserted = try layout(pane, composition: try XCTUnwrap(ComposeComposition(primary: 1, values: [1: insertion])))
    let insertRange = try XCTUnwrap(inserted.draftDisplayRange), cellRange = try XCTUnwrap(inserted.text.tables[0].rows[1].cells[0].display)
    XCTAssertLessThanOrEqual(cellRange.location, insertRange.location)
    XCTAssertGreaterThanOrEqual(NSMaxRange(cellRange), NSMaxRange(insertRange))
    let cross = NSRange(location: raw.range(of: "café").location,
      length: code.location + 1 - raw.range(of: "café").location)
    let crossed = try marked(pane, range: cross, text: "CROSS_CELL_DRAFT")
    let shared = try layout(pane, width: 320, composition: try XCTUnwrap(ComposeComposition(primary: 1, values: [1: crossed])))
    XCTAssertEqual(shared.text.tables.count, 1, "the affected table uses one shared flow until the cross-cell draft commits")
    XCTAssertEqual(shared.text.projection.text.components(separatedBy: "CROSS_CELL_DRAFT").count, 2)
    let display = try XCTUnwrap(shared.draftDisplayRange)
    let covered = shared.text.fragments.reduce(0) { $0 + NSIntersectionRange($1.range, display).length }
    XCTAssertEqual(covered, display.length)
    XCTAssertEqual(shared.pane.text, pane.text)
  }

  func testStructuralRowsUseFullWidthSourceAndNarrowTablesExposeOverflow() throws {
    let pane = try sourcePane()
    let value = try layout(pane, width: 320)
    XCTAssertTrue(value.text.tables.allSatisfy { $0.rows.allSatisfy { $0.raw && $0.cells.isEmpty } })
    let row = value.text.tables[0].rows[1]
    let fragment = try XCTUnwrap(value.text.fragments.first { $0.table?.row == row.source })
    XCTAssertNil(fragment.table?.column)
    XCTAssertEqual(fragment.rect.minX, row.rect.minX + 8, accuracy: 0.01)
    let run = try XCTUnwrap((CTLineGetGlyphRuns(fragment.line) as! [CTRun]).first)
    let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
    XCTAssertTrue(CTFontGetSymbolicTraits(font).contains(.traitMonoSpace))
    let narrow = try layout(fixture(), width: 60)
    XCTAssertGreaterThan(narrow.text.size.width, 60, "complete clusters expose their extent for horizontal scrolling")
    for fragment in narrow.text.fragments where fragment.table != nil && fragment.range.length > 0 {
      let text = narrow.text.projection.text as NSString
      XCTAssertEqual(text.rangeOfComposedCharacterSequences(for: fragment.range), fragment.range)
    }
  }

  private func render(_ value: ComposePaneLayout, environment: String) throws {
    let height = Int(ceil(value.text.size.height)) + 48, width = Int(ceil(value.text.size.width)) + 48
    let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    value.draw(in: context, origin: CGPoint(x: 24, y: 24), clip: bounds, dirty: bounds,
      foreground: CGColor(gray: 0.1, alpha: 1), background: CGColor(gray: 1, alpha: 1), selection: CGColor(gray: 0.7, alpha: 1))
    let image = try XCTUnwrap(context.makeImage())
    if let path = ProcessInfo.processInfo.environment[environment] {
      let output = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil))
      CGImageDestinationAddImage(output, image, nil); XCTAssertTrue(CGImageDestinationFinalize(output))
    }
  }

  func testTablesRenderThroughTheProductionDrawingPath() throws {
    try render(layout(fixture(), width: 680), environment: "FC_COMPOSE_TABLE_PREVIEW_FILE")
  }

  func testAnEmptyFinalCellWithoutALineEndingKeepsItsOwnCaretLine() throws {
    // Source is |A|\n|-|\n||. The last cell is real, with a zero-length
    // source anchor at byte 9; the source's final row projects to no text.
    let pane = WireComposePane.with {
      $0.text = "A\n"; $0.sourceEnd = 10; $0.documentLen = 10
      $0.segments = [
        .with { $0.sourceEnd = 1; $0.kind = 1 },
        .with { $0.sourceStart = 1; $0.sourceEnd = 2; $0.displayEnd = 1 },
        .with { $0.sourceStart = 2; $0.sourceEnd = 3; $0.displayStart = 1; $0.displayEnd = 1; $0.kind = 1 },
        .with { $0.sourceStart = 3; $0.sourceEnd = 4; $0.displayStart = 1; $0.displayEnd = 2 },
        .with { $0.sourceStart = 4; $0.sourceEnd = 10; $0.displayStart = 2; $0.displayEnd = 2; $0.kind = 1 },
      ]
      $0.tables = [.with {
        $0.end = 10; $0.alignments = [0]
        $0.rows = [
          .with { $0.end = 4; $0.contentEnd = 3; $0.header = true; $0.cells = [.with { $0.start = 1; $0.end = 2 }] },
          .with { $0.start = 8; $0.end = 10; $0.contentEnd = 10; $0.cells = [.with { $0.start = 9; $0.end = 9 }] },
        ]
      }]
    }
    let value = try layout(pane), row = try XCTUnwrap(value.text.tables.first?.rows.last)
    let caret = try XCTUnwrap(value.text.caret(for: 9))
    XCTAssertTrue(row.cells[0].content.insetBy(dx: -1, dy: -1).contains(caret))
    XCTAssertEqual(value.text.hit(at: CGPoint(x: row.rect.midX, y: row.rect.midY))?.source, 9)
    let fragment = try XCTUnwrap(value.text.fragments.last)
    XCTAssertEqual(fragment.range, NSRange(location: 2, length: 0))
    XCTAssertEqual(fragment.table?.source, 9..<9)
    XCTAssertEqual(CTLineGetGlyphCount(fragment.line), 0)
  }

  func testImageSourcePreviewAndItsMarkupStayInsideTheMeasuredCell() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "compose-table-image-source", withExtension: "pb", subdirectory: "Fixtures"))
    let pane = try WireComposePane(serializedBytes: Data(contentsOf: url)), value = try layout(pane, width: 360)
    let image = try XCTUnwrap(value.text.attachments.first { $0.attachment.preview })
    let cell = value.text.tables[0].rows[1].cells[2]
    let sourceLine = try XCTUnwrap(value.text.fragments.first { $0.table?.row == value.text.tables[0].rows[1].source && $0.table?.column == 2 })
    XCTAssertEqual(sourceLine.rect.minX, cell.content.minX, accuracy: 0.01, "edited markup uses a stable left edge rather than reading alignment")
    XCTAssertTrue(cell.content.insetBy(dx: -1, dy: -1).contains(image.rect))
    let source = try XCTUnwrap(cell.source)
    let rects = value.text.selectionRects(for: source)
    XCTAssertFalse(rects.isEmpty)
    XCTAssertTrue(rects.allSatisfy { cell.content.insetBy(dx: -1, dy: -1).contains($0) })
    let fragments = value.text.fragments.filter { $0.table?.row == value.text.tables[0].rows[1].source && $0.table?.column == 2 }
    XCTAssertEqual(fragments.reduce(0) { $0 + $1.range.length }, try XCTUnwrap(cell.display).length,
      "wrapping carries trailing spaces without dropping any source markup")
    let end = try XCTUnwrap(value.text.caret(for: source.upperBound, affinity: .upstream))
    XCTAssertTrue(cell.content.insetBy(dx: -1, dy: -1).contains(end))
    let hit = try XCTUnwrap(value.text.hit(at: CGPoint(x: image.rect.minX + 1, y: image.rect.midY)))
    XCTAssertEqual(hit.attachment, image.attachment.source)
    XCTAssertEqual(value.pane.text, pane.text)
    try render(value, environment: "FC_COMPOSE_TABLE_SOURCE_PREVIEW_FILE")
  }

  func testWrappedSpacesRemainAddressableInsideTheirCell() throws {
    let source = "aaaa aaaa ", end = UInt64(source.utf8.count)
    let pane = WireComposePane.with {
      $0.text = source; $0.sourceEnd = end; $0.documentLen = end
      $0.segments = [.with { $0.sourceEnd = end; $0.displayEnd = end }]
      $0.tables = [.with { $0.end = end; $0.alignments = [0]
        $0.rows = [.with { $0.end = end; $0.contentEnd = end; $0.cells = [.with { $0.end = end }] }] }]
    }
    let value = try layout(pane, width: 60), cell = value.text.tables[0].rows[0].cells[0]
    let bounds = cell.content.insetBy(dx: -0.001, dy: -0.001)
    XCTAssertTrue(value.text.selectionRects(for: 0..<Int(end)).allSatisfy { bounds.contains($0) })
    for source in 0...Int(end) {
      XCTAssertTrue(bounds.contains(try XCTUnwrap(value.text.caret(for: source))))
    }
    XCTAssertEqual(value.text.fragments.filter { $0.table != nil }.reduce(0) { $0 + $1.range.length }, source.utf16.count)
  }

  func testDraftAtARowBoundaryHasOneOwnerAndAnEOFInsertionStaysInItsCell() throws {
    let pane = try sourcePane(), next = pane.tables[0].rows[3].start
    let context = try XCTUnwrap(ComposeTextContext(pane.textContext, documentLength: pane.documentLen))
    let start = try XCTUnwrap(context.utf16Position(for: Int(next)))
    let draft = try marked(pane, range: NSRange(location: start, length: 0), text: "ROW_BOUNDARY")
    let value = try layout(pane, composition: try XCTUnwrap(ComposeComposition(primary: 1, values: [1: draft])))
    let display = try XCTUnwrap(value.draftDisplayRange)
    let fragments = value.text.fragments.filter { NSIntersectionRange($0.range, display).length > 0 }
    XCTAssertFalse(fragments.isEmpty)
    XCTAssertTrue(fragments.allSatisfy { $0.table?.row.lowerBound == Int(next) })
    XCTAssertEqual(fragments.reduce(0) { $0 + NSIntersectionRange($1.range, display).length }, display.length)

    let eof = WireComposePane.with {
      $0.text = "A\nx"; $0.sourceEnd = 9; $0.documentLen = 9
      $0.textContext = .with { $0.text = "|A|\n|-|\nx"; $0.selectionStart = 9; $0.selectionEnd = 9 }
      $0.segments = [
        .with { $0.sourceEnd = 1; $0.kind = 1 },
        .with { $0.sourceStart = 1; $0.sourceEnd = 2; $0.displayEnd = 1 },
        .with { $0.sourceStart = 2; $0.sourceEnd = 3; $0.displayStart = 1; $0.displayEnd = 1; $0.kind = 1 },
        .with { $0.sourceStart = 3; $0.sourceEnd = 4; $0.displayStart = 1; $0.displayEnd = 2 },
        .with { $0.sourceStart = 4; $0.sourceEnd = 8; $0.displayStart = 2; $0.displayEnd = 2; $0.kind = 1 },
        .with { $0.sourceStart = 8; $0.sourceEnd = 9; $0.displayStart = 2; $0.displayEnd = 3 },
      ]
      $0.tables = [.with {
        $0.end = 9; $0.alignments = [0]
        $0.rows = [
          .with { $0.end = 4; $0.contentEnd = 3; $0.header = true; $0.cells = [.with { $0.start = 1; $0.end = 2 }] },
          .with { $0.start = 8; $0.end = 9; $0.contentEnd = 9; $0.cells = [.with { $0.start = 8; $0.end = 9 }] },
        ]
      }]
    }
    let end = try marked(eof, range: NSRange(location: 9, length: 0), text: "EOF_DRAFT")
    let inserted = try layout(eof, composition: try XCTUnwrap(ComposeComposition(primary: 1, values: [1: end])))
    let cell = try XCTUnwrap(inserted.text.tables.first?.rows.last?.cells.first?.display)
    let selection = try XCTUnwrap(inserted.draftDisplayRange)
    XCTAssertLessThanOrEqual(cell.location, selection.location)
    XCTAssertGreaterThanOrEqual(NSMaxRange(cell), NSMaxRange(selection))
  }
}
