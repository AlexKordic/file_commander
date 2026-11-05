import XCTest
import CoreText
import ImageIO
@testable import FreshKit

final class ComposeTests: XCTestCase {
  func testNavigationFeedbackUsesTheMeasuredCaretAndCompleteUnicodeClusters() throws {
    let value = "Wide heading café 👩🏽‍💻\n\nWi iii WWW e\u{301} body text that wraps."
    let layout = try XCTUnwrap(ComposeTextLayout(projection: try copied(value), font: font(24), width: 170))
    let feedback = try XCTUnwrap(layout.navigation(id: 7, pageHeight: 200, documentLength: UInt64(value.utf8.count), positions: [0]))
    var valid: Set<Int> = [0]
    var byte = 0
    for cluster in value { byte += cluster.utf8.count; valid.insert(byte) }
    XCTAssertEqual(feedback.totalLines, UInt64(layout.fragments.count))
    XCTAssertEqual(feedback.height, Double(layout.size.height))
    for line in feedback.lines {
      XCTAssertGreaterThan(line.height, 24)
      XCTAssertTrue(line.hasStart)
      XCTAssertTrue(line.hasEnd)
      for point in line.stops {
        XCTAssertTrue(valid.contains(Int(point.source)), "interior source grapheme in navigation feedback")
        let affinity: ComposeProjection.Affinity = point.affinity == 1 ? .upstream : .downstream
        let caret = try XCTUnwrap(layout.caret(for: Int(point.source), affinity: affinity))
        XCTAssertEqual(Double(caret.minX), point.x, accuracy: 0.0001)
        XCTAssertEqual(Double(caret.minY), line.y, accuracy: 0.0001)
      }
    }
    let bytes: [UInt8] = try feedback.serializedBytes()
    XCTAssertEqual(try WireComposeLayout(serializedBytes: bytes), feedback)
  }

  func testWrappedLineClickAndNavigationRetainTheirCaretAffinity() throws {
    let layout = try XCTUnwrap(ComposeTextLayout(projection: try copied("a heading that wraps across lines"), font: font(24), width: 120))
    let first = layout.fragments[0], next = layout.fragments[1]
    let end = try XCTUnwrap(layout.hit(at: CGPoint(x: 500, y: first.rect.midY)))
    let start = try XCTUnwrap(layout.hit(at: CGPoint(x: 0, y: next.rect.midY)))
    XCTAssertEqual(end.source, start.source)
    XCTAssertEqual(end.affinity, .upstream)
    XCTAssertEqual(start.affinity, .downstream)
    let feedback = try XCTUnwrap(layout.navigation(id: 9, pageHeight: 100, documentLength: UInt64(layout.projection.source.upperBound), positions: [0]))
    XCTAssertEqual(feedback.lines[0].end.source, feedback.lines[1].start.source)
    XCTAssertEqual(feedback.lines[0].end.affinity, 1)
    XCTAssertEqual(feedback.lines[1].start.affinity, 0)
  }

  func testSparseFeedbackKeepsLineOrdinalsAndRequestsAdditionalPixelRegions() throws {
    let value = (0..<1000).map { "line \($0) some words\n" }.joined()
    let layout = try XCTUnwrap(ComposeTextLayout(projection: try copied(value), font: font(16), width: 300))
    let positions: [UInt64] = [0, UInt64(value.utf8.count)]
    let first = try XCTUnwrap(layout.navigation(id: 1, pageHeight: 100, documentLength: UInt64(value.utf8.count), positions: positions))
    XCTAssertLessThan(first.lines.count, 50, "only nearby geometry crosses the socket")
    XCTAssertEqual(first.totalLines, UInt64(layout.fragments.count))
    XCTAssertTrue(zip(first.lines, first.lines.dropFirst()).contains { $1.number > $0.number + 1 })
    let y = layout.fragments[500].rect.midY
    let requested = try XCTUnwrap(layout.navigation(id: 2, pageHeight: 100, documentLength: UInt64(value.utf8.count), positions: positions, aroundY: y))
    XCTAssertLessThan(requested.lines.count, 80)
    XCTAssertTrue(requested.lines.contains { $0.number == 500 })
    XCTAssertTrue(requested.lines.contains { $0.number == 0 })
  }

