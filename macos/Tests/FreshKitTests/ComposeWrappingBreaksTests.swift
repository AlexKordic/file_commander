import XCTest
import CoreText
@testable import FreshKit

final class ComposeWrappingBreaksTests: XCTestCase {
  private let fonts = [CTFontCreateWithName("Helvetica" as CFString, 18, nil),
    CTFontCreateWithName("Menlo" as CFString, 12, nil),
    CTFontCreateWithName("Helvetica-Bold" as CFString, 26, nil)]

  private func styled(_ text: String, variant: Int = 0) -> NSMutableAttributedString {
    let result = NSMutableAttributedString(string: text,
      attributes: [NSAttributedString.Key(kCTFontAttributeName as String): fonts[variant % fonts.count]])
    var from = 0
    for (index, character) in text.enumerated() {
      let count = String(character).utf16.count
      if index % 7 == 0 {
        result.addAttribute(NSAttributedString.Key(kCTFontAttributeName as String),
          value: fonts[(variant + index) % fonts.count], range: NSRange(location: from, length: count))
      }
      from += count
    }
    return result
  }

  private func check(_ attributed: NSAttributedString, widths: [Double], minimumMeasuredBreaks: Int = 0,
                     file: StaticString = #filePath, line: UInt = #line) throws {
    let string = attributed.string as NSString
    let index = try XCTUnwrap(ComposeWrappingBreaks(string), file: file, line: line)
    let typesetter = CTTypesetterCreateWithAttributedString(attributed)
    for width in widths {
      var from = 0
      while from < string.length {
        let expected = CTTypesetterSuggestLineBreak(typesetter, from, width)
        let actual = index.suggest(typesetter, from: from, width: width)
        XCTAssertEqual(actual, expected, "UTF-16 \(from), width \(width)", file: file, line: line)
        // Match the renderer's complete-grapheme overflow policy when the
        // viewport is narrower than one typographic cluster.
        var end = from + max(1, expected)
        if end < string.length {
          let cluster = string.rangeOfComposedCharacterSequence(at: end)
          if cluster.location < end { end = NSMaxRange(cluster) }
        }
        from = end
      }
    }
    XCTAssertGreaterThanOrEqual(index.measuredBreakCount, minimumMeasuredBreaks, file: file, line: line)
  }

  func testLongStyledParagraphsAndNonzeroOffsetsMatchNativeCoreText() throws {
    let body = "An ordinary café 👩🏽‍💻 paragraph continues with proportional words. "
    let source = "café 👩🏽‍💻 before\r\n" + String(repeating: body, count: 100) + "\r\n\n"
      + String(repeating: "漢字かな「括弧」 العربية אבג שלום and more words. ", count: 150) + "\n"
    try check(styled(source), widths: [57, 93, 157, 273, 640, 959])
    let text = styled(source), string = source as NSString
    let index = try XCTUnwrap(ComposeWrappingBreaks(string))
    let typesetter = CTTypesetterCreateWithAttributedString(text)
    for from in [0, 3, string.range(of: "👩🏽‍💻").location, string.range(of: "漢字").location] {
      for width: Double in [1, 12, 19] {
        XCTAssertEqual(index.suggest(typesetter, from: from, width: width),
          CTTypesetterSuggestLineBreak(typesetter, from, width))
      }
    }
  }

  func testSpecialWhitespaceAndControlsKeepNativeContextualBreaks() throws {
    let ordinary = String(repeating: "An ordinary paragraph with words. ", count: 140) + "\r\n"
    for special in ["\u{0000}", "\u{001f}", "\u{007f}", "\t", "\u{00a0}", "\u{202f}", "\u{200b}", "\u{2060}", "\u{00ad}",
                    "\u{2067}אבג\u{2069}", "\u{2028}", "\u{2029}", "\u{0085}"] {
      let source = ordinary + String(repeating: "A\(special) word and more text. ", count: 260) + "\r\n" + ordinary
      try check(styled(source, variant: 1), widths: [19, 93, 273, 640])
    }
  }

