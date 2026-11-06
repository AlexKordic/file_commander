import AppKit
import ImageIO
import XCTest
import FreshKit
import SwiftProtobuf
@testable import FileCommander

@MainActor
private final class MemoryPasteboard: EditorPasteboard {
  private(set) var editorText: String?
  func replaceEditorText(_ text: String) { editorText = text }
}

/// A private scene peer controls acknowledgment timing. The production editor,
/// socket, scene store, AppKit pane and input queue run unchanged.
private final class ScenePeer: @unchecked Sendable {
  let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("fc-compose-input-\(UUID().uuidString)")
  var path: String { directory.appendingPathComponent("scene.sock").path }
  private let lock = NSLock()
  private var listener: Int32 = -1
  private var client: Int32 = -1
  private var received: [WireComposeInput] = []
  private var receivedHellos: [WireClientHello] = []
  private var receivedKeys: [WireKey] = []
  private var receivedViewports: [WireComposeViewportRequest] = []
  private var receivedAssets: [WireComposeAssetRequest] = []
  private var sequence: UInt64 = 0
  private var applied: UInt64 = 0

  var hellos: [WireClientHello] { lock.lock(); defer { lock.unlock() }; return receivedHellos }
  var inputs: [WireComposeInput] { lock.lock(); defer { lock.unlock() }; return received }
  var keys: [WireKey] { lock.lock(); defer { lock.unlock() }; return receivedKeys }
  var viewports: [WireComposeViewportRequest] { lock.lock(); defer { lock.unlock() }; return receivedViewports }
  var assets: [WireComposeAssetRequest] { lock.lock(); defer { lock.unlock() }; return receivedAssets }
  var lastApplied: UInt64 { lock.lock(); defer { lock.unlock() }; return applied }

  init(pane: WirePane) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    var started = false
    defer { if !started { close() } }
    guard listener >= 0 else { throw POSIXError(.EIO) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0, Darwin.listen(listener, 1) == 0 else { throw POSIXError(.EIO) }
    let listener = listener
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let fd = Darwin.accept(listener, nil, nil)
      guard fd >= 0 else { return }
      guard let self else { Darwin.close(fd); return }
      defer {
        lock.lock(); if client == fd { client = -1 }; lock.unlock()
        Darwin.close(fd)
      }
      lock.lock(); client = fd; lock.unlock()
      var noSignal: Int32 = 1
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
      while let kind = Self.varint(fd), let size = Self.varint(fd), size <= UInt64(SceneWire.maxPayload),
            let payload = Self.read(fd, count: Int(size)) {
        if kind == SceneWire.Kind.clientHello.rawValue {
          if let hello = try? WireClientHello(serializedBytes: payload) {
            lock.lock(); receivedHellos.append(hello); lock.unlock()
          }
          send(.serverHello, WireServerHello.with { $0.version = SceneWire.version; $0.scene = self.frame(pane: pane) })
        } else if kind == SceneWire.Kind.composeInput.rawValue, let input = try? WireComposeInput(serializedBytes: payload) {
          lock.lock(); received.append(input); lock.unlock()
        } else if kind == SceneWire.Kind.applied.rawValue, let ack = try? WireApplied(serializedBytes: payload) {
          lock.lock(); applied = ack.seq; lock.unlock()
        } else if kind == SceneWire.Kind.key.rawValue, let key = try? WireKey(serializedBytes: payload) {
          lock.lock(); receivedKeys.append(key); lock.unlock()
        } else if kind == SceneWire.Kind.composeViewport.rawValue, let request = try? WireComposeViewportRequest(serializedBytes: payload) {
          lock.lock(); receivedViewports.append(request); lock.unlock()
        } else if kind == SceneWire.Kind.composeAsset.rawValue, let request = try? WireComposeAssetRequest(serializedBytes: payload) {
          lock.lock(); receivedAssets.append(request); lock.unlock()
        }
      }
    }
    started = true
  }

  private static func read(_ fd: Int32, count: Int) -> [UInt8]? {
    var result = [UInt8](repeating: 0, count: count), offset = 0
    while offset < count {
      let length = result.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), count - offset) }
      if length < 0 && errno == EINTR { continue }
      guard length > 0 else { return nil }
      offset += length
    }
    return result
  }

  private static func varint(_ fd: Int32) -> UInt64? {
    var value: UInt64 = 0
    for index in 0..<10 {
      guard let byte = read(fd, count: 1)?.first, index < 9 || byte <= 1 else { return nil }
      value |= UInt64(byte & 127) << (index * 7)
      if byte < 128 { return value }
    }
    return nil
  }

  private func send(_ kind: SceneWire.Kind, _ message: some SwiftProtobuf.Message) {
    guard let bytes: [UInt8] = try? message.serializedBytes() else { return }
    let data = SceneWire.message(kind, payload: bytes)
    lock.lock(); defer { lock.unlock() }
    guard client >= 0 else { return }
    var offset = 0
    while offset < data.count {
      let count = data.withUnsafeBytes { Darwin.write(client, $0.baseAddress!.advanced(by: offset), data.count - offset) }
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else { return }
      offset += count
    }
  }

  private func frame(pane: WirePane?) -> WireFrame {
    lock.lock(); sequence += 1; let sequence = sequence; lock.unlock()
    return .with {
      $0.seq = sequence; $0.windowID = 1; $0.width = 80; $0.height = 36
      if let pane { $0.paneLen = 1; $0.panes = [.with { $0.index = 0; $0.pane = pane }] }
    }
  }

  @discardableResult
  func reply(_ reply: WireInputReply, pane: WirePane? = nil) -> UInt64 {
    var frame = frame(pane: pane); frame.inputReply = reply; send(.frame, frame)
    return frame.seq
  }

  func show(_ pane: WirePane) { send(.frame, frame(pane: pane)) }

  func acknowledgeScroll(_ request: WireComposeViewportRequest, pane: WirePane) {
    var frame = frame(pane: pane)
    frame.viewportReply = .with { $0.id = request.id; $0.accepted = true }
    send(.frame, frame)
  }

  @discardableResult
  func copy(_ text: String, sequence: UInt64) -> UInt64 {
    var frame = frame(pane: nil)
    frame.clipboard = .with { $0.text = text; $0.seq = sequence }
    send(.frame, frame); return frame.seq
  }

  @discardableResult
  func image(_ chunk: WireComposeAssetChunk) -> UInt64 {
    var frame = frame(pane: nil); frame.composeAssets = [chunk]; send(.frame, frame)
    return frame.seq
  }

  func close() {
    lock.lock()
    let oldClient = client, oldListener = listener
    client = -1; listener = -1
    lock.unlock()
    if oldClient >= 0 { Darwin.shutdown(oldClient, SHUT_RDWR) }
    if oldListener >= 0 { Darwin.shutdown(oldListener, SHUT_RDWR); Darwin.close(oldListener) }
    try? FileManager.default.removeItem(at: directory)
  }
}

