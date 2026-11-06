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
        $0.focused = true; $0.keyboard = true
        $0.cursors = [.with { $0.primary = true; $0.id = 1; $0.position = revision == 4 ? 0 : 1 }]
        $0.textContext = .with {
          $0.text = text; $0.selectionStart = revision == 4 ? 0 : 1; $0.selectionEnd = $0.selectionStart
        }
      }
    }
  }

  @MainActor
  private func richEditor(pasteboard: (any EditorPasteboard)? = nil) -> NativeEditor {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let gate = ProcessInfo.processInfo.environment["FC_NATIVE_RICH_COMPOSE"]
    setenv("FC_NATIVE_RICH_COMPOSE", "1", 1)
    defer { if let gate { setenv("FC_NATIVE_RICH_COMPOSE", gate, 1) } else { unsetenv("FC_NATIVE_RICH_COMPOSE") } }
    return NativeEditor(pasteboard: pasteboard ?? MemoryPasteboard())
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
