import XCTest
import CoreText
@testable import FreshKit

final class ComposeFlowTests: XCTestCase {
  func testAnchorsUsePhysicalSourceStartsWhileSoftWrapsRemainOnlyNavigationLines() throws {
    let text = "Proportional café 👩🏽‍💻 words that wrap across several lines.\r\n\r\nNext physical paragraph.\n"
    let projection = try XCTUnwrap(ComposeProjection(source: 0..<text.utf8.count, text: text,
      segments: [.init(source: 0..<text.utf8.count, display: 0..<text.utf8.count, kind: .copy)]))
    let layout = try XCTUnwrap(ComposeTextLayout(projection: projection,
      font: CTFontCreateWithName("Helvetica" as CFString, 18, nil), width: 100))
    let feedback = try XCTUnwrap(layout.navigation(id: 1, pageHeight: 500, documentLength: UInt64(text.utf8.count), positions: [0], environmentRevision: 42))
    XCTAssertEqual(feedback.environmentRevision, 42)
    XCTAssertGreaterThan(feedback.lines.count, feedback.anchors.count)
    let bytes = Array(text.utf8)
    for anchor in feedback.anchors where anchor.kind == 0 {
      XCTAssertTrue(anchor.source == 0 || bytes[Int(anchor.source) - 1] == 10)
      XCTAssertEqual(anchor.contextStart, anchor.source); XCTAssertGreaterThan(anchor.contextEnd, anchor.source)
      let line = try XCTUnwrap(feedback.lines.first { $0.start.source == anchor.source })
      XCTAssertEqual(anchor.y, line.y, accuracy: 0.001)
    }
    XCTAssertEqual(feedback.anchors.last?.kind, 2)
    XCTAssertEqual(feedback.anchors.last?.contextEnd, UInt64(text.utf8.count))
  }

  func testDisplayOnlyPrefixesDoNotInventSourceContextAndRealScenesHaveOrderedAnchors() throws {
    let projection = try XCTUnwrap(ComposeProjection(source: 0..<5, text: "    body\n", segments: [
      .init(source: 0..<0, display: 0..<4, kind: .insertion),
      .init(source: 0..<5, display: 4..<9, kind: .copy),
    ]))
    let layout = try XCTUnwrap(ComposeTextLayout(projection: projection,
      font: CTFontCreateWithName("Helvetica" as CFString, 18, nil), width: 320))
    let feedback = try XCTUnwrap(layout.navigation(id: 1, pageHeight: 500, documentLength: 5, positions: [0]))
    let prefix = try XCTUnwrap(feedback.anchors.first)
    XCTAssertEqual(prefix.source, 0); XCTAssertEqual(prefix.contextEnd, 1)
    for name in ["compose-lists", "compose-code", "compose-ornaments", "compose-images", "compose-tables-missing-source"] {
      let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "pb", subdirectory: "Fixtures"))
      let pane = try WireComposePane(serializedBytes: Data(contentsOf: url))
      let value = try XCTUnwrap(ComposePaneLayout(pane: pane, body: CTFontCreateWithName("Helvetica" as CFString, 18, nil),
        monospace: CTFontCreateWithName("Menlo" as CFString, 18, nil), width: 320))
      let result = try XCTUnwrap(value.text.navigation(id: 1, pageHeight: 10_000, documentLength: pane.documentLen, positions: [0]))
      XCTAssertFalse(result.anchors.isEmpty, name)
      for anchor in result.anchors {
        XCTAssertGreaterThanOrEqual(anchor.contextStart, pane.sourceStart, name)
        XCTAssertLessThanOrEqual(anchor.contextEnd, pane.sourceEnd, name)
        if anchor.kind == 0 { XCTAssertLessThan(anchor.contextStart, anchor.contextEnd, name) }
      }
      XCTAssertTrue(zip(result.anchors, result.anchors.dropFirst()).allSatisfy {
        ($0.source < $1.source || ($0.source == $1.source && $0.kind < $1.kind)) && $0.y <= $1.y
      }, name)
    }
  }

  func testTableAnchorsOwnCompleteRowsAndUseTheSharedRowTop() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "compose-tables", withExtension: "pb", subdirectory: "Fixtures"))
    let pane = try WireComposePane(serializedBytes: Data(contentsOf: url))
    let layout = try XCTUnwrap(ComposePaneLayout(pane: pane, body: CTFontCreateWithName("Helvetica" as CFString, 18, nil),
      monospace: CTFontCreateWithName("Menlo" as CFString, 18, nil), width: 320))
    let feedback = try XCTUnwrap(layout.text.navigation(id: 1, pageHeight: 10_000, documentLength: pane.documentLen, positions: [0]))
    for row in layout.text.tables.flatMap(\.rows) {
      let anchor = try XCTUnwrap(feedback.anchors.first { $0.kind == 1 && $0.source == row.source.lowerBound })
      XCTAssertEqual(anchor.contextStart, UInt64(row.source.lowerBound)); XCTAssertEqual(anchor.contextEnd, UInt64(row.source.upperBound))
      XCTAssertEqual(anchor.y, Double(row.rect.minY), accuracy: 0.001)
    }
    XCTAssertTrue(zip(feedback.anchors, feedback.anchors.dropFirst()).allSatisfy { $0.source <= $1.source && $0.y <= $1.y })
  }

  func testPageContinuationUsesTheSameMeasuredRowAfterTheOriginalCursorLeavesTheWindow() throws {
    func fixture(_ name: String) throws -> WireComposePane {
      let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "pb", subdirectory: "Fixtures"))
      return try WireComposePane(serializedBytes: Data(contentsOf: url))
    }
    let a = try fixture("compose-page-window-a"), b = try fixture("compose-page-window-b")
    let body = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
    let mono = CTFontCreateWithName("Menlo" as CFString, 18, nil)
    let first = try XCTUnwrap(ComposePaneLayout(pane: a, body: body, monospace: mono, width: 320))
    let next = try XCTUnwrap(ComposePaneLayout(pane: b, body: body, monospace: mono, width: 320, reuse: first))
    let origin = try XCTUnwrap(a.cursors.first).position
    XCTAssertGreaterThan(b.sourceStart, origin)
    let before = try XCTUnwrap(first.text.navigation(id: 401, pageHeight: 10_000, documentLength: a.documentLen,
      positions: [origin], environmentRevision: 7))
    let after = try XCTUnwrap(next.text.navigation(id: 402, pageHeight: 10_000, documentLength: b.documentLen,
      positions: [origin], environmentRevision: 7))
    let pivot = try XCTUnwrap(before.anchors.last)
    XCTAssertEqual(pivot.kind, 1)
    let moved = try XCTUnwrap(after.anchors.first { $0.source == pivot.source && $0.kind == pivot.kind })
    let targetY = moved.y + before.height + 10 - pivot.y
    let target = try XCTUnwrap(after.lines.first { !$0.hasCell && $0.y <= targetY && targetY < $0.y + $0.height })
    XCTAssertEqual(target.start.source, a.sourceEnd)
    XCTAssertEqual(first.text.tables[0].columns, next.text.tables[0].columns)
    for (key, value) in [("FC_COMPOSE_PAGE_LAYOUT_A", before), ("FC_COMPOSE_PAGE_LAYOUT_B", after)] {
      if let path = ProcessInfo.processInfo.environment[key] { try value.serializedData().write(to: URL(fileURLWithPath: path)) }
    }
  }

}
