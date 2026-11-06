import XCTest
import CoreText
@testable import FreshKit

final class ComposeHangingContextTests: XCTestCase {
  private func pane(_ source: String, prefix: String, first: String, start: Int = 0,
                    physical: Bool = false, styled: Bool = false) -> WireComposePane {
    let text = String(decoding: Array(source.utf8).dropFirst(start), as: UTF8.self)
    return .with {
      $0.sourceStart = UInt64(start); $0.sourceEnd = UInt64(source.utf8.count); $0.documentLen = $0.sourceEnd
      $0.text = text
      $0.segments = [.with { $0.sourceStart = UInt64(start); $0.sourceEnd = UInt64(source.utf8.count); $0.displayEnd = UInt64(text.utf8.count) }]
      $0.spans = [10, 13].map { role in .with {
        $0.end = UInt64(source.utf8.count); $0.role = UInt32(role)
        if role == 13 { $0.contentStart = UInt64(prefix.utf8.count) }
      } }
      if styled { $0.spans.append(.with { $0.start = UInt64(prefix.utf8.count); $0.end = UInt64(source.utf8.count); $0.role = 1; $0.flags = 3 }) }
      $0.hangingContexts = [.with {
        $0.contentStart = UInt64(prefix.utf8.count); $0.text = prefix + first
        $0.prefixEnd = UInt64(prefix.utf8.count); $0.sourceLineStart = physical
        if styled { $0.spans = [.with { $0.start = UInt64(prefix.utf8.count); $0.end = UInt64((prefix + first).utf8.count); $0.role = 1; $0.flags = 3 }] }
      }]
    }
  }

  private func layout(_ pane: WireComposePane, size: CGFloat, width: CGFloat) throws -> ComposePaneLayout {
    try XCTUnwrap(ComposePaneLayout(pane: pane, body: CTFontCreateWithName("Helvetica" as CFString, size, nil),
      monospace: CTFontCreateWithName("Menlo" as CFString, size, nil), width: width))
  }

  func testClippedMarkersUseTheSameNativeFontMetricsWithoutAddingSourceText() throws {
    for prefix in ["1) ", "100. ", "    + ", "> 12. [ ] "] {
      for words in ["An ordinary body with words. ", "אבג שלום מילים ", "العربية نص طويل ", "123 אבג words ", "👩🏽‍💻 e\u{301} 東京 words "] {
        let first = String(try XCTUnwrap(words.first))
        let source = prefix + String(repeating: words, count: 12) + "\n"
        let start = prefix.utf8.count + words.utf8.count * 3
        for size: CGFloat in [12, 22] {
          for width: CGFloat in [180, 320] {
            for styled in [false, true] {
              let whole = try layout(pane(source, prefix: prefix, first: first, styled: styled), size: size, width: width)
              let expected = try XCTUnwrap(whole.text.fragments.dropFirst().first { $0.range.length > 0 }).rect.minX
              let clipped = try layout(pane(source, prefix: prefix, first: first, start: start, styled: styled), size: size, width: width)
              XCTAssertGreaterThan(clipped.text.fragments.count, 2)
              for fragment in clipped.text.fragments where fragment.range.length > 0 {
                XCTAssertEqual(fragment.rect.minX, expected, accuracy: 0.001, "\(prefix)\(words), \(size), \(width), styled=\(styled)")
              }
              XCTAssertEqual(clipped.text.projection.text, String(decoding: Array(source.utf8).dropFirst(start), as: UTF8.self))
              XCTAssertNotNil(clipped.text.caret(for: start))
              XCTAssertNil(clipped.text.caret(for: 0))
              if size == 12 && width == 180 && !styled {
                var missing = pane(source, prefix: prefix, first: first, start: start)
                missing.hangingContexts = []
                let unmeasured = try layout(missing, size: size, width: width)
                XCTAssertNotEqual(unmeasured.text.fragments[0].rect.minX, expected,
                  "the test must actually require offscreen prefix context")
              }
            }
          }
        }
      }
    }
  }

  func testClippedPhysicalIndentationIsNotChargedTwice() throws {
    let prefix = "100) ", source = prefix + "First line\r\n     Physical continuation with words that wrap across the remaining width.\r\n"
    let start = source.range(of: "     Physical")!.lowerBound.utf16Offset(in: source)
    let body = start + 5
    let whole = try layout(pane(source, prefix: prefix, first: "F"), size: 18, width: 220)
    let clipped = try layout(pane(source, prefix: prefix, first: "F", start: start, physical: true), size: 18, width: 220)
    XCTAssertEqual(try XCTUnwrap(clipped.text.caret(for: body)).minX, try XCTUnwrap(whole.text.caret(for: body)).minX, accuracy: 0.001)
    let expected = try XCTUnwrap(whole.text.caret(for: prefix.utf8.count)).minX
    for fragment in clipped.text.fragments.dropFirst() where fragment.range.length > 0 {
      XCTAssertEqual(fragment.rect.minX, expected, accuracy: 0.001)
    }
  }