final class ComposeInputTests: XCTestCase {
  @MainActor
  func testReceiptBoundTypingDoesNotWaitForBackgroundSemanticGeometry() async throws {
    let peer = try ScenePeer(pane: pane("alpha Tail\n")); defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid), unspecified = NSRange(location: NSNotFound, length: 0)
    grid.insertText("日", replacementRange: unspecified)
    grid.insertText("本", replacementRange: unspecified)
    try await eventually { peer.inputs.count == 1 }
    var raw = pane("日alpha Tail\n", revision: 5)
    raw.compose.ready = false; raw.compose.currentProjection = false
    raw.compose.cursors[0].position = 3; raw.compose.cursors[0].utf16Position = 1
    raw.compose.textContext.selectionStart = 1; raw.compose.textContext.selectionEnd = 1
    let edit = WireComposeEditReceipt.with {
      $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.cursors = [1]; $0.pane = raw.compose
    }
    peer.reply(.with { $0.id = 1; $0.accepted = true; $0.edit = edit }, pane: raw)
    try await eventually { peer.inputs.count == 2 }
    XCTAssertEqual(peer.inputs[1].sourceRevision, 5)
    XCTAssertEqual(peer.inputs[1].replacementStart, 3); XCTAssertEqual(peer.inputs[1].replacementEnd, 3)
    XCTAssertEqual(try WirePaste(serializedBytes: peer.inputs[1].payload).text, "本")
    XCTAssertEqual(grid.focusedCompose?.layout.text.projection.text, "日本alpha Tail\n")
    raw = pane("日本alpha Tail\n", revision: 6); raw.compose.ready = false; raw.compose.currentProjection = false
    raw.compose.cursors[0].position = 6; raw.compose.cursors[0].utf16Position = 2
    raw.compose.textContext.selectionStart = 2; raw.compose.textContext.selectionEnd = 2
    var next = edit; next.pane = raw.compose
    let sequence = peer.reply(.with { $0.id = 2; $0.accepted = true; $0.edit = next }, pane: raw)
    try await eventually { peer.lastApplied >= sequence }
    XCTAssertEqual(grid.selectedRange(), NSRange(location: 2, length: 0))
    XCTAssertTrue(editor.uninsertedText.isEmpty)
  }

  @MainActor
  func testRichAccessibilityUsesMeasuredLinesGraphemesAndScreenGeometry() async throws {
    let source = "Title\n\nProportional café 👩🏽‍💻 office affinity אבג words wrap across several measured lines.\nTail\n"
    var scene = pane(source, width: 24)
    scene.compose.spans = [.with { $0.start = 0; $0.end = 5; $0.role = 1 }]
    let peer = try ScenePeer(pane: scene); defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let window = NSWindow(contentRect: CGRect(x: 90, y: 110, width: 1040, height: 700),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = try XCTUnwrap(editor.view)
    defer { window.contentView = nil; window.close() }
    let grid = try XCTUnwrap(editor.grid), presentation = try XCTUnwrap(grid.focusedCompose)
    let text = source as NSString
    XCTAssertEqual(grid.accessibilityNumberOfCharacters(), text.length)
    let emoji = text.range(of: "👩🏽‍💻")
    XCTAssertEqual(grid.accessibilityRange(for: emoji.location + 2), emoji)
    XCTAssertEqual(grid.accessibilityString(for: emoji), "👩🏽‍💻")
    XCTAssertNil(grid.accessibilityString(for: NSRange(location: text.length, length: Int.max)))
    XCTAssertEqual(grid.accessibilityRange(forLine: -1).location, NSNotFound)
    let fragments = presentation.layout.text.fragments
    XCTAssertGreaterThan(fragments.count, 5)
    for (index, fragment) in fragments.enumerated() where fragment.range.length > 0 {
      XCTAssertEqual(grid.accessibilityRange(forLine: index), fragment.range)
      XCTAssertEqual(grid.accessibilityLine(for: fragment.range.location), index)
    }
    let title = try XCTUnwrap(grid.accessibilityAttributedString(for: NSRange(location: 0, length: 5)))
    let font = try XCTUnwrap(title.attribute(.accessibilityFont, at: 0, effectiveRange: nil) as? [NSAccessibility.FontAttributeKey: Any])
    XCTAssertGreaterThan(try XCTUnwrap(font[.fontSize] as? CGFloat), CTFontGetSize(presentation.body))
    let range = NSRange(location: 0, length: emoji.location)
    let frame = grid.accessibilityFrame(for: range)
    let first = grid.accessibilityFrame(for: NSRange(location: 0, length: 1))
    XCTAssertGreaterThan(frame.height, first.height, "AX bounds enclose every measured line, not only the first")
    let glyph = grid.accessibilityRange(for: CGPoint(x: first.midX, y: first.midY))
    XCTAssertEqual(glyph, NSRange(location: 0, length: 1))
    XCTAssertEqual(grid.accessibilityRange(for: CGPoint(x: -10000, y: -10000)).location, NSNotFound)
    var checked = 0
    for fragment in fragments {
      for run in CTLineGetGlyphRuns(fragment.line) as! [CTRun] {
        let count = CTRunGetGlyphCount(run), source = CTRunGetStringRange(run)
        var indices = [CFIndex](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
        var advances = [CGSize](repeating: .zero, count: count)
        CTRunGetStringIndices(run, CFRange(), &indices); CTRunGetPositions(run, CFRange(), &positions)
        CTRunGetAdvances(run, CFRange(), &advances)
        let boundaries = Array(Set(indices + [source.location + source.length])).sorted()
        for index in 0..<count where advances[index].width > 1 {
          guard let end = boundaries.first(where: { $0 > indices[index] }), end - indices[index] > 1 else { continue }
          let local = CGPoint(x: fragment.rect.minX + positions[index].x + advances[index].width * 0.75,
            y: fragment.rect.midY)
          let screen = window.convertPoint(toScreen: grid.convert(CGPoint(x: presentation.origin.x + local.x, y: presentation.origin.y + local.y), to: nil))
          let actual = grid.accessibilityRange(for: screen)
          XCTAssertLessThanOrEqual(actual.location, indices[index]); XCTAssertGreaterThanOrEqual(NSMaxRange(actual), end)
          checked += 1
        }
      }
    }
    XCTAssertGreaterThan(checked, 0, "the fixture exercises a shaped glyph spanning several UTF-16 units")
    XCTAssertTrue(peer.inputs.isEmpty, "accessibility reads do not move or edit the backend")
  }

  @MainActor
  func testRichAccessibilityFollowsPendingClickAndSecondaryCompositionSelections() async throws {
    var scene = pane("aa BB cc\n")
    scene.compose.cursors.append(.with { $0.id = 2; $0.position = 5; $0.utf16Position = 5 })
    let peer = try ScenePeer(pane: scene); defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid), unspecified = NSRange(location: NSNotFound, length: 0)
    grid.insertText("日本", replacementRange: unspecified)
    let pending = try XCTUnwrap(grid.focusedCompose)
    let point = try XCTUnwrap(pending.layout.text.caret(atUTF16: 8))
    editor.grid(grid, point: CGPoint(x: pending.origin.x + point.minX, y: pending.origin.y + point.midY),
      in: pending, extend: false, count: 1)
    XCTAssertEqual(grid.accessibilitySelectedTextRange(), NSRange(location: 8, length: 0))
    grid.setMarkedText("XY", selectedRange: NSRange(location: 0, length: 1), replacementRange: unspecified)
    let ranges = try XCTUnwrap(grid.accessibilitySelectedTextRanges()).map(\.rangeValue)
    XCTAssertEqual(ranges.count, 2)
    XCTAssertEqual(grid.accessibilitySelectedTextRange(), ranges[0])
    XCTAssertEqual(grid.accessibilitySelectedText(), "X")
    XCTAssertEqual(grid.accessibilityString(for: ranges[1]), "X")
    XCTAssertEqual(grid.accessibilityInsertionPointLineNumber(), grid.accessibilityLine(for: ranges[0].location))
  }

  @MainActor
  func testRichAccessibilityDoesNotPromoteAVisibleSecondaryWhenPrimaryIsOutsideTheSourceWindow() async throws {
    var scene = pane("Before\nTail\n")
    scene.compose.sourceStart = 7; scene.compose.text = "Tail\n"
    scene.compose.segments = [.with { $0.sourceStart = 7; $0.sourceEnd = 12; $0.displayEnd = 5 }]
    scene.compose.cursors.append(.with { $0.id = 2; $0.position = 8; $0.utf16Position = 8 })
    let peer = try ScenePeer(pane: scene); defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid)
    XCTAssertEqual(grid.accessibilitySelectedTextRange().location, NSNotFound)
    XCTAssertNil(grid.accessibilitySelectedText())
    XCTAssertEqual(grid.accessibilitySelectedTextRanges()?.map(\.rangeValue), [NSRange(location: 1, length: 0)])
    XCTAssertEqual(grid.accessibilityInsertionPointLineNumber(), NSNotFound)
  }

  @MainActor
  func testRichAccessibilityImagesHaveLabelsGeometryAndScopedSourceSelection() async throws {
    var scene = pane("Before ![pic](x.png) after text.\n")
    scene.compose.assetAuthority = 5; scene.compose.assetDocument = 7
    scene.compose.images = [.with { $0.start = 7; $0.end = 20; $0.target = "x.png"; $0.alt = "Picture"; $0.rendered = true }]
    let peer = try ScenePeer(pane: scene); defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose?.layout.text.attachments.count == 1 }
    let window = NSWindow(contentRect: CGRect(x: 90, y: 110, width: 1040, height: 700),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = try XCTUnwrap(editor.view)
    defer { window.contentView = nil; window.close() }
    let grid = try XCTUnwrap(editor.grid)
    let image = try XCTUnwrap(grid.accessibilityChildren()?.first as? NSAccessibilityElement)
    XCTAssertEqual(image.accessibilityRole(), .image)
    XCTAssertEqual(image.accessibilityLabel(), "Picture: loading")
    let stable = try XCTUnwrap(grid.accessibilityChildren()?.first as? NSAccessibilityElement)
    XCTAssertTrue(image === stable)
    let value = try XCTUnwrap(grid.accessibilityValue() as? String) as NSString
    let object = value.range(of: "\u{fffc}")
    let annotated = try XCTUnwrap(grid.accessibilityAttributedString(for: object))
    XCTAssertTrue((annotated.attribute(.accessibilityAttachment, at: 0, effectiveRange: nil) as? NSAccessibilityElement) === image)
    let frame = image.accessibilityFrame()
    XCTAssertGreaterThan(frame.width, 1); XCTAssertGreaterThan(frame.height, 1)
    XCTAssertTrue((grid.accessibilityHitTest(CGPoint(x: frame.midX, y: frame.midY)) as? NSAccessibilityElement) === image)
    XCTAssertEqual(grid.accessibilityRange(for: CGPoint(x: frame.midX, y: frame.midY)), object)
    XCTAssertEqual(grid.accessibilityVisibleChildren()?.count, 1)
    try await eventually { !peer.assets.isEmpty }
    peer.image(.with { $0.id = peer.assets.last!.id; $0.error = "Image not found" })
    try await eventually { image.accessibilityLabel() == "Picture: Image not found" }
    XCTAssertTrue((grid.accessibilityChildren()?.first as? NSAccessibilityElement) === image)
    var revealed = scene
    revealed.compose.images[0].rendered = false; revealed.compose.images[0].sourcePreview = true
    revealed.compose.cursors[0].position = 10; revealed.compose.cursors[0].utf16Position = 10
    revealed.compose.textContext.selectionStart = 10; revealed.compose.textContext.selectionEnd = 10
    revealed.compose.selectionRevision = 5; peer.show(revealed)
    try await eventually { grid.focusedCompose?.layout.text.attachments.first?.attachment.preview == true }
    XCTAssertEqual(grid.accessibilityValue() as? String, scene.compose.text, "a source preview adds no AX character")
    let markup = NSRange(location: 7, length: 13)
    let raw = try XCTUnwrap(grid.accessibilityAttributedString(for: markup))
    XCTAssertNil(raw.attribute(.accessibilityAttachment, at: 0, effectiveRange: nil))
    let preview = image.accessibilityFrame(), rawBounds = grid.accessibilityFrame(for: markup)
    XCTAssertTrue(rawBounds.contains(preview), "the source range also owns its measured preview bounds")
    XCTAssertEqual(grid.accessibilityRange(for: CGPoint(x: preview.midX, y: preview.midY)), markup)
    XCTAssertTrue((grid.accessibilityChildren()?.first as? NSAccessibilityElement) === image)
    XCTAssertTrue(image.accessibilityPerformPress())
    try await eventually { peer.inputs.count == 1 }
    XCTAssertEqual(peer.inputs[0].attachmentStart, 7); XCTAssertEqual(peer.inputs[0].position, 20)
    XCTAssertEqual(peer.inputs[0].scope.buffer, 3)
    var changed = scene; changed.compose.bufferRevision = 5; peer.show(changed)
    try await eventually { grid.focusedCompose?.pane.compose.bufferRevision == 5 }
    XCTAssertFalse(image.accessibilityPerformPress(), "a retained old AX object cannot act on a new source revision")
    XCTAssertNil(image.accessibilityLabel())
    XCTAssertEqual(peer.inputs.count, 1)
    let beforeReconnect = try XCTUnwrap(grid.accessibilityChildren()?.first as? NSAccessibilityElement)
    editor.detachAll()
    XCTAssertFalse(beforeReconnect.accessibilityPerformPress()); XCTAssertNil(beforeReconnect.accessibilityLabel())
    let newPeer = try ScenePeer(pane: changed); defer { newPeer.close() }
    editor.attach(socketPath: newPeer.path, app: nil)
    try await eventually { editor.connected && grid.accessibilityChildren()?.count == 1 }
    XCTAssertFalse((grid.accessibilityChildren()?.first as? NSAccessibilityElement) === beforeReconnect)
    XCTAssertFalse(beforeReconnect.accessibilityPerformPress(), "repeated backend scene IDs do not revive an old object")
    XCTAssertTrue(newPeer.inputs.isEmpty)
  }

  @MainActor
  func testMeasuredTableCapabilityRequiresBothDevelopmentSwitches() async throws {
    _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
    for (environment, rich, tables) in [
      ([:], false, false),
      (["FC_NATIVE_MEASURED_TABLES": "1"], false, false),
      (["FC_NATIVE_RICH_COMPOSE": "1"], true, false),
      (["FC_NATIVE_RICH_COMPOSE": "1", "FC_NATIVE_MEASURED_TABLES": "1"], true, true),
    ] {
      let peer = try ScenePeer(pane: pane("Capability check\n"))
      defer { peer.close() }
      let editor = NativeEditor(pasteboard: MemoryPasteboard(), environment: environment)
      defer { editor.detachAll() }
      editor.attach(socketPath: peer.path, app: nil)
      try await eventually { editor.connected && !peer.hellos.isEmpty }
      XCTAssertEqual(peer.hellos.count, 1)
      XCTAssertEqual(peer.hellos[0].richCompose, rich)
      XCTAssertEqual(peer.hellos[0].measuredTables, tables)
    }
  }

  @MainActor
  func testMarkedTextCapturesAllOriginalCaretsThroughReflowAndCommitsOneBatch() async throws {
    let source = "café and Tail\n"
    var initial = pane(source)
    initial.compose.cursors = [
      .with { $0.id = 1; $0.anchor = 0; $0.position = 5; $0.utf16Anchor = 0; $0.utf16Position = 4 },
      .with { $0.id = 2; $0.primary = true; $0.anchor = 10; $0.position = 14; $0.utf16Anchor = 9; $0.utf16Position = 13 },
    ]
    initial.compose.textContext.selectionStart = 9; initial.compose.textContext.selectionEnd = 13
    let peer = try ScenePeer(pane: initial)
    defer { peer.close() }
    let editor = richEditor()
    defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid)
    grid.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertEqual(grid.markedRange(), NSRange(location: 7, length: 2))
    XCTAssertEqual(grid.selectedRange(), NSRange(location: 9, length: 0))
    XCTAssertEqual(grid.focusedCompose?.layout.draftDisplayRanges.count, 2)
    XCTAssertEqual(grid.focusedCompose?.carets.count, 2)
    var actual = NSRange(location: NSNotFound, length: 0)
    XCTAssertEqual(grid.attributedSubstring(forProposedRange: NSRange(location: 0, length: 100), actualRange: &actual)?.string, "日本 and 日本\n")
    var changed = initial; changed.content.w = 40; changed.compose.bufferRevision = 5
    changed.compose.cursors.append(.with { $0.id = 3; $0.position = 8 })
    peer.show(changed)
    try await eventually { peer.lastApplied >= 2 }
    XCTAssertTrue(peer.inputs.isEmpty)
    grid.unmarkText(); grid.unmarkText()
    try await eventually { peer.inputs.count == 1 }
    let input = peer.inputs[0]
    XCTAssertEqual(input.sourceRevision, 4)
    XCTAssertEqual(input.replacementCursor, 2)
    XCTAssertEqual(input.replacementStart, 10); XCTAssertEqual(input.replacementEnd, 14)
    XCTAssertEqual(input.replacements.map(\.cursor), [1])
    XCTAssertEqual(input.replacements[0].start, 0); XCTAssertEqual(input.replacements[0].end, 5)
    XCTAssertEqual(try WirePaste(serializedBytes: input.payload).text, "日本")
  }

  @MainActor
  func testRetiringAnyCapturedCaretRecoversTheWholeCompositionWithoutEditingTheSurvivor() async throws {
    var initial = pane("first Tail\n")
    initial.compose.cursors.append(.with { $0.id = 2; $0.position = 6 })
    let peer = try ScenePeer(pane: initial)
    defer { peer.close() }
    let editor = richEditor()
    defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid)
    grid.setMarkedText("保存", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    initial.compose.cursors.removeLast()
    peer.show(initial)
    try await eventually { !grid.hasMarkedText() }
    XCTAssertTrue(peer.inputs.isEmpty)
    XCTAssertEqual(editor.uninsertedText, ["保存"])
  }

  @MainActor
  func testMarkedCommitWaitsForModalOwnershipAndResigningCommitsOnlyOnce() async throws {
    let initial = pane("original\n"), peer = try ScenePeer(pane: initial)
    defer { peer.close() }
    let editor = richEditor()
    defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid)
    grid.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    var modal = initial; modal.compose.keyboard = false
    peer.show(modal)
    try await eventually { peer.inputs.count == 1 }
    let waiting = peer.reply(.with { $0.id = 1; $0.needsLayout = true }, pane: modal)
    try await eventually { peer.lastApplied >= waiting }
    XCTAssertFalse(grid.hasMarkedText())
    editor.send(.key(.with { $0.key = "Escape" }))
    try await eventually { peer.keys.count == 1 }
    XCTAssertEqual(peer.inputs.count, 1, "a waiting replacement must not spin or bypass a modal")
    peer.show(initial)
    try await eventually { peer.inputs.count == 2 }
    XCTAssertEqual(peer.inputs[1].id, 1)
    XCTAssertEqual(try WirePaste(serializedBytes: peer.inputs[1].payload).text, "日本")
    let accepted = peer.reply(.with { $0.id = 1; $0.accepted = true }, pane: initial)
    try await eventually { peer.lastApplied >= accepted }
    grid.setMarkedText("次", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(grid.resignFirstResponder()); grid.unmarkText()
    try await eventually { peer.inputs.count == 3 }
    XCTAssertEqual(peer.inputs[2].id, 2)
    XCTAssertEqual(try WirePaste(serializedBytes: peer.inputs[2].payload).text, "次")
  }

  @MainActor
  func testMarkedTextReflowsAndCommitsItsCapturedSourceOnceThenRetainsRejectedTextForExplicitCopy() async throws {
    let source = "before café after\n"
    var initial = pane(source, width: 24)
    initial.compose.cursors[0].position = 12; initial.compose.cursors[0].anchor = 7
    initial.compose.textContext.selectionStart = 7; initial.compose.textContext.selectionEnd = 11
    let peer = try ScenePeer(pane: initial)
    defer { peer.close() }
    let clipboard = MemoryPasteboard(), editor = richEditor(pasteboard: clipboard)
    defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid), draft = String(repeating: "日本語 ", count: 8)
    grid.setMarkedText(NSAttributedString(string: draft, attributes: [.markedClauseSegment: 1]),
      selectedRange: NSRange(location: 2, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(grid.hasMarkedText())
    XCTAssertEqual(grid.markedRange(), NSRange(location: 7, length: draft.utf16.count))
    XCTAssertEqual(grid.selectedRange(), NSRange(location: 9, length: 1))
    XCTAssertEqual(grid.accessibilitySelectedTextRange(), NSRange(location: 9, length: 1))
    var actual = NSRange(location: NSNotFound, length: 0)
    XCTAssertEqual(grid.attributedSubstring(forProposedRange: grid.markedRange(), actualRange: &actual)?.string, draft)
    let presentation = try XCTUnwrap(grid.focusedCompose)
    XCTAssertNotNil(presentation.textServiceRect(for: grid.selectedRange()))
    XCTAssertGreaterThan(presentation.layout.text.fragments.count, 1)
    var external = pane("prefix " + source, revision: 5, width: 48)
    external.compose.cursors[0].position = 19; external.compose.cursors[0].anchor = 14
    peer.show(external)
    try await eventually { peer.lastApplied >= 2 }
    XCTAssertTrue(peer.inputs.isEmpty, "marked-text updates never edit the source")
    XCTAssertEqual(grid.focusedCompose?.pane.compose.bufferRevision, 4, "the provisional snapshot must not relabel old source coordinates")
    XCTAssertEqual(grid.selectedRange(), NSRange(location: 9, length: 1))
    grid.unmarkText(); grid.unmarkText()
    try await eventually { peer.inputs.count == 1 }
    XCTAssertFalse(grid.hasMarkedText())
    let input = peer.inputs[0]
    XCTAssertEqual(input.replacementStart, 7); XCTAssertEqual(input.replacementEnd, 12)
    XCTAssertEqual(input.sourceRevision, 4)
    XCTAssertEqual(try WirePaste(serializedBytes: input.payload).text, draft)
    let sequence = peer.reply(.with { $0.id = input.id; $0.cancelled = true; $0.error = "The original range changed." }, pane: external)
    try await eventually { peer.lastApplied >= sequence }
    XCTAssertEqual(editor.uninsertedText, [draft]); XCTAssertNil(clipboard.editorText)
    editor.copyUninsertedText()
    XCTAssertEqual(clipboard.editorText, draft); XCTAssertEqual(editor.uninsertedText, [draft], "copying must not destroy the recovery text")
  }

  @MainActor
  func testCompositionCancellationAndRetiredBufferNeverCommitIntoAnotherView() async throws {
    let peer = try ScenePeer(pane: pane("original\n"))
    defer { peer.close() }
    let editor = richEditor()
    defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid)
    grid.setMarkedText("取消", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    grid.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
    XCTAssertFalse(grid.hasMarkedText()); XCTAssertTrue(editor.uninsertedText.isEmpty)
    grid.setMarkedText("保存", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    var replacement = pane("replacement\n"); replacement.compose.viewport.epoch = 8
    peer.show(replacement)
    try await eventually { peer.lastApplied >= 2 }
    XCTAssertFalse(grid.hasMarkedText()); XCTAssertTrue(peer.inputs.isEmpty)
    XCTAssertEqual(editor.uninsertedText, ["保存"])
    XCTAssertEqual(grid.focusedCompose?.pane.compose.text, "replacement\n")
  }

  @MainActor
  func testDependentMarkedDraftUsesTheAcceptedReceiptInsteadOfANewerSceneCursor() async throws {
    var before = pane("alpha Tail")
    before.compose.cursors[0].anchor = 0; before.compose.cursors[0].position = 5
    before.compose.cursors[0].utf16Anchor = 0; before.compose.cursors[0].utf16Position = 5
    before.compose.textContext.selectionStart = 0; before.compose.textContext.selectionEnd = 5
    let peer = try ScenePeer(pane: before); defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid)
    grid.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    grid.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertFalse(grid.hasMarkedText())
    XCTAssertEqual(grid.selectedRange(), NSRange(location: 2, length: 0))
    XCTAssertEqual(grid.attributedSubstring(forProposedRange: NSRange(location: 0, length: 100), actualRange: nil)?.string, "日本 Tail")
    XCTAssertEqual(grid.focusedCompose?.layout.text.projection.text, "日本 Tail")
    try await eventually { peer.inputs.count == 1 }
    grid.setMarkedText("語", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertEqual(grid.markedRange(), NSRange(location: 2, length: 1))
    XCTAssertEqual(grid.selectedRange(), NSRange(location: 3, length: 0))
    XCTAssertEqual(grid.focusedCompose?.layout.text.projection.text, "日本語 Tail")
    var committed = pane("日本 Tail", revision: 5)
    committed.compose.ready = false // Receipt source is current while formatting still owes its projection.
    committed.compose.cursors[0].position = 6; committed.compose.cursors[0].utf16Position = 2
    committed.compose.textContext.selectionStart = 2; committed.compose.textContext.selectionEnd = 2
    let receipt = WireComposeEditReceipt.with {
      $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.cursors = [1]; $0.pane = committed.compose
    }
    let newer = pane("X日本 Tail", revision: 6)
    peer.reply(.with { $0.id = 1; $0.accepted = true; $0.edit = receipt }, pane: newer)
    try await eventually { grid.markedRange().location == 2 && grid.focusedCompose?.pane.compose.bufferRevision == 5 }
    XCTAssertTrue(grid.focusedCompose?.layout.text.projection.text.contains("日本語 Tail") == true)
    XCTAssertEqual(grid.selectedRange(), NSRange(location: 3, length: 0))
    grid.insertText("語", replacementRange: NSRange(location: NSNotFound, length: 0))
    try await eventually { peer.inputs.count == 2 }
    let next = peer.inputs[1]
    XCTAssertEqual(next.sourceRevision, 5); XCTAssertEqual(next.replacementStart, 6); XCTAssertEqual(next.replacementEnd, 6)
    XCTAssertEqual(next.replacementCursor, 1)
    peer.reply(.with { $0.id = 2; $0.accepted = true })
  }

  @MainActor
  func testExplicitReplacementOfPendingPrefixAndThreeCommitsWaitForTheirOwnReceipts() async throws {
    let unspecified = NSRange(location: NSNotFound, length: 0)
    var source = pane("alpha Tail")
    source.compose.cursors[0].anchor = 0; source.compose.cursors[0].position = 5
    source.compose.cursors[0].utf16Anchor = 0; source.compose.cursors[0].utf16Position = 5
    source.compose.textContext.selectionEnd = 5
    let peer = try ScenePeer(pane: source); defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid)
    grid.insertText("beta", replacementRange: unspecified)
    XCTAssertEqual(grid.selectedRange().location, 4)
    XCTAssertEqual(grid.focusedCompose?.layout.text.projection.text, "beta Tail")
    grid.insertText("theta", replacementRange: NSRange(location: 0, length: 4))
    grid.insertText("!", replacementRange: unspecified)
    XCTAssertFalse(grid.hasMarkedText())
    XCTAssertEqual(grid.selectedRange().location, 6)
    XCTAssertEqual(grid.focusedCompose?.layout.text.projection.text, "theta! Tail")
    XCTAssertEqual(grid.attributedSubstring(forProposedRange: NSRange(location: 0, length: 100), actualRange: nil)?.string, "theta! Tail")
    try await eventually { peer.inputs.count == 1 }
    func receipt(_ text: String, cursor: UInt64, revision: UInt64) -> (WirePane, WireComposeEditReceipt) {
      var current = pane(text, revision: revision)
      current.compose.cursors[0].position = cursor; current.compose.cursors[0].utf16Position = cursor
      current.compose.textContext.selectionStart = cursor; current.compose.textContext.selectionEnd = cursor
      return (current, .with { $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.cursors = [1]; $0.pane = current.compose })
    }
    let first = receipt("beta Tail", cursor: 4, revision: 5)
    peer.reply(.with { $0.id = 1; $0.accepted = true; $0.edit = first.1 }, pane: first.0)
    try await eventually { peer.inputs.count == 2 }
    XCTAssertEqual(peer.inputs[1].sourceRevision, 5)
    XCTAssertEqual(peer.inputs[1].replacementStart, 0); XCTAssertEqual(peer.inputs[1].replacementEnd, 4)
    XCTAssertEqual(try WirePaste(serializedBytes: peer.inputs[1].payload).text, "theta")
    XCTAssertEqual(grid.focusedCompose?.layout.text.projection.text, "theta! Tail")
    let second = receipt("theta Tail", cursor: 5, revision: 6)
    peer.reply(.with { $0.id = 2; $0.accepted = true; $0.edit = second.1 }, pane: second.0)
    try await eventually { peer.inputs.count == 3 }
    XCTAssertEqual(peer.inputs[2].sourceRevision, 6)
    XCTAssertEqual(peer.inputs[2].replacementStart, 5); XCTAssertEqual(peer.inputs[2].replacementEnd, 5)
    XCTAssertEqual(try WirePaste(serializedBytes: peer.inputs[2].payload).text, "!")
    let third = receipt("theta! Tail", cursor: 6, revision: 7)
    let sequence = peer.reply(.with { $0.id = 3; $0.accepted = true; $0.edit = third.1 }, pane: third.0)
    try await eventually { peer.lastApplied >= sequence && grid.focusedCompose?.pane.compose.bufferRevision == 7 }
    XCTAssertEqual(grid.selectedRange().location, 6)
    XCTAssertTrue(editor.uninsertedText.isEmpty)
  }

  @MainActor
  func testLiteralNewlinePreviewUsesDeclaredPolicyBeforeTheReply() async throws {
    var source = pane("tail\r\n"); source.compose.nativeNewline = 2
    let peer = try ScenePeer(pane: source); defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid), unspecified = NSRange(location: NSNotFound, length: 0)
    grid.insertText("🙂\n", replacementRange: unspecified)
    XCTAssertFalse(grid.hasMarkedText())
    XCTAssertEqual(grid.selectedRange().location, 4)
    XCTAssertEqual(grid.attributedSubstring(forProposedRange: NSRange(location: 0, length: 100), actualRange: nil)?.string, "🙂\r\ntail\r\n")
    grid.setMarkedText("語", selectedRange: NSRange(location: 1, length: 0), replacementRange: unspecified)
    XCTAssertEqual(grid.markedRange(), NSRange(location: 4, length: 1))
    XCTAssertEqual(grid.selectedRange().location, 5)
    XCTAssertEqual(grid.attributedSubstring(forProposedRange: NSRange(location: 0, length: 100), actualRange: nil)?.string, "🙂\r\n語tail\r\n")
    try await eventually { peer.inputs.count == 1 }
    XCTAssertTrue(peer.inputs[0].textInput)
    XCTAssertEqual(try WirePaste(serializedBytes: peer.inputs[0].payload).text, "🙂\n")
    peer.reply(.with { $0.id = 1; $0.cancelled = true })
    try await eventually { editor.uninsertedText.count == 2 }
    XCTAssertEqual(editor.uninsertedText, ["🙂\r\n", "語"])
  }

  @MainActor
  func testBroadcastAfterPrimaryOnlyCommitRequiresTheSecondarysSourceWitness() async throws {
    for witnessed in [true, false] {
      let unspecified = NSRange(location: NSNotFound, length: 0)
      var source = pane("cat dog")
      source.compose.cursors.append(.with { $0.id = 2; $0.position = 7; $0.anchor = 4; $0.utf16Position = 7; $0.utf16Anchor = 4 })
      let peer = try ScenePeer(pane: source); defer { peer.close() }
      let editor = richEditor(); defer { editor.detachAll() }
      editor.attach(socketPath: peer.path, app: nil)
      try await eventually { editor.grid?.focusedCompose != nil }
      let grid = try XCTUnwrap(editor.grid)
      grid.insertText("日", replacementRange: NSRange(location: 0, length: 3))
      grid.insertText("本", replacementRange: unspecified)
      XCTAssertEqual(grid.attributedSubstring(forProposedRange: NSRange(location: 0, length: 100), actualRange: nil)?.string, "日本 本")
      try await eventually { peer.inputs.count == 1 }
      XCTAssertEqual(peer.inputs[0].observedCursors.map(\.id), [1, 2])
      XCTAssertEqual(peer.inputs[0].observedCursors[1].anchor, 4)
      var current = pane("日 dog", revision: 5)
      current.compose.cursors = [.with { $0.id = 1; $0.primary = true; $0.position = 3; $0.utf16Position = 1 },
        .with { $0.id = 2; $0.position = 7; $0.anchor = 4; $0.utf16Position = 5; $0.utf16Anchor = 2 }]
      current.compose.textContext.selectionStart = 1; current.compose.textContext.selectionEnd = 1
      let receipt = WireComposeEditReceipt.with {
        $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.cursors = [1]
        $0.preservedCursors = witnessed ? [1, 2] : [1]; $0.pane = current.compose
      }
      peer.reply(.with { $0.id = 1; $0.accepted = true; $0.edit = receipt }, pane: current)
      if witnessed {
        try await eventually { peer.inputs.count == 2 }
        XCTAssertEqual(peer.inputs[1].replacementStart, 3); XCTAssertEqual(peer.inputs[1].replacementEnd, 3)
        XCTAssertEqual(peer.inputs[1].replacements.count, 1)
        XCTAssertEqual(peer.inputs[1].replacements[0].cursor, 2)
        XCTAssertEqual(peer.inputs[1].replacements[0].start, 4); XCTAssertEqual(peer.inputs[1].replacements[0].end, 7)
        XCTAssertEqual(peer.inputs[1].observedCursors.map(\.id), [1, 2])
        XCTAssertEqual(try WirePaste(serializedBytes: peer.inputs[1].payload).text, "本")
        XCTAssertTrue(editor.uninsertedText.isEmpty)
        peer.reply(.with { $0.id = 2; $0.accepted = true })
      } else {
        try await eventually { editor.uninsertedText == ["本"] }
        XCTAssertEqual(peer.inputs.count, 1, "the primary must not be edited as a subset of the failed broadcast")
      }
    }
  }

  @MainActor
  func testInitialPrimaryOnlyPrefixRetainsUntouchedSecondaryDuringAPendingClickAndConversion() async throws {
    var initial = pane("aa BB cc")
    initial.compose.cursors[0].utf16Position = 0
    initial.compose.cursors.append(.with { $0.id = 2; $0.position = 3; $0.utf16Position = 3 })
    let peer = try ScenePeer(pane: initial); defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid)
    grid.insertText("ab", replacementRange: NSRange(location: 0, length: 0))
    try await eventually { peer.inputs.count == 1 }
    XCTAssertEqual(grid.focusedCompose?.carets.count, 2)
    let prefix = try XCTUnwrap(grid.focusedCompose), range = try XCTUnwrap(prefix.layout.draftDisplayRanges[1])
    let rect = try XCTUnwrap(prefix.layout.text.caret(atUTF16: range.location + 1))
    editor.grid(grid, point: CGPoint(x: prefix.origin.x + rect.minX, y: prefix.origin.y + rect.midY), in: prefix, extend: false, count: 1)
    XCTAssertEqual(grid.focusedCompose?.carets.count, 2)
    grid.setMarkedText("X", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertEqual(grid.focusedCompose?.carets.count, 2)
    XCTAssertEqual(grid.focusedCompose?.layout.text.projection.text, "aXbaa XBB cc")
    XCTAssertTrue(editor.uninsertedText.isEmpty)
  }

  @MainActor
  func testCompletedFormattingReplacesVisibleMarkupDuringAVirtualComposition() async throws {
    let source = "# Title\n\n**bold**\n\nTail\n"
    var initial = pane(source)
    initial.compose.text = String(source.dropFirst(2))
    initial.compose.segments = [.with { $0.sourceEnd = 2; $0.kind = 1 },
      .with { $0.sourceStart = 2; $0.sourceEnd = UInt64(source.utf8.count); $0.displayEnd = UInt64(source.utf8.count - 2) }]
    initial.compose.spans = [.with { $0.start = 0; $0.end = 8; $0.role = 1 }, .with { $0.start = 9; $0.end = 17; $0.flags = 1 }]
    initial.compose.cursors[0].position = UInt64(source.utf8.count); initial.compose.cursors[0].utf16Position = UInt64(source.utf16.count)
    initial.compose.textContext.selectionStart = UInt64(source.utf16.count); initial.compose.textContext.selectionEnd = UInt64(source.utf16.count)
    initial.compose.ready = false; initial.compose.currentProjection = true
    let peer = try ScenePeer(pane: initial); defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid), unspecified = NSRange(location: NSNotFound, length: 0)
    grid.insertText("abc", replacementRange: unspecified)
    let prefix = try XCTUnwrap(grid.focusedCompose), range = try XCTUnwrap(prefix.layout.draftDisplayRanges[1])
    let rect = try XCTUnwrap(prefix.layout.text.caret(atUTF16: range.location + 1))
    editor.grid(grid, point: CGPoint(x: prefix.origin.x + rect.minX, y: prefix.origin.y + rect.midY), in: prefix, extend: false, count: 1)
    grid.setMarkedText("日", selectedRange: NSRange(location: 1, length: 0), replacementRange: unspecified)
    XCTAssertTrue(try XCTUnwrap(grid.focusedCompose).layout.text.projection.text.contains("**bold**"))
    var ready = initial
    ready.compose.ready = true; ready.compose.projectionRevision = 5
    ready.compose.text = "Title\n\nbold\n\nTail\n"
    ready.compose.segments = [.with { $0.sourceEnd = 2; $0.kind = 1 },
      .with { $0.sourceStart = 2; $0.sourceEnd = 9; $0.displayEnd = 7 },
      .with { $0.sourceStart = 9; $0.sourceEnd = 11; $0.displayStart = 7; $0.displayEnd = 7; $0.kind = 1 },
      .with { $0.sourceStart = 11; $0.sourceEnd = 15; $0.displayStart = 7; $0.displayEnd = 11 },
      .with { $0.sourceStart = 15; $0.sourceEnd = 17; $0.displayStart = 11; $0.displayEnd = 11; $0.kind = 1 },
      .with { $0.sourceStart = 17; $0.sourceEnd = UInt64(source.utf8.count); $0.displayStart = 11; $0.displayEnd = UInt64(ready.compose.text.utf8.count) }]
    let sequence = peer.lastApplied; peer.show(ready)
    try await eventually { peer.lastApplied > sequence }
    XCTAssertEqual(grid.focusedCompose?.layout.text.projection.text, "Title\n\nbold\n\nTail\na日bc")
    XCTAssertEqual(grid.markedRange(), NSRange(location: source.utf16.count + 1, length: 1))
    XCTAssertEqual(grid.focusedCompose?.scope.projectionRevision, 5)
    XCTAssertTrue(editor.uninsertedText.isEmpty)
  }

  @MainActor
  func testPendingClickAtSoftWrapKeepsCaretAndCandidateOnTheCapturedVisualLine() async throws {
    let peer = try ScenePeer(pane: pane("Tail\n", width: 20)); defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid), prefix = "A long pending line that wraps across several rows "
    grid.insertText(prefix, replacementRange: NSRange(location: NSNotFound, length: 0))
    try await eventually { peer.inputs.count == 1 }
    let pending = try XCTUnwrap(grid.focusedCompose)
    XCTAssertGreaterThan(pending.layout.text.fragments.count, 1)
    let boundary = pending.layout.text.fragments[1].range.location
    XCTAssertLessThan(boundary, prefix.utf16.count)
    let upstream = try XCTUnwrap(pending.layout.text.caret(atUTF16: boundary, affinity: .upstream))
    let downstream = try XCTUnwrap(pending.layout.text.caret(atUTF16: boundary, affinity: .downstream))
    XCTAssertGreaterThan(downstream.minY, upstream.minY)
    editor.grid(grid, point: CGPoint(x: pending.origin.x + upstream.minX, y: pending.origin.y + upstream.midY),
      in: pending, extend: false, count: 1)
    let clicked = try XCTUnwrap(grid.focusedCompose), caret = try XCTUnwrap(clicked.caret)
    XCTAssertEqual(caret.minY - clicked.origin.y, upstream.minY, accuracy: 0.01)
    let candidate = try XCTUnwrap(clicked.textServiceRect(for: grid.selectedRange()))
    XCTAssertEqual(candidate.rect.minY, upstream.minY, accuracy: 0.01)
    XCTAssertEqual(candidate.range, grid.selectedRange())
    var inserted = pane(prefix + "Tail\n", revision: 5, width: 20)
    inserted.compose.cursors[0].position = UInt64(prefix.utf8.count); inserted.compose.cursors[0].utf16Position = UInt64(prefix.utf16.count)
    inserted.compose.textContext.selectionStart = UInt64(prefix.utf16.count); inserted.compose.textContext.selectionEnd = UInt64(prefix.utf16.count)
    let edit = WireComposeEditReceipt.with {
      $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.cursors = [1]; $0.pane = inserted.compose
    }
    peer.reply(.with { $0.id = 1; $0.accepted = true; $0.edit = edit }, pane: inserted)
    try await eventually { peer.inputs.count == 2 }
    XCTAssertEqual(peer.inputs[1].affinity, 1)
    let following = try XCTUnwrap(grid.focusedCompose)
    XCTAssertEqual(try XCTUnwrap(following.caret).minY - following.origin.y, upstream.minY, accuracy: 0.01)
    XCTAssertEqual(try XCTUnwrap(following.textServiceRect(for: grid.selectedRange())).rect.minY, upstream.minY, accuracy: 0.01)
    inserted.compose.cursors[0].position = UInt64(boundary); inserted.compose.cursors[0].utf16Position = UInt64(boundary)
    inserted.compose.textContext.selectionStart = UInt64(boundary); inserted.compose.textContext.selectionEnd = UInt64(boundary)
    inserted.compose.selectionRevision = 6
    let result = WireComposeEditReceipt.with {
      $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.pane = inserted.compose
    }
    let sequence = peer.reply(.with { $0.id = 2; $0.accepted = true; $0.result = result
      $0.carets = [.with { $0.id = 1; $0.position = UInt64(boundary); $0.affinity = 1 }] }, pane: inserted)
    try await eventually { peer.lastApplied >= sequence }
    let accepted = try XCTUnwrap(grid.focusedCompose)
    XCTAssertEqual(try XCTUnwrap(accepted.caret).minY - accepted.origin.y, upstream.minY, accuracy: 0.01)
    XCTAssertEqual(try XCTUnwrap(accepted.textServiceRect(for: grid.selectedRange())).rect.minY, upstream.minY, accuracy: 0.01)
  }

  @MainActor
  func testPendingDragCanCrossFromAnInsertIntoSourceAndKeepItsTextServiceSelectionDuringReflow() async throws {
    let initial = pane("Tail\n"), peer = try ScenePeer(pane: initial)
    defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid)
    grid.insertText("abcd", replacementRange: NSRange(location: NSNotFound, length: 0))
    try await eventually { peer.inputs.count == 1 }
    func point(_ position: Int, extend: Bool) throws {
      let current = try XCTUnwrap(grid.focusedCompose), rect = try XCTUnwrap(current.layout.text.caret(atUTF16: position))
      editor.grid(grid, point: CGPoint(x: current.origin.x + rect.minX, y: current.origin.y + rect.midY), in: current, extend: extend, count: 1)
    }
    try point(1, extend: false); try point(6, extend: true)
    XCTAssertEqual(grid.selectedRange(), NSRange(location: 1, length: 5))
    var actual = NSRange(location: NSNotFound, length: 0)
    XCTAssertEqual(grid.attributedSubstring(forProposedRange: grid.selectedRange(), actualRange: &actual)?.string, "bcdTa")
    XCTAssertEqual(actual, grid.selectedRange())
    var preferences = ComposePreferences(); preferences.bodySize = 24
    grid.setComposePreferences(preferences, zoom: 1)
    XCTAssertEqual(grid.selectedRange(), NSRange(location: 1, length: 5))
    let candidate = try XCTUnwrap(grid.focusedCompose?.textServiceRect(for: grid.selectedRange()))
    XCTAssertEqual(candidate.range, grid.selectedRange()); XCTAssertGreaterThan(candidate.rect.width, 0)
    XCTAssertEqual(peer.inputs.count, 1)
    var inserted = pane("abcdTail\n", revision: 5)
    inserted.compose.cursors[0].position = 4; inserted.compose.cursors[0].utf16Position = 4
    inserted.compose.textContext.selectionStart = 4; inserted.compose.textContext.selectionEnd = 4
    let edit = WireComposeEditReceipt.with {
      $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.cursors = [1]; $0.pane = inserted.compose
    }
    peer.reply(.with { $0.id = 1; $0.accepted = true; $0.edit = edit }, pane: inserted)
    try await eventually { peer.inputs.count == 2 }
    XCTAssertEqual(grid.selectedRange(), NSRange(location: 1, length: 5))
    inserted.compose.cursors[0].position = 1; inserted.compose.cursors[0].utf16Position = 1
    inserted.compose.textContext.selectionStart = 1; inserted.compose.textContext.selectionEnd = 1
    inserted.compose.selectionRevision = 6
    let result = WireComposeEditReceipt.with {
      $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.pane = inserted.compose
    }
    peer.reply(.with { $0.id = 2; $0.accepted = true; $0.result = result }, pane: inserted)
    try await eventually { peer.inputs.count == 3 }
    XCTAssertEqual(peer.inputs[2].position, 6); XCTAssertEqual(peer.inputs[2].sourceRevision, 5)
    XCTAssertEqual(grid.selectedRange(), NSRange(location: 1, length: 5))
    peer.reply(.with { $0.id = 3; $0.accepted = true })
  }

  @MainActor
  func testPendingClickInsideAnotherDraftPreviewsEveryCaretAndPartialIMEBeforeReplies() async throws {
    var initial = pane("aa BB cc\n")
    initial.compose.cursors[0].utf16Position = 0
    initial.compose.cursors.append(.with { $0.id = 2; $0.position = 3; $0.utf16Position = 3 })
    let peer = try ScenePeer(pane: initial); defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid), unspecified = NSRange(location: NSNotFound, length: 0)
    grid.insertText("日本", replacementRange: unspecified)
    try await eventually { peer.inputs.count == 1 }
    let prefix = try XCTUnwrap(grid.focusedCompose), range = try XCTUnwrap(prefix.layout.draftDisplayRanges[2])
    let rect = try XCTUnwrap(prefix.layout.text.caret(atUTF16: range.location + 1))
    editor.grid(grid, point: CGPoint(x: prefix.origin.x + rect.minX, y: prefix.origin.y + rect.midY), in: prefix, extend: false, count: 1)
    XCTAssertEqual(grid.selectedRange(), NSRange(location: 6, length: 0))
    grid.setMarkedText("X", selectedRange: NSRange(location: 1, length: 0), replacementRange: unspecified)
    XCTAssertEqual(grid.markedRange(), NSRange(location: 6, length: 1))
    XCTAssertEqual(grid.focusedCompose?.layout.text.projection.text, "日本aa 日X本XBB cc\n")
    XCTAssertEqual(grid.focusedCompose?.carets.count, 2)
    grid.setMarkedText("YZ", selectedRange: NSRange(location: 1, length: 0), replacementRange: unspecified)
    XCTAssertEqual(grid.markedRange(), NSRange(location: 6, length: 2)); XCTAssertEqual(grid.selectedRange().location, 7)
    XCTAssertEqual(grid.focusedCompose?.layout.text.projection.text, "日本aa 日YZ本YZBB cc\n")
    let candidate = try XCTUnwrap(grid.focusedCompose?.textServiceRect(for: grid.selectedRange()))
    XCTAssertEqual(candidate.range, grid.selectedRange()); XCTAssertGreaterThan(candidate.rect.height, 0)
    grid.insertText("YZ", replacementRange: unspecified)
    XCTAssertEqual(peer.inputs.count, 1)
    editor.send(.action(name: "save", argsJson: ""))
    XCTAssertEqual(grid.focusedCompose?.layout.text.projection.text, "日本aa 日YZ本YZBB cc\n")
    var inserted = pane("日本aa 日本BB cc\n", revision: 5)
    inserted.compose.cursors = [.with { $0.id = 1; $0.primary = true; $0.position = 6; $0.utf16Position = 2 },
      .with { $0.id = 2; $0.position = 15; $0.utf16Position = 7 }]
    inserted.compose.textContext.selectionStart = 2; inserted.compose.textContext.selectionEnd = 2
    let edit = WireComposeEditReceipt.with {
      $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.cursors = [1, 2]; $0.pane = inserted.compose
    }
    peer.reply(.with { $0.id = 1; $0.accepted = true; $0.edit = edit }, pane: inserted)
    try await eventually { peer.inputs.count == 2 }
    XCTAssertEqual(peer.inputs[1].position, 12)
    XCTAssertEqual(grid.focusedCompose?.layout.text.projection.text, "日本aa 日YZ本YZBB cc\n")
    inserted.compose.cursors[0].position = 12; inserted.compose.cursors[0].utf16Position = 6
    inserted.compose.textContext.selectionStart = 6; inserted.compose.textContext.selectionEnd = 6
    inserted.compose.selectionRevision = 8
    let result = WireComposeEditReceipt.with {
      $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.pane = inserted.compose
    }
    peer.reply(.with { $0.id = 2; $0.accepted = true; $0.result = result }, pane: inserted)
    try await eventually { peer.inputs.count == 3 }
    XCTAssertEqual(peer.inputs[2].sourceRevision, 5)
    XCTAssertEqual(peer.inputs[2].replacementStart, 12); XCTAssertEqual(peer.inputs[2].replacements.first?.start, 15)
    XCTAssertEqual(try WirePaste(serializedBytes: peer.inputs[2].payload).text, "YZ")
    XCTAssertTrue(editor.uninsertedText.isEmpty)
    var committed = pane("日本aa 日YZ本YZBB cc\n", revision: 6)
    committed.compose.cursors = [.with { $0.id = 1; $0.primary = true; $0.position = 14; $0.utf16Position = 8 },
      .with { $0.id = 2; $0.position = 19; $0.utf16Position = 11 }]
    committed.compose.textContext.selectionStart = 8; committed.compose.textContext.selectionEnd = 8
    let receipt = WireComposeEditReceipt.with {
      $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.cursors = [1, 2]; $0.pane = committed.compose
    }
    peer.reply(.with { $0.id = 3; $0.accepted = true; $0.edit = receipt }, pane: committed)
    try await eventually { peer.inputs.count == 4 }
    XCTAssertEqual(grid.focusedCompose?.layout.text.projection.text, "日本aa 日YZ本YZBB cc\n")
    peer.reply(.with { $0.id = 4; $0.accepted = true })
  }

  @MainActor
  func testExplicitPendingConversionKeepsSecondaryFeedbackAcrossBindingAndFollowingBroadcast() async throws {
    var initial = pane("aa BB cc")
    initial.compose.cursors[0].utf16Position = 0
    initial.compose.cursors.append(.with { $0.id = 2; $0.position = 3; $0.utf16Position = 3 })
    let peer = try ScenePeer(pane: initial); defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid), unspecified = NSRange(location: NSNotFound, length: 0)
    grid.insertText("日本", replacementRange: unspecified)
    let prefix = try XCTUnwrap(grid.focusedCompose), range = try XCTUnwrap(prefix.layout.draftDisplayRanges[2])
    let rect = try XCTUnwrap(prefix.layout.text.caret(atUTF16: range.location + 1))
    editor.grid(grid, point: CGPoint(x: prefix.origin.x + rect.minX, y: prefix.origin.y + rect.midY), in: prefix, extend: false, count: 1)
    grid.setMarkedText("X", selectedRange: NSRange(location: 1, length: 0), replacementRange: grid.selectedRange())
    XCTAssertEqual(grid.focusedCompose?.carets.count, 2)
    var actual = pane("日本aa 日本BB cc", revision: 5)
    actual.compose.cursors = [.with { $0.id = 1; $0.primary = true; $0.position = 6; $0.utf16Position = 2 },
      .with { $0.id = 2; $0.position = 15; $0.utf16Position = 7 }]
    actual.compose.textContext.selectionStart = 2; actual.compose.textContext.selectionEnd = 2
    func receipt(_ pane: WirePane, edited: [UInt64] = [], preserved: [UInt64] = []) -> WireComposeEditReceipt {
      .with { $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.cursors = edited; $0.preservedCursors = preserved; $0.pane = pane.compose }
    }
    try await eventually { peer.inputs.count == 1 }
    peer.reply(.with { $0.id = 1; $0.accepted = true; $0.edit = receipt(actual, edited: [1, 2]) }, pane: actual)
    try await eventually { peer.inputs.count == 2 }
    actual.compose.cursors[0].position = 12; actual.compose.cursors[0].utf16Position = 6
    actual.compose.textContext.selectionStart = 6; actual.compose.textContext.selectionEnd = 6
    actual.compose.selectionRevision = 7
    let sequence = peer.reply(.with { $0.id = 2; $0.accepted = true; $0.result = receipt(actual) }, pane: actual)
    try await eventually { peer.lastApplied >= sequence }
    XCTAssertTrue(grid.hasMarkedText()); XCTAssertEqual(grid.focusedCompose?.carets.count, 2)
    XCTAssertEqual(grid.focusedCompose?.layout.text.projection.text, "日本aa 日X本BB cc")
    grid.insertText("X", replacementRange: unspecified)
    grid.insertText("Y", replacementRange: unspecified)
    try await eventually { peer.inputs.count == 3 }
    XCTAssertTrue(peer.inputs[2].replacements.isEmpty); XCTAssertEqual(Set(peer.inputs[2].observedCursors.map(\.id)), [1, 2])
    actual = pane("日本aa 日X本BB cc", revision: 6)
    actual.compose.cursors = [.with { $0.id = 1; $0.primary = true; $0.position = 13; $0.utf16Position = 7 },
      .with { $0.id = 2; $0.position = 16; $0.utf16Position = 8 }]
    actual.compose.textContext.selectionStart = 7; actual.compose.textContext.selectionEnd = 7
    peer.reply(.with { $0.id = 3; $0.accepted = true; $0.edit = receipt(actual, edited: [1], preserved: [2]) }, pane: actual)
    try await eventually { peer.inputs.count == 4 }
    XCTAssertEqual(peer.inputs[3].replacementStart, 13); XCTAssertEqual(peer.inputs[3].replacements.first?.start, 16)
    XCTAssertEqual(grid.focusedCompose?.carets.count, 2)
    XCTAssertEqual(grid.focusedCompose?.layout.text.projection.text, "日本aa 日XY本YBB cc")
    XCTAssertTrue(editor.uninsertedText.isEmpty)
    peer.reply(.with { $0.id = 4; $0.accepted = true })
  }

  @MainActor
  func testClickInsidePendingInsertUsesItsReceiptBeforeSendingFollowingText() async throws {
    let initial = pane("Tail\n"), peer = try ScenePeer(pane: initial)
    defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid), unspecified = NSRange(location: NSNotFound, length: 0)
    let prefix = "café 👩🏽‍💻 "
    grid.insertText(prefix, replacementRange: unspecified)
    try await eventually { peer.inputs.count == 1 }
    let pending = try XCTUnwrap(grid.focusedCompose), display = try XCTUnwrap(pending.layout.draftDisplayRanges[1])
    let rect = try XCTUnwrap(pending.layout.text.caret(atUTF16: display.location + 2))
    editor.grid(grid, point: CGPoint(x: pending.origin.x + rect.minX, y: pending.origin.y + rect.midY),
      in: pending, extend: false, count: 1)
    grid.insertText("日", replacementRange: unspecified)
    var preferences = ComposePreferences(); preferences.bodySize = 24
    grid.setComposePreferences(preferences, zoom: 1)
    var inserted = pane(prefix + "Tail\n", revision: 5)
    inserted.compose.cursors[0].position = UInt64(prefix.utf8.count); inserted.compose.cursors[0].utf16Position = UInt64(prefix.utf16.count)
    inserted.compose.textContext.selectionStart = UInt64(prefix.utf16.count); inserted.compose.textContext.selectionEnd = UInt64(prefix.utf16.count)
    let edit = WireComposeEditReceipt.with {
      $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.cursors = [1]; $0.pane = inserted.compose
    }
    var newer = inserted
    newer.compose.cursors[0].position += 4; newer.compose.cursors[0].utf16Position += 4
    newer.compose.textContext.selectionStart += 4; newer.compose.textContext.selectionEnd += 4
    newer.compose.selectionRevision = 6
    peer.reply(.with { $0.id = 1; $0.accepted = true; $0.edit = edit }, pane: newer)
    try await eventually { peer.inputs.count == 2 }
    XCTAssertEqual(peer.inputs[1].position, 2, "the captured point lies within the accepted insert, not at its former source boundary")
    XCTAssertEqual(peer.inputs[1].sourceRevision, 5)
    inserted.compose.cursors[0].position = 2; inserted.compose.cursors[0].utf16Position = 2
    inserted.compose.textContext.selectionStart = 2; inserted.compose.textContext.selectionEnd = 2
    inserted.compose.selectionRevision = 7
    let result = WireComposeEditReceipt.with {
      $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.pane = inserted.compose
    }
    peer.reply(.with { $0.id = 2; $0.accepted = true; $0.result = result }, pane: inserted)
    try await eventually { peer.inputs.count == 3 }
    XCTAssertEqual(peer.inputs[2].replacementStart, 2); XCTAssertEqual(peer.inputs[2].replacementEnd, 2)
    XCTAssertEqual(try WirePaste(serializedBytes: peer.inputs[2].payload).text, "日")
    XCTAssertTrue(editor.uninsertedText.isEmpty)
    peer.reply(.with { $0.id = 3; $0.accepted = true })
  }

  @MainActor
  func testClickInAnEarlierPrefixSurvivesTheLaterPrefixRebindingToRealSource() async throws {
    let initial = pane("Tail\n"), peer = try ScenePeer(pane: initial)
    defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid), unspecified = NSRange(location: NSNotFound, length: 0)
    grid.insertText("ab", replacementRange: unspecified)
    try await eventually { peer.inputs.count == 1 }
    grid.insertText("cd", replacementRange: unspecified)
    let pending = try XCTUnwrap(grid.focusedCompose), range = try XCTUnwrap(pending.layout.draftDisplayRanges[1])
    let rect = try XCTUnwrap(pending.layout.text.caret(atUTF16: range.location + 1))
    editor.grid(grid, point: CGPoint(x: pending.origin.x + rect.minX, y: pending.origin.y + rect.midY),
      in: pending, extend: false, count: 1)
    func inserted(_ prefix: String, revision: UInt64) -> WirePane {
      var value = pane(prefix + "Tail\n", revision: revision)
      value.compose.cursors[0].position = UInt64(prefix.utf8.count); value.compose.cursors[0].utf16Position = UInt64(prefix.utf16.count)
      value.compose.textContext.selectionStart = UInt64(prefix.utf16.count); value.compose.textContext.selectionEnd = UInt64(prefix.utf16.count)
      return value
    }
    func edit(_ value: WirePane) -> WireComposeEditReceipt {
      .with { $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.cursors = [1]; $0.pane = value.compose }
    }
    let first = inserted("ab", revision: 5)
    peer.reply(.with { $0.id = 1; $0.accepted = true; $0.edit = edit(first) }, pane: first)
    try await eventually { peer.inputs.count == 2 }
    XCTAssertEqual(peer.inputs[1].replacementStart, 2); XCTAssertEqual(peer.inputs[1].sourceRevision, 5)
    let second = inserted("abcd", revision: 6)
    peer.reply(.with { $0.id = 2; $0.accepted = true; $0.edit = edit(second) }, pane: second)
    try await eventually { peer.inputs.count == 3 }
    XCTAssertEqual(peer.inputs[2].position, 1); XCTAssertEqual(peer.inputs[2].sourceRevision, 6)
    XCTAssertTrue(editor.uninsertedText.isEmpty)
    peer.reply(.with { $0.id = 3; $0.accepted = true })
  }

  @MainActor
  func testClickInsideASecondaryPendingInsertUsesThatInsertsOwner() async throws {
    var initial = pane("Tail Next\n")
    initial.compose.cursors[0].utf16Position = 0
    initial.compose.cursors.append(.with { $0.id = 2; $0.position = 5; $0.utf16Position = 5 })
    let peer = try ScenePeer(pane: initial); defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid)
    grid.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
    let pending = try XCTUnwrap(grid.focusedCompose), range = try XCTUnwrap(pending.layout.draftDisplayRanges[2])
    let rect = try XCTUnwrap(pending.layout.text.caret(atUTF16: range.location + 1))
    editor.grid(grid, point: CGPoint(x: pending.origin.x + rect.minX, y: pending.origin.y + rect.midY),
      in: pending, extend: false, count: 1)
    try await eventually { peer.inputs.count == 1 }
    var inserted = pane("日本Tail 日本Next\n", revision: 5)
    inserted.compose.cursors = [.with { $0.id = 1; $0.primary = true; $0.position = 6; $0.utf16Position = 2 },
      .with { $0.id = 2; $0.position = 17; $0.utf16Position = 9 }]
    inserted.compose.textContext.selectionStart = 2; inserted.compose.textContext.selectionEnd = 2
    let edit = WireComposeEditReceipt.with {
      $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.cursors = [1, 2]; $0.pane = inserted.compose
    }
    peer.reply(.with { $0.id = 1; $0.accepted = true; $0.edit = edit }, pane: inserted)
    try await eventually { peer.inputs.count == 2 }
    XCTAssertEqual(peer.inputs[1].position, 14); XCTAssertEqual(peer.inputs[1].sourceRevision, 5)
    XCTAssertTrue(editor.uninsertedText.isEmpty)
    peer.reply(.with { $0.id = 2; $0.accepted = true })
  }

  @MainActor
  func testUnprovenPendingInsertClickCancelsAndRecoversItsFollowingText() async throws {
    for cancelled in [true, false] {
      let initial = pane("Tail\n"), peer = try ScenePeer(pane: initial)
      defer { peer.close() }
      let editor = richEditor(); defer { editor.detachAll() }
      editor.attach(socketPath: peer.path, app: nil)
      try await eventually { editor.grid?.focusedCompose != nil }
      let grid = try XCTUnwrap(editor.grid), unspecified = NSRange(location: NSNotFound, length: 0)
      grid.insertText("日本 ", replacementRange: unspecified)
      let pending = try XCTUnwrap(grid.focusedCompose), range = try XCTUnwrap(pending.layout.draftDisplayRanges[1])
      let rect = try XCTUnwrap(pending.layout.text.caret(atUTF16: range.location + 1))
      editor.grid(grid, point: CGPoint(x: pending.origin.x + rect.minX, y: pending.origin.y + rect.midY),
        in: pending, extend: false, count: 1)
      grid.setMarkedText("lost", selectedRange: NSRange(location: 1, length: 0), replacementRange: unspecified)
      if !cancelled { grid.unmarkText() }
      try await eventually { peer.inputs.count == 1 }
      let sequence: UInt64
      if cancelled {
        sequence = peer.reply(.with { $0.id = 1; $0.cancelled = true; $0.error = "The insert was cancelled." })
      } else {
        var changed = pane("変更 Tail\n", revision: 5)
        changed.compose.cursors[0].position = 7; changed.compose.cursors[0].utf16Position = 3
        changed.compose.textContext.selectionStart = 3; changed.compose.textContext.selectionEnd = 3
        let edit = WireComposeEditReceipt.with {
          $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.cursors = [1]; $0.pane = changed.compose
        }
        sequence = peer.reply(.with { $0.id = 1; $0.accepted = true; $0.edit = edit }, pane: changed)
      }
      try await eventually { peer.lastApplied >= sequence }
      XCTAssertFalse(grid.hasMarkedText()); XCTAssertEqual(peer.inputs.count, 1)
      XCTAssertEqual(editor.uninsertedText, cancelled ? ["日本 ", "lost"] : ["lost"])
    }
  }

  @MainActor
  func testSourceClickPlacesCaretAndCompositionBeforeItsReplyWithoutChangingTheCapturedIntent() async throws {
    let initial = pane("alpha café Tail\n"), peer = try ScenePeer(pane: initial)
    defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let window = NSWindow(contentRect: CGRect(x: 90, y: 110, width: 1040, height: 700),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = try XCTUnwrap(editor.view)
    defer { window.contentView = nil; window.close() }
    let grid = try XCTUnwrap(editor.grid), before = try XCTUnwrap(grid.focusedCompose)
    let caret = try XCTUnwrap(before.layout.text.caret(for: 6))
    editor.grid(grid, point: CGPoint(x: before.origin.x + caret.minX, y: before.origin.y + caret.midY),
      in: before, extend: false, count: 1)
    try await eventually { peer.inputs.count == 1 }
    XCTAssertEqual(peer.inputs[0].position, 6)
    XCTAssertEqual(editor.store.panes[0].compose.cursors[0].position, 0, "the preview must not mutate Fresh's snapshot")
    XCTAssertEqual(grid.selectedRange(), NSRange(location: 6, length: 0))
    let unspecified = NSRange(location: NSNotFound, length: 0)
    grid.setMarkedText("日本", selectedRange: NSRange(location: 1, length: 0), replacementRange: unspecified)
    XCTAssertEqual(grid.markedRange(), NSRange(location: 6, length: 2))
    XCTAssertEqual(grid.focusedCompose?.layout.text.projection.text, "alpha 日本café Tail\n")
    let provisional = try XCTUnwrap(grid.focusedCompose)
    let area = try XCTUnwrap(provisional.textServiceRect(for: grid.selectedRange()))
    XCTAssertEqual(area.range, grid.selectedRange())
    XCTAssertGreaterThan(area.rect.minX, caret.minX)
    var actualRange = NSRange(location: NSNotFound, length: 0)
    let screen = grid.firstRect(forCharacterRange: grid.selectedRange(), actualRange: &actualRange)
    XCTAssertEqual(actualRange, grid.selectedRange()); XCTAssertGreaterThan(screen.height, 0)
    XCTAssertEqual(grid.characterIndex(for: CGPoint(x: screen.midX, y: screen.midY)), grid.selectedRange().location)
    var moved = initial
    moved.compose.cursors[0].position = 7; moved.compose.cursors[0].utf16Position = 7
    moved.compose.textContext.selectionStart = 7; moved.compose.textContext.selectionEnd = 7
    moved.compose.selectionRevision = 5
    let result = WireComposeEditReceipt.with {
      $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.pane = moved.compose
    }
    var newer = moved
    newer.compose.cursors[0].position = 12; newer.compose.cursors[0].utf16Position = 11
    newer.compose.textContext.selectionStart = 11; newer.compose.textContext.selectionEnd = 11
    newer.compose.selectionRevision = 6
    peer.reply(.with { $0.id = 1; $0.accepted = true; $0.result = result }, pane: newer)
    try await eventually { peer.lastApplied >= 2 }
    XCTAssertEqual(grid.markedRange(), NSRange(location: 7, length: 2))
    XCTAssertEqual(grid.focusedCompose?.layout.text.projection.text, "alpha c日本afé Tail\n")
    grid.insertText("日本", replacementRange: unspecified)
    try await eventually { peer.inputs.count == 2 }
    XCTAssertEqual(peer.inputs[1].replacementStart, 7); XCTAssertEqual(peer.inputs[1].replacementEnd, 7)
    XCTAssertEqual(peer.inputs[1].sourceRevision, 4)
    XCTAssertEqual(try WirePaste(serializedBytes: peer.inputs[1].payload).text, "日本")
    peer.reply(.with { $0.id = 2; $0.accepted = true })
  }

  @MainActor
  func testQueuedSourceDragKeepsItsSelectionThroughReflowAndRevertsWhenCancelled() async throws {
    let initial = pane("alpha café Tail\n"), peer = try ScenePeer(pane: initial)
    defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid)
    func click(_ position: Int, extend: Bool) throws {
      let current = try XCTUnwrap(grid.focusedCompose), rect = try XCTUnwrap(current.layout.text.caret(for: position))
      editor.grid(grid, point: CGPoint(x: current.origin.x + rect.minX, y: current.origin.y + rect.midY),
        in: current, extend: extend, count: 1)
    }
    try click(6, extend: false)
    try await eventually { peer.inputs.count == 1 }
    try click(12, extend: true)
    XCTAssertEqual(grid.selectedRange(), NSRange(location: 6, length: 5))
    XCTAssertEqual(editor.store.panes[0].compose.cursors[0].position, 0)
    var preferences = ComposePreferences(); preferences.bodySize = 22
    grid.setComposePreferences(preferences, zoom: 1)
    XCTAssertEqual(grid.selectedRange(), NSRange(location: 6, length: 5))
    var moved = initial
    moved.compose.cursors[0].position = 6; moved.compose.cursors[0].utf16Position = 6
    moved.compose.textContext.selectionStart = 6; moved.compose.textContext.selectionEnd = 6
    moved.compose.selectionRevision = 5
    let result = WireComposeEditReceipt.with {
      $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.pane = moved.compose
    }
    peer.reply(.with { $0.id = 1; $0.accepted = true; $0.result = result }, pane: moved)
    try await eventually { peer.inputs.count == 2 }
    XCTAssertEqual(peer.inputs[1].position, 12); XCTAssertTrue(peer.inputs[1].extend)
    XCTAssertEqual(peer.inputs[1].sourceRevision, 4)
    XCTAssertEqual(grid.selectedRange(), NSRange(location: 6, length: 5))
    let sequence = peer.reply(.with { $0.id = 2; $0.cancelled = true; $0.error = "The source drag was cancelled." })
    try await eventually { peer.lastApplied >= sequence }
    XCTAssertEqual(grid.selectedRange(), NSRange(location: 6, length: 0))
    XCTAssertEqual(grid.focusedCompose?.layout.text.projection.text, initial.compose.text)
  }

  @MainActor
  func testCancelledSourceClickRecoversItsFollowingCompositionAndRetiresThePreview() async throws {
    let initial = pane("alpha Tail\n"), peer = try ScenePeer(pane: initial)
    defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid), current = try XCTUnwrap(grid.focusedCompose)
    let rect = try XCTUnwrap(current.layout.text.caret(for: 6))
    editor.grid(grid, point: CGPoint(x: current.origin.x + rect.minX, y: current.origin.y + rect.midY),
      in: current, extend: false, count: 1)
    grid.setMarkedText("保存", selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertEqual(grid.markedRange().location, 6)
    try await eventually { peer.inputs.count == 1 }
    let sequence = peer.reply(.with { $0.id = 1; $0.cancelled = true; $0.error = "The source click was cancelled." })
    try await eventually { peer.lastApplied >= sequence }
    XCTAssertFalse(grid.hasMarkedText()); XCTAssertEqual(editor.uninsertedText, ["保存"])
    XCTAssertEqual(grid.selectedRange(), NSRange(location: 0, length: 0))
    XCTAssertEqual(peer.inputs.count, 1); XCTAssertEqual(grid.focusedCompose?.layout.text.projection.text, initial.compose.text)
  }

  @MainActor
  func testSourceChangeRetiresSelectionPreviewWithoutRelabelingTheQueuedClick() async throws {
    let initial = pane("alpha Tail\n"), peer = try ScenePeer(pane: initial)
    defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid), current = try XCTUnwrap(grid.focusedCompose)
    let rect = try XCTUnwrap(current.layout.text.caret(for: 6))
    editor.grid(grid, point: CGPoint(x: current.origin.x + rect.minX, y: current.origin.y + rect.midY),
      in: current, extend: false, count: 1)
    try await eventually { peer.inputs.count == 1 }
    XCTAssertEqual(grid.selectedRange().location, 6)
    var group = initial
    group.compose.cursors.append(.with { $0.id = 2; $0.position = 10; $0.utf16Position = 10 })
    group.compose.selectionRevision = 5
    var sequence = peer.lastApplied; peer.show(group)
    try await eventually { peer.lastApplied > sequence }
    XCTAssertEqual(grid.focusedCompose?.pane.compose.cursors.map(\.id), [1, 2], "a primary preview cannot roll back authoritative secondary carets")
    XCTAssertEqual(grid.selectedRange().location, 6)
    group.compose.cursors[0].id = 3
    sequence = peer.lastApplied; peer.show(group)
    try await eventually { peer.lastApplied > sequence }
    XCTAssertFalse(try XCTUnwrap(grid.focusedCompose).pendingSelection, "retiring the captured primary retires its selection preview")
    XCTAssertEqual(grid.selectedRange().location, 0)
    sequence = peer.lastApplied
    peer.show(pane("Zalpha Tail\n", revision: 5))
    try await eventually { peer.lastApplied > sequence }
    XCTAssertEqual(grid.selectedRange().location, 1)
    XCTAssertFalse(try XCTUnwrap(grid.focusedCompose).pendingSelection)
    XCTAssertEqual(peer.inputs[0].sourceRevision, 4); XCTAssertEqual(peer.inputs[0].position, 6)
  }

  @MainActor
  func testAcceptedSourceClickRevealsItsCaretAfterReflowWhileItsReplyWasDelayed() async throws {
    let source = (0..<30).map { "Line \($0) measured words.\n" }.joined()
    let initial = pane(source), peer = try ScenePeer(pane: initial)
    defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid), current = try XCTUnwrap(grid.focusedCompose)
    let index = try XCTUnwrap(source.range(of: "Line 16")), position = source[..<index.lowerBound].utf8.count
    let rect = try XCTUnwrap(current.layout.text.caret(for: position))
    let point = CGPoint(x: current.origin.x + rect.minX, y: current.origin.y + rect.midY)
    XCTAssertTrue(current.bounds.contains(point))
    editor.grid(grid, point: point, in: current, extend: false, count: 1)
    try await eventually { peer.inputs.count == 1 }
    var preferences = ComposePreferences(); preferences.bodySize = 48
    grid.setComposePreferences(preferences, zoom: 1)
    let resized = try XCTUnwrap(grid.focusedCompose)
    XCTAssertGreaterThan(try XCTUnwrap(resized.caret).maxY, resized.bounds.maxY)
    var moved = initial
    moved.compose.cursors[0].position = UInt64(position); moved.compose.cursors[0].utf16Position = UInt64(position)
    moved.compose.textContext.selectionStart = UInt64(position); moved.compose.textContext.selectionEnd = UInt64(position)
    moved.compose.selectionRevision = 5
    let result = WireComposeEditReceipt.with {
      $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.pane = moved.compose
    }
    peer.reply(.with { $0.id = 1; $0.accepted = true; $0.result = result }, pane: moved)
    try await eventually { peer.viewports.count == 1 }
    XCTAssertGreaterThan(peer.viewports[0].position, 0)
    XCTAssertEqual(peer.viewports[0].scope.bufferRevision, 4)
  }

  @MainActor
  func testMarkedCommitBehindNavigationUsesItsCorrelatedResultRatherThanANewerCursor() async throws {
    let peer = try ScenePeer(pane: pane("alpha Tail")); defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid), unspecified = NSRange(location: NSNotFound, length: 0)
    editor.send(.key(.with { $0.key = "ArrowRight" }))
    try await eventually { peer.inputs.count == 1 }
    grid.setMarkedText("日", selectedRange: NSRange(location: 1, length: 0), replacementRange: unspecified)
    grid.insertText("日", replacementRange: unspecified)
    var moved = pane("alpha Tail")
    moved.compose.cursors[0].position = 1; moved.compose.cursors[0].utf16Position = 1
    moved.compose.textContext.selectionStart = 1; moved.compose.textContext.selectionEnd = 1
    moved.compose.selectionRevision = 5
    let result = WireComposeEditReceipt.with {
      $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.cursors = [1]; $0.pane = moved.compose
    }
    var newer = moved
    newer.compose.cursors[0].position = 7; newer.compose.cursors[0].utf16Position = 7
    newer.compose.textContext.selectionStart = 7; newer.compose.textContext.selectionEnd = 7
    newer.compose.selectionRevision = 6
    peer.reply(.with { $0.id = 1; $0.accepted = true; $0.result = result }, pane: newer)
    try await eventually { peer.inputs.count == 2 }
    XCTAssertEqual(peer.inputs[1].replacementStart, 1, "the composition follows the queued navigation, not its old or newer scene cursor")
    XCTAssertEqual(peer.inputs[1].replacementEnd, 1)
    XCTAssertEqual(try WirePaste(serializedBytes: peer.inputs[1].payload).text, "日")
    peer.reply(.with { $0.id = 2; $0.accepted = true })
  }

  @MainActor
  func testActiveCompositionFollowsAnActionsNewGroupAfterItsOriginalCaretRetires() async throws {
    let peer = try ScenePeer(pane: pane("alpha Tail")); defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid), unspecified = NSRange(location: NSNotFound, length: 0)
    editor.send(.action(name: "add_cursor_below", argsJson: ""))
    grid.setMarkedText("日", selectedRange: NSRange(location: 1, length: 0), replacementRange: unspecified)
    try await eventually { peer.inputs.count == 1 }
    var resulting = pane("alpha Tail")
    resulting.compose.cursors = [.with { $0.id = 10; $0.position = 1; $0.utf16Position = 1 },
      .with { $0.id = 20; $0.primary = true; $0.position = 6; $0.utf16Position = 6 }]
    resulting.compose.textContext.selectionStart = 6; resulting.compose.textContext.selectionEnd = 6
    resulting.compose.selectionRevision = 5
    let result = WireComposeEditReceipt.with {
      $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.pane = resulting.compose
    }
    peer.reply(.with { $0.id = 1; $0.accepted = true; $0.result = result }, pane: resulting)
    try await eventually { grid.hasMarkedText() && grid.markedRange().location == 7 }
    XCTAssertEqual(grid.focusedCompose?.layout.composition?.ordered, [10, 20])
    grid.insertText("日", replacementRange: unspecified)
    try await eventually { peer.inputs.count == 2 }
    XCTAssertEqual(peer.inputs[1].replacementCursor, 20)
    XCTAssertEqual(peer.inputs[1].replacementStart, 6)
    XCTAssertEqual(peer.inputs[1].replacements.first?.cursor, 10)
    XCTAssertEqual(peer.inputs[1].replacements.first?.start, 1)
    XCTAssertTrue(editor.uninsertedText.isEmpty)
    peer.reply(.with { $0.id = 2; $0.accepted = true })
  }

  @MainActor
  func testCanceledActionRecoversQueuedAndMarkedFollowingTextWithoutPartialInsertion() async throws {
    let peer = try ScenePeer(pane: pane("alpha Tail")); defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid), unspecified = NSRange(location: NSNotFound, length: 0)
    editor.send(.key(.with { $0.key = "ArrowRight" }))
    grid.insertText("日", replacementRange: unspecified)
    grid.setMarkedText("語", selectedRange: NSRange(location: 1, length: 0), replacementRange: unspecified)
    try await eventually { peer.inputs.count == 1 }
    peer.reply(.with { $0.id = 1; $0.cancelled = true; $0.error = "The original view was replaced." })
    try await eventually { editor.uninsertedText == ["日", "語"] }
    XCTAssertFalse(grid.hasMarkedText()); XCTAssertEqual(peer.inputs.count, 1)
  }

  @MainActor
  func testExplicitReplacementInPendingPrefixKeepsItsSourceTargetAcrossQueuedNavigation() async throws {
    let peer = try ScenePeer(pane: pane("alpha Tail")); defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid), unspecified = NSRange(location: NSNotFound, length: 0)
    grid.insertText("beta", replacementRange: unspecified)
    editor.send(.key(.with { $0.key = "ArrowLeft" }))
    XCTAssertEqual(grid.attributedSubstring(forProposedRange: NSRange(location: 0, length: 100), actualRange: nil)?.string, "betaalpha Tail")
    grid.insertText("theta", replacementRange: NSRange(location: 0, length: 4))
    try await eventually { peer.inputs.count == 1 }
    var first = pane("betaalpha Tail", revision: 5)
    first.compose.cursors[0].position = 4; first.compose.cursors[0].utf16Position = 4
    first.compose.textContext.selectionStart = 4; first.compose.textContext.selectionEnd = 4
    let edit = WireComposeEditReceipt.with {
      $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.cursors = [1]; $0.pane = first.compose
    }
    peer.reply(.with { $0.id = 1; $0.accepted = true; $0.edit = edit }, pane: first)
    try await eventually { peer.inputs.count == 2 }
    first.compose.cursors[0].position = 3; first.compose.cursors[0].utf16Position = 3
    first.compose.textContext.selectionStart = 3; first.compose.textContext.selectionEnd = 3
    var result = edit; result.pane = first.compose; result.cursors = []
    peer.reply(.with { $0.id = 2; $0.accepted = true; $0.result = result }, pane: first)
    try await eventually { peer.inputs.count == 3 }
    XCTAssertEqual(peer.inputs[2].sourceRevision, 5)
    XCTAssertEqual(peer.inputs[2].replacementStart, 0); XCTAssertEqual(peer.inputs[2].replacementEnd, 4)
    XCTAssertEqual(try WirePaste(serializedBytes: peer.inputs[2].payload).text, "theta")
    XCTAssertTrue(editor.uninsertedText.isEmpty)
    peer.reply(.with { $0.id = 3; $0.accepted = true })
  }

  @MainActor
  func testRejectingAPredecessorRecoversQueuedAndStillMarkedDependentPhrasesOnce() async throws {
    let peer = try ScenePeer(pane: pane("alpha Tail")); defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid)
    for text in ["日本", "語"] {
      grid.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
      grid.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    grid.setMarkedText("次", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    try await eventually { peer.inputs.count == 1 }
    peer.reply(.with { $0.id = 1; $0.cancelled = true; $0.error = "The original range changed." })
    try await eventually { editor.uninsertedText.count == 3 }
    XCTAssertEqual(editor.uninsertedText, ["日本", "語", "次"])
    XCTAssertFalse(grid.hasMarkedText()); XCTAssertEqual(peer.inputs.count, 1)
    grid.insertText("ok", replacementRange: NSRange(location: NSNotFound, length: 0))
    try await eventually { peer.inputs.count == 2 }
    XCTAssertEqual(try WirePaste(serializedBytes: peer.inputs[1].payload).text, "ok")
    peer.reply(.with { $0.id = 2; $0.accepted = true })
  }

  @MainActor
  func testLargePrimarySelectionCanBeReplacedBeyondTheBoundedTextContext() async throws {
    let prefix = String(repeating: "文", count: 4000), source = prefix + "Tail"
    var last = pane(source)
    last.compose.sourceStart = UInt64(prefix.utf8.count); last.compose.text = "Tail"
    last.compose.segments = [.with {
      $0.sourceStart = UInt64(prefix.utf8.count); $0.sourceEnd = UInt64(source.utf8.count); $0.displayEnd = 4
    }]
    last.compose.cursors[0].position = UInt64(source.utf8.count); last.compose.cursors[0].anchor = 0
    last.compose.textContext = .with {
      $0.text = "Tail"; $0.sourceStart = UInt64(prefix.utf8.count); $0.utf16Start = 4000; $0.selectionEnd = 4004
    }
    let peer = try ScenePeer(pane: last)
    defer { peer.close() }
    let editor = richEditor()
    defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid)
    XCTAssertEqual(grid.selectedRange(), NSRange(location: 0, length: 4004))
    grid.insertText("", replacementRange: grid.selectedRange())
    try await eventually { peer.inputs.count == 1 }
    XCTAssertEqual(peer.inputs[0].replacementStart, 0)
    XCTAssertEqual(peer.inputs[0].replacementEnd, UInt64(source.utf8.count))
    XCTAssertEqual(try WirePaste(serializedBytes: peer.inputs[0].payload).text, "")
  }

  @MainActor
  func testTextServicesKeepSourceCoordinatesAcrossConcealmentAndSourceWindowChanges() async throws {
    let prefix = String(repeating: "👩🏽‍💻 before\r\n", count: 100), raw = "**café** tail\r\n"
    let start = prefix.utf8.count, base = prefix.utf16.count
    var compact = pane(prefix + raw)
    compact.compose.sourceStart = UInt64(start); compact.compose.text = "café tail\r\n"
    compact.compose.segments = [
      .with { $0.sourceStart = UInt64(start); $0.sourceEnd = UInt64(start + 2); $0.kind = 1 },
      .with { $0.sourceStart = UInt64(start + 2); $0.sourceEnd = UInt64(start + 7); $0.displayEnd = 5 },
      .with { $0.sourceStart = UInt64(start + 7); $0.sourceEnd = UInt64(start + 9); $0.displayStart = 5; $0.displayEnd = 5; $0.kind = 1 },
      .with { $0.sourceStart = UInt64(start + 9); $0.sourceEnd = compact.compose.sourceEnd; $0.displayStart = 5; $0.displayEnd = UInt64(compact.compose.text.utf8.count) },
    ]
    compact.compose.cursors[0].position = UInt64(start + 7); compact.compose.cursors[0].anchor = UInt64(start + 2)
    compact.compose.textContext = .with {
      $0.text = raw; $0.sourceStart = UInt64(start); $0.utf16Start = UInt64(base)
      $0.selectionStart = UInt64(base + 2); $0.selectionEnd = UInt64(base + 6)
    }
    let peer = try ScenePeer(pane: compact)
    defer { peer.close() }
    let editor = richEditor()
    defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid), selection = NSRange(location: base + 2, length: 4)
    XCTAssertEqual(grid.selectedRange(), selection)
    XCTAssertEqual(grid.accessibilitySelectedTextRange(), NSRange(location: 0, length: 4), "accessibility addresses the displayed value, not raw-source context")
    var actual = NSRange(location: NSNotFound, length: 0)
    XCTAssertEqual(grid.attributedSubstring(forProposedRange: selection, actualRange: &actual)?.string, "café")
    XCTAssertEqual(actual, selection)
    let presentation = try XCTUnwrap(grid.focusedCompose)
    XCTAssertEqual(presentation.textServiceRect(for: selection)?.range, selection)
    XCTAssertEqual(presentation.textServiceIndex(for: start + 2), base + 2)
    var revealed = pane(prefix + raw, width: 40)
    revealed.compose.cursors = compact.compose.cursors; revealed.compose.textContext = compact.compose.textContext
    peer.show(revealed)
    try await eventually { grid.focusedCompose?.pane.compose.sourceStart == 0 }
    XCTAssertEqual(grid.selectedRange(), selection)
    XCTAssertEqual(grid.attributedSubstring(forProposedRange: selection, actualRange: &actual)?.string, "café")
    grid.insertText("東京", replacementRange: selection)
    try await eventually { peer.inputs.count == 1 }
    XCTAssertEqual(peer.inputs[0].replacementStart, UInt64(start + 2))
    XCTAssertEqual(peer.inputs[0].replacementEnd, UInt64(start + 7))
  }
  @MainActor
  func testCommittedPhraseWaitsForModalKeyboardOwnershipWithoutInventingLayoutFeedback() async throws {
    let source = "Text before the input.\n"
    let peer = try ScenePeer(pane: pane(source))
    defer { peer.close() }
    let editor = richEditor()
    defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    editor.send(.text("東京"))
    try await eventually { peer.inputs.count == 1 }
    var modal = pane(source); modal.compose.keyboard = false
    let waiting = peer.reply(.with { $0.id = 1; $0.needsLayout = true }, pane: modal)
    try await eventually { peer.lastApplied >= waiting }
    editor.send(.key(.with { $0.key = "Escape" }))
    try await eventually { peer.keys.count == 1 }
    XCTAssertEqual(peer.inputs.count, 1)
    peer.show(pane(source))
    try await eventually { peer.inputs.count == 2 }
    XCTAssertEqual(peer.inputs[1].id, 1)
    XCTAssertTrue(peer.inputs[1].textInput)
    XCTAssertFalse(peer.inputs[1].hasLayout)
    XCTAssertEqual(peer.inputs[1].layoutID, 0)
    XCTAssertEqual(try WirePaste(serializedBytes: peer.inputs[1].payload).text, "東京")
  }
  @MainActor
  func testNativeReplacementCapturesUtf8RangeThroughQueuedReflowAndNormalTextCommitsOnce() async throws {
    let source = "👩🏽‍💻 **café** tail\r\n"
    let peer = try ScenePeer(pane: pane(source))
    defer { peer.close() }
    let editor = richEditor()
    defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid)
    let range = (source as NSString).range(of: "café")
    let start = source[..<source.range(of: "café")!.lowerBound].utf8.count
    var actual = NSRange(location: NSNotFound, length: 0)
    XCTAssertEqual(grid.attributedSubstring(forProposedRange: range, actualRange: &actual)?.string, "café")
    XCTAssertEqual(actual, range)
    XCTAssertEqual(grid.selectedRange(), grid.focusedCompose?.selectedRange)
    editor.send(.key(.with { $0.key = "X" }))
    try await eventually { peer.inputs.count == 1 }
    grid.insertText("東京", replacementRange: range)
    let updated = pane("prefix " + source, revision: 5, width: 40)
    peer.reply(.with { $0.id = 1; $0.accepted = true }, pane: updated)
    try await eventually { peer.inputs.count == 2 }
    let replacement = peer.inputs[1]
    XCTAssertEqual(replacement.replacementStart, UInt64(start))
    XCTAssertEqual(replacement.replacementEnd, UInt64(start + "café".utf8.count))
    XCTAssertEqual(replacement.sourceRevision, 4)
    XCTAssertEqual(replacement.bufferEpoch, 7)
    XCTAssertEqual(replacement.replacementCursor, 1)
    XCTAssertEqual(try WirePaste(serializedBytes: replacement.payload).text, "東京")
    peer.reply(.with { $0.id = 2; $0.accepted = true })
    try await eventually { peer.lastApplied >= 3 }
    grid.insertText("日本語", replacementRange: NSRange(location: NSNotFound, length: 0))
    try await eventually { peer.inputs.count == 3 }
    XCTAssertEqual(UInt64(peer.inputs[2].kind), SceneWire.Kind.paste.rawValue)
    XCTAssertFalse(peer.inputs[2].hasReplacementStart)
    XCTAssertTrue(peer.inputs[2].textInput)
    XCTAssertEqual(try WirePaste(serializedBytes: peer.inputs[2].payload).text, "日本語",
      "a committed phrase is one Fresh text action, not a sequence of character keys")
  }
  private func pane(_ text: String, revision: UInt64 = 4, width: UInt32 = 80) -> WirePane {
    .with {
      $0.leaf = 2; $0.buffer = 3; $0.content = .with { $0.w = width; $0.h = 35 }
      $0.compose = .with {
        $0.text = text; $0.sourceEnd = UInt64(text.utf8.count); $0.documentLen = $0.sourceEnd
        $0.bufferRevision = revision; $0.projectionRevision = revision; $0.selectionRevision = revision
        $0.segments = [.with { $0.sourceEnd = UInt64(text.utf8.count); $0.displayEnd = $0.sourceEnd }]
        $0.viewport = .with { $0.epoch = 7 }
        $0.focused = true; $0.keyboard = true; $0.nativeNewline = 1
        $0.cursors = [.with { $0.primary = true; $0.id = 1; $0.position = revision == 4 ? 0 : 1 }]
        $0.textContext = .with {
          $0.text = text; $0.selectionStart = revision == 4 ? 0 : 1; $0.selectionEnd = $0.selectionStart
        }
      }
    }
  }

  @MainActor
  private func richEditor(pasteboard: (any EditorPasteboard)? = nil,
                          decodeImage: @escaping @Sendable (Data, Int) throws -> ComposeImageAsset = { try ComposeImageAsset.decode($0, maximumDimension: $1) }) -> NativeEditor {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let gate = ProcessInfo.processInfo.environment["FC_NATIVE_RICH_COMPOSE"]
    setenv("FC_NATIVE_RICH_COMPOSE", "1", 1)
    defer { if let gate { setenv("FC_NATIVE_RICH_COMPOSE", gate, 1) } else { unsetenv("FC_NATIVE_RICH_COMPOSE") } }
    return NativeEditor(pasteboard: pasteboard ?? MemoryPasteboard(), decodeComposeImage: decodeImage)
  }

  @MainActor
  private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertTrue(condition(), file: file, line: line)
    if !condition() { throw POSIXError(.ETIMEDOUT) }
  }

  @MainActor
  func testQueuedClickRetainsItsSourceAndCancelledTargetsDoNotStrandOrRedirectLaterTyping() async throws {
    let source = (0..<200).map { "Paragraph \($0) with words to wrap across the page.\n\n" }.joined()
    let peer = try ScenePeer(pane: pane(source, revision: 4))
    defer { peer.close() }
    let editor = richEditor()
    defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.connected && editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid), original = try XCTUnwrap(grid.focusedCompose)
    let point = CGPoint(x: original.origin.x + 220, y: original.origin.y + original.layout.text.fragments[2].rect.midY)
    let captured = try XCTUnwrap(original.hit(at: point))
    editor.send(.key(.with { $0.key = "X" }))
    try await eventually { peer.inputs.count == 1 }
    XCTAssertEqual(peer.inputs[0].bufferEpoch, 7)
    editor.grid(grid, point: point, in: original, extend: false, count: 1)
    editor.send(.key(.with { $0.key = "Y" }))
    XCTAssertEqual(peer.inputs.count, 1, "later events wait for the first source edit")
    var changed = pane("X" + source, revision: 5, width: 40)
    changed.compose.viewport.position = UInt64(("X" + source)[..<("X" + source).range(of: "Paragraph 40")!.lowerBound].utf8.count)
    peer.reply(.with { $0.id = 1; $0.accepted = true }, pane: changed)
    try await eventually { peer.inputs.count == 2 }
    let click = peer.inputs[1]
    XCTAssertEqual(click.id, 2)
    XCTAssertEqual(click.position, UInt64(captured.source))
    XCTAssertEqual(click.sourceRevision, 4)
    XCTAssertEqual(click.bufferEpoch, 7)
    XCTAssertNotEqual(grid.focusedCompose?.hit(at: point)?.source, captured.source, "the old screen point now refers to another part of the file")
    let replacement = WirePane.with { $0.leaf = 2; $0.buffer = 9; $0.content = changed.content }
    peer.reply(.with { $0.id = 2; $0.cancelled = true; $0.error = "The clicked file was replaced." }, pane: replacement)
    try await eventually { peer.inputs.count == 3 }
    XCTAssertEqual(peer.inputs[2].scope.buffer, 3, "queued typing remains bound to its captured file")
    XCTAssertEqual(peer.inputs[2].bufferEpoch, 7)
    let cancelled = peer.reply(.with { $0.id = 3; $0.cancelled = true; $0.error = "The queued file was closed." })
    try await eventually { peer.lastApplied >= cancelled }
    editor.send(.key(.with { $0.key = "Z" }))
    try await eventually { peer.inputs.count == 4 }
    XCTAssertEqual(peer.inputs[3].id, 4)
    XCTAssertFalse(peer.inputs[3].hasScope, "new input uses the currently displayed source view")
    XCTAssertEqual(try WireKey(serializedBytes: peer.inputs[3].payload).key, "Z")
    peer.reply(.with { $0.id = 4; $0.accepted = true })
  }

  @MainActor
  func testModalUiStaysUsableAndTheDeferredDocumentKeyRetainsItsRequest() async throws {
    let original = pane("Heading\n\nA paragraph to measure.\n")
    let peer = try ScenePeer(pane: original)
    defer { peer.close() }
    let editor = richEditor()
    defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.connected && editor.grid?.focusedCompose != nil }
    editor.send(.key(.with { $0.key = "ArrowDown" }))
    try await eventually { peer.inputs.count == 1 }
    var modal = original; modal.compose.keyboard = false
    let parked = peer.reply(.with { $0.id = 1; $0.needsLayout = true }, pane: modal)
    try await eventually { peer.lastApplied >= parked }
    editor.send(.key(.with { $0.key = "Escape" }))
    try await eventually { peer.keys.count == 1 }
    XCTAssertEqual(peer.keys[0].key, "Escape")
    XCTAssertEqual(peer.inputs.count, 1, "modal input does not replace the deferred document request")
    peer.show(original)
    try await eventually { peer.inputs.count == 2 }
    XCTAssertEqual(peer.inputs.map(\.id), [1, 1])
    XCTAssertEqual(peer.inputs[0].payload, peer.inputs[1].payload)
    XCTAssertTrue(peer.inputs[1].hasLayout)
    XCTAssertEqual(peer.inputs[1].scope.buffer, 3)
    let finished = peer.reply(.with { $0.id = 1; $0.accepted = true })
    try await eventually { peer.lastApplied >= finished }
    editor.send(.key(.with { $0.key = "T" }))
    try await eventually { peer.inputs.count == 3 }
    XCTAssertEqual(peer.inputs[2].id, 2)
  }

  @MainActor
  func testBufferLifetimeReplacementExplicitlyCancelsQueuedTypingBeforeUsingTheNewBuffer() async throws {
    let original = pane("Original document\n")
    let peer = try ScenePeer(pane: original)
    defer { peer.close() }
    let editor = richEditor()
    defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.connected && editor.grid?.focusedCompose != nil }
    editor.send(.key(.with { $0.key = "X" }))
    try await eventually { peer.inputs.count == 1 }
    editor.send(.key(.with { $0.key = "Y" }))
    var replacement = pane("Replacement document\n"); replacement.compose.viewport.epoch = 8
    peer.reply(.with { $0.id = 1; $0.accepted = true }, pane: replacement)
    try await eventually { peer.inputs.count == 2 }
    XCTAssertTrue(peer.inputs[1].cancel, "the same numeric buffer id cannot inherit old queued typing after its lifetime changes")
    let cancelled = peer.reply(.with { $0.id = 2; $0.cancelled = true; $0.error = "The queued file was replaced." })
    try await eventually { peer.lastApplied >= cancelled }
    editor.send(.key(.with { $0.key = "Z" }))
    try await eventually { peer.inputs.count == 3 }
    XCTAssertEqual(peer.inputs[2].id, 3)
    XCTAssertFalse(peer.inputs[2].cancel)
    XCTAssertEqual(peer.inputs[2].scope.buffer, 3)
    XCTAssertEqual(peer.inputs[2].bufferEpoch, 8)
  }

  @MainActor
  func testPendingFormattingHoldsTheOldSourceMapAndQueuesInputUntilTheCurrentProjectionIsReady() async throws {
    let source = String(repeating: "Paragraph words café to wrap across the page.\n\n", count: 50)
    let peer = try ScenePeer(pane: pane(source))
    defer { peer.close() }
    let editor = richEditor()
    defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.connected && editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid), original = try XCTUnwrap(grid.focusedCompose)
    let point = CGPoint(x: original.origin.x + 150, y: original.origin.y + original.layout.text.fragments[1].rect.midY)
    let clicked = try XCTUnwrap(original.hit(at: point))
    var pending = pane("X" + source, revision: 5); pending.compose.ready = false
    peer.show(pending)
    try await eventually { editor.store.panes[0].compose.hasReady && !editor.store.panes[0].compose.ready }
    XCTAssertEqual(grid.focusedCompose?.pane.compose.bufferRevision, 4)
    XCTAssertEqual(grid.focusedCompose?.layout.text.projection.text, source)
    editor.send(.key(.with { $0.key = "T" }))
    editor.grid(grid, point: point, in: try XCTUnwrap(grid.focusedCompose), extend: false, count: 1)
    XCTAssertTrue(peer.inputs.isEmpty, "partial decoration frames cannot supply interactive input geometry")
    pending.compose.ready = true
    peer.show(pending)
    try await eventually { peer.inputs.count == 1 }
    XCTAssertEqual(peer.inputs[0].scope.bufferRevision, 5, "keyboard dispatch binds to the now-coherent current map")
    XCTAssertEqual(grid.focusedCompose?.pane.compose.bufferRevision, 5)
    peer.reply(.with { $0.id = 1; $0.accepted = true })
    try await eventually { peer.inputs.count == 2 }
    XCTAssertEqual(peer.inputs[1].sourceRevision, 4, "a click captured on the held presentation retains that source revision")
    XCTAssertEqual(peer.inputs[1].position, UInt64(clicked.source))
  }

  @MainActor
  func testAcceptedTextRemainsVisibleAndQueryableWhileFormattingIsPending() async throws {
    for includePane in [true, false] {
      let peer = try ScenePeer(pane: pane("alpha Tail")); defer { peer.close() }
      let editor = richEditor(); defer { editor.detachAll() }
      editor.attach(socketPath: peer.path, app: nil)
      try await eventually { editor.grid?.focusedCompose != nil }
      let grid = try XCTUnwrap(editor.grid)
      grid.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
      try await eventually { peer.inputs.count == 1 }
      var current = pane("日本alpha Tail", revision: 5)
      current.compose.ready = false
      current.compose.cursors[0].position = 6; current.compose.cursors[0].utf16Position = 2
      current.compose.textContext.selectionStart = 2; current.compose.textContext.selectionEnd = 2
      let receipt = WireComposeEditReceipt.with {
        $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.cursors = [1]; $0.pane = current.compose
      }
      let sequence = peer.reply(.with { $0.id = 1; $0.accepted = true; $0.edit = receipt }, pane: includePane ? current : nil)
      try await eventually { peer.lastApplied >= sequence }
      XCTAssertEqual(grid.focusedCompose?.layout.text.projection.text, "日本alpha Tail")
      XCTAssertEqual(grid.focusedCompose?.pane.compose.bufferRevision, 5)
      XCTAssertEqual(grid.selectedRange(), NSRange(location: 2, length: 0))
      XCTAssertEqual(grid.attributedSubstring(forProposedRange: NSRange(location: 0, length: 100), actualRange: nil)?.string, "日本alpha Tail")
      XCTAssertFalse(grid.hasMarkedText())
      current.compose.ready = true
      let before = peer.lastApplied
      peer.show(current)
      try await eventually { peer.lastApplied > before && grid.focusedCompose?.pane.compose.bufferRevision == 5 && grid.focusedCompose?.pane.compose.formattingReady == true }
      XCTAssertEqual(grid.focusedCompose?.layout.text.projection.text, "日本alpha Tail")
      XCTAssertTrue(editor.uninsertedText.isEmpty)
    }
  }

  @MainActor
  func testAcceptedNavigationKeepsItsSelectionAndLaterPaneUpdatesRemainAuthoritative() async throws {
    for includePane in [true, false] {
      let peer = try ScenePeer(pane: pane("alpha Tail")); defer { peer.close() }
      let editor = richEditor(); defer { editor.detachAll() }
      editor.attach(socketPath: peer.path, app: nil)
      try await eventually { editor.grid?.focusedCompose != nil }
      let grid = try XCTUnwrap(editor.grid)
      editor.send(.key(.with { $0.key = "ArrowRight" }))
      try await eventually { peer.inputs.count == 1 }
      var current = pane("alpha Tail")
      current.compose.ready = false; current.compose.selectionRevision = 1 // Hash identity can decrease.
      current.compose.cursors[0].position = 1; current.compose.cursors[0].utf16Position = 1
      current.compose.textContext.selectionStart = 1; current.compose.textContext.selectionEnd = 1
      let result = WireComposeEditReceipt.with {
        $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.pane = current.compose
      }
      let accepted = peer.reply(.with { $0.id = 1; $0.accepted = true; $0.result = result }, pane: includePane ? current : nil)
      try await eventually { peer.lastApplied >= accepted }
      XCTAssertEqual(grid.selectedRange(), NSRange(location: 1, length: 0))
      XCTAssertEqual(editor.store.panes[0].compose.selectionRevision, 1)
      current.compose.selectionRevision = 2; current.compose.cursors[0].position = 7; current.compose.cursors[0].utf16Position = 7
      current.compose.textContext.selectionStart = 7; current.compose.textContext.selectionEnd = 7
      let before = peer.lastApplied
      peer.show(current)
      try await eventually { peer.lastApplied > before }
      XCTAssertEqual(grid.selectedRange(), NSRange(location: 7, length: 0), "a later actual pane can move beyond the accepted result")
    }
  }

  @MainActor
  func testFurtherTypingUsesAcceptedSourceWhileMeasuredNavigationWaitsForFormatting() async throws {
    let peer = try ScenePeer(pane: pane("alpha Tail")); defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid), unspecified = NSRange(location: NSNotFound, length: 0)
    grid.insertText("日本", replacementRange: unspecified)
    try await eventually { peer.inputs.count == 1 }
    var current = pane("日本alpha Tail", revision: 5)
    current.compose.ready = false; current.compose.currentProjection = false
    current.compose.cursors[0].position = 6; current.compose.cursors[0].utf16Position = 2
    current.compose.textContext.selectionStart = 2; current.compose.textContext.selectionEnd = 2
    let receipt = WireComposeEditReceipt.with {
      $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.cursors = [1]; $0.pane = current.compose
    }
    let accepted = peer.reply(.with { $0.id = 1; $0.accepted = true; $0.edit = receipt })
    try await eventually { peer.lastApplied >= accepted }
    grid.insertText("語", replacementRange: unspecified)
    XCTAssertEqual(grid.attributedSubstring(forProposedRange: NSRange(location: 0, length: 100), actualRange: nil)?.string, "日本語alpha Tail")
    XCTAssertEqual(grid.selectedRange().location, 3)
    try await eventually { peer.inputs.count == 2 }
    XCTAssertEqual(peer.inputs[1].scope.bufferRevision, 5)
    XCTAssertTrue(peer.inputs[1].textInput)
    XCTAssertEqual(try WirePaste(serializedBytes: peer.inputs[1].payload).text, "語")
    editor.send(.key(.with { $0.key = "ArrowRight" }))
    current = pane("日本語alpha Tail", revision: 6)
    current.compose.ready = false; current.compose.currentProjection = false
    current.compose.cursors[0].position = 9; current.compose.cursors[0].utf16Position = 3
    current.compose.textContext.selectionStart = 3; current.compose.textContext.selectionEnd = 3
    var next = receipt; next.pane = current.compose
    let nextAccepted = peer.reply(.with { $0.id = 2; $0.accepted = true; $0.edit = next }, pane: current)
    try await eventually { peer.lastApplied >= nextAccepted }
    XCTAssertEqual(peer.inputs.count, 2, "measured navigation still needs a usable current projection")
    current.compose.ready = true; peer.show(current)
    try await eventually { peer.inputs.count == 3 }
    XCTAssertEqual(peer.inputs[2].scope.bufferRevision, 6)
    XCTAssertFalse(peer.inputs[2].textInput)
    XCTAssertEqual(try WireKey(serializedBytes: peer.inputs[2].payload).key, "ArrowRight")
    peer.reply(.with { $0.id = 3; $0.accepted = true })
  }

  @MainActor
  func testAcceptedSourceCannotReplaceANewerSceneOrEscapeItsBufferLifetime() async throws {
    let peer = try ScenePeer(pane: pane("alpha Tail")); defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid)
    grid.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
    try await eventually { peer.inputs.count == 1 }
    var accepted = pane("日本alpha Tail", revision: 5)
    accepted.compose.cursors[0].position = 6; accepted.compose.cursors[0].utf16Position = 2
    accepted.compose.textContext.selectionStart = 2; accepted.compose.textContext.selectionEnd = 2
    let receipt = WireComposeEditReceipt.with {
      $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.cursors = [1]; $0.pane = accepted.compose
    }
    var newer = pane("X日本alpha Tail", revision: 6); newer.compose.ready = false
    let sequence = peer.reply(.with { $0.id = 1; $0.accepted = true; $0.edit = receipt }, pane: newer)
    try await eventually { peer.lastApplied >= sequence }
    XCTAssertEqual(grid.focusedCompose?.pane.compose.bufferRevision, 6)
    XCTAssertEqual(grid.attributedSubstring(forProposedRange: NSRange(location: 0, length: 100), actualRange: nil)?.string, "X日本alpha Tail")
    var replacement = pane("replacement", revision: 1); replacement.compose.viewport.epoch = 8; replacement.compose.ready = false
    let before = peer.lastApplied
    peer.show(replacement)
    try await eventually { peer.lastApplied > before }
    XCTAssertTrue(editor.store.composeAcceptances.isEmpty)
    XCTAssertEqual(grid.focusedCompose?.layout.text.projection.text, "replacement")
    XCTAssertTrue(editor.uninsertedText.isEmpty)
  }

  @MainActor
  func testAcceptedInputRevealsTheCaretAfterFormattingFinishes() async throws {
    let source = (0..<200).map { "Paragraph \($0) with enough words to measure.\n\n" }.joined()
    let peer = try ScenePeer(pane: pane(source))
    defer { peer.close() }
    let editor = richEditor()
    defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.connected && editor.grid?.focusedCompose != nil }
    editor.send(.key(.with { $0.key = "T" }))
    try await eventually { peer.inputs.count == 1 }
    let updated = "X" + source
    var pending = pane(updated, revision: 5)
    pending.compose.cursors[0].position = UInt64(updated[..<updated.range(of: "Paragraph 100")!.lowerBound].utf8.count)
    pending.compose.ready = false
    let accepted = peer.reply(.with { $0.id = 1; $0.accepted = true }, pane: pending)
    try await eventually { peer.lastApplied >= accepted }
    XCTAssertTrue(peer.viewports.isEmpty, "old held geometry cannot reveal a new source caret")
    pending.compose.ready = true
    peer.show(pending)
    try await eventually { !peer.viewports.isEmpty }
    let presentation = try XCTUnwrap(editor.grid?.focusedCompose)
    let caret = try XCTUnwrap(presentation.caret)
    XCTAssertGreaterThanOrEqual(caret.minY, presentation.bounds.minY + 12 - 0.01)
    XCTAssertLessThanOrEqual(caret.maxY, presentation.bounds.maxY - 12 + 0.01)
  }

  @MainActor
  func testFormattingFailureUsesTheCurrentSourceAndKeepsInputEditable() async throws {
    let peer = try ScenePeer(pane: pane("Original paragraph\n"))
    defer { peer.close() }
    let editor = richEditor()
    defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.connected && editor.grid?.focusedCompose != nil }
    let source = "# Current source\n\n**Editable Markdown**\n"
    var fallback = pane(source, revision: 5)
    fallback.compose.ready = true
    fallback.compose.error = "Formatting is unavailable. The Markdown source remains editable."
    peer.show(fallback)
    try await eventually { editor.grid?.focusedCompose?.pane.compose.bufferRevision == 5 }
    XCTAssertEqual(editor.grid?.focusedCompose?.layout.text.projection.text, source)
    editor.send(.key(.with { $0.key = "T" }))
    try await eventually { peer.inputs.count == 1 }
    XCTAssertEqual(peer.inputs[0].scope.bufferRevision, 5)
    XCTAssertFalse(peer.inputs[0].cancel)
  }

  @MainActor
  func testTypographyChangesPreserveTheReadingAnchorAndInvalidateNavigationMeasurements() async throws {
    let source = (0..<200).map { "Paragraph \($0) with words café 👩🏽‍💻 to wrap across the page.\n\n" }.joined()
    var scene = pane(source)
    let anchor = source[..<source.range(of: "Paragraph 40")!.lowerBound].utf8.count
    scene.compose.viewport.position = UInt64(anchor)
    scene.compose.viewport.offset = 5
    let peer = try ScenePeer(pane: scene)
    defer { peer.close() }
    let editor = richEditor()
    defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.connected && editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid), original = try XCTUnwrap(grid.focusedCompose)
    let navigation = try XCTUnwrap(original.measuredNavigation())
    let measurement = try XCTUnwrap(grid.composeMeasurement(identity: original.identity, projection: original.pane.compose))
    XCTAssertEqual(try XCTUnwrap(measurement.measuredNavigation()).environmentRevision, navigation.environmentRevision)
    let before = try XCTUnwrap(original.layout.text.caret(for: anchor)).minY + original.origin.y
    var settings = ComposePreferences()
    settings.bodyFamily = "system-rounded"; settings.bodySize = 22
    settings.pageWidth = 400; settings.lineSpacing = 8; settings.paragraphSpacing = 18
    settings.headingScales = [2.2, 1.9, 1.6, 1.4, 1.2, 1]
    grid.setComposePreferences(settings, zoom: 1)
    let changed = try XCTUnwrap(grid.focusedCompose)
    XCTAssertEqual(changed.scope, original.scope, "changing presentation does not relabel source revisions")
    XCTAssertEqual(changed.layout.text.projection.text, source)
    XCTAssertEqual(CTFontGetSize(changed.body), 22)
    XCTAssertEqual(changed.layout.width, 400)
    XCTAssertFalse(changed.layout.text === original.layout.text)
    XCTAssertEqual(try XCTUnwrap(changed.layout.text.caret(for: anchor)).minY + changed.origin.y, before, accuracy: 0.001)
    let updated = try XCTUnwrap(changed.measuredNavigation())
    XCTAssertNotEqual(updated.styleRevision, navigation.styleRevision)
    XCTAssertNotEqual(updated.environmentRevision, navigation.environmentRevision)
    editor.send(.key(.with { $0.key = "T" }))
    try await eventually { peer.inputs.count == 1 }
    XCTAssertEqual(peer.inputs[0].layoutID, updated.id)
    XCTAssertEqual(peer.inputs[0].scope.bufferRevision, 4)
  }

  @MainActor
  func testHorizontalRevealAndScrollingShareTableInputGeometryAndSurviveAcknowledgment() async throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("FreshKitTests/Fixtures/compose-tables.pb")
    var initial = pane("", width: 10)
    initial.compose = try WireComposePane(serializedBytes: Data(contentsOf: fixture))
    initial.compose.focused = true; initial.compose.keyboard = true
    initial.compose.viewport = .with { $0.epoch = 7 }
    let peer = try ScenePeer(pane: initial)
    defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid), before = try XCTUnwrap(grid.focusedCompose)
    let target = initial.compose.tables[0].rows[0].cells[2].start + 2
    let navigation = try XCTUnwrap(before.measuredNavigation())
    editor.send(.key(.with { $0.key = "ArrowRight" }))
    try await eventually { peer.inputs.count == 1 }
    var updated = initial
    updated.compose.cursors[0].position = target; updated.compose.selectionRevision &+= 1
    updated.compose.textContext.selectionStart = target; updated.compose.textContext.selectionEnd = target
    peer.reply(.with { $0.id = 1; $0.accepted = true }, pane: updated)
    try await eventually { peer.viewports.count == 1 }
    let request = peer.viewports[0]
    XCTAssertGreaterThan(request.horizontalOffset, 0)
    XCTAssertEqual(request.position, 0)
    let scrolled = try XCTUnwrap(grid.focusedCompose), caret = try XCTUnwrap(scrolled.caret)
    XCTAssertTrue(scrolled.layout.text === before.layout.text)
    XCTAssertLessThan(scrolled.origin.x, before.origin.x)
    XCTAssertGreaterThanOrEqual(caret.minX, scrolled.bounds.minX + 16 - 0.01)
    XCTAssertLessThanOrEqual(caret.maxX, scrolled.bounds.maxX - 16 + 0.01)
    XCTAssertEqual(scrolled.hit(at: CGPoint(x: caret.midX, y: caret.midY))?.source, Int(target))
    XCTAssertEqual(try XCTUnwrap(scrolled.measuredNavigation()).styleRevision, navigation.styleRevision,
      "panning changes the presentation origin, not its layout coordinates or pixel goal")
    let index = try XCTUnwrap(scrolled.textServiceIndex(for: Int(target)))
    let area = try XCTUnwrap(scrolled.textServiceRect(for: NSRange(location: index, length: 0)))
    XCTAssertEqual(area.rect.minX + scrolled.origin.x, caret.minX, accuracy: 0.01)

    updated.compose.viewport = .with {
      $0.epoch = request.epoch; $0.sequence = request.id; $0.position = request.position
      $0.offset = request.offset; $0.affinity = request.affinity; $0.horizontalOffset = request.horizontalOffset
    }
    peer.acknowledgeScroll(request, pane: updated)
    try await eventually { grid.focusedCompose?.pane.compose.viewport.sequence == request.id }
    let acknowledged = try XCTUnwrap(grid.focusedCompose)
    XCTAssertEqual(acknowledged.origin.x, scrolled.origin.x, accuracy: 0.001)
    editor.grid(grid, scroll: CGPoint(x: -10_000, y: 0), in: acknowledged)
    try await eventually { peer.viewports.count == 2 }
    XCTAssertEqual(peer.viewports[1].horizontalOffset, 0)
    XCTAssertEqual(peer.inputs.count, 1, "scrolling cannot edit source or move its cursor")
    XCTAssertEqual(grid.focusedCompose?.layout.text.projection.text, before.layout.text.projection.text)
  }

  @MainActor
  func testMarkedCaretCanRevealHorizontallyWithoutCommittingAndRetainsItsPanAfterAcknowledgment() async throws {
    var initial = pane("x", width: 5)
    initial.compose.cursors[0].position = 1; initial.compose.cursors[0].anchor = 0
    initial.compose.textContext.selectionStart = 0; initial.compose.textContext.selectionEnd = 1
    let peer = try ScenePeer(pane: initial)
    defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose != nil }
    let grid = try XCTUnwrap(editor.grid), draft = "👩🏽‍💻"
    grid.setMarkedText(draft, selectedRange: NSRange(location: draft.utf16.count, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    try await eventually { peer.viewports.count == 1 }
    let request = peer.viewports[0]
    XCTAssertGreaterThan(request.horizontalOffset, 0)
    XCTAssertTrue(peer.inputs.isEmpty)
    let presentation = try XCTUnwrap(grid.focusedCompose), caret = try XCTUnwrap(presentation.caret)
    XCTAssertLessThanOrEqual(caret.maxX, presentation.bounds.maxX - 16 + 0.01)
    XCTAssertEqual(presentation.pane.compose.text, "x")
    XCTAssertEqual(presentation.layout.text.projection.text, draft)
    let area = try XCTUnwrap(presentation.textServiceRect(for: grid.selectedRange()))
    XCTAssertEqual(area.rect.minX + presentation.origin.x, caret.minX, accuracy: 0.01)
    initial.compose.viewport = .with {
      $0.epoch = request.epoch; $0.sequence = request.id; $0.position = request.position
      $0.offset = request.offset; $0.affinity = request.affinity; $0.horizontalOffset = request.horizontalOffset
    }
    peer.acknowledgeScroll(request, pane: initial)
    try await eventually { grid.focusedCompose?.pane.compose.viewport.sequence == request.id }
    XCTAssertEqual(try XCTUnwrap(grid.focusedCompose?.caret).minX, caret.minX, accuracy: 0.01)
    XCTAssertTrue(grid.hasMarkedText()); XCTAssertTrue(peer.inputs.isEmpty)
    grid.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
    XCTAssertFalse(grid.hasMarkedText()); XCTAssertTrue(peer.inputs.isEmpty)
  }

  @MainActor
  func testReceivedImageDecodeSurvivesAnExplicitlyUnusableFormattingFrame() async throws {
    let source = "Before ![pic](x.png) after text.\n"
    var scene = pane(source)
    scene.compose.assetAuthority = 5; scene.compose.assetDocument = 7
    scene.compose.images = [.with { $0.start = 7; $0.end = 20; $0.target = "x.png"; $0.alt = "Picture"; $0.rendered = true }]
    let peer = try ScenePeer(pane: scene); defer { peer.close() }
    let started = expectation(description: "received bytes on the native decode queue")
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let editor = richEditor(decodeImage: { bytes, dimension in
      XCTAssertFalse(Thread.isMainThread)
      started.fulfill(); release.wait()
      return try ComposeImageAsset.decode(bytes, maximumDimension: dimension)
    })
    defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { peer.assets.contains { !$0.cancel } }
    let pixels = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8,
      bytesPerRow: 160, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let bytes = NSMutableData(), png = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(png, try XCTUnwrap(pixels.makeImage()), nil); XCTAssertTrue(CGImageDestinationFinalize(png))
    peer.image(.with { $0.id = peer.assets.last!.id; $0.data = bytes as Data; $0.total = UInt64(bytes.length); $0.done = true
      $0.version = Data(repeating: 1, count: 32); $0.digest = Data(repeating: 1, count: 32) })
    await fulfillment(of: [started], timeout: 3)
    var pending = pane("X" + source, revision: 5)
    pending.compose.assetAuthority = 5; pending.compose.assetDocument = 7
    pending.compose.ready = false; pending.compose.currentProjection = false
    peer.show(pending)
    try await eventually { editor.store.panes.first?.compose.bufferRevision == 5 }
    XCTAssertEqual(editor.grid?.focusedCompose?.pane.compose.bufferRevision, 4,
      "pending source retains its original coherent presentation and image references")
    release.signal()
    try await eventually { editor.grid?.focusedCompose?.layout.text.attachments.first?.rect.width == 40 }
    XCTAssertEqual(peer.assets.filter { !$0.cancel }.count, 1,
      "a pending presentation may finish received bytes but must not start a stale source read")
    pending.compose.ready = true; pending.compose.currentProjection = true
    pending.compose.images = scene.compose.images.map { image in var image = image; image.start += 1; image.end += 1; return image }
    peer.show(pending)
    try await eventually { editor.grid?.focusedCompose?.pane.compose.bufferRevision == 5 }
    XCTAssertEqual(editor.grid?.focusedCompose?.layout.text.attachments.first?.rect.width, 40)
    XCTAssertEqual(peer.assets.filter { !$0.cancel }.count, 1)
  }

  @MainActor
  func testReturningToTheEditorRevalidatesImagesWithoutBlankingTheNativePreview() async throws {
    let source = "Before ![pic](x.png) after text.\n"
    var scene = pane(source)
    scene.compose.assetAuthority = 5; scene.compose.assetDocument = 7
    scene.compose.images = [.with { $0.start = 7; $0.end = 20; $0.target = "x.png"; $0.alt = "Picture"; $0.rendered = true }]
    let peer = try ScenePeer(pane: scene)
    defer { peer.close() }
    let editor = richEditor()
    defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { peer.assets.contains { !$0.cancel } }
    func png(_ width: Int) throws -> Data {
      let context = try XCTUnwrap(CGContext(data: nil, width: width, height: 20, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      let data = NSMutableData()
      let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
      CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
      XCTAssertTrue(CGImageDestinationFinalize(destination))
      return data as Data
    }
    func previewWidth() -> CGFloat? { editor.grid?.focusedCompose?.layout.text.attachments.first?.rect.width }
    let initial = try png(40)
    peer.image(.with { $0.id = peer.assets.last!.id; $0.data = initial; $0.total = UInt64(initial.count); $0.done = true
      $0.version = Data(repeating: 1, count: 32); $0.digest = Data(repeating: 1, count: 32) })
    try await eventually { previewWidth() == 40 }
    editor.switchBack(); editor.show()
    try await eventually { peer.assets.filter { !$0.cancel }.count == 2 }
    let check = try XCTUnwrap(peer.assets.last)
    XCTAssertEqual(check.knownVersion, Data(repeating: 1, count: 32))
    XCTAssertEqual(check.knownDigest, Data(repeating: 1, count: 32))
    XCTAssertEqual(previewWidth(), 40, "an in-flight revalidation retains the already drawn image")
    let checked = peer.image(.with { $0.id = check.id; $0.done = true; $0.unchanged = true
      $0.version = Data(repeating: 2, count: 32); $0.digest = check.knownDigest })
    try await eventually { peer.lastApplied >= checked }
    XCTAssertEqual(previewWidth(), 40)
    editor.switchBack(); editor.show()
    try await eventually { peer.assets.filter { !$0.cancel }.count == 3 }
    let replacement = try png(80)
    XCTAssertEqual(previewWidth(), 40)
    peer.image(.with { $0.id = peer.assets.last!.id; $0.data = replacement; $0.total = UInt64(replacement.count); $0.done = true
      $0.version = Data(repeating: 3, count: 32); $0.digest = Data(repeating: 3, count: 32) })
    try await eventually { previewWidth() == 80 }
    XCTAssertEqual(editor.grid?.focusedCompose?.scope.bufferRevision, 4)
    XCTAssertEqual(editor.grid?.focusedCompose?.pane.compose.text, source)
    editor.switchBack(); editor.show()
    try await eventually { peer.assets.filter { !$0.cancel }.count == 4 }
    let interrupted = peer.image(.with { $0.id = peer.assets.last!.id; $0.error = "Temporarily offline"; $0.retryable = true; $0.done = true })
    try await eventually { peer.lastApplied >= interrupted }
    XCTAssertEqual(previewWidth(), 80)
    let current = try XCTUnwrap(editor.grid?.focusedCompose)
    let rect = try XCTUnwrap(current.layout.text.attachments.first?.rect).offsetBy(dx: current.origin.x, dy: current.origin.y)
    let description = editor.grid?.composeImageDescription(at: CGPoint(x: rect.midX, y: rect.midY))
    XCTAssertTrue(description?.contains("Picture") == true)
    XCTAssertTrue(description?.contains("last preview") == true)
    XCTAssertTrue(description?.contains("Temporarily offline") == true)
    scene.compose.images[0].rendered = false; scene.compose.images[0].sourcePreview = true
    scene.compose.projectionRevision = 5; scene.compose.selectionRevision = 5
    scene.compose.cursors[0].position = 10
    peer.show(scene)
    try await eventually { editor.grid?.focusedCompose?.layout.text.attachments.first?.attachment.preview == true }
    XCTAssertEqual(previewWidth(), 80, "entering source editing retains the decoded preview")
    XCTAssertEqual(peer.assets.filter { !$0.cancel }.count, 4, "revealing markup alone does not redownload unchanged bytes")
    XCTAssertEqual(editor.grid?.focusedCompose?.layout.text.projection.text, source)
  }

  @MainActor
  func testAutomaticWindowContinuationWaitsForCompleteFormattingOfCurrentSource() async throws {
    var pending = pane("Current source\n")
    pending.compose.documentLen = 10_000; pending.compose.ready = false; pending.compose.currentProjection = true
    let peer = try ScenePeer(pane: pending); defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose?.pane.compose.currentProjection == true }
    editor.send(.key(.with { $0.key = "ArrowRight" }))
    try await eventually { peer.inputs.count == 1 }
    XCTAssertTrue(peer.viewports.isEmpty, "a provisional height cannot trigger automatic source-window loading")
    pending.compose.ready = true
    peer.show(pending)
    try await eventually { peer.viewports.count == 1 }
    XCTAssertEqual(peer.viewports[0].position, pending.compose.sourceEnd)
  }

  @MainActor
  func testCurrentPendingProjectionKeepsLargeHeadingsAndDecodedInlineImagesInteractive() async throws {
    let markup = "![pic](x.png)"
    func rich(_ word: String, revision: UInt64) -> WirePane {
      let source = "# Title\n\n\(word) \(markup) after.\n"
      let start = source[..<source.range(of: markup)!.lowerBound].utf8.count, end = start + markup.utf8.count
      var value = pane(source, revision: revision)
      value.compose.text = String(source.dropFirst(2)).replacingOccurrences(of: markup, with: "\u{fffc}")
      value.compose.segments = [
        .with { $0.sourceEnd = 2; $0.kind = 1 },
        .with { $0.sourceStart = 2; $0.sourceEnd = UInt64(start); $0.displayEnd = UInt64(start - 2) },
        .with { $0.sourceStart = UInt64(start); $0.sourceEnd = UInt64(end); $0.displayStart = UInt64(start - 2); $0.displayEnd = UInt64(start + 1); $0.kind = 2 },
        .with { $0.sourceStart = UInt64(end); $0.sourceEnd = UInt64(source.utf8.count); $0.displayStart = UInt64(start + 1); $0.displayEnd = UInt64(value.compose.text.utf8.count) },
      ]
      value.compose.spans = [.with { $0.start = 0; $0.end = 8; $0.role = 1 }]
      value.compose.assetAuthority = 5; value.compose.assetDocument = 7
      value.compose.images = [.with { $0.start = UInt64(start); $0.end = UInt64(end); $0.target = "x.png"; $0.alt = "Picture"; $0.rendered = true }]
      value.compose.cursors[0].position = UInt64(source.utf8.count); value.compose.cursors[0].utf16Position = UInt64(source.utf16.count)
      value.compose.textContext.selectionStart = UInt64(source.utf16.count); value.compose.textContext.selectionEnd = UInt64(source.utf16.count)
      return value
    }
    let peer = try ScenePeer(pane: rich("Before", revision: 4)); defer { peer.close() }
    let editor = richEditor(); defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { peer.assets.contains { !$0.cancel } }
    let pixels = try XCTUnwrap(CGContext(data: nil, width: 80, height: 20, bitsPerComponent: 8,
      bytesPerRow: 320, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    pixels.setFillColor(CGColor(red: 0.1, green: 0.65, blue: 0.35, alpha: 1)); pixels.fill(CGRect(x: 0, y: 0, width: 80, height: 20))
    let bytes = NSMutableData(), png = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(png, try XCTUnwrap(pixels.makeImage()), nil); XCTAssertTrue(CGImageDestinationFinalize(png))
    peer.image(.with { $0.id = peer.assets.last!.id; $0.data = bytes as Data; $0.total = UInt64(bytes.length); $0.done = true
      $0.version = Data(repeating: 1, count: 32); $0.digest = Data(repeating: 1, count: 32) })
    try await eventually { editor.grid?.focusedCompose?.layout.text.attachments.first?.rect.width == 80 }
    let grid = try XCTUnwrap(editor.grid)
    func artifact(_ name: String) throws {
      guard let directory = ProcessInfo.processInfo.environment["FC_COMPOSE_ARTIFACT_DIR"] else { return }
      let pane = try XCTUnwrap(grid.focusedCompose), width = Int(ceil(pane.bounds.width)), height = Int(ceil(pane.bounds.height))
      let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
      pane.draw(in: context, dirty: pane.bounds, foreground: .black, background: .white, selection: .blue)
      let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let output = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
      CGImageDestinationAddImage(output, try XCTUnwrap(context.makeImage()), nil); XCTAssertTrue(CGImageDestinationFinalize(output))
    }
    try artifact("before")
    var pending = rich("Changed", revision: 5)
    pending.compose.ready = false; pending.compose.currentProjection = true
    let before = peer.lastApplied; peer.show(pending)
    try await eventually { peer.lastApplied > before }
    let current = try XCTUnwrap(grid.focusedCompose)
    XCTAssertEqual(current.pane.compose.bufferRevision, 5)
    XCTAssertEqual(current.layout.text.projection.text, "Title\n\nChanged \u{fffc} after.\n")
    XCTAssertEqual(current.layout.text.attachments.first?.rect.width, 80)
    XCTAssertEqual(peer.assets.filter { !$0.cancel }.count, 1, "a source offset change retains the decoded resource")
    XCTAssertGreaterThan(try XCTUnwrap(current.layout.text.fragments.first?.rect.height), try XCTUnwrap(current.layout.text.fragments.last?.rect.height))
    try artifact("pending")
    editor.send(.key(.with { $0.key = "ArrowRight" }))
    try await eventually { peer.inputs.count == 1 }
    XCTAssertEqual(peer.inputs[0].scope.bufferRevision, 5)
    peer.reply(.with { $0.id = 1; $0.needsLayout = true; $0.compose = pending.compose })
    try await eventually { peer.inputs.count == 2 }
    XCTAssertEqual(peer.inputs[1].id, 1); XCTAssertTrue(peer.inputs[1].hasLayout)
    XCTAssertEqual(peer.inputs[1].scope.projectionRevision, 5)
    let sequence = peer.reply(.with { $0.id = 1; $0.accepted = true })
    try await eventually { peer.lastApplied >= sequence }
    let unspecified = NSRange(location: NSNotFound, length: 0)
    grid.insertText("abc", replacementRange: unspecified)
    try await eventually { peer.inputs.count == 3 }
    let prefix = try XCTUnwrap(grid.focusedCompose), draft = try XCTUnwrap(prefix.layout.draftDisplayRanges[1])
    let rect = try XCTUnwrap(prefix.layout.text.caret(atUTF16: draft.location + 1))
    editor.grid(grid, point: CGPoint(x: prefix.origin.x + rect.minX, y: prefix.origin.y + rect.midY), in: prefix, extend: false, count: 1)
    grid.setMarkedText("日", selectedRange: NSRange(location: 1, length: 0), replacementRange: unspecified)
    let layered = try XCTUnwrap(grid.focusedCompose)
    XCTAssertTrue(layered.layout.text.projection.text.hasSuffix("a日bc"))
    XCTAssertEqual(layered.layout.text.attachments.first?.rect.width, 80)
    XCTAssertEqual(peer.assets.filter { !$0.cancel }.count, 1)
    XCTAssertGreaterThan(try XCTUnwrap(layered.layout.text.fragments.first?.rect.height), try XCTUnwrap(layered.layout.text.fragments.last?.rect.height))
    try artifact("nested-pending")
  }

  @MainActor
  func testSourcePreviewUsesTheImageRangeAndPasteSendsOnlyCopiedMarkdown() async throws {
    let markup = "![**café**](<images/a b.png>)"
    let source = "Before \(markup) after.\r\n"
    var scene = pane(source)
    scene.compose.assetAuthority = 5; scene.compose.assetDocument = 7
    scene.compose.images = [.with { $0.start = 7; $0.end = UInt64(7 + markup.utf8.count)
      $0.target = "images/a b.png"; $0.alt = "café"; $0.sourcePreview = true }]
    scene.compose.cursors[0].position = 11
    let peer = try ScenePeer(pane: scene)
    defer { peer.close() }
    let pasteboard = MemoryPasteboard()
    let editor = richEditor(pasteboard: pasteboard)
    defer { editor.detachAll() }
    editor.attach(socketPath: peer.path, app: nil)
    try await eventually { editor.grid?.focusedCompose?.layout.text.attachments.first?.attachment.preview == true }
    let grid = try XCTUnwrap(editor.grid), presentation = try XCTUnwrap(grid.focusedCompose)
    XCTAssertEqual(presentation.layout.text.projection.text, source)
    let rect = try XCTUnwrap(presentation.layout.text.attachments.first?.rect)
      .offsetBy(dx: presentation.origin.x, dy: presentation.origin.y)
    editor.grid(grid, point: CGPoint(x: rect.midX, y: rect.midY), in: presentation, extend: false, count: 1)
    try await eventually { peer.inputs.count == 1 }
    XCTAssertEqual(peer.inputs[0].attachmentStart, 7)
    XCTAssertEqual(peer.inputs[0].position, scene.compose.images[0].end)
    XCTAssertEqual(peer.inputs[0].sourceRevision, 4)
    scene.compose.images[0].sourcePreview = false; scene.compose.images[0].rendered = true
    scene.compose.projectionRevision = 5; scene.compose.selectionRevision = 5
    scene.compose.cursors[0].position = scene.compose.images[0].end
    scene.compose.cursors[0].anchor = 7
    peer.reply(.with { $0.id = 1; $0.accepted = true }, pane: scene)
    try await eventually { grid.focusedCompose?.pane.compose.projectionRevision == 5 }
    let copied = peer.copy(markup, sequence: 1)
    try await eventually { peer.lastApplied >= copied }
    XCTAssertEqual(pasteboard.editorText, markup)
    editor.gridPaste(grid)
    try await eventually { peer.inputs.count == 2 }
    XCTAssertEqual(UInt64(peer.inputs[1].kind), SceneWire.Kind.paste.rawValue)
    XCTAssertEqual(try WirePaste(serializedBytes: peer.inputs[1].payload).text, markup)
    XCTAssertEqual(peer.inputs[1].scope.projectionRevision, 5)
  }
}
