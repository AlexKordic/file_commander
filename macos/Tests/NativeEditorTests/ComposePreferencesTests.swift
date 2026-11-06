import AppKit
import CoreText
import XCTest
import FreshKit
@testable import FileCommander

final class ComposePreferencesTests: XCTestCase {
  @MainActor
  func testSplitPanesKeepTheirOwnScopeCursorViewportAndGeometry() throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("FreshKitTests/Fixtures/compose-tables.pb")
    var compose = try WireComposePane(serializedBytes: Data(contentsOf: fixture))
    compose.assetAuthority = 11; compose.assetDocument = 22; compose.clearTextContext()
    let top = compose.tables[0].rows[0], bottom = compose.tables[0].rows[4]
    var left = WirePane.with {
      $0.leaf = 1; $0.buffer = 10; $0.content.w = 90; $0.content.h = 6; $0.compose = compose
    }
    left.compose.focused = true; left.compose.keyboard = true; left.compose.selectionRevision = 1
    left.compose.cursors = [.with { $0.id = 1; $0.primary = true; $0.position = top.cells[0].start }]
    left.compose.viewport = .with { $0.epoch = 7; $0.position = top.start }
    var right = left
    right.leaf = 2; right.content.x = 90; right.content.w = 65
    right.compose.focused = false; right.compose.keyboard = false; right.compose.selectionRevision = 2
    right.compose.cursors[0].position = bottom.cells[0].start
    right.compose.viewport.position = bottom.start
    let store = SceneStore(), grid = CellGridView(store: store)
    store.onChange = { [weak grid] change in grid?.apply(change) }
    func show(_ panes: [WirePane]) throws {
      let frame = WireFrame.with {
        $0.windowID = 99; $0.width = 155; $0.height = 6; $0.paneLen = UInt32(panes.count)
        $0.panes = panes.enumerated().map { index, pane in .with { $0.index = UInt32(index); $0.pane = pane } }
      }
      let bytes: [UInt8] = try frame.serializedBytes()
      store.apply(try XCTUnwrap(SceneMessage(kind: SceneWire.Kind.frame.rawValue, payload: bytes[...])))
    }
    try show([left, right])
    let a = try XCTUnwrap(grid.composePanes[1]), b = try XCTUnwrap(grid.composePanes[2])
    XCTAssertEqual(a.scope.windowID, 99); XCTAssertEqual(b.scope.windowID, 99)
    XCTAssertEqual(a.scope.leaf, 1); XCTAssertEqual(b.scope.leaf, 2)
    XCTAssertEqual(a.scope.selectionRevision, 1); XCTAssertEqual(b.scope.selectionRevision, 2)
    XCTAssertEqual(a.cursor?.position, top.cells[0].start); XCTAssertEqual(b.cursor?.position, bottom.cells[0].start)
    XCTAssertEqual(a.viewport.position, top.start); XCTAssertEqual(b.viewport.position, bottom.start)
    XCTAssertFalse(a.layout.text === b.layout.text)
    XCTAssertNotEqual(a.layout.width, b.layout.width)
    for (pane, row) in [(a, top), (b, bottom)] {
      let caret = try XCTUnwrap(pane.caret)
      let hit = try XCTUnwrap(pane.hit(at: CGPoint(x: caret.minX + 0.1, y: caret.midY)))
      XCTAssertTrue((Int(row.start)..<Int(row.end)).contains(hit.source))
    }
    right.compose.cursors[0].position = top.cells[0].start
    right.compose.selectionRevision = 3; right.compose.viewport.position = top.start
    try show([left, right])
    XCTAssertEqual(grid.composePanes[1]?.scope, a.scope)
    XCTAssertEqual(grid.composePanes[1]?.viewport, a.viewport)
    XCTAssertEqual(grid.composePanes[2]?.scope.selectionRevision, 3)
    XCTAssertEqual(grid.composePanes[2]?.cursor?.position, top.cells[0].start)
  }

  func testOldProfilesKeepDefaultsAndComposeSettingsPersistInTheAppProfile() throws {
    let old = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"terminalEditor":true,"scrollMargin":7}"#.utf8))
    XCTAssertEqual(old.compose, ComposePreferences())
    XCTAssertEqual(old.compose.pageWidth, 0, "native Compose uses the available width by default")
    XCTAssertTrue(old.terminalEditor)
    var preferences = old
    preferences.compose.bodyFamily = "system-rounded"
    preferences.compose.monospaceFamily = "Menlo"
    preferences.compose.bodySize = 22
    preferences.compose.headingScales = [2.1, 1.9, 1.7, 1.5, 1.3, 1.1]
    preferences.compose.lineSpacing = 5
    preferences.compose.paragraphSpacing = 12
    preferences.compose.indent = 28
    preferences.compose.pageWidth = 1000
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fc-compose-prefs-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("app_settings.json")
    preferences.save(to: path)
    XCTAssertEqual(AppPreferences.load(from: path), preferences)
  }

  @MainActor
  func testInvalidPreferencesAreBoundedAndUnavailableOrProportionalCodeFontsFallBack() throws {
    let source = #"{"optionAsAlt":true,"compose":{"bodySize":-20,"headingScales":[2],"lineSpacing":90,"paragraphSpacing":-1,"indent":900,"pageWidth":0,"bodyFamily":" ","monospaceFamily":"Helvetica"}}"#
    let preferences = try JSONDecoder().decode(AppPreferences.self, from: Data(source.utf8))
    XCTAssertTrue(preferences.optionAsAlt)
    XCTAssertEqual(preferences.compose.bodySize, 8)
    XCTAssertEqual(preferences.compose.headingScales, ComposePreferences().headingScales)
    XCTAssertEqual(preferences.compose.lineSpacing, 24)
    XCTAssertEqual(preferences.compose.paragraphSpacing, 0)
    XCTAssertEqual(preferences.compose.indent, 64)
    XCTAssertEqual(preferences.compose.pageWidth, 0)
    XCTAssertEqual(preferences.compose.bodyFamily, "system")
    XCTAssertTrue(CTFontGetSymbolicTraits(preferences.compose.fonts(zoom: 1).monospace as CTFont).contains(.traitMonoSpace))
    var missing = ComposePreferences()
    missing.bodyFamily = "FC does not have this font \(UUID().uuidString)"
    missing.monospaceFamily = missing.bodyFamily
    missing.bodySize = .nan
    let fonts = missing.fonts(zoom: .infinity)
    XCTAssertEqual(fonts.body.pointSize, 16)
    XCTAssertTrue(CTFontGetSymbolicTraits(fonts.monospace as CTFont).contains(.traitMonoSpace))
  }

  @MainActor
  func testNativeWrappingUsesTheAvailablePixelWidthUnlessTheUserChoosesAReadingLimit() throws {
    let text = String(repeating: "Proportional words with iii and WWW measure in pixels. ", count: 25)
    var pane = WirePane.with {
      $0.buffer = 1; $0.leaf = 2; $0.content.w = 240; $0.content.h = 40
      $0.compose = .with {
        $0.text = text; $0.sourceEnd = UInt64(text.utf8.count); $0.documentLen = $0.sourceEnd
        $0.segments = [.with { $0.sourceEnd = UInt64(text.utf8.count); $0.displayEnd = $0.sourceEnd }]
      }
    }
    let body = NSFont.systemFont(ofSize: 18), mono = NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)
    let full = try XCTUnwrap(ComposePresentation(pane: pane, window: 1, cell: CGSize(width: 8, height: 16), body: body, monospace: mono))
    XCTAssertEqual(full.layout.text.size.width, 1888)
    pane.content.w = 120
    let narrower = try XCTUnwrap(ComposePresentation(pane: pane, window: 1, cell: CGSize(width: 8, height: 16), body: body, monospace: mono))
    XCTAssertEqual(narrower.layout.text.size.width, 928)
    XCTAssertGreaterThan(narrower.layout.text.fragments.count, full.layout.text.fragments.count)
    let limited = try XCTUnwrap(ComposePresentation(pane: pane, window: 1, cell: CGSize(width: 8, height: 16), body: body, monospace: mono, pageWidth: 500))
    XCTAssertEqual(limited.layout.text.size.width, 500)
    XCTAssertGreaterThan(limited.layout.text.fragments.count, narrower.layout.text.fragments.count)
  }
}