  func testMalformedOrForeignPrefixContextsAreRefused() throws {
    let source = "1) café words that wrap across a page.\n"
    let valid = pane(source, prefix: "1) ", first: "c", start: 8)
    XCTAssertNotNil(try? layout(valid, size: 18, width: 180))
    var cases: [WireComposePane] = []
    var value = valid; value.hangingContexts[0].itemStart = 9; cases.append(value)
    value = valid; value.hangingContexts[0].contentStart = 4; cases.append(value)
    value = valid; value.hangingContexts.append(value.hangingContexts[0]); cases.append(value)
    value = valid; value.hangingContexts[0].text = "1) ca"; cases.append(value)
    value = valid; value.hangingContexts[0].text = "1\nc"; value.hangingContexts[0].prefixEnd = 2; cases.append(value)
    value = valid; value.hangingContexts[0].text = "1) 👩🏽‍💻"; value.hangingContexts[0].prefixEnd = 4; cases.append(value)
    value = valid; value.hangingContexts[0].spans = [.with { $0.start = 1; $0.end = 99 }]; cases.append(value)
    value = valid; value.hangingContexts[0].text = "1) é"; value.hangingContexts[0].spans = [.with { $0.end = 4 }]; cases.append(value)
    for pane in cases {
      XCTAssertNil(ComposePaneLayout(pane: pane, body: CTFontCreateWithName("Helvetica" as CFString, 18, nil),
        monospace: CTFontCreateWithName("Menlo" as CFString, 18, nil), width: 180))
    }
  }

  func testChangedPrefixFontsInvalidateReusedBodyGeometry() throws {
    let source = "100) An ordinary body with enough words to wrap across the remaining width.\n"
    let original = pane(source, prefix: "100) ", first: "A", start: 17)
    let first = try layout(original, size: 18, width: 180)
    var changed = original
    changed.hangingContexts[0].spans = [.with { $0.end = 5; $0.role = 7; $0.flags = 1 }]
    let second = try XCTUnwrap(ComposePaneLayout(pane: changed,
      body: CTFontCreateWithName("Helvetica" as CFString, 18, nil),
      monospace: CTFontCreateWithName("Menlo" as CFString, 18, nil), width: 180, reuse: first))
    XCTAssertNotEqual(second.text.fragments[0].rect.minX, first.text.fragments[0].rect.minX)
    XCTAssertEqual(second.text.projection.text, first.text.projection.text)
  }

  func testRealFreshPrefixSampleKeepsIndentationWhenItsSourceMarkerIsOffscreen() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "compose-lists", withExtension: "pb", subdirectory: "Fixtures"))
    let full = try WireComposePane(serializedBytes: Data(contentsOf: url))
    XCTAssertEqual(full.hangingContexts.count, 5)
    let sample = try XCTUnwrap(full.hangingContexts.last)
    let item = try XCTUnwrap(full.spans.first { $0.role == 13 && $0.start == sample.itemStart })
    let projection = try XCTUnwrap(ComposeProjection(full)), start = Int(item.contentStart)
    let copy = try XCTUnwrap(projection.segments.first { $0.kind == .copy && $0.source.contains(start) })
    let end = min(Int(item.end), copy.source.upperBound)
    XCTAssertGreaterThan(end - start, 80)
    let a = try XCTUnwrap(projection.displayPosition(for: start)), b = try XCTUnwrap(projection.displayPosition(for: end, affinity: .upstream))
    let text = String(decoding: Array(projection.text.utf8)[a..<b], as: UTF8.self)
    XCTAssertEqual(text.utf8.count, end - start)
    var clipped = full
    clipped.sourceStart = UInt64(start); clipped.sourceEnd = UInt64(end); clipped.text = text
    clipped.segments = [.with { $0.sourceStart = UInt64(start); $0.sourceEnd = UInt64(end); $0.displayEnd = UInt64(text.utf8.count) }]
    clipped.spans = full.spans.filter { $0.start < clipped.sourceEnd && $0.end > clipped.sourceStart }
    clipped.hangingContexts = [sample]; clipped.hangingContexts[0].sourceLineStart = false
    clipped.images = []; clipped.tables = []; clipped.cursors = []
    let whole = try layout(full, size: 18, width: 260)
    let window = try layout(clipped, size: 18, width: 260)
    let expected = try XCTUnwrap(whole.text.caret(for: start)).minX
    for fragment in window.text.fragments where fragment.range.length > 0 {
      XCTAssertEqual(fragment.rect.minX, expected, accuracy: 0.001)
    }
    XCTAssertEqual(window.text.projection.text, text)
    XCTAssertNil(window.text.caret(for: Int(item.start)))
  }
}
