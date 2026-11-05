import AppKit
import CoreText
import XCTest
import FreshKit
@testable import FileCommander

final class ComposePreferencesTests: XCTestCase {
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