  func testPaddingFeedbackContainsOnlyCaretsTheSourceMapCanRepresent() throws {
    let projection = try XCTUnwrap(ComposeProjection(source: 0..<3, text: "    abc   ", segments: [
      .init(source: 0..<0, display: 0..<4, kind: .insertion),
      .init(source: 0..<3, display: 4..<7, kind: .copy),
      .init(source: 3..<3, display: 7..<10, kind: .insertion),
    ]))
    let layout = try XCTUnwrap(ComposeTextLayout(projection: projection, font: font(16), width: 300))
    let feedback = try XCTUnwrap(layout.navigation(id: 1, pageHeight: 100, documentLength: 3, positions: [0]))
    for line in feedback.lines {
      for point in line.stops {
        let caret = try XCTUnwrap(layout.caret(for: Int(point.source), affinity: point.affinity == 1 ? .upstream : .downstream))
        XCTAssertEqual(Double(caret.minX), point.x, accuracy: 0.0001)
      }
    }
  }
  private func wirePane(_ text: String) -> WireComposePane {
    WireComposePane.with {
      $0.text = text
      $0.sourceEnd = UInt64(text.utf8.count)
      $0.documentLen = $0.sourceEnd
      $0.projectionRevision = 1
      if !text.isEmpty {
        $0.segments = [WireComposeSegment.with { $0.sourceEnd = UInt64(text.utf8.count); $0.displayEnd = $0.sourceEnd }]
      }
    }
  }

