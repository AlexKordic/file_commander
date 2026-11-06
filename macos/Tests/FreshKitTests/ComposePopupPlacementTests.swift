import XCTest
@testable import FreshKit

final class ComposePopupPlacementTests: XCTestCase {
  private let cell = CGSize(width: 8, height: 16)
  private let bounds = CGRect(x: 0, y: 0, width: 640, height: 480)
  private var rect: WireRect { .with { $0.x = 3; $0.y = 4; $0.w = 20; $0.h = 6 } }

  func testMeasuredHeadingCaretAndWordShareOneDrawAndPointerTranslation() throws {
    let caret = CGRect(x: 149.25, y: 233.5, width: 1, height: 37.75)
    let word = CGRect(x: 113.75, y: caret.minY, width: 1, height: caret.height)
    let p = try XCTUnwrap(ComposePopupPlacement(rect: rect, cell: cell, within: bounds,
      anchor: caret, horizontal: word, placement: 2))
    XCTAssertEqual(p.frame.minX, word.minX)
    XCTAssertEqual(p.frame.minY, caret.maxY)
    XCTAssertEqual(p.original.origin, CGPoint(x: 24, y: 64))
    let point = CGPoint(x: p.frame.minX + 3.5 * cell.width, y: p.frame.minY + 2.5 * cell.height)
    let local = try XCTUnwrap(p.localCell(at: point))
    XCTAssertEqual(local.column, 3); XCTAssertEqual(local.row, 2)
    XCTAssertTrue(p.contains(point))
    XCTAssertEqual(p.frame, p.original.offsetBy(dx: p.translation.x, dy: p.translation.y))
  }

  func testBelowFlipsAboveAndOtherPlacementsClampWithoutScalingCells() throws {
    let caret = CGRect(x: 600, y: 420.25, width: 1, height: 30.5)
    let below = try XCTUnwrap(ComposePopupPlacement(rect: rect, cell: cell, within: bounds, anchor: caret, placement: 2))
    XCTAssertEqual(below.frame.maxY, caret.minY)
    XCTAssertEqual(below.frame.maxX, bounds.maxX)
    let above = try XCTUnwrap(ComposePopupPlacement(rect: rect, cell: cell, within: bounds, anchor: caret, placement: 3))
    XCTAssertEqual(above.frame, below.frame)
    let over = try XCTUnwrap(ComposePopupPlacement(rect: rect, cell: cell, within: bounds, anchor: caret, placement: 1))
    XCTAssertEqual(over.frame.maxY, bounds.maxY)
    XCTAssertEqual(over.frame.size, CGSize(width: 160, height: 96))
  }

  func testWrappedCompletionWordUsesTheCaretsOwnVisualRow() throws {
    let caret = CGRect(x: 31, y: 250, width: 1, height: 24)
    let previousRow = CGRect(x: 500, y: 226, width: 1, height: 24)
    let p = try XCTUnwrap(ComposePopupPlacement(rect: rect, cell: cell, within: bounds,
      anchor: caret, horizontal: previousRow, placement: 2))
    XCTAssertEqual(p.frame.minX, caret.minX)
  }

  func testSmallFrameCropsCellsAndOutsideDragsRetainSignedLocalCoordinates() throws {
    let small = CGRect(x: 0, y: 0, width: 80, height: 48)
    let p = try XCTUnwrap(ComposePopupPlacement(rect: rect, cell: cell, within: small))
    XCTAssertEqual(p.frame.size, CGSize(width: 160, height: 96))
    XCTAssertEqual(p.clip, small)
    XCTAssertFalse(p.contains(CGPoint(x: 100, y: 20)))
    let outside = try XCTUnwrap(p.localCell(at: CGPoint(x: -1, y: -17)))
    XCTAssertEqual(outside.column, -1); XCTAssertEqual(outside.row, -2)
    XCTAssertNil(p.localCell(at: CGPoint(x: CGFloat.infinity, y: 0)))
    XCTAssertNil(ComposePopupPlacement(rect: rect, cell: .zero, within: bounds))
    XCTAssertNil(ComposePopupPlacement(rect: rect, cell: cell, within: bounds,
      anchor: CGRect(x: 0, y: 0, width: 1, height: 24), placement: 99))
  }
}
