import Foundation
import XCTest
@testable import OverlayCore

final class EventDecoderTests: XCTestCase {
  func testDecodesEventsThatPlayEmits() {
    XCTAssertEqual(EventDecoder.decode(#"{"t": 2.1, "event": "start", "cols": 214, "rows": 42, "title": "FC"}"#),
                   TimedEvent(time: 2.1, event: .start(cols: 214, rows: 42, title: "FC")))
    XCTAssertEqual(EventDecoder.decode(#"{"t": 3, "event": "highlight", "rect": {"row": 6, "col": 1, "rows": 1, "cols": 7}, "style": "box", "label": ""}"#)?.event,
                   .highlight(rect: CellRect(row: 6, col: 1, rows: 1, cols: 7), style: "box", label: ""))
    XCTAssertEqual(EventDecoder.decode(#"{"t": 4, "event": "pointer", "rect": {"row": 1, "col": 2, "rows": 1, "cols": 3}, "ms": 700, "click": true}"#)?.event,
                   .pointer(rect: CellRect(row: 1, col: 2, rows: 1, cols: 3), milliseconds: 700, click: true))
    XCTAssertEqual(EventDecoder.decode(#"{"t": 5, "event": "geometry", "cell_w": 8.5, "cell_h": 17, "scale": 2, "terminal": "iTerm.app"}"#)?.event,
                   .geometry(TerminalGeometry(cellWidth: 8.5, cellHeight: 17, scale: 2, terminal: "iTerm.app")))
    XCTAssertEqual(EventDecoder.decode(#"{"t": 6, "event": "caption", "text": "Copy with F5", "sub": "Other panel"}"#)?.event,
                   .caption(text: "Copy with F5", sub: "Other panel"))
    XCTAssertEqual(EventDecoder.decode(#"{"t": 6, "event": "drag", "rect": {"row": 9, "col": 4}, "to": {"row": 9, "col": 30}, "ms": 800}"#)?.event,
                   .drag(from: CellRect(row: 9, col: 4), to: CellRect(row: 9, col: 30), milliseconds: 800))
    XCTAssertEqual(EventDecoder.decode(#"{"t": 7, "event": "calibrate_key", "key": "left", "big": true}"#)?.event,
                   .calibrateKey(.move(dx: -10, dy: 0)))
    XCTAssertEqual(EventDecoder.decode(#"{"t": 8, "event": "calibrate_key", "key": "taller"}"#)?.event,
                   .calibrateKey(.cellHeight(0.05)))
  }

  func testRejectsUnknownAndMalformedLines() {
    XCTAssertNil(EventDecoder.decode(#"{"t": 1, "event": "teleport"}"#))
    XCTAssertNil(EventDecoder.decode(#"{"t": 1, "event": "highlight"}"#), "a highlight needs a rect")
    XCTAssertNil(EventDecoder.decode(#"{"t": 1, "event": "drag", "rect": {"row": 1, "col": 1}}"#), "a drag needs an end")
    XCTAssertNil(EventDecoder.decode(#"{"t": 1, "event": "start", "cols": 0, "rows": 3}"#))
    XCTAssertNil(EventDecoder.decode(#"{"t": 1, "event": "calibrate_key", "key": "sideways"}"#))
    XCTAssertNil(EventDecoder.decode("not json"))
  }
}

final class EasingTests: XCTestCase {
  func testCurvesStartAndEndInPlace() {
    for easing in [Easing.linear, .inCubic, .outCubic, .inOutCubic, .outBack] {
      XCTAssertEqual(easing.value(at: 0), 0, accuracy: 1e-6)
      XCTAssertEqual(easing.value(at: 1), 1, accuracy: 1e-6)
    }
  }

  func testCurveShapes() {
    XCTAssertEqual(Easing.inOutCubic.value(at: 0.5), 0.5, accuracy: 1e-3)
    XCTAssertGreaterThan(Easing.outCubic.value(at: 0.3), 0.3, "ease-out runs ahead of linear early on")
    XCTAssertLessThan(Easing.inCubic.value(at: 0.3), 0.3)
    let peak = stride(from: 0.0, through: 1.0, by: 0.01).map { Easing.outBack.value(at: $0) }.max() ?? 0
    XCTAssertGreaterThan(peak, 1.02, "outBack overshoots")
  }

  func testNames() {
    XCTAssertEqual(Easing(name: "outBack"), .outBack)
    XCTAssertNil(Easing(name: "bounce"))
  }
}

final class GridTests: XCTestCase {
  func testCellRectangles() {
    let grid = CellGrid(originX: 5, originY: 30, cellWidth: 8, cellHeight: 20, cols: 214, rows: 42)
    XCTAssertEqual(grid.rect(CellRect(row: 2, col: 3, rows: 1, cols: 4)), CGRect(x: 29, y: 70, width: 32, height: 20))
    XCTAssertEqual(grid.rect(CellRect(row: 0, col: 0), padding: 4), CGRect(x: 1, y: 26, width: 16, height: 28))
    XCTAssertEqual(grid.center(CellRect(row: 1, col: 1, rows: 1, cols: 2)), CGPoint(x: 21, y: 60))
    XCTAssertEqual(grid.textArea, CGRect(x: 5, y: 30, width: 1712, height: 840))
  }

  func testCellSizePrecedence() {
    let window = CGSize(width: 1000, height: 600)
    let terminal = TerminalGeometry(cellWidth: 9, cellHeight: 18)
    XCTAssertEqual(GridSolver.grid(window: window, cols: 100, rows: 30, terminal: terminal, calibration: nil).cellWidth, 9,
                   "the terminal's report beats an estimate")
    let handTuned = Calibration(left: 6, top: 40, cellWidth: 9.5, cellHeight: nil)
    let grid = GridSolver.grid(window: window, cols: 100, rows: 30, terminal: terminal, calibration: handTuned)
    XCTAssertEqual(grid.cellWidth, 9.5, "a hand calibration beats the terminal's report")
    XCTAssertEqual(grid.cellHeight, 18)
    XCTAssertEqual(grid.originX, 6)
    let estimated = GridSolver.grid(window: window, cols: 99, rows: 28, terminal: nil, calibration: nil)
    XCTAssertEqual(estimated.cellWidth, (1000 - 10) / 99, accuracy: 1e-9)
    XCTAssertEqual(estimated.cellHeight, (600 - 37) / 28, accuracy: 1e-9)
  }

  func testCalibrationStoreKeepsOtherTerminals() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("c.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = CalibrationStore(url: url)
    XCTAssertNil(store.load(terminal: "iTerm2"))
    try store.save(Calibration(left: 5, top: 30), terminal: "iTerm2")
    try store.save(Calibration(left: 8, top: 24, cellWidth: 9, cellHeight: 18), terminal: "Terminal")
    XCTAssertEqual(store.load(terminal: "iTerm2"), Calibration(left: 5, top: 30))
    XCTAssertEqual(store.load(terminal: "Terminal")?.cellWidth, 9)
  }
}

final class ThemeTests: XCTestCase {
  func testColours() {
    XCTAssertEqual(RGBA(hex: "#FF8000"), RGBA(r: 1, g: 128.0 / 255, b: 0, a: 1))
    XCTAssertEqual(RGBA(hex: "00000080")?.a ?? 0, 128.0 / 255, accuracy: 1e-9)
    XCTAssertNil(RGBA(hex: "#12345"))
  }

  func testPartialThemeKeepsDefaults() throws {
    let theme = try Theme.load(Data(##"{"accent": "#FF0000", "badgeMax": 5}"##.utf8))
    XCTAssertEqual(theme.accent, "#FF0000")
    XCTAssertEqual(theme.badgeMax, 5)
    XCTAssertEqual(theme.captionTitleSize, Theme().captionTitleSize)
  }

  func testUnknownThemeKeyIsAnError() {
    XCTAssertThrowsError(try Theme.load(Data(##"{"acent": "#FF0000"}"##.utf8)))
  }
}

final class KeyTests: XCTestCase {
  func testLabels() {
    XCTAssertEqual(KeyLabel.pretty("Down"), "↓")
    XCTAssertEqual(KeyLabel.pretty("Ctrl+Right"), "Ctrl+→")
    XCTAssertEqual(KeyLabel.pretty("F5"), "F5")
  }

  func testRepeatsMergeOnlyWhenQuick() {
    var keys = KeyCoalescer(window: 0.9)
    XCTAssertEqual(keys.add("Down", at: 1.0).text, "↓")
    let second = keys.add("Down", at: 1.5)
    XCTAssertEqual(second.text, "↓ ×2")
    XCTAssertTrue(second.merges)
    XCTAssertFalse(keys.add("Down", at: 3.0).merges, "a slow repeat is a new badge")
    XCTAssertFalse(keys.add("Enter", at: 3.1).merges)
  }
}
