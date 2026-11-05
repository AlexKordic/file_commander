import AppKit
import XCTest
import FreshKit
import SwiftProtobuf
@testable import FileCommander

/// A private scene peer controls acknowledgment timing. The production editor,
/// socket, scene store, AppKit pane and input queue run unchanged.
private final class ScenePeer: @unchecked Sendable {
  let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("fc-compose-input-\(UUID().uuidString)")
  var path: String { directory.appendingPathComponent("scene.sock").path }
  private let lock = NSLock()
  private var listener: Int32 = -1
  private var client: Int32 = -1
  private var received: [WireComposeInput] = []
  private var receivedKeys: [WireKey] = []
  private var receivedViewports: [WireComposeViewportRequest] = []
  private var sequence: UInt64 = 0
  private var applied: UInt64 = 0

  var inputs: [WireComposeInput] { lock.lock(); defer { lock.unlock() }; return received }
  var keys: [WireKey] { lock.lock(); defer { lock.unlock() }; return receivedKeys }
  var viewports: [WireComposeViewportRequest] { lock.lock(); defer { lock.unlock() }; return receivedViewports }
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
          send(.serverHello, WireServerHello.with { $0.version = SceneWire.version; $0.scene = self.frame(pane: pane) })
        } else if kind == SceneWire.Kind.composeInput.rawValue, let input = try? WireComposeInput(serializedBytes: payload) {
          lock.lock(); received.append(input); lock.unlock()
        } else if kind == SceneWire.Kind.applied.rawValue, let ack = try? WireApplied(serializedBytes: payload) {
          lock.lock(); applied = ack.seq; lock.unlock()
        } else if kind == SceneWire.Kind.key.rawValue, let key = try? WireKey(serializedBytes: payload) {
          lock.lock(); receivedKeys.append(key); lock.unlock()
        } else if kind == SceneWire.Kind.composeViewport.rawValue, let request = try? WireComposeViewportRequest(serializedBytes: payload) {
          lock.lock(); receivedViewports.append(request); lock.unlock()
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
      }
    }
  }

  @MainActor
  private func richEditor() -> NativeEditor {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let gate = ProcessInfo.processInfo.environment["FC_NATIVE_RICH_COMPOSE"]
    setenv("FC_NATIVE_RICH_COMPOSE", "1", 1)
    defer { if let gate { setenv("FC_NATIVE_RICH_COMPOSE", gate, 1) } else { unsetenv("FC_NATIVE_RICH_COMPOSE") } }
    return NativeEditor()
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
    XCTAssertEqual(changed.layout.text.size.width, 400)
    XCTAssertFalse(changed.layout.text === original.layout.text)
    XCTAssertEqual(try XCTUnwrap(changed.layout.text.caret(for: anchor)).minY + changed.origin.y, before, accuracy: 0.001)
    let updated = try XCTUnwrap(changed.measuredNavigation())
    XCTAssertNotEqual(updated.styleRevision, navigation.styleRevision)
    editor.send(.key(.with { $0.key = "T" }))
    try await eventually { peer.inputs.count == 1 }
    XCTAssertEqual(peer.inputs[0].layoutID, updated.id)
    XCTAssertEqual(peer.inputs[0].scope.bufferRevision, 4)
  }
}
