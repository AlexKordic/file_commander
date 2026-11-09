import AppKit
import XCTest
import FreshKit
@testable import FileCommander

@MainActor
final class ComposeInputSnapshotTests: XCTestCase {
  private func pane(_ source: String, revision: UInt64 = 4, selection: Int = 0) -> WirePane {
    .with {
      $0.leaf = 2; $0.buffer = 3; $0.content.w = 80; $0.content.h = 20
      $0.compose = .with {
        $0.text = source; $0.sourceEnd = UInt64(source.utf8.count); $0.documentLen = $0.sourceEnd
        $0.bufferRevision = revision; $0.projectionRevision = revision; $0.selectionRevision = revision
        $0.assetAuthority = 11; $0.assetDocument = 22; $0.viewport.epoch = 7
        $0.focused = true; $0.keyboard = true; $0.ready = true
        $0.segments = [.with { $0.sourceEnd = UInt64(source.utf8.count); $0.displayEnd = $0.sourceEnd }]
        $0.textContext = .with { $0.text = source; $0.selectionStart = UInt64(selection); $0.selectionEnd = UInt64(selection) }
        let prefix = (source as NSString).substring(to: selection)
        $0.cursors = [.with { $0.id = 1; $0.primary = true; $0.position = UInt64(prefix.utf8.count); $0.utf16Position = UInt64(selection) }]
      }
    }
  }

  private func presentation(_ pane: WirePane) throws -> ComposePresentation {
    _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
    return try XCTUnwrap(ComposePresentation(pane: pane, window: 99, cell: CGSize(width: 8, height: 16),
      body: .systemFont(ofSize: 18), monospace: .monospacedSystemFont(ofSize: 18, weight: .regular)))
  }

  private func show(_ pane: WirePane, in store: SceneStore, window: UInt64 = 99) throws {
    let frame = WireFrame.with {
      $0.windowID = window; $0.width = 80; $0.height = 20; $0.paneLen = 1
      $0.panes = [.with { $0.pane = pane }]
    }
    let bytes: [UInt8] = try frame.serializedBytes()
    store.apply(try XCTUnwrap(SceneMessage(kind: SceneWire.Kind.frame.rawValue, payload: bytes[...])))
  }

  func testRawReceiptOwnsItsCurrentSourceWithoutReadyProjectionOrRetainedOldGeometry() throws {
    let oldPane = pane("**old café**\r\n")
    var previous: ComposePresentation? = try presentation(oldPane)
    weak var oldGeometry = previous
    let source = "追加 café 👩🏽‍💻\r\n"
    var receipt = pane(source, revision: 5, selection: 3)
    receipt.compose.ready = false
    receipt.compose.text = "unfinished"; receipt.compose.segments = []
    XCTAssertNil(ComposePresentation(pane: receipt, window: 99, cell: CGSize(width: 8, height: 16),
      body: .systemFont(ofSize: 18), monospace: .monospacedSystemFont(ofSize: 18, weight: .regular)))
    let snapshot = try XCTUnwrap(ComposeInputSnapshot(pane: receipt, window: 99, previous: previous))
    XCTAssertEqual(snapshot.scope.bufferRevision, 5); XCTAssertEqual(snapshot.scope.selectionRevision, 5)
    XCTAssertEqual(snapshot.pane.compose.text, "unfinished", "the raw owner is not replaced by an older ready projection")
    XCTAssertEqual(snapshot.textContext?.selection, NSRange(location: 3, length: 0))
    XCTAssertEqual(snapshot.textContext?.sourceRange(forUTF16: NSRange(location: 3, length: 0)), 7..<7)
    XCTAssertEqual(snapshot.textContext?.text, source)
    XCTAssertNil(snapshot.measuredInputBase)
    previous = nil
    XCTAssertNil(oldGeometry, "a new source snapshot must not keep the old glyph layout alive")
  }

  func testMeasurementCandidateStaysWithinItsOriginalSourceLifetime() throws {
    let original = pane("café source 👩🏽‍💻")
    let measured = try presentation(original)
    var selection = original; selection.compose.selectionRevision += 1
    selection.compose.textContext.selectionEnd = 4
    let snapshot = try XCTUnwrap(ComposeInputSnapshot(pane: selection, window: 99, previous: measured))
    XCTAssertTrue(snapshot.measuredInputBase === measured)
    XCTAssertEqual(snapshot.textContext?.selection, NSRange(location: 0, length: 4))
    XCTAssertEqual(measured.textContext?.selection, NSRange(location: 0, length: 0))
    let changes: [(inout WirePane) -> Void] = [
      { $0.leaf += 1 }, { $0.buffer += 1 }, { $0.compose.viewport.epoch += 1 },
      { $0.compose.assetAuthority += 1 }, { $0.compose.assetDocument += 1 }, { $0.compose.bufferRevision += 1 },
    ]
    for change in changes {
      var pane = original; change(&pane)
      XCTAssertNil(try XCTUnwrap(ComposeInputSnapshot(pane: pane, window: 99, previous: snapshot)).measuredInputBase)
    }
    XCTAssertNil(try XCTUnwrap(ComposeInputSnapshot(pane: original, window: 100, previous: snapshot)).measuredInputBase)
  }

