import XCTest
import CoreText
import ImageIO
@testable import FreshKit

final class ComposeTests: XCTestCase {
  func testTextServiceRangesPreserveConcealedMarkupAndRejectPartialSurrogates() throws {
    let body = "café 👩🏽‍💻", source = "**\(body)**"
    let end = body.utf8.count + 2
    let projection = try XCTUnwrap(ComposeProjection(source: 0..<source.utf8.count, text: body, segments: [
      .init(source: 0..<2, display: 0..<0, kind: .hidden),
      .init(source: 2..<end, display: 0..<body.utf8.count, kind: .copy),
      .init(source: end..<source.utf8.count, display: body.utf8.count..<body.utf8.count, kind: .hidden),
    ]))
    let layout = try XCTUnwrap(ComposeTextLayout(projection: projection, font: font(22), width: 160))
    XCTAssertEqual(layout.sourceRange(forUTF16: NSRange(location: 0, length: body.utf16.count)), 2..<end)
    XCTAssertEqual(layout.sourceRange(forUTF16: NSRange(location: body.utf16.count, length: 0), insertion: end), end..<end)
    XCTAssertNil(layout.sourceRange(forUTF16: NSRange(location: 6, length: 1)))
    XCTAssertNil(layout.sourceRange(forUTF16: NSRange(location: NSNotFound, length: 0)))
    XCTAssertNil(layout.sourceRange(forUTF16: NSRange(location: 1, length: Int.max)))
    let area = try XCTUnwrap(layout.firstRect(forUTF16: NSRange(location: 0, length: body.utf16.count)))
    XCTAssertEqual(area.rect.minY, layout.fragments[0].rect.minY)
    XCTAssertEqual(area.range.location, 0)
    XCTAssertLessThanOrEqual(NSMaxRange(area.range), layout.fragments[0].contentEnd)
  }
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

  func testParagraphSpacingAndNestedIndentsShareCaretHitSelectionAndNavigationGeometry() throws {
    let quote = "Quoted café 👩🏽‍💻 words that wrap across the available width and remain editable.\r\n"
    let source = quote + "\r\nNested item with more words to wrap.\r\n"
    var pane = wirePane(source)
    pane.spans = [
      .with { $0.end = UInt64(quote.utf8.count); $0.role = 9 },
      .with { $0.end = UInt64(quote.utf8.count); $0.role = 11 },
      .with { $0.start = UInt64(quote.utf8.count + 2); $0.end = pane.sourceEnd; $0.role = 10 },
      .with { $0.start = UInt64(quote.utf8.count + 2); $0.end = pane.sourceEnd; $0.role = 10 },
      .with { $0.start = UInt64(quote.utf8.count + 2); $0.end = pane.sourceEnd; $0.role = 13 },
    ]
    let mono = CTFontCreateWithName("Menlo" as CFString, 16, nil)
    let base = try XCTUnwrap(ComposePaneLayout(pane: pane, body: font(16), monospace: mono, width: 190,
      typography: .init(paragraphSpacing: 0)))
    let spaced = try XCTUnwrap(ComposePaneLayout(pane: pane, body: font(16), monospace: mono, width: 190,
      typography: .init(paragraphSpacing: 14)))
    XCTAssertEqual(spaced.text.size.height - base.text.size.height, 14, accuracy: 0.001,
      "paragraph spacing applies once at the block edge, not at every soft wrap")
    XCTAssertEqual(spaced.text.fragments[0].rect.minX, 24)
    let nested = try XCTUnwrap(spaced.text.caret(for: quote.utf8.count + 2))
    XCTAssertEqual(nested.minX, 48)
    let café = source[..<source.range(of: "café")!.lowerBound].utf8.count
    let caret = try XCTUnwrap(spaced.text.caret(for: café))
    XCTAssertEqual(spaced.text.sourcePosition(at: CGPoint(x: caret.minX + 0.01, y: caret.midY)), café)
    XCTAssertEqual(spaced.text.selectionRects(for: 0..<quote.utf8.count).first?.minX, 24)
    let navigation = try XCTUnwrap(spaced.text.navigation(id: 8, pageHeight: 500, documentLength: pane.documentLen, positions: [0]))
    for line in navigation.lines {
      for stop in line.stops {
        let caret = try XCTUnwrap(spaced.text.caret(for: Int(stop.source), affinity: stop.affinity == 1 ? .upstream : .downstream))
        XCTAssertEqual(Double(caret.minX), stop.x, accuracy: 0.001)
      }
    }
    XCTAssertEqual(spaced.text.projection.text, source)
  }