  func testSeededMixedScriptsPunctuationAndFontChangesMatchNativeBreaks() throws {
    let pieces = [" ", " ", "👩🏽‍💻", "e\u{301}", "क्षि", "क", "אבג", "العربية", "漢字", "，", "。", "?",
      "longword", "Wii", "A", "–", "—", "…", "👨‍👩‍👧‍👦", "🇺🇸🇷🇸🇫🇷", "abc\u{200d}def", "word-", "xy/", "(foo)"]
    var seed: UInt64 = 0x5eede210
    for variant in 0..<18 {
      var value = ""
      for _ in 0..<100 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        value += pieces[Int((seed >> 32) % UInt64(pieces.count))]
      }
      let source = String(repeating: value, count: 5000 / value.utf16.count + 1) + "\r\n"
      try check(styled(source, variant: variant), widths: [57, 93, 157, 273, 640])
    }
  }

  func testInlineObjectMetricsAndLeadingSpacesMatchNativeBreaks() throws {
    let source = String(repeating: "        Words \u{fffc} with an image and more text. ", count: 180) + "\n"
    let text = styled(source), string = source as NSString
    var callbacks = CTRunDelegateCallbacks(version: kCTRunDelegateCurrentVersion,
      dealloc: { _ in }, getAscent: { _ in 32 }, getDescent: { _ in 0 }, getWidth: { _ in 120 })
    let delegate = try XCTUnwrap(CTRunDelegateCreate(&callbacks, nil))
    var from = 0
    while from < string.length {
      let image = string.range(of: "\u{fffc}", range: NSRange(location: from, length: string.length - from))
      guard image.location != NSNotFound else { break }
      text.addAttribute(NSAttributedString.Key(kCTRunDelegateAttributeName as String), value: delegate, range: image)
      from = NSMaxRange(image)
    }
    try check(text, widths: [19, 93, 157, 273, 640, 959], minimumMeasuredBreaks: 1)
  }

  func testDenseObjectMetricsChangesRetireTheMeasuredTypesetterAndKeepNativeBreaks() throws {
    let source = String(repeating: "office café e\u{301} 👩🏽‍💻 \u{fffc} text following an image. ", count: 180) + "\n"
    let string = source as NSString, index = try XCTUnwrap(ComposeWrappingBreaks(string))
    var setters: [CTTypesetter] = []
    for variant in 0..<3 {
      let text = styled(source, variant: variant)
      var callbacks = CTRunDelegateCallbacks(version: kCTRunDelegateCurrentVersion,
        dealloc: { Unmanaged<NSNumber>.fromOpaque($0).release() }, getAscent: { _ in 32 }, getDescent: { _ in 0 },
        getWidth: { CGFloat(Unmanaged<NSNumber>.fromOpaque($0).takeUnretainedValue().doubleValue) })
      let metrics = Unmanaged.passRetained(NSNumber(value: [32.0, 120, 300][variant])).toOpaque()
      let delegate = try XCTUnwrap(CTRunDelegateCreate(&callbacks, metrics))
      var from = 0
      while from < string.length {
        let image = string.range(of: "\u{fffc}", range: NSRange(location: from, length: string.length - from))
        guard image.location != NSNotFound else { break }
        text.addAttribute(NSAttributedString.Key(kCTRunDelegateAttributeName as String), value: delegate, range: image)
        from = NSMaxRange(image)
      }
      setters.append(CTTypesetterCreateWithAttributedString(text))
    }
    for setter in setters + [setters[0]] {
      for width: Double in [1, 19, 93, 273, 640, 959] {
        var from = 0
        while from < string.length {
          let expected = CTTypesetterSuggestLineBreak(setter, from, width)
          XCTAssertEqual(index.suggest(setter, from: from, width: width), expected, "UTF-16 \(from), width \(width)")
          var end = from + max(1, expected)
          if end < string.length {
            let cluster = string.rangeOfComposedCharacterSequence(at: end)
            if cluster.location < end { end = NSMaxRange(cluster) }
          }
          from = end
        }
      }
    }
    XCTAssertGreaterThan(index.measuredBreakCount, 100)
  }

  func testDenseObjectsWithBidiKeepTheNativeContextualPath() throws {
    let source = String(repeating: "image \u{fffc} العربية אבג and café 👩🏽‍💻 words. ", count: 180) + "\n"
    let text = styled(source), string = source as NSString
    let index = try XCTUnwrap(ComposeWrappingBreaks(string)), setter = CTTypesetterCreateWithAttributedString(text)
    for width: Double in [93, 273, 640] {
      var from = 0
      while from < string.length {
        let expected = CTTypesetterSuggestLineBreak(setter, from, width)
        XCTAssertEqual(index.suggest(setter, from: from, width: width), expected)
        from += max(1, expected)
      }
    }
    XCTAssertEqual(index.measuredBreakCount, 0, "reordered/RTL runs must retain native contextual breaking")
  }
}