  func testTextOnlyContextReuseKeepsLiteralUnicodeAndRejectsInvalidRawHeaders() throws {
    let before = "é e\u{301}", after = "e\u{301} é"
    XCTAssertEqual(before, after); XCTAssertEqual(before.utf8.count, after.utf8.count)
    let old = try XCTUnwrap(ComposeInputSnapshot(pane: pane(before), window: 99))
    let current = try XCTUnwrap(ComposeInputSnapshot(pane: pane(after, revision: 5), window: 99, previous: old))
    XCTAssertEqual(Array(try XCTUnwrap(current.textContext).text.utf8), Array(after.utf8))
    XCTAssertEqual(current.textContext?.sourceRange(forUTF16: NSRange(location: 1, length: 0)), 1..<1)
    XCTAssertEqual(old.textContext?.sourceRange(forUTF16: NSRange(location: 1, length: 0)), 2..<2)
    var bad = pane(after, revision: 6); bad.compose.textContext.selectionEnd = UInt64.max
    XCTAssertNil(ComposeInputSnapshot(pane: bad, window: 99, previous: current))
    bad = pane(after); bad.compose.textContext.sourceStart = bad.compose.documentLen + 1
    XCTAssertNil(ComposeInputSnapshot(pane: bad, window: 99, previous: current))
  }

  func testTextServicesReadCurrentRawOwnerWhilePriorGeometryRemainsVisible() throws {
    _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
    let store = SceneStore(), grid = CellGridView(store: store)
    store.onChange = { [weak grid] in grid?.apply($0) }
    try show(pane("old source"), in: store)
    let visible = try XCTUnwrap(grid.focusedCompose)
    XCTAssertTrue(grid.textServiceGeometry === visible)
    store.onChange = nil // Hold geometry while changing only the authoritative scene.
    let source = "追加 café 👩🏽‍💻\r\n"
    var current = pane(source, revision: 5, selection: 3)
    current.compose.ready = false; current.compose.text = "unfinished"; current.compose.segments = []
    try show(current, in: store)
    XCTAssertTrue(grid.focusedCompose === visible)
    XCTAssertNil(grid.textServiceGeometry, "new raw ranges cannot borrow the old frame's pixels")
    XCTAssertEqual(grid.selectedRange(), NSRange(location: 3, length: 0))
    var actual = NSRange(location: 100, length: 100)
    let text = grid.attributedSubstring(forProposedRange: NSRange(location: 0, length: source.utf16.count), actualRange: &actual)
    XCTAssertEqual(text?.string, source); XCTAssertEqual(actual, NSRange(location: 0, length: source.utf16.count))
    XCTAssertEqual(visible.layout.text.projection.text, "old source")
    XCTAssertEqual(grid.composeTextInputBasis?.scope.bufferRevision, 5)
    XCTAssertNil(grid.composeTextInputBasis?.measuredInputBase)
    actual = NSRange(location: 3, length: 0)
    XCTAssertEqual(grid.firstRect(forCharacterRange: NSRange(location: 3, length: 0), actualRange: &actual), .zero)
    XCTAssertEqual(actual, NSRange(location: NSNotFound, length: 0))
    current.compose.textContext.selectionEnd = UInt64.max
    try show(current, in: store)
    XCTAssertEqual(grid.selectedRange(), NSRange(location: NSNotFound, length: 0))
    XCTAssertNil(grid.textServiceGeometry)
    XCTAssertNil(grid.attributedSubstring(forProposedRange: NSRange(location: 0, length: 3), actualRange: &actual))
    XCTAssertEqual(actual, NSRange(location: NSNotFound, length: 0), "a failed query cannot expose the prior frame's text")
  }

  func testMarkedTextCapturesCurrentRawContextBeforeGeometryRefresh() throws {
    _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
    let store = SceneStore(), grid = CellGridView(store: store)
    store.onChange = { [weak grid] in grid?.apply($0) }
    try show(pane("old source"), in: store)
    let visible = try XCTUnwrap(grid.focusedCompose)
    store.onChange = nil
    let source = "追加 café 👩🏽‍💻\r\n"
    try show(pane(source, revision: 5, selection: 3), in: store)
    XCTAssertTrue(grid.focusedCompose === visible)
    grid.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    defer { grid.cancelComposition(recover: false) }
    XCTAssertEqual(grid.markedRange(), NSRange(location: 3, length: 2))
    XCTAssertEqual(grid.selectedRange(), NSRange(location: 5, length: 0))
    XCTAssertEqual(grid.pendingComposition?.text.presentation.primary.source, 7..<7)
    let expected = "追加 日本café 👩🏽‍💻\r\n"
    var actual = NSRange(location: NSNotFound, length: 0)
    let result = grid.attributedSubstring(forProposedRange: NSRange(location: 0, length: expected.utf16.count), actualRange: &actual)
    XCTAssertEqual(result?.string, expected); XCTAssertEqual(actual, NSRange(location: 0, length: expected.utf16.count))
  }
}
