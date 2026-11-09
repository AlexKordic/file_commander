import XCTest
import CoreText
@testable import FreshKit

final class ComposeIntervalIndexTests: XCTestCase {
  func testNestedOverlappingAndDisjointIntervalsKeepOriginalIdentitiesAndHalfOpenEdges() {
    let index = ComposeIntervalIndex([0..<10000, 100..<110, 10..<20, 0..<0, 105..<120, 100..<110, 9000..<9010])
    XCTAssertEqual(Set(index.matches(at: 0)), [0])
    XCTAssertEqual(Set(index.matches(at: 15)), [0, 2])
    XCTAssertEqual(Set(index.matches(at: 20)), [0])
    XCTAssertEqual(Set(index.matches(at: 105)), [0, 1, 4, 5])
    XCTAssertEqual(Set(index.matches(at: 110)), [0, 4])
    XCTAssertEqual(Set(index.matches(at: 9009)), [0, 6])
    XCTAssertEqual(Set(index.matches(at: 9010)), [0])
    XCTAssertTrue(index.matches(at: -1).isEmpty); XCTAssertTrue(index.matches(at: 10000).isEmpty)
    XCTAssertTrue(ComposeIntervalIndex([]).matches(at: 0).isEmpty)
  }

  func testEqualParagraphRangesKeepTheirOriginalStylePrecedence() throws {
    let text = "first\nsecond\n", end = text.utf8.count
    let projection = try XCTUnwrap(ComposeProjection(source: 0..<end, text: text,
      segments: [.init(source: 0..<end, display: 0..<end, kind: .copy)]))
    let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
    let first = ComposeTextLayout.ParagraphRun(display: 0..<end, indent: 10, before: 20, after: 30)
    let fallback = ComposeTextLayout.ParagraphRun(display: 0..<end, indent: 90, before: 99, after: 99)
    let layout = try XCTUnwrap(ComposeTextLayout(projection: projection, font: font, width: 320, paragraphs: [first, fallback]))
    let reference = try XCTUnwrap(ComposeTextLayout(projection: projection, font: font, width: 320, paragraphs: [first]))
    XCTAssertEqual(layout.fragments.map(\.rect), reference.fragments.map(\.rect))
    XCTAssertEqual(layout.size, reference.size)
    XCTAssertEqual(layout.fragments.first?.rect.minX, 10)
    XCTAssertEqual(layout.fragments.first?.rect.minY, 20)
  }
}
