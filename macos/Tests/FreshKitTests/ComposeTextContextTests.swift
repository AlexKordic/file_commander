import XCTest
@testable import FreshKit

final class ComposeTextContextTests: XCTestCase {
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
