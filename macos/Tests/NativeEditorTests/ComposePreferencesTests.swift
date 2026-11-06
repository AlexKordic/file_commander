import AppKit
import CoreText
import XCTest
import FreshKit
@testable import FileCommander

final class ComposePreferencesTests: XCTestCase {
  @MainActor
  func testVirtualPendingProjectionCannotBePublishedAsBackendNavigation() throws {
    _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
    let source = "aa BB cc"
    let context = try XCTUnwrap(ComposeTextContext(.with { $0.text = source }, documentLength: UInt64(source.utf8.count)))
    let marked = try XCTUnwrap(ComposeMarkedText(context: context, range: NSRange(location: 0, length: 0), source: 0..<0,
      text: NSAttributedString(string: "日本"), selected: NSRange(location: 2, length: 0)))
    let prefix = try XCTUnwrap(ComposeComposition(primary: 1, values: [1: marked]))
    let selected = try XCTUnwrap(ComposeVirtualSelections(prefix: prefix))
    let pending = try XCTUnwrap(ComposeVirtualInsertion(selections: selected, text: NSAttributedString(string: "X"), selected: NSRange(location: 1, length: 0)))
    let pane = WirePane.with {
      $0.buffer = 1; $0.leaf = 2; $0.content.w = 80; $0.content.h = 20
      $0.compose = .with {
        $0.text = source; $0.sourceEnd = UInt64(source.utf8.count); $0.documentLen = $0.sourceEnd
        $0.segments = [.with { $0.sourceEnd = UInt64(source.utf8.count); $0.displayEnd = $0.sourceEnd }]
      }
    }
    let body = NSFont.systemFont(ofSize: 18), mono = NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)
    let visible = try XCTUnwrap(ComposePresentation(pane: pane, window: 99, cell: CGSize(width: 8, height: 16), body: body,
      monospace: mono, virtualInsertion: pending))
    XCTAssertEqual(visible.layout.text.projection.text, "日本Xaa BB cc")
    XCTAssertNil(visible.measuredNavigation(), "pending text is presentation-only until a matching backend receipt")
  }

  @MainActor
  func testSparseNavigationIsResampledForNewCaretsAndCurrentSceneOwnership() throws {
    _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
    let source = String(repeating: "Proportional café 👩🏽‍💻 words in a complete paragraph.\n\n", count: 400) + "Tail.\n"
    var pane = WirePane.with {
      $0.buffer = 1; $0.leaf = 2; $0.content.w = 80; $0.content.h = 12
      $0.compose = .with {
        $0.text = source; $0.sourceEnd = UInt64(source.utf8.count); $0.documentLen = $0.sourceEnd
        $0.segments = [.with { $0.sourceEnd = UInt64(source.utf8.count); $0.displayEnd = $0.sourceEnd }]
        $0.cursors = [.with { $0.id = 1; $0.primary = true }]
      }
    }
    let body = NSFont.systemFont(ofSize: 18), mono = NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)
    func presentation(_ reuse: ComposePresentation? = nil, geometry: UInt64 = 0) throws -> ComposePresentation {
      try XCTUnwrap(ComposePresentation(pane: pane, window: 99, cell: CGSize(width: 8, height: 16), body: body, monospace: mono,
        reuse: reuse, geometryRevision: geometry))
    }
    let first = try presentation(), original = try XCTUnwrap(first.measuredNavigation())
    pane.compose.cursors[0].position = 1; pane.compose.selectionRevision += 1
    let nearby = try presentation(first)
    XCTAssertTrue(first.layout.text === nearby.layout.text)
    XCTAssertEqual(try XCTUnwrap(nearby.measuredNavigation()).id, original.id,
      "an already measured nearby caret must not force another geometry exchange")
    let tail = UInt64(source.utf8.count - "Tail.\n".utf8.count)
    XCTAssertFalse(original.lines.flatMap(\.stops).contains { $0.source == tail })
    pane.compose.cursors[0].position = tail; pane.compose.selectionRevision += 1
    let moved = try presentation(nearby), current = try XCTUnwrap(moved.measuredNavigation())
    XCTAssertTrue(first.layout.text === moved.layout.text)
    XCTAssertNotEqual(current.id, original.id)
    XCTAssertTrue(current.lines.flatMap(\.stops).contains { $0.source == tail }, "the new cursor needs actual measured stops")
    pane.compose.bufferRevision += 1
    let revised = try presentation(moved), updated = try XCTUnwrap(revised.measuredNavigation())
    XCTAssertTrue(moved.layout.text === revised.layout.text)
    XCTAssertNotEqual(current.id, updated.id, "navigation ownership follows the current source scope")
    let changed = try presentation(revised, geometry: 1), measured = try XCTUnwrap(changed.measuredNavigation())
    XCTAssertTrue(revised.layout.text === changed.layout.text)
    XCTAssertNotEqual(measured.environmentRevision, updated.environmentRevision)
  }

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