  func testListContinuationsUseTheShapedPrefixAndPreserveSourceCaretGeometry() throws {
    for prefix in ["• ", "100. ", "> 12. [ ] ", "    + "] {
      let source = prefix + "Wide café 👩🏽‍💻 words with enough text to wrap across several measured rows and remain editable.\r\n"
      for size: CGFloat in [12, 22] {
        var pane = wirePane(source)
        let marker = prefix.hasPrefix(">") ? 2 : prefix.hasPrefix("    ") ? 4 : 0
        pane.spans = [10, 13].map { role in .with {
          $0.start = UInt64(marker); $0.end = pane.sourceEnd; $0.role = UInt32(role)
          if role == 13 { $0.contentStart = UInt64(prefix.utf8.count) }
        } }
        if prefix.hasPrefix(">") { pane.spans.append(.with { $0.end = pane.sourceEnd; $0.role = 9 }) }
        let layout = try XCTUnwrap(ComposePaneLayout(pane: pane, body: font(size), monospace: font(size), width: 220))
        let body = try XCTUnwrap(layout.text.caret(for: prefix.utf8.count))
        XCTAssertGreaterThan(layout.text.fragments.count, 3)
        for fragment in layout.text.fragments.dropFirst() where fragment.range.length > 0 {
          XCTAssertEqual(fragment.rect.minX, body.minX, accuracy: 0.001, "\(prefix), \(size)")
          let hit = try XCTUnwrap(layout.text.hit(at: CGPoint(x: fragment.rect.minX + 0.01, y: fragment.rect.midY)))
          let caret = try XCTUnwrap(layout.text.caret(for: hit.source, affinity: hit.affinity))
          XCTAssertEqual(caret.minX, fragment.rect.minX, accuracy: 0.001)
        }
        let navigation = try XCTUnwrap(layout.text.navigation(id: 1, pageHeight: 1000, documentLength: pane.documentLen, positions: [0]))
        for line in navigation.lines {
          for stop in line.stops {
            let caret = try XCTUnwrap(layout.text.caret(for: Int(stop.source), affinity: stop.affinity == 1 ? .upstream : .downstream))
            XCTAssertEqual(Double(caret.minX), stop.x, accuracy: 0.001)
          }
        }
        XCTAssertEqual(layout.text.projection.text, source)
      }
    }
  }

  func testPhysicalContinuationWhitespaceIsNotChargedTwice() throws {
    let source = "100. First line\n     Physical continuation with words that wrap across the remaining measured width.\n"
    var pane = wirePane(source)
    pane.spans = [10, 13].map { role in .with { $0.end = pane.sourceEnd; $0.role = UInt32(role)
      if role == 13 { $0.contentStart = 5 } } }
    let layout = try XCTUnwrap(ComposePaneLayout(pane: pane, body: font(16), monospace: font(16), width: 260))
    let first = try XCTUnwrap(layout.text.caret(for: 5))
    let physical = source[..<source.range(of: "Physical")!.lowerBound].utf8.count
    XCTAssertEqual(try XCTUnwrap(layout.text.caret(for: physical)).minX, first.minX, accuracy: 0.001)
    for fragment in layout.text.fragments.dropFirst(2) where fragment.range.length > 0 {
      XCTAssertEqual(fragment.rect.minX, first.minX, accuracy: 0.001)
    }
  }