  func testSemanticTypographyRendersThroughTheNativeDrawingPath() throws {
    let source = "Compose typography\n\nProportional prose with bold and italic, café 👩🏽‍💻.\n\nA smaller heading\n\nlet answer = 42;\n"
    var pane = wirePane(source)
    func span(_ text: String, role: UInt32 = 0, flags: UInt32 = 0) -> WireComposeSpan {
      let range = source.range(of: text)!
      return WireComposeSpan.with {
        $0.start = UInt64(source[..<range.lowerBound].utf8.count)
        $0.end = UInt64(source[..<range.upperBound].utf8.count)
        $0.role = role
        $0.flags = flags
      }
    }
    pane.spans = [span("Compose typography", role: 1), span("bold", flags: 1), span("italic", flags: 2),
                  span("A smaller heading", role: 2), span("let answer = 42;", role: 7)]
    let mono = CTFontCreateWithName("Menlo" as CFString, 16, nil)
    let layout = try XCTUnwrap(ComposePaneLayout(pane: pane, body: font(16), monospace: mono, width: 500))
    XCTAssertGreaterThan(layout.text.fragments[0].rect.height, 29)
    let fonts = layout.text.fragments.flatMap { CTLineGetGlyphRuns($0.line) as! [CTRun] }.map {
      (CTRunGetAttributes($0) as NSDictionary)[kCTFontAttributeName] as! CTFont
    }
    XCTAssertTrue(fonts.contains { CTFontGetSize($0) > 28 })
    XCTAssertTrue(fonts.contains { CTFontGetSymbolicTraits($0).contains(.traitItalic) })
    XCTAssertTrue(fonts.contains { (CTFontCopyPostScriptName($0) as String).contains("Menlo") })
    let width = 560, height = Int(ceil(layout.text.size.height)) + 48
    let context = try XCTUnwrap(CGContext(data: nil, width: width * 2, height: height * 2,
      bitsPerComponent: 8, bytesPerRow: width * 8, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.scaleBy(x: 2, y: 2)
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    layout.draw(in: context, origin: CGPoint(x: 24, y: 24), clip: bounds, dirty: bounds,
      foreground: CGColor(gray: 0.1, alpha: 1), background: CGColor(gray: 1, alpha: 1),
      selection: CGColor(red: 0.7, green: 0.8, blue: 1, alpha: 1))
    let image = try XCTUnwrap(context.makeImage())
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    let ink = (0..<(width * 2 * height * 2)).filter { i in
      pixels[i * 4] < 128 && pixels[i * 4 + 1] < 128 && pixels[i * 4 + 2] < 128
    }.count
    XCTAssertGreaterThan(ink, 2000, "the shared native draw path painted shaped text")
    if let path = ProcessInfo.processInfo.environment["FC_COMPOSE_PREVIEW_FILE"] {
      let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
        "public.png" as CFString, 1, nil))
      CGImageDestinationAddImage(destination, image, nil)
      XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
  }

  func testCursorOnlyFramesReuseLayoutWhileResizeAndTypographyInvalidateIt() throws {
    var pane = wirePane("A heading\nbody")
    pane.spans = [WireComposeSpan.with { $0.end = 9; $0.role = 1 }]
    let mono = CTFontCreateWithName("Menlo" as CFString, 16, nil)
    let first = try XCTUnwrap(ComposePaneLayout(pane: pane, body: font(16), monospace: mono, width: 200))
    pane.cursors = [WireComposeSelection.with { $0.position = 10 }]
    let moved = try XCTUnwrap(ComposePaneLayout(pane: pane, body: font(16), monospace: mono, width: 200, reuse: first))
    XCTAssertTrue(first.text === moved.text)
    let resized = try XCTUnwrap(ComposePaneLayout(pane: pane, body: font(16), monospace: mono, width: 100, reuse: moved))
    XCTAssertFalse(resized.text === moved.text)
    let zoomed = try XCTUnwrap(ComposePaneLayout(pane: pane, body: font(20), monospace: mono, width: 200, reuse: moved))
    XCTAssertFalse(zoomed.text === moved.text)
  }

  func testSelectionUsesWrappedMeasuredLinesAndKeepsUTF8SourceRanges() throws {
    let projection = try copied("Héllo words that wrap on several lines", start: 30)
    let layout = try XCTUnwrap(ComposeTextLayout(projection: projection, font: font(22), width: 130))
    let rects = layout.selectionRects(for: 30..<projection.source.upperBound)
    XCTAssertEqual(rects.count, layout.fragments.count)
    for (rect, line) in zip(rects, layout.fragments) {
      XCTAssertEqual(rect.minY, line.rect.minY)
      XCTAssertEqual(rect.height, line.rect.height)
      XCTAssertGreaterThan(rect.width, 0)
    }
    XCTAssertTrue(layout.selectionRects(for: 31..<31).isEmpty)
  }

  func testWireProjectionRefusesUnknownKindsAndUnrepresentableCoordinates() {
    var pane = wirePane("ok")
    pane.segments[0].kind = 99
    XCTAssertNil(ComposeProjection(pane))
    pane = wirePane("ok")
    pane.sourceEnd = UInt64.max
    XCTAssertNil(ComposeProjection(pane))
  }
  func testInsertedPaddingKeepsCopiedTextAndBothBoundaryAffinities() throws {
    let projection = try XCTUnwrap(ComposeProjection(source: 40..<43, text: "    abc   ", segments: [
      .init(source: 40..<40, display: 0..<4, kind: .insertion),
      .init(source: 40..<43, display: 4..<7, kind: .copy),
      .init(source: 43..<43, display: 7..<10, kind: .insertion),
    ]))
    XCTAssertEqual(projection.sourcePosition(at: 5), 41)
    XCTAssertEqual(projection.sourcePosition(at: 2), 40)
    XCTAssertEqual(projection.sourcePosition(at: 9), 43)
    XCTAssertEqual(projection.displayPosition(for: 40, affinity: .upstream), 0)
    XCTAssertEqual(projection.displayPosition(for: 40, affinity: .downstream), 4)
    XCTAssertEqual(projection.displayPosition(for: 43, affinity: .upstream), 7)
    XCTAssertEqual(projection.displayPosition(for: 43, affinity: .downstream), 10)
  }
  private func copied(_ text: String, start: Int = 0) throws -> ComposeProjection {
    try XCTUnwrap(ComposeProjection(source: start..<(start + text.utf8.count), text: text,
      segments: text.isEmpty ? [] : [.init(source: start..<(start + text.utf8.count), display: 0..<text.utf8.count, kind: .copy)]))
  }

  private func font(_ size: CGFloat) -> CTFont { CTFontCreateWithName("Helvetica" as CFString, size, nil) }

  func testHiddenHeadingAndEmphasisRetainTheirSourceEdges() throws {
    // Same projection contract exercised by fresh-core's Rust tests.
    let text = "Héllo world\r\n"
    let p = try XCTUnwrap(ComposeProjection(source: 100..<121, text: text, segments: [
      .init(source: 100..<103, display: 0..<0, kind: .hidden),
      .init(source: 103..<110, display: 0..<7, kind: .copy),
      .init(source: 110..<112, display: 7..<7, kind: .hidden),
      .init(source: 112..<117, display: 7..<12, kind: .copy),
      .init(source: 117..<119, display: 12..<12, kind: .hidden),
      .init(source: 119..<121, display: 12..<14, kind: .copy),
    ]))
    XCTAssertEqual(p.sourcePosition(at: 0, affinity: .upstream), 100)
    XCTAssertEqual(p.sourcePosition(at: 0), 103)
    XCTAssertEqual(p.sourcePosition(at: 7, affinity: .upstream), 110)
    XCTAssertEqual(p.sourcePosition(at: 7), 112)
    XCTAssertNil(p.sourcePosition(at: 2)) // Middle of é.
    XCTAssertEqual(p.text, text)
  }

  func testMalformedProjectionCannotBeUsedToAddressTheBuffer() {
    XCTAssertNil(ComposeProjection(source: 10..<12, text: "é", segments: [
      .init(source: 10..<11, display: 0..<1, kind: .copy),
      .init(source: 11..<12, display: 1..<2, kind: .copy),
    ]))
    XCTAssertNil(ComposeProjection(source: 0..<3, text: "abc", segments: [
      .init(source: 0..<2, display: 0..<2, kind: .copy),
    ]))
    XCTAssertNil(ComposeProjection(source: 0..<3, text: "abc", segments: [
      .init(source: 0..<2, display: 0..<2, kind: .copy),
      .init(source: 1..<3, display: 2..<3, kind: .copy),
    ]))
  }

  func testLargerHeadingUsesMeasuredHeightAndWrapsAtItsOwnFontSize() throws {
    let text = "A heading with enough words to wrap over several lines"
    let projection = try copied(text)
    let body = try XCTUnwrap(ComposeTextLayout(projection: projection, font: font(14), width: 180))
    let heading = try XCTUnwrap(ComposeTextLayout(projection: projection, font: font(28), width: 180))
    XCTAssertGreaterThan(heading.fragments.count, body.fragments.count)
    XCTAssertGreaterThan(heading.fragments[0].rect.height, body.fragments[0].rect.height)
    XCTAssertGreaterThan(heading.size.height, body.size.height)
    for fragment in heading.fragments {
      XCTAssertGreaterThan(fragment.rect.height, 28)
      let width = CTLineGetTypographicBounds(fragment.line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(fragment.line)
      XCTAssertLessThanOrEqual(width, 181)
    }
  }

  func testProportionalHitTestingReturnsSourceBytesAtDifferentFontSizes() throws {
    let projection = try copied("Wi Wi café", start: 40)
    for size: CGFloat in [14, 28] {
      let layout = try XCTUnwrap(ComposeTextLayout(projection: projection, font: font(size), width: 400))
      let afterW = try XCTUnwrap(layout.caret(for: 41))
      let afterI = try XCTUnwrap(layout.caret(for: 42))
      XCTAssertGreaterThan(afterW.minX, afterI.minX - afterW.minX)
      for byte in [40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 51] {
        let caret = try XCTUnwrap(layout.caret(for: byte))
        XCTAssertEqual(layout.sourcePosition(at: CGPoint(x: caret.minX, y: caret.midY)), byte)
      }
    }
  }

  func testWrappingAffinitiesHaveDifferentGeometryForTheSameSourceCaret() throws {
    let projection = try copied("A long heading that wraps to several lines")
    let layout = try XCTUnwrap(ComposeTextLayout(projection: projection, font: font(24), width: 150))
    XCTAssertGreaterThan(layout.fragments.count, 1)
    let boundary = layout.fragments[1].range.location // ASCII: UTF-16 equals UTF-8.
    let before = try XCTUnwrap(layout.caret(for: boundary, affinity: .upstream))
    let after = try XCTUnwrap(layout.caret(for: boundary, affinity: .downstream))
    XCTAssertGreaterThan(after.minY, before.minY)
    XCTAssertLessThan(after.minX, before.minX)
  }

  func testCRLFAndTrailingEmptyLineHaveDistinctCaretPositions() throws {
    let projection = try copied("one\r\ntwo\r\n", start: 12)
    let layout = try XCTUnwrap(ComposeTextLayout(projection: projection, font: font(16), width: 300))
    XCTAssertEqual(layout.fragments.count, 3)
    XCTAssertEqual(layout.fragments.map(\.contentEnd), [3, 8, 10])
    XCTAssertEqual(layout.sourcePosition(at: CGPoint(x: 250, y: layout.fragments[0].rect.midY)), 15)
    let final = try XCTUnwrap(layout.caret(for: 22))
    XCTAssertEqual(final.minY, layout.fragments[2].rect.minY)
    XCTAssertEqual(layout.sourcePosition(at: CGPoint(x: 0, y: final.midY)), 22)
  }

  func testEmojiAndCombiningSequencesNeverProduceAnInteriorCaretOnHit() throws {
    let text = "a 👩🏽‍💻 e\u{301} z"
    let layout = try XCTUnwrap(ComposeTextLayout(projection: try copied(text), font: font(18), width: 400))
    var boundaries: Set<Int> = [0]
    var byte = 0
    for grapheme in text {
      byte += grapheme.utf8.count
      boundaries.insert(byte)
    }
    let end = try XCTUnwrap(layout.caret(for: text.utf8.count)).minX
    for x in stride(from: CGFloat(0), through: end, by: 0.5) {
      let hit = try XCTUnwrap(layout.sourcePosition(at: CGPoint(x: x, y: 5)))
      XCTAssertTrue(boundaries.contains(hit), "Interior grapheme caret at byte \(hit), x=\(x)")
    }
  }

  func testEmptyParagraphStillHasAnEditableLine() throws {
    let layout = try XCTUnwrap(ComposeTextLayout(projection: try copied("", start: 90), font: font(16), width: 300))
    XCTAssertEqual(layout.fragments.count, 1)
    XCTAssertGreaterThan(layout.size.height, 0)
    XCTAssertEqual(layout.sourcePosition(at: CGPoint(x: 10, y: 4)), 90)
    XCTAssertNotNil(layout.caret(for: 90))
  }

  func testMixedFontRunsUseUTF8RangesAndAffectTheMeasuredLine() throws {
    let text = "é BIG text"
    let projection = try copied(text)
    let body = try XCTUnwrap(ComposeTextLayout(projection: projection, font: font(14), width: 400))
    let mixed = try XCTUnwrap(ComposeTextLayout(projection: projection, font: font(14), width: 400,
      fonts: [.init(display: 3..<6, font: font(30))]))
    XCTAssertGreaterThan(mixed.size.height, body.size.height)
    XCTAssertGreaterThan(try XCTUnwrap(mixed.caret(for: 6)).minX, try XCTUnwrap(body.caret(for: 6)).minX)
    XCTAssertNil(ComposeTextLayout(projection: projection, font: font(14), width: 400,
      fonts: [.init(display: 1..<3, font: font(30))]))
  }

  func testNarrowWrappingNeverSplitsAComposedCharacter() throws {
    let text = "👩🏽‍💻e\u{301}z"
    let projection = try copied(text)
    let layout = try XCTUnwrap(ComposeTextLayout(projection: projection, font: font(18), width: 1))
    var valid: Set<Int> = [0]
    var offset = 0
    for grapheme in text {
      offset += grapheme.utf16.count
      valid.insert(offset)
    }
    for fragment in layout.fragments {
      XCTAssertTrue(valid.contains(fragment.range.location))
      XCTAssertTrue(valid.contains(NSMaxRange(fragment.range)))
    }
    XCTAssertNotNil(layout.caret(for: projection.source.upperBound))
  }
}
