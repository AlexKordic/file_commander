import XCTest
@testable import FreshKit

final class ComposeTextContextTests: XCTestCase {
  func testReusedSourceIndicesKeepSelectionAndRelocatedUnicodeCoordinatesCurrent() throws {
    let original = WireComposeTextContext.with {
      $0.text = "café 👩🏽‍💻 e\u{301} 東京\r\n"; $0.sourceStart = 100; $0.utf16Start = 40
      $0.selectionStart = 40; $0.selectionEnd = 40
    }
    let prior = try XCTUnwrap(ComposeTextContext(original, documentLength: 512))
    var variants = [original]
    var selected = original; selected.selectionStart = 45; selected.selectionEnd = 52; variants.append(selected)
    var moved = selected; moved.sourceStart = 200; moved.utf16Start = 80; moved.selectionStart = 80; moved.selectionEnd = 84; variants.append(moved)
    var changed = original; changed.text = "e\u{301} café 👩🏽‍💻 東京\r\n"; variants.append(changed)
    for wire in variants {
      let fresh = try XCTUnwrap(ComposeTextContext(wire, documentLength: 512))
      let reused = try XCTUnwrap(ComposeTextContext(wire, documentLength: 512, reuse: prior))
      XCTAssertEqual(Array(reused.text.utf8), Array(fresh.text.utf8))
      XCTAssertEqual(reused.source, fresh.source); XCTAssertEqual(reused.range, fresh.range); XCTAssertEqual(reused.selection, fresh.selection)
      for index in fresh.range.location...NSMaxRange(fresh.range) {
        let query = NSRange(location: index, length: 0)
        XCTAssertEqual(reused.sourceRange(forUTF16: query), fresh.sourceRange(forUTF16: query))
      }
      for byte in fresh.source {
        XCTAssertEqual(reused.utf16Position(for: byte), fresh.utf16Position(for: byte))
      }
    }
    XCTAssertEqual(prior.selection, NSRange(location: 40, length: 0), "selection updates cannot mutate the retained source snapshot")
    let longer = try XCTUnwrap(ComposeTextContext(original, documentLength: 1024, reuse: prior))
    XCTAssertNotNil(longer.selecting(NSRange(location: 900, length: 0)), "a new document length must replace the old selection bound")
  }

  func testReusableIndicesDoNotBypassIncomingContextValidation() throws {
    let original = WireComposeTextContext.with { $0.text = "café 👩🏽‍💻"; $0.sourceStart = 100; $0.utf16Start = 40 }
    let prior = try XCTUnwrap(ComposeTextContext(original, documentLength: 512))
    var invalid: [WireComposeTextContext] = []
    var wire = original; wire.selectionStart = 20; wire.selectionEnd = 19; invalid.append(wire)
    wire = original; wire.selectionEnd = 513; invalid.append(wire)
    wire = original; wire.selectionStart = UInt64.max; wire.selectionEnd = UInt64.max; invalid.append(wire)
    wire = original; wire.sourceStart = UInt64.max; invalid.append(wire)
    wire = original; wire.utf16Start = 101; invalid.append(wire)
    wire = original; wire.text = String(repeating: "x", count: 500); invalid.append(wire)
    for wire in invalid {
      XCTAssertNil(ComposeTextContext(wire, documentLength: 512))
      XCTAssertNil(ComposeTextContext(wire, documentLength: 512, reuse: prior))
    }
    XCTAssertNil(ComposeTextContext(original, documentLength: 99, reuse: prior))
  }

  func testDocumentCoordinatesRetainConcealedMarkdownAndCompleteUnicodeClusters() throws {
    let prefix = "👩🏽‍💻 café\r\n", text = "**日本 e\u{301} 👩🏽‍💻**\r\n"
    let base = prefix.utf16.count, start = prefix.utf8.count
    let context = try XCTUnwrap(ComposeTextContext(.with {
      $0.text = text; $0.sourceStart = UInt64(start); $0.utf16Start = UInt64(base)
      $0.selectionStart = UInt64(base + 2); $0.selectionEnd = UInt64(base + 4)
    }, documentLength: UInt64(start + text.utf8.count)))
    XCTAssertEqual(context.selection, NSRange(location: base + 2, length: 2))
    XCTAssertEqual(context.sourceRange(forUTF16: context.selection), (start + 2)..<(start + 8))
    XCTAssertEqual(context.utf16Position(for: start + 8), base + 4)
    let all = try XCTUnwrap(context.substring(forProposedRange: NSRange(location: 0, length: base + text.utf16.count)))
    XCTAssertEqual(all.text, text)
    XCTAssertEqual(all.range, NSRange(location: base, length: text.utf16.count))
    let emoji = try XCTUnwrap(text.range(of: "👩🏽‍💻"))
    let interior = NSRange(emoji, in: text).location + 1
    XCTAssertNil(context.sourceRange(forUTF16: NSRange(location: base + interior, length: 0)))
    let cluster = try XCTUnwrap(context.substring(forProposedRange: NSRange(location: base + interior, length: 1)))
    XCTAssertEqual(cluster.text, "👩🏽‍💻")
    XCTAssertNil(context.substring(forProposedRange: NSRange(location: 0, length: 1)))
    XCTAssertNil(context.substring(forProposedRange: NSRange(location: NSNotFound, length: 0)))
    XCTAssertNil(context.substring(forProposedRange: NSRange(location: base, length: Int.max)))
  }

  func testSelectionMayExtendOutsideTheBoundedContextButUnknownReplacementsAreRefused() throws {
    let context = try XCTUnwrap(ComposeTextContext(.with {
      $0.text = "Tail"; $0.sourceStart = 10_000; $0.utf16Start = 8000
      $0.selectionStart = 0; $0.selectionEnd = 8004
    }, documentLength: 10_004))
    XCTAssertEqual(context.selection, NSRange(location: 0, length: 8004))
    XCTAssertNil(context.sourceRange(forUTF16: context.selection))
    XCTAssertEqual(context.sourceRange(forUTF16: NSRange(location: 8004, length: 0)), 10_004..<10_004)
    XCTAssertNil(context.sourceRange(forUTF16: NSRange(location: 8003, length: Int.max)))
    XCTAssertNil(ComposeTextContext(.with { $0.text = "overflow"; $0.sourceStart = 99 }, documentLength: 100))
    XCTAssertNil(ComposeTextContext(.with { $0.utf16Start = 5; $0.sourceStart = 3 }, documentLength: 100))
    XCTAssertNil(ComposeTextContext(.with { $0.selectionStart = 5; $0.selectionEnd = 4 }, documentLength: 100))
    XCTAssertNil(ComposeTextContext(.with { $0.sourceStart = UInt64.max }, documentLength: UInt64.max))
    XCTAssertNotNil(ComposeTextContext(.init(), documentLength: 0))
  }
}