  func testRealFreshListSceneKeepsWrappedBodiesAndInlineImagesWithinTheMeasure() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/compose-lists", withExtension: "pb"))
    let pane = try WireComposePane(serializedBytes: Data(contentsOf: url))
    let items = pane.spans.filter { $0.role == 13 && $0.hasContentStart }
    XCTAssertEqual(items.count, 5)
    for width: CGFloat in [260, 520] {
      let layout = try XCTUnwrap(ComposePaneLayout(pane: pane, body: font(16), monospace: font(16), width: width))
      for item in items {
        let body = try XCTUnwrap(layout.text.caret(for: Int(item.contentStart)))
        let display = try XCTUnwrap(layout.text.projection.displayPosition(for: Int(item.contentStart)))
        let bytes = Array(layout.text.projection.text.utf8)
        let end = bytes[display...].firstIndex(where: { $0 == 10 || $0 == 13 }) ?? bytes.count
        let end16 = String(decoding: bytes[..<end], as: UTF8.self).utf16.count
        let index = try XCTUnwrap(layout.text.fragments.firstIndex { $0.rect.minY == body.minY })
        let following = layout.text.fragments.dropFirst(index + 1).prefix { $0.range.location < end16 }
        XCTAssertFalse(following.isEmpty, "fixture item must exercise soft wrapping")
        for fragment in following { XCTAssertEqual(fragment.rect.minX, body.minX, accuracy: 0.001) }
      }
      for placed in layout.text.attachments {
        XCTAssertGreaterThanOrEqual(placed.rect.minX, 0)
        XCTAssertLessThanOrEqual(placed.rect.maxX, width + 0.001)
      }
      if width == 520, let path = ProcessInfo.processInfo.environment["FC_COMPOSE_LIST_PREVIEW_FILE"] {
        let w = 568, h = Int(ceil(layout.text.size.height)) + 48
        let context = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(h)); context.scaleBy(x: 1, y: -1)
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        layout.draw(in: context, origin: CGPoint(x: 24, y: 24), clip: bounds, dirty: bounds,
          foreground: CGColor(gray: 0.1, alpha: 1), background: CGColor(gray: 1, alpha: 1), selection: CGColor(gray: 0.5, alpha: 1))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
      }
    }
  }

  func testRealFreshOrnamentsUseMeasuredRulesAndContinuousQuoteRails() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/compose-ornaments", withExtension: "pb"))
    let pane = try WireComposePane(serializedBytes: Data(contentsOf: url))
    XCTAssertFalse(pane.text.contains("─")); XCTAssertFalse(pane.text.contains("▌"))
    XCTAssertFalse(pane.text.contains("--------------"))
    XCTAssertTrue(pane.text.contains("Setext title\r\n\r\n"))
    XCTAssertTrue(pane.text.contains("> literal code"))
    for width: CGFloat in [240, 520] {
      let mono = CTFontCreateWithName("Menlo" as CFString, 16, nil)
      let layout = try XCTUnwrap(ComposePaneLayout(pane: pane, body: font(16), monospace: mono, width: width))
      XCTAssertEqual(layout.thematicRules.count, 3)
      XCTAssertEqual(layout.quoteRails.count, 2, "one continuous rail per parsed quote level")
      XCTAssertEqual(Set(layout.thematicRules.map { $0.rect.minY }).count, 3)
      for rule in layout.thematicRules {
        XCTAssertEqual(rule.rect.height, 1)
        XCTAssertLessThanOrEqual(rule.rect.maxX, width)
        XCTAssertGreaterThanOrEqual(rule.rect.minX, 0)
        let row = try XCTUnwrap(layout.text.fragments.first { $0.rect.contains(CGPoint(x: rule.rect.midX, y: rule.rect.midY)) })
        XCTAssertEqual(row.contentEnd, row.range.location, "a thematic rule has its own line instead of sharing a code/text row")
        let source = try XCTUnwrap(layout.text.sourcePosition(at: CGPoint(x: rule.rect.midX, y: rule.rect.midY)))
        XCTAssertTrue(rule.source.contains(source) || source == rule.source.upperBound,
          "the native rule occupies a source-mapped line, not a separate fake row")
      }
      let codeByte = pane.text[..<pane.text.range(of: "literal code")!.lowerBound].utf8.count
      let source = try XCTUnwrap(layout.text.projection.sourcePosition(at: codeByte))
      let caret = try XCTUnwrap(layout.text.caret(for: source))
      XCTAssertTrue(layout.quoteRails[0].contains(CGPoint(x: layout.quoteRails[0].midX, y: caret.midY)),
        "a line consisting only of monospace code still has its enclosing quote rail")
      if width == 520, let path = ProcessInfo.processInfo.environment["FC_COMPOSE_ORNAMENT_PREVIEW_FILE"] {
        let w = 568, h = Int(ceil(layout.text.size.height)) + 48
        let context = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(h)); context.scaleBy(x: 1, y: -1)
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        layout.draw(in: context, origin: CGPoint(x: 24, y: 24), clip: bounds, dirty: bounds,
          foreground: CGColor(gray: 0.1, alpha: 1), background: CGColor(gray: 1, alpha: 1), selection: CGColor(gray: 0.5, alpha: 1))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
      }
    }
    // Revealed or failed-formatting source is not painted over with a rule.
    var revealed = wirePane("***\r\n")
    revealed.spans = [.with { $0.end = 3; $0.role = 14 }]
    let layout = try XCTUnwrap(ComposePaneLayout(pane: revealed, body: font(16), monospace: font(16), width: 240))
    XCTAssertTrue(layout.thematicRules.isEmpty)
    XCTAssertEqual(layout.text.projection.text, "***\r\n")
  }

  func testAllHeadingScalesAndSpacingInvalidateLayoutWithoutChangingSource() throws {
    let source = (1...6).map { "Heading \($0)\r\n" }.joined()
    var pane = wirePane(source), offset: UInt64 = 0
    pane.spans = (1...6).map { level in
      let length = UInt64("Heading \(level)\r\n".utf8.count)
      defer { offset += length }
      return .with { $0.start = offset; $0.end = offset + length; $0.role = UInt32(level) }
    }
    let mono = CTFontCreateWithName("Menlo" as CFString, 16, nil)
    let original = try XCTUnwrap(ComposePaneLayout(pane: pane, body: font(16), monospace: mono, width: 400))
    let scales: [CGFloat] = [2.4, 2, 1.8, 1.6, 1.4, 1.2]
    let changed = try XCTUnwrap(ComposePaneLayout(pane: pane, body: font(16), monospace: mono, width: 400,
      typography: .init(headingScales: scales, lineSpacing: 7), reuse: original))
    XCTAssertFalse(original.text === changed.text)
    for (fragment, scale) in zip(changed.text.fragments, scales) {
      let run = try XCTUnwrap((CTLineGetGlyphRuns(fragment.line) as! [CTRun]).first)
      let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
      XCTAssertEqual(CTFontGetSize(font), 16 * scale, accuracy: 0.001)
      XCTAssertTrue(CTFontGetSymbolicTraits(font).contains(.traitBold))
    }
    XCTAssertEqual(changed.text.projection.text, source)
    XCTAssertNil(ComposePaneLayout(pane: pane, body: font(16), monospace: mono, width: 400,
      typography: .init(headingScales: [1])))
  }

  func testNativeDrawPaintsLinkColorAndTextDecorationsInLightAndDarkAppearances() throws {
    let source = "Linked words and struck words\n"
    var pane = wirePane(source)
    pane.spans = [.with { $0.end = 12; $0.flags = 4 | 16 }, .with { $0.start = 17; $0.end = 29; $0.flags = 8 }]
    let layout = try XCTUnwrap(ComposePaneLayout(pane: pane, body: font(20), monospace: font(20), width: 360))
    let link = CGColor(red: 0.1, green: 0.35, blue: 0.95, alpha: 1)
    for dark in [false, true] {
      let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 80, bitsPerComponent: 8,
        bytesPerRow: 1600, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.translateBy(x: 0, y: 80); context.scaleBy(x: 1, y: -1)
      let foreground = CGColor(gray: dark ? 0.95 : 0.05, alpha: 1), background = CGColor(gray: dark ? 0.05 : 1, alpha: 1)
      let bounds = CGRect(x: 0, y: 0, width: 400, height: 80)
      layout.draw(in: context, origin: CGPoint(x: 12, y: 12), clip: bounds, dirty: bounds, foreground: foreground,
        background: background, selection: foreground,
        palette: .init(link: link, quote: foreground, code: foreground, codeBackground: background))
      if let path = ProcessInfo.processInfo.environment["FC_COMPOSE_STYLE_PREVIEW"] {
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: path + (dark ? "-dark.png" : "-light.png")) as CFURL,
          "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
      }
      let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
      let blue = (0..<(400 * 80)).filter { pixels[$0 * 4 + 2] > 180 && Int(pixels[$0 * 4 + 2]) > Int(pixels[$0 * 4]) + 50 }.count
      XCTAssertGreaterThan(blue, 100, "link text and its underline use the theme color")
      let fragment = layout.text.fragments[0]
      let underline = Int(12 + fragment.baseline - CTFontGetUnderlinePosition(font(20)))
      let strike = Int(12 + fragment.baseline - CTFontGetXHeight(font(20)) * 0.5)
      func painted(at x: Int, y: Int) -> Bool {
        let index = (y * 400 + x) * 4
        return dark ? pixels[index] > 180 : pixels[index] < 80
      }
      XCTAssertTrue((underline...underline + 2).contains { y in
        let index = (y * 400 + 25) * 4
        return pixels[index + 2] > 180 && Int(pixels[index + 2]) > Int(pixels[index]) + 50
      }, "the underline is painted below the baseline")
      let struck = try XCTUnwrap(layout.text.caret(for: 17))
      XCTAssertTrue((strike...strike + 2).contains { painted(at: Int(12 + struck.minX + 2), y: $0) }, "strikethrough is painted across the run")
    }
  }

  func testSemanticTypographyRendersThroughTheNativeDrawingPath() throws {
    let source = "Compose typography\n\nProportional prose with bold and italic, café 👩🏽‍💻.\n\nA smaller heading\n\nlet answer = 42;\n\nQuoted words with a link and removed text.\n\n• A list item with words that wrap across the page while preserving its source mapping.\n"
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
                  span("A smaller heading", role: 2), span("let answer = 42;", role: 7),
                  span("Quoted words with a link and removed text.", role: 9),
                  span("Quoted words with a link and removed text.", role: 11),
                  span("a link", flags: 4 | 16), span("removed text", flags: 8),
                  span("• A list item with words that wrap across the page while preserving its source mapping.", role: 10),
                  span("• A list item with words that wrap across the page while preserving its source mapping.", role: 13)]
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
      selection: CGColor(red: 0.7, green: 0.8, blue: 1, alpha: 1),
      palette: .init(link: CGColor(red: 0.1, green: 0.35, blue: 0.9, alpha: 1), quote: CGColor(gray: 0.4, alpha: 1),
        code: CGColor(gray: 0.15, alpha: 1), codeBackground: CGColor(gray: 0.95, alpha: 1)))
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
