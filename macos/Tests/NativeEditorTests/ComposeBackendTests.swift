import AppKit
import ImageIO
import XCTest
import FreshKit
@testable import FileCommander

@MainActor
private final class BackendPasteboard: EditorPasteboard {
  private(set) var editorText: String?
  func replaceEditorText(_ text: String) { editorText = text }
}

/// Owns one foreground Fresh process and private filesystem/runtime directories.
/// Explicit opt-in keeps ordinary Swift tests independent of a development binary.
private final class ComposeBackend {
  let root: URL
  let binary, config: URL
  let server = Process()
  let environment: [String: String]
  let name = "native-compose"
  private let log: FileHandle

  init(binary: URL) throws {
    self.binary = binary
    root = URL(fileURLWithPath: "/tmp/fc-cn-\(UUID().uuidString.prefix(10))")
    for directory in ["", "home", "config", "data", "cache", "state", "runtime", "session"] {
      try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    }
    config = root.appendingPathComponent("settings.json")
    let settings: [String: Any] = [
      "check_for_updates": false,
      "clipboard": ["use_system_clipboard": false, "use_osc52": false],
      "editor": ["auto_close": false, "auto_indent": false, "animations": false],
      "plugins": ["orchestrator": ["settings": ["autoOpenDock": "never"]],
        "welcome_screen": ["settings": ["showOnStartup": false]]],
    ]
    try JSONSerialization.data(withJSONObject: settings).write(to: config)
    var env = ProcessInfo.processInfo.environment
    for (key, directory) in [("HOME", "home"), ("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"),
      ("XDG_CACHE_HOME", "cache"), ("XDG_STATE_HOME", "state"), ("XDG_RUNTIME_DIR", "runtime"), ("FRESH_FC_DATA_DIR", "session")] {
      env[key] = root.appendingPathComponent(directory).path
    }
    env["FC_EDITOR_SWITCH_KEY"] = "f10"; env["RUST_LOG"] = env["FC_COMPOSE_TEST_LOG"] ?? "warn"
    env.removeValue(forKey: "FC_LEGACY_CHECKPOINT")
    environment = env
    let path = root.appendingPathComponent("launcher.log")
    _ = FileManager.default.createFile(atPath: path.path, contents: nil)
    log = try FileHandle(forWritingTo: path)
    server.executableURL = binary
    server.arguments = ["--server", "--session-name", name, "--config", config.path, "--no-init", "--no-upgrade-check"]
    server.environment = env; server.currentDirectoryURL = root
    server.standardInput = FileHandle.nullDevice; server.standardOutput = log; server.standardError = log
    try server.run()
  }

  func command(_ arguments: [String]) async throws -> Data {
    let binary = binary, root = root, config = config, env = environment
    return try await withCheckedThrowingContinuation { continuation in
      // Keep launch/wait on one worker: a suspended cooperative task can
      // resume on another thread. The harness previously stalled in
      // Foundation's termination wait after making that thread transition.
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let output = root.appendingPathComponent("command-\(UUID().uuidString).log")
          _ = FileManager.default.createFile(atPath: output.path, contents: nil)
          let log = try FileHandle(forWritingTo: output)
          defer { try? log.close() }
          let process = Process()
          process.executableURL = binary; process.arguments = ["--config", config.path, "--cmd", "session"] + arguments
          process.environment = env; process.currentDirectoryURL = root
          process.standardInput = FileHandle.nullDevice; process.standardOutput = log; process.standardError = log
          try process.run()
          let deadline = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
          DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: deadline)
          process.waitUntilExit(); deadline.cancel()
          let result = try Data(contentsOf: output)
          guard process.terminationStatus == 0 else {
            throw NSError(domain: "ComposeBackend", code: Int(process.terminationStatus),
              userInfo: [NSLocalizedDescriptionKey: String(decoding: result.suffix(2000), as: UTF8.self)])
          }
          continuation.resume(returning: result)
        } catch { continuation.resume(throwing: error) }
      }
    }
  }

  func stop() {
    if server.isRunning { server.terminate() }
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while server.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
    if server.isRunning { kill(server.processIdentifier, SIGKILL) }
    server.waitUntilExit()
    try? log.close()
    try? FileManager.default.removeItem(at: root)
  }

  func captureDiagnostics(_ name: String) {
    guard let path = ProcessInfo.processInfo.environment["FC_COMPOSE_ARTIFACT_DIR"] else { return }
    let destination = URL(fileURLWithPath: path).appendingPathComponent(name + "-" + root.lastPathComponent)
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
    // Keep this fixture and its command/launcher/server logs. The detached
    // backend redirects stderr into XDG_STATE_HOME, rather than launcher.log.
    guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys) else { return }
    try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    for file in files {
      guard let values = try? file.resourceValues(forKeys: Set(keys)),
            values.isRegularFile == true, values.isSymbolicLink != true else { continue }
      let output = destination.appendingPathComponent(file.lastPathComponent)
      try? FileManager.default.copyItem(at: file, to: output)
    }
    let logs = root.appendingPathComponent("state/fresh/logs")
    for file in (try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: keys)) ?? [] {
      guard let values = try? file.resourceValues(forKeys: Set(keys)),
            values.isRegularFile == true, values.isSymbolicLink != true else { continue }
      try? FileManager.default.copyItem(at: file, to: destination.appendingPathComponent(file.lastPathComponent))
    }
  }
}

final class ComposeBackendTests: XCTestCase {
  @MainActor
  private func eventually(_ editor: NativeEditor? = nil, _ description: String,
                          timeout: TimeInterval = 12, _ condition: () -> Bool,
                          file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    if !condition() {
      let state = editor?.store.panes.map { pane in
        let c = pane.compose
        return "leaf=\(pane.leaf) ready=\(c.ready) key=\(c.keyboard) source=\(c.sourceStart)..<\(c.sourceEnd)/\(c.documentLen) cursors=\(c.cursors.map { "\($0.position):\($0.hasAnchor ? String($0.anchor) : "nil")" }) error=\(c.error.prefix(160))"
      }.joined(separator: "; ") ?? "startup"
      XCTFail("\(description): \(state)", file: file, line: line)
      throw POSIXError(.ETIMEDOUT)
    }
  }

  private func backend() throws -> ComposeBackend {
    guard let path = ProcessInfo.processInfo.environment["FC_COMPOSE_TEST_FRESH"] else {
      throw XCTSkip("Set FC_COMPOSE_TEST_FRESH to a matching Fresh binary with the web feature for the native/backend contract")
    }
    guard FileManager.default.isExecutableFile(atPath: path) else { throw POSIXError(.ENOENT) }
    return try ComposeBackend(binary: URL(fileURLWithPath: path))
  }

  @MainActor
  private func attach(_ backend: ComposeBackend, file: URL, editor: NativeEditor) async throws {
    let control = backend.root.appendingPathComponent("runtime/fresh/\(backend.name).ctrl.sock")
    try await eventually(nil, "private server control socket") { backend.server.isRunning && FileManager.default.fileExists(atPath: control.path) }
    let result = try await backend.command(["ensure", backend.name])
    let record = try XCTUnwrap(try JSONSerialization.jsonObject(with: result) as? [String: Any])
    XCTAssertEqual((record["pid"] as? NSNumber)?.int32Value, backend.server.processIdentifier)
    let path = try XCTUnwrap(record["scene"] as? String)
    _ = try await backend.command(["open-file", backend.name, file.path])
    editor.attach(socketPath: path, app: nil)
    try await eventually(editor, "connected native editor") { editor.connected && !editor.store.panes.isEmpty }
    if editor.grid?.focusedCompose == nil { editor.send(.action(name: "markdownToggleCompose", argsJson: "")) }
    try await eventually(editor, "ready measured Compose") {
      guard let pane = editor.grid?.focusedCompose else { return false }
      return pane.pane.compose.formattingReady && pane.pane.compose.keyboard && !pane.layout.text.tables.isEmpty
    }
  }

  @MainActor
  private func editor(_ pasteboard: BackendPasteboard) -> NativeEditor {
    _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
    return NativeEditor(pasteboard: pasteboard,
      environment: ["FC_NATIVE_RICH_COMPOSE": "1", "FC_NATIVE_MEASURED_TABLES": "1"])
  }

  @MainActor
  private func click(_ source: UInt64, editor: NativeEditor) async throws {
    let grid = try XCTUnwrap(editor.grid), pane = try XCTUnwrap(grid.focusedCompose)
    let rect = try XCTUnwrap(pane.layout.text.caret(for: Int(source)))
    let point = CGPoint(x: rect.minX + pane.origin.x + 0.01, y: rect.midY + pane.origin.y)
    XCTAssertEqual(pane.hit(at: point)?.source, Int(source))
    editor.grid(grid, point: point, in: pane, extend: false, count: 1)
    try await eventually(editor, "source click \(source)") { editor.grid?.focusedCompose?.cursor?.position == source }
  }

  @MainActor
  func testRealBackendSplitTablesKeepDocumentIdentityAndIndependentCursorsThroughSaveUndo() async throws {
    let backend = try backend(); defer { backend.stop() }
    let editor = editor(BackendPasteboard()); defer { editor.detachAll() }
    let original = "# Split tables\n\n| A | B |\n|---|---|\n| alpha | beta |\n| one | two |\n\nTail\n"
    let file = backend.root.appendingPathComponent("splits.md")
    try Data(original.utf8).write(to: file)
    try await attach(backend, file: file, editor: editor)
    let grid = try XCTUnwrap(editor.grid), before = try XCTUnwrap(grid.focusedCompose)
    editor.send(.action(name: "split_vertical", argsJson: ""))
    try await eventually(editor, "two native split panes") { editor.store.panes.count == 2 }
    if grid.composePanes.count < 2 { editor.send(.action(name: "markdownToggleCompose", argsJson: "")) }
    try await eventually(editor, "both split panes have ready tables") {
      grid.composePanes.count == 2 && grid.composePanes.values.allSatisfy {
        $0.pane.compose.formattingReady && !$0.layout.text.tables.isEmpty
      }
    }
    let peers = Array(grid.composePanes.values)
    XCTAssertEqual(Set(peers.map { $0.pane.buffer }).count, 1)
    XCTAssertEqual(Set(peers.map { $0.pane.compose.assetAuthority }).count, 1)
    XCTAssertEqual(Set(peers.map { $0.pane.compose.assetDocument }).count, 1)
    XCTAssertEqual(Set(peers.map { $0.pane.compose.tables[0].measurementID }).count, 1)
    XCTAssertFalse(peers[0].layout.text === peers[1].layout.text)
    let active = try XCTUnwrap(grid.focusedCompose)
    let other = try XCTUnwrap(peers.first { $0.identity != active.identity })
    let position = UInt64(original[..<original.range(of: "alpha")!.lowerBound].utf8.count)
    try await click(position, editor: editor)
    grid.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
    editor.send(.action(name: "save", argsJson: ""))
    let expected = Data(original.utf8.prefix(Int(position))) + Data("X".utf8) + Data(original.utf8.dropFirst(Int(position)))
    try await eventually(editor, "save updates the shared source in both independent views") {
      (try? Data(contentsOf: file)) == expected
        && grid.composePanes.values.allSatisfy { $0.pane.compose.documentLen == UInt64(expected.count) }
    }
    XCTAssertEqual(grid.composePanes[other.identity.leaf]?.cursor?.position, other.cursor?.position)
    XCTAssertEqual(grid.focusedCompose?.cursor?.position, position + 1)
    editor.send(.action(name: "undo", argsJson: "")); editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "one undo restores the original source in both splits") {
      (try? Data(contentsOf: file)) == Data(original.utf8)
        && grid.composePanes.values.allSatisfy { $0.pane.compose.documentLen == before.pane.compose.documentLen }
    }
    XCTAssertTrue(editor.uninsertedText.isEmpty)
  }

  @MainActor
  func testRealBackendTableEditingImagesResizeUndoSaveAndSwitching() async throws {
    let backend = try backend(); defer { backend.stop() }
    let pasteboard = BackendPasteboard(), editor = editor(pasteboard)
    defer { editor.detachAll() }
    let original = ["# Native Compose", "", "> 1. Nested **prose** with café 👩🏽‍💻.", ">", ">    ```swift", ">    let answer = 42", ">    ```", "",
      "| Name | Detail |", "|:---|---:|", "| alpha | prose and ![tiny](tiny.png) |", "| | beta |", "| missing |", "", "Tail paragraph.", ""].joined(separator: "\r\n")
    let file = backend.root.appendingPathComponent("native.md")
    try Data(original.utf8).write(to: file)
    let bitmap = try XCTUnwrap(CGContext(data: nil, width: 12, height: 8, bitsPerComponent: 8, bytesPerRow: 48,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    bitmap.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
    let png = NSMutableData(), image = try XCTUnwrap(bitmap.makeImage())
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
    try (png as Data).write(to: backend.root.appendingPathComponent("tiny.png"))
    try await attach(backend, file: file, editor: editor)
    let grid = try XCTUnwrap(editor.grid), initial = try XCTUnwrap(grid.focusedCompose)
    XCTAssertFalse(CTFontGetSymbolicTraits(initial.body).contains(.traitMonoSpace))
    XCTAssertTrue(initial.pane.compose.spans.contains { $0.role == 1 })
    XCTAssertFalse(initial.layout.codeFrames.isEmpty)
    try await eventually(editor, "inline image decoded through Fresh filesystem") {
      guard let pane = grid.focusedCompose, let annotation = pane.pane.compose.images.first else { return false }
      return pane.layout.imageDescription(annotation) == "tiny"
    }
    let accessibleImage = try XCTUnwrap(grid.accessibilityChildren()?.first as? NSAccessibilityElement)
    XCTAssertEqual(accessibleImage.accessibilityRole(), .image)
    XCTAssertEqual(accessibleImage.accessibilityLabel(), "tiny")
    XCTAssertTrue(accessibleImage.accessibilityPerformPress())
    let imageSource = try XCTUnwrap(initial.pane.compose.images.first)
    try await eventually(editor, "accessible image action selects its exact Markdown source") {
      guard let cursor = grid.focusedCompose?.cursor else { return false }
      return cursor.position == imageSource.end && cursor.hasAnchor && cursor.anchor == imageSource.start
    }
    editor.send(.action(name: "copy", argsJson: ""))
    try await eventually(editor, "accessible image selection copies source into the private pasteboard") {
      pasteboard.editorText == "![tiny](tiny.png)"
    }
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "accessibility reads and selection preserve source bytes") { (try? Data(contentsOf: file)) == Data(original.utf8) }
    let alpha = try XCTUnwrap(original.range(of: "alpha"))
    try await click(UInt64(original[..<alpha.lowerBound].utf8.count), editor: editor)
    let row = initial.pane.compose.tables[0].rows[2]
    let empty = try XCTUnwrap(initial.measuredNavigation()?.lines.first {
      $0.hasCell && $0.cell.rowStart == row.start && $0.cell.hasColumn && $0.cell.column == 0
    }).start.source
    editor.send(.action(name: "move_down", argsJson: ""))
    try await eventually(editor, "Down into real empty cell") { grid.focusedCompose?.cursor?.position == empty }
    grid.insertText("東京", replacementRange: NSRange(location: NSNotFound, length: 0))
    let expected = Data(original.utf8.prefix(Int(empty))) + Data("東京".utf8) + Data(original.utf8.dropFirst(Int(empty)))
    try await eventually(editor, "atomic native insertion") { grid.focusedCompose?.pane.compose.documentLen == UInt64(expected.count) }
    editor.send(.action(name: "undo", argsJson: ""))
    try await eventually(editor, "undo native insertion") { grid.focusedCompose?.pane.compose.documentLen == UInt64(original.utf8.count) }
    editor.send(.action(name: "redo", argsJson: ""))
    try await eventually(editor, "redo native insertion") { grid.focusedCompose?.pane.compose.documentLen == UInt64(expected.count) }
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "save exact CRLF Markdown") { (try? Data(contentsOf: file)) == expected }
    let width = try XCTUnwrap(grid.focusedCompose).layout.width
    grid.setFrameSize(CGSize(width: 500, height: 420))
    try await eventually(editor, "native available-width resize") { (grid.focusedCompose?.layout.width ?? width) < width }
    let identity = try XCTUnwrap(grid.focusedCompose).identity
    editor.switchBack(); XCTAssertFalse(editor.shown); editor.show(); XCTAssertTrue(editor.shown)
    XCTAssertEqual(grid.focusedCompose?.identity, identity)
    XCTAssertTrue(backend.server.isRunning)
    XCTAssertEqual(try Data(contentsOf: file), expected)
  }

  @MainActor
  func testRealBackendTightNestedListWindowsKeepParentIndentThroughPagingResizeSaveAndUndo() async throws {
    let backend = try backend(); defer {
      backend.captureDiagnostics("tight-windows")
      backend.stop()
    }
    let editor = editor(BackendPasteboard()); defer { editor.detachAll() }
    let header = "| A | B |\r\n|---|---|\r\n| one | two |\r\n\r\n# Tight windows\r\n\r\n100) **Parent** café 👩🏽‍💻\r\n"
    let children = (0..<2000).map { "     - [ ] Child \($0) café 東京 👩🏽‍💻 with **prose** and `code` that wrap across the available native measure.\r\n       continued with [link](target.md) and more words for the same complete paragraph.\r\n" }.joined()
    let original = header + children + "\r\nTail\r\n"
    let bodyEnd = original.utf8.count - "\r\nTail\r\n".utf8.count
    let file = backend.root.appendingPathComponent("tight-windows.md")
    try Data(original.utf8).write(to: file)
    try await attach(backend, file: file, editor: editor)
    let grid = try XCTUnwrap(editor.grid), initial = try XCTUnwrap(grid.focusedCompose)
    let items = initial.pane.compose.spans.filter { $0.role == 13 && $0.hasContentStart }
    let parent = try XCTUnwrap(items.first), child = try XCTUnwrap(items.dropFirst().first)
    let hangingX = try XCTUnwrap(initial.layout.text.caret(for: Int(child.contentStart))).minX
    XCTAssertGreaterThan(original.utf8.count, 256 << 10)
    editor.send(.action(name: "move_document_end", argsJson: ""))
    try await eventually(editor, "tight-list document end") { grid.focusedCompose?.cursor?.position == UInt64(original.utf8.count) }
    for _ in 0..<10 {
      let before = try XCTUnwrap(grid.focusedCompose?.cursor?.position)
      if before < bodyEnd { break }
      editor.send(.action(name: "move_up", argsJson: ""))
      try await eventually(editor, "Up enters a distant tight child paragraph") { (grid.focusedCompose?.cursor?.position ?? before) < before }
    }
    var position = try XCTUnwrap(grid.focusedCompose?.cursor?.position)
    XCTAssertGreaterThan(position, UInt64(original.utf8.count / 2)); XCTAssertLessThan(position, UInt64(bodyEnd))
    editor.send(.action(name: "move_line_start", argsJson: ""))
    try await eventually(editor, "Home measures the distant tight paragraph") {
      guard let pane = grid.focusedCompose, let cursor = pane.cursor,
            let caret = pane.layout.text.caret(for: Int(cursor.position)) else { return false }
      return abs(caret.minX - hangingX) < 0.001
    }
    position = try XCTUnwrap(grid.focusedCompose?.cursor?.position)
    var pane = try XCTUnwrap(grid.focusedCompose)
    XCTAssertGreaterThan(pane.pane.compose.sourceStart, parent.contentStart)
    XCTAssertLessThan(pane.pane.compose.sourceEnd - pane.pane.compose.sourceStart, 128 << 10)
    XCTAssertTrue(pane.pane.compose.hangingContexts.contains { $0.itemStart == parent.start && $0.text == "100) P" })
    let edge = pane.pane.compose.sourceStart
    var pageCount = 0
    for _ in 0..<128 {
      if position < edge { break }
      let before = position; pageCount += 1
      editor.send(.action(name: "move_page_up", argsJson: ""))
      try await eventually(editor, "Page Up crosses tight child paragraph windows") { (grid.focusedCompose?.cursor?.position ?? before) < before }
      position = try XCTUnwrap(grid.focusedCompose?.cursor?.position)
    }
    XCTAssertLessThan(position, edge)
    pane = try XCTUnwrap(grid.focusedCompose)
    XCTAssertGreaterThan(pane.pane.compose.sourceStart, parent.contentStart)
    XCTAssertLessThan(pane.pane.compose.sourceEnd - pane.pane.compose.sourceStart, 128 << 10)
    // Paging can enter a link target and reveal its exact source, reshaping
    // that caret's line. The item's body origin still owns its hanging inset.
    let currentChild = try XCTUnwrap(pane.pane.compose.spans.filter {
      $0.role == 13 && $0.hasContentStart && $0.start <= position && position < $0.end
    }.min { $0.end - $0.start < $1.end - $1.start })
    let currentBodyX = try XCTUnwrap(pane.layout.text.caret(for: Int(currentChild.contentStart))).minX
    XCTAssertEqual(currentBodyX, hangingX, accuracy: 0.001)
    let prefix = Data(original.utf8.prefix(Int(position))), suffix = Data(original.utf8.dropFirst(Int(position)))
    XCTAssertEqual(grid.selectedRange(), NSRange(location: String(decoding: prefix, as: UTF8.self).utf16.count, length: 0))
    let width = pane.layout.width
    grid.setFrameSize(CGSize(width: 460, height: 420))
    try await eventually(editor, "resize retains tight-list source ownership") {
      grid.focusedCompose?.cursor?.position == position && (grid.focusedCompose?.layout.width ?? width) < width
    }
    let insertion = "追加👩🏽‍💻"
    grid.insertText(insertion, replacementRange: NSRange(location: NSNotFound, length: 0))
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "save exact CRLF bytes through a nested tight window") { (try? Data(contentsOf: file)) == prefix + Data(insertion.utf8) + suffix }
    editor.send(.action(name: "undo", argsJson: "")); editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "one undo restores the tight-list source") { (try? Data(contentsOf: file)) == Data(original.utf8) }
    XCTAssertTrue(editor.uninsertedText.isEmpty); XCTAssertTrue(backend.server.isRunning)
    let report: [String: Any] = ["document_bytes": original.utf8.count, "parent_source": parent.start,
      "child_body_source": child.contentStart, "body_caret_x": Double(hangingX), "page_up_count": pageCount,
      "body_x_after_pages": Double(currentBodyX),
      "caret_x_after_pages": Double(try XCTUnwrap(pane.layout.text.caret(for: Int(position))).minX),
      "window_start_before_pages": edge, "cursor_after_pages": position,
      "window_start_after_pages": pane.pane.compose.sourceStart, "window_end_after_pages": pane.pane.compose.sourceEnd]
    try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: backend.root.appendingPathComponent("tight-window-report.json"))
  }

  @MainActor
  func testRealBackendLooseListWindowsKeepOffscreenMarkersThroughResizeSaveAndUndo() async throws {
    let backend = try backend(); defer {
      backend.captureDiagnostics("paragraph-windows")
      backend.stop()
    }
    let editor = editor(BackendPasteboard()); defer { editor.detachAll() }
    let header = "| A | B |\r\n|---|---|\r\n| one | two |\r\n\r\n# Paragraph windows\r\n\r\n100) **Opening** café 👩🏽‍💻\r\n\r\n"
    let paragraphs = (0..<1600).map { "     Paragraph \($0) café 東京 👩🏽‍💻 with **prose** and `code` that wrap across the available native measure.\r\n\r\n" }.joined()
    let original = header + paragraphs + "Tail\r\n"
    let tail = original.utf8.count - "Tail\r\n".utf8.count
    let bodyEnd = tail - "\r\n\r\n".utf8.count
    let file = backend.root.appendingPathComponent("paragraph-windows.md")
    try Data(original.utf8).write(to: file)
    try await attach(backend, file: file, editor: editor)
    let grid = try XCTUnwrap(editor.grid), initial = try XCTUnwrap(grid.focusedCompose)
    let item = try XCTUnwrap(initial.pane.compose.spans.first { $0.role == 13 && $0.hasContentStart })
    let hangingX = try XCTUnwrap(initial.layout.text.caret(for: Int(item.contentStart))).minX
    XCTAssertGreaterThan(original.utf8.count, 128 << 10)
    editor.send(.action(name: "move_document_end", argsJson: ""))
    try await eventually(editor, "loose-list document end") { grid.focusedCompose?.cursor?.position == UInt64(original.utf8.count) }
    for _ in 0..<8 {
      let before = try XCTUnwrap(grid.focusedCompose?.cursor?.position)
      if before < bodyEnd { break }
      editor.send(.action(name: "move_up", argsJson: ""))
      try await eventually(editor, "measured Up into a distant loose-list paragraph") {
        guard let position = grid.focusedCompose?.cursor?.position else { return false }
        return position < before
      }
    }
    var position = try XCTUnwrap(grid.focusedCompose?.cursor?.position)
    XCTAssertGreaterThan(position, UInt64(original.utf8.count / 2)); XCTAssertLessThan(position, UInt64(bodyEnd))
    // Up may correctly land before source-owned indentation on a physical
    // line. Walk those real spaces before comparing the first prose caret.
    let bytes = Array(original.utf8)
    while position < UInt64(bytes.count) && bytes[Int(position)] == 32 {
      let before = position
      editor.send(.action(name: "move_right", argsJson: ""))
      try await eventually(editor, "Right can address source indentation in the clipped window") {
        (grid.focusedCompose?.cursor?.position ?? before) > before
      }
      position = try XCTUnwrap(grid.focusedCompose?.cursor?.position)
    }
    var pane = try XCTUnwrap(grid.focusedCompose)
    XCTAssertGreaterThan(pane.pane.compose.sourceStart, item.contentStart)
    XCTAssertLessThan(pane.pane.compose.sourceEnd - pane.pane.compose.sourceStart, 128 << 10,
      "this fixture's window must omit the unrelated earlier paragraphs")
    XCTAssertTrue(pane.pane.compose.hangingContexts.contains { $0.itemStart == item.start && $0.text == "100) O" })
    XCTAssertEqual(try XCTUnwrap(pane.layout.text.caret(for: Int(position))).minX, hangingX, accuracy: 0.001)
    let edge = pane.pane.compose.sourceStart
    var pageCount = 0
    for _ in 0..<128 {
      if position < edge { break }
      let before = position
      pageCount += 1
      editor.send(.action(name: "move_page_up", argsJson: ""))
      try await eventually(editor, "Page Up continues across loose-list source windows") {
        (grid.focusedCompose?.cursor?.position ?? before) < before
      }
      position = try XCTUnwrap(grid.focusedCompose?.cursor?.position)
    }
    XCTAssertLessThan(position, edge, "paging must actually cross the original source-window boundary")
    pane = try XCTUnwrap(grid.focusedCompose)
    XCTAssertLessThan(pane.pane.compose.sourceEnd - pane.pane.compose.sourceStart, 128 << 10,
      "the continuation must keep omitting unrelated paragraphs after crossing its original window")
    XCTAssertEqual(try XCTUnwrap(pane.layout.text.caret(for: Int(position))).minX, hangingX, accuracy: 0.001)
    let prefix = Data(original.utf8.prefix(Int(position))), suffix = Data(original.utf8.dropFirst(Int(position)))
    XCTAssertEqual(grid.selectedRange(), NSRange(location: String(decoding: prefix, as: UTF8.self).utf16.count, length: 0))
    let width = pane.layout.width
    grid.setFrameSize(CGSize(width: 460, height: 420))
    try await eventually(editor, "resize keeps the distant paragraph caret") {
      grid.focusedCompose?.cursor?.position == position && (grid.focusedCompose?.layout.width ?? width) < width
    }
    let insertion = "追加👩🏽‍💻"
    grid.insertText(insertion, replacementRange: NSRange(location: NSNotFound, length: 0))
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "save exact CRLF source through a clipped list window") {
      (try? Data(contentsOf: file)) == prefix + Data(insertion.utf8) + suffix
    }
    editor.send(.action(name: "undo", argsJson: "")); editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "undo one clipped-window insertion") { (try? Data(contentsOf: file)) == Data(original.utf8) }
    XCTAssertTrue(editor.uninsertedText.isEmpty); XCTAssertTrue(backend.server.isRunning)
    let report: [String: Any] = ["document_bytes": original.utf8.count,
      "marker_source": item.start, "marker_body_source": item.contentStart,
      "window_start_before_pages": edge, "cursor_after_pages": position,
      "window_start_after_pages": pane.pane.compose.sourceStart,
      "window_end_after_pages": pane.pane.compose.sourceEnd,
      "page_up_count": pageCount, "body_caret_x": Double(hangingX)]
    try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: backend.root.appendingPathComponent("paragraph-window-report.json"))
  }

  @MainActor
  func testRealBackendLongWrappedListKeepsMeasuredInputThroughResizeSaveAndUndo() async throws {
    let backend = try backend(); defer {
      backend.captureDiagnostics("long-paragraph")
      backend.stop()
    }
    let editor = editor(BackendPasteboard()); defer { editor.detachAll() }
    defer {
      if ProcessInfo.processInfo.environment["FC_COMPOSE_ARTIFACT_DIR"] != nil,
         let pane = editor.store.panes.first(where: { $0.hasCompose }) {
        try? pane.compose.serializedData().write(to: backend.root.appendingPathComponent("long-paragraph-final-pane.pb"))
      }
    }
    let header = "| A | B |\n|---|---|\n| one | two |\n\n# Long paragraph\n\n1) "
    let body = String(repeating: "Measured **prose** café 👩🏽‍💻 東京 with words that continue in one physical paragraph. ", count: 2000)
    let original = header + body + "\n\nTail\n"
    let bodyStart = UInt64(header.utf8.count), bodyEnd = bodyStart + UInt64(body.utf8.count)
    XCTAssertGreaterThan(body.utf8.count, 64 << 10)
    let file = backend.root.appendingPathComponent("long-paragraph.md")
    try Data(original.utf8).write(to: file)
    try await attach(backend, file: file, editor: editor)
    let grid = try XCTUnwrap(editor.grid), initial = try XCTUnwrap(grid.focusedCompose)
    XCTAssertFalse(CTFontGetSymbolicTraits(initial.body).contains(.traitMonoSpace))
    XCTAssertTrue(initial.pane.compose.spans.contains { $0.role == 1 })
    let hangingX = try XCTUnwrap(initial.layout.text.caret(for: Int(bodyStart))).minX
    editor.send(.action(name: "move_document_end", argsJson: ""))
    try await eventually(editor, "end of document after the long paragraph") {
      grid.focusedCompose?.cursor?.position == UInt64(original.utf8.count)
    }
    for _ in 0..<4 {
      let before = try XCTUnwrap(grid.focusedCompose?.cursor?.position)
      if before < bodyEnd { break }
      editor.send(.action(name: "move_up", argsJson: ""))
      try await eventually(editor, "measured Up across a long-paragraph boundary") {
        guard let position = grid.focusedCompose?.cursor?.position else { return false }
        return position < before
      }
    }
    let position = try XCTUnwrap(grid.focusedCompose?.cursor?.position)
    XCTAssertGreaterThan(position, bodyStart + UInt64(body.utf8.count / 2))
    XCTAssertLessThan(position, bodyEnd)
    let measured = try XCTUnwrap(grid.focusedCompose)
    XCTAssertEqual(try XCTUnwrap(measured.layout.text.caret(for: Int(position)),
      "cursor=\(position) projection=\(measured.layout.text.projection.source) wire=\(measured.pane.compose.sourceStart)..<\(measured.pane.compose.sourceEnd) displayed=\(String(describing: measured.layout.text.projection.displayPosition(for: Int(position))))").minX,
      hangingX, accuracy: 0.001, "a continuation window must retain its offscreen list marker's measured inset")
    let prefix = Data(original.utf8.prefix(Int(position))), suffix = Data(original.utf8.dropFirst(Int(position)))
    XCTAssertEqual(grid.selectedRange(), NSRange(location: String(decoding: prefix, as: UTF8.self).utf16.count, length: 0))
    let width = try XCTUnwrap(grid.focusedCompose?.layout.width)
    grid.setFrameSize(CGSize(width: 460, height: 420))
    try await eventually(editor, "resize preserves the long-paragraph source caret") {
      guard let pane = grid.focusedCompose else { return false }
      return pane.layout.width < width && pane.cursor?.position == position
    }
    XCTAssertNotNil(grid.focusedCompose?.layout.text.caret(for: Int(position)))
    let insertion = "追加👩🏽‍💻"
    grid.insertText(insertion, replacementRange: NSRange(location: NSNotFound, length: 0))
    editor.send(.action(name: "save", argsJson: ""))
    let expected = prefix + Data(insertion.utf8) + suffix
    try await eventually(editor, "save exact source from the long measured paragraph") { (try? Data(contentsOf: file)) == expected }
    editor.send(.action(name: "undo", argsJson: "")); editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "undo the long-paragraph edit once") { (try? Data(contentsOf: file)) == Data(original.utf8) }
    XCTAssertTrue(editor.uninsertedText.isEmpty); XCTAssertTrue(backend.server.isRunning)
  }

  @MainActor
  func testRealBackendRichComposeBeyondTwoMiBKeepsGlobalInputCoordinatesAndExactSaveUndo() async throws {
    let backend = try backend(); defer { backend.stop() }
    let pasteboard = BackendPasteboard(), editor = editor(pasteboard)
    defer { editor.detachAll() }
    let original = "| A | B |\n|---|---|\n| one | two |\n\n# Large heading\n\nProse ![tiny](tiny.png) after.\n\n"
      + String(repeating: "Paragraph café 東京 👩🏽‍💻 with proportional words.\n\n", count: 45000) + "Tail\n"
    XCTAssertGreaterThan(original.utf8.count, 2 << 20)
    let file = backend.root.appendingPathComponent("large.md")
    try Data(original.utf8).write(to: file)
    let bitmap = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 160,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let png = NSMutableData(), image = try XCTUnwrap(bitmap.makeImage())
    let output = try XCTUnwrap(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(output, image, nil); XCTAssertTrue(CGImageDestinationFinalize(output))
    try (png as Data).write(to: backend.root.appendingPathComponent("tiny.png"))
    try await attach(backend, file: file, editor: editor)
    let grid = try XCTUnwrap(editor.grid), initial = try XCTUnwrap(grid.focusedCompose)
    XCTAssertEqual(initial.pane.compose.documentLen, UInt64(original.utf8.count))
    XCTAssertFalse(CTFontGetSymbolicTraits(initial.body).contains(.traitMonoSpace))
    XCTAssertTrue(initial.pane.compose.spans.contains { $0.role == 1 })
    try await eventually(editor, "large document inline image loaded") {
      grid.focusedCompose?.layout.text.attachments.first?.rect.width == 40
    }
    let annotation = try XCTUnwrap(grid.focusedCompose?.pane.compose.images.first)
    grid.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
    let pending = try XCTUnwrap(grid.focusedCompose), placed = try XCTUnwrap(pending.layout.text.attachments.first)
    editor.grid(grid, point: CGPoint(x: pending.origin.x + placed.rect.midX, y: pending.origin.y + placed.rect.midY),
      in: pending, extend: false, count: 1)
    try await eventually(editor, "image click waits for the new semantic snapshot instead of being cancelled") {
      guard let cursor = grid.focusedCompose?.cursor else { return false }
      return cursor.position == annotation.end + 1 && cursor.hasAnchor && cursor.anchor == annotation.start + 1
    }
    editor.send(.action(name: "undo", argsJson: "")); editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "undo the pending prefix without losing the image action") { (try? Data(contentsOf: file)) == Data(original.utf8) }
    editor.send(.action(name: "move_document_end", argsJson: ""))
    try await eventually(editor, "native navigation reaches a source window beyond the former cutoff") {
      guard let pane = grid.focusedCompose else { return false }
      return pane.cursor?.position == UInt64(original.utf8.count) && pane.pane.compose.sourceStart > 2 << 20
    }
    XCTAssertEqual(grid.selectedRange(), NSRange(location: original.utf16.count, length: 0))
    grid.insertText("追加", replacementRange: NSRange(location: NSNotFound, length: 0))
    editor.send(.action(name: "save", argsJson: ""))
    let expected = Data((original + "追加").utf8)
    try await eventually(editor, "exact save after an edit in the large document") { (try? Data(contentsOf: file)) == expected }
    editor.send(.action(name: "undo", argsJson: "")); editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "large-document undo remains one source transaction") { (try? Data(contentsOf: file)) == Data(original.utf8) }
    XCTAssertTrue(editor.uninsertedText.isEmpty); XCTAssertTrue(backend.server.isRunning)
  }

  @MainActor
  func testRealBackendSourceClickPreviewsAndCommitsFollowingCompositionBeforeAcknowledgment() async throws {
    let backend = try backend(); defer { backend.stop() }
    let pasteboard = BackendPasteboard(), editor = editor(pasteboard)
    defer { editor.detachAll() }
    let original = "| A | B |\n|---|---|\n| one | two |\n\n# Heading\n\nalpha café Tail\n"
    let file = backend.root.appendingPathComponent("click.md")
    try Data(original.utf8).write(to: file)
    try await attach(backend, file: file, editor: editor)
    let grid = try XCTUnwrap(editor.grid), initial = try XCTUnwrap(grid.focusedCompose)
    let index = try XCTUnwrap(original.range(of: "café"))
    let position = original[..<index.lowerBound].utf8.count, unit = original[..<index.lowerBound].utf16.count
    let rect = try XCTUnwrap(initial.layout.text.caret(for: position))
    editor.grid(grid, point: CGPoint(x: initial.origin.x + rect.minX, y: initial.origin.y + rect.midY),
      in: initial, extend: false, count: 1)
    XCTAssertEqual(grid.selectedRange(), NSRange(location: unit, length: 0))
    XCTAssertEqual(editor.store.panes.first?.compose.cursors.first?.position, initial.cursor?.position)
    let unspecified = NSRange(location: NSNotFound, length: 0)
    grid.setMarkedText("日本", selectedRange: NSRange(location: 1, length: 0), replacementRange: unspecified)
    XCTAssertEqual(grid.markedRange(), NSRange(location: unit, length: 2))
    XCTAssertTrue(try XCTUnwrap(grid.focusedCompose).layout.text.projection.text.contains("alpha 日本café Tail"))
    grid.insertText("日本", replacementRange: unspecified)
    try await eventually(editor, "source click and immediately committed conversion") {
      grid.focusedCompose?.cursor?.position == UInt64(position + "日本".utf8.count)
        && grid.focusedCompose?.pane.compose.documentLen == UInt64(original.utf8.count + "日本".utf8.count)
    }
    let expected = Data(original.utf8.prefix(position)) + Data("日本".utf8) + Data(original.utf8.dropFirst(position))
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "save composition at the clicked source") { (try? Data(contentsOf: file)) == expected }
    editor.send(.action(name: "undo", argsJson: ""))
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "undo the composition while retaining the click") { (try? Data(contentsOf: file)) == Data(original.utf8) }
    XCTAssertTrue(editor.uninsertedText.isEmpty); XCTAssertTrue(backend.server.isRunning)
  }

  @MainActor
  func testRealBackendClickWithinUnacknowledgedTextKeepsBothNativeUndoTransactions() async throws {
    let backend = try backend(); defer { backend.stop() }
    let pasteboard = BackendPasteboard(), editor = editor(pasteboard)
    defer { editor.detachAll() }
    let original = "| A | B |\n|---|---|\n| one | two |\n\n# Heading\n\nTail\n"
    let file = backend.root.appendingPathComponent("pending-click.md")
    try Data(original.utf8).write(to: file)
    try await attach(backend, file: file, editor: editor)
    let position = original[..<original.range(of: "Tail")!.lowerBound].utf8.count
    try await click(UInt64(position), editor: editor)
    let grid = try XCTUnwrap(editor.grid), prefix = "日café 👩🏽‍💻 ", unspecified = NSRange(location: NSNotFound, length: 0)
    grid.insertText(prefix, replacementRange: unspecified)
    let pending = try XCTUnwrap(grid.focusedCompose), id = try XCTUnwrap(pending.cursor?.id)
    let display = try XCTUnwrap(pending.layout.draftDisplayRanges[id])
    let rect = try XCTUnwrap(pending.layout.text.caret(atUTF16: display.location + 1))
    editor.grid(grid, point: CGPoint(x: pending.origin.x + rect.minX, y: pending.origin.y + rect.midY),
      in: pending, extend: false, count: 1)
    XCTAssertEqual(grid.selectedRange(), NSRange(location: position + 1, length: 0))
    grid.setMarkedText("X", selectedRange: NSRange(location: 1, length: 0), replacementRange: unspecified)
    XCTAssertEqual(grid.markedRange(), NSRange(location: position + 1, length: 1))
    let converted = try XCTUnwrap(grid.focusedCompose)
    XCTAssertTrue(converted.layout.text.projection.text.contains("日Xcafé"))
    let candidate = try XCTUnwrap(converted.textServiceRect(for: grid.selectedRange()))
    XCTAssertEqual(candidate.range, grid.selectedRange()); XCTAssertGreaterThan(candidate.rect.height, 0)
    grid.insertText("X", replacementRange: unspecified)
    let prefixWithX = "日Xcafé 👩🏽‍💻 "
    let expected = Data(original.utf8.prefix(position)) + Data(prefixWithX.utf8) + Data(original.utf8.dropFirst(position))
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "save at the point inside an unacknowledged insert") { (try? Data(contentsOf: file)) == expected }
    editor.send(.action(name: "undo", argsJson: "")); editor.send(.action(name: "save", argsJson: ""))
    let firstOnly = Data(original.utf8.prefix(position)) + Data(prefix.utf8) + Data(original.utf8.dropFirst(position))
    try await eventually(editor, "undo only the following insertion") { (try? Data(contentsOf: file)) == firstOnly }
    editor.send(.action(name: "undo", argsJson: "")); editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "undo the original provisional insert") { (try? Data(contentsOf: file)) == Data(original.utf8) }
    XCTAssertTrue(editor.uninsertedText.isEmpty); XCTAssertTrue(backend.server.isRunning)
  }

  @MainActor
  func testRealBackendPageSelectionCrossesTheSourceWindowAndCommitsOneReplacement() async throws {
    let backend = try backend(); defer { backend.stop() }
    let pasteboard = BackendPasteboard(), editor = editor(pasteboard)
    defer { editor.detachAll() }
    let original = "| Head | Image |\n|---|---|\n| tiny | ![p](" + String(repeating: "x", count: 90_000)
      + ".png) |\n\n" + (0..<500).map { "Paragraph \($0) with measured words and café 👩🏽‍💻.\n\n" }.joined()
    let file = backend.root.appendingPathComponent("page.md")
    try Data(original.utf8).write(to: file)
    try await attach(backend, file: file, editor: editor)
    let grid = try XCTUnwrap(editor.grid), initial = try XCTUnwrap(grid.focusedCompose)
    let origin = UInt64(2), edge = initial.pane.compose.sourceEnd
    XCTAssertLessThan(edge, initial.pane.compose.documentLen)
    try await click(origin, editor: editor)
    editor.send(.action(name: "select_page_down", argsJson: ""))
    try await eventually(editor, "Page Down continued beyond source window", timeout: 20) {
      guard let cursor = grid.focusedCompose?.cursor else { return false }
      return cursor.position >= edge && cursor.anchor == origin
    }
    let end = try XCTUnwrap(grid.focusedCompose?.cursor).position
    XCTAssertEqual(try Data(contentsOf: file), Data(original.utf8))
    grid.insertText("PAGED", replacementRange: NSRange(location: NSNotFound, length: 0))
    let expected = Data(original.utf8.prefix(Int(origin))) + Data("PAGED".utf8) + Data(original.utf8.dropFirst(Int(end)))
    try await eventually(editor, "replacement of the complete cross-window selection") {
      grid.focusedCompose?.pane.compose.documentLen == UInt64(expected.count) && grid.focusedCompose?.cursor?.position == origin + 5
    }
    editor.send(.action(name: "undo", argsJson: ""))
    try await eventually(editor, "undo complete selection replacement") { grid.focusedCompose?.pane.compose.documentLen == UInt64(original.utf8.count) }
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "save after undo") { (try? Data(contentsOf: file)) == Data(original.utf8) }
    XCTAssertTrue(editor.uninsertedText.isEmpty)
  }

  @MainActor
  func testRealBackendMissingCellSourceRevealRetainsItsColumnAcrossAFontChange() async throws {
    let backend = try backend(); defer { backend.stop() }
    let pasteboard = BackendPasteboard(), editor = editor(pasteboard)
    defer { editor.detachAll() }
    let original = "| A | B | C |\n|---|---|---|\n| one | two | three |\n| short |\n| last | target | end |\n\nTail\n"
    let file = backend.root.appendingPathComponent("missing.md")
    try Data(original.utf8).write(to: file)
    try await attach(backend, file: file, editor: editor)
    let grid = try XCTUnwrap(editor.grid), initial = try XCTUnwrap(grid.focusedCompose)
    let word = try XCTUnwrap(original.range(of: "two"))
    try await click(UInt64(original[..<word.lowerBound].utf8.count), editor: editor)
    editor.send(.action(name: "move_down", argsJson: ""))
    let row = initial.pane.compose.tables[0].rows[2]
    try await eventually(editor, "missing column reveals structural row source") {
      grid.focusedCompose?.cursor?.position == row.contentEnd
        && grid.focusedCompose?.pane.compose.tables[0].rows[2].source == true
    }
    var preferences = ComposePreferences(); preferences.bodySize = 22
    grid.setComposePreferences(preferences, zoom: 1)
    editor.send(.action(name: "move_down", argsJson: ""))
    let cell = initial.pane.compose.tables[0].rows[3].cells[1]
    try await eventually(editor, "Down retains logical column after source reveal and font change") {
      guard let cursor = grid.focusedCompose?.cursor else { return false }
      return cell.start <= cursor.position && cursor.position <= cell.end
    }
    XCTAssertEqual(try Data(contentsOf: file), Data(original.utf8))
  }

  @MainActor
  func testConsecutiveNativeCompositionsRetainTheFirstCommitWhileTheSecondDraftIsMarked() async throws {
    let backend = try backend(); defer { backend.stop() }
    let pasteboard = BackendPasteboard(), editor = editor(pasteboard)
    defer { editor.detachAll() }
    let original = "| A | B |\n|---|---|\n| alpha | beta |\n"
    let file = backend.root.appendingPathComponent("compositions.md")
    try Data(original.utf8).write(to: file)
    try await attach(backend, file: file, editor: editor)
    let grid = try XCTUnwrap(editor.grid)
    let word = try XCTUnwrap(original.range(of: "alpha")), start = UInt64(original[..<word.lowerBound].utf8.count)
    try await click(start, editor: editor)
    let revision = try XCTUnwrap(grid.focusedCompose).pane.compose.bufferRevision
    grid.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    grid.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
    grid.setMarkedText("語", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    try await eventually(editor, "first commit reaches Fresh during the next marked draft") {
      editor.store.panes.contains { $0.hasCompose && $0.compose.bufferRevision != revision }
    }
    XCTAssertTrue(grid.hasMarkedText())
    XCTAssertTrue(grid.focusedCompose?.layout.text.projection.text.contains("日本語alpha") == true,
      "the acknowledged first commit must remain visible while composing the next phrase")
    let base = original[..<word.lowerBound].utf16.count
    XCTAssertEqual(grid.markedRange().location, base + "日本".utf16.count)
    grid.insertText("語", replacementRange: NSRange(location: NSNotFound, length: 0))
    let expected = Data(original.utf8.prefix(Int(start))) + Data("日本語".utf8) + Data(original.utf8.dropFirst(Int(start)))
    try await eventually(editor, "consecutive native commits append in source order") {
      grid.focusedCompose?.pane.compose.documentLen == UInt64(expected.count)
    }
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "save both phrases without reversing or replacing either") { (try? Data(contentsOf: file)) == expected }
    XCTAssertTrue(editor.uninsertedText.isEmpty)
  }

  @MainActor
  func testConsecutiveCommitsBeforeAcknowledgmentReplaceTheOriginalSelectionOnlyOnce() async throws {
    let backend = try backend(); defer { backend.stop() }
    let pasteboard = BackendPasteboard(), editor = editor(pasteboard)
    defer { editor.detachAll() }
    let original = "| A | B |\n|---|---|\n| alpha | beta |\n"
    let file = backend.root.appendingPathComponent("queued-compositions.md")
    try Data(original.utf8).write(to: file)
    try await attach(backend, file: file, editor: editor)
    let grid = try XCTUnwrap(editor.grid)
    let word = try XCTUnwrap(original.range(of: "alpha")), start = UInt64(original[..<word.lowerBound].utf8.count)
    try await click(start, editor: editor)
    for _ in 0..<5 { editor.send(.action(name: "select_right", argsJson: "")) }
    try await eventually(editor, "select original word") { grid.focusedCompose?.cursor?.position == start + 5 && grid.focusedCompose?.cursor?.anchor == start }
    for phrase in ["日本", "語"] {
      grid.setMarkedText(phrase, selectedRange: NSRange(location: phrase.utf16.count, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
      grid.insertText(phrase, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    let expected = Data(original.utf8.prefix(Int(start))) + Data("日本語".utf8) + Data(original.utf8.dropFirst(Int(start) + 5))
    try await eventually(editor, "queued conversions complete without replacing the first phrase") {
      grid.focusedCompose?.pane.compose.documentLen == UInt64(expected.count) && grid.focusedCompose?.cursor?.position == start + 9
    }
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "save queued conversions in order") { (try? Data(contentsOf: file)) == expected }
    editor.send(.action(name: "undo", argsJson: ""))
    try await eventually(editor, "undo only the second phrase") { grid.focusedCompose?.pane.compose.documentLen == UInt64(original.utf8.count + 1) }
    editor.send(.action(name: "undo", argsJson: ""))
    try await eventually(editor, "undo the original replacement") { grid.focusedCompose?.pane.compose.documentLen == UInt64(original.utf8.count) }
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "save exact original after two undos") { (try? Data(contentsOf: file)) == Data(original.utf8) }
    XCTAssertTrue(editor.uninsertedText.isEmpty)
  }

  @MainActor
  func testDependentConversionsKeepEveryOriginalCaretThroughARealBackendBatch() async throws {
    let backend = try backend(); defer { backend.stop() }
    let pasteboard = BackendPasteboard(), editor = editor(pasteboard)
    defer { editor.detachAll() }
    let original = "| A | B |\n|---|---|\n| cell | value |\n\nalpha one\nalpha two\n"
    let file = backend.root.appendingPathComponent("multi-compositions.md")
    try Data(original.utf8).write(to: file)
    try await attach(backend, file: file, editor: editor)
    let grid = try XCTUnwrap(editor.grid), word = try XCTUnwrap(original.range(of: "alpha"))
    try await click(UInt64(original[..<word.lowerBound].utf8.count), editor: editor)
    editor.send(.action(name: "add_cursor_below", argsJson: ""))
    try await eventually(editor, "two captured carets") { grid.focusedCompose?.pane.compose.cursors.count == 2 }
    let ids = Set(try XCTUnwrap(grid.focusedCompose).pane.compose.cursors.map(\.id))
    for phrase in ["日本", "語"] {
      grid.setMarkedText(phrase, selectedRange: NSRange(location: phrase.utf16.count, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
      grid.insertText(phrase, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    let expected = Data(original.replacingOccurrences(of: "alpha", with: "日本語alpha").utf8)
    try await eventually(editor, "both batches complete at both original carets") {
      grid.focusedCompose?.pane.compose.documentLen == UInt64(expected.count)
    }
    XCTAssertEqual(Set(try XCTUnwrap(grid.focusedCompose).pane.compose.cursors.map(\.id)), ids)
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "save both complete phrases at both carets") { (try? Data(contentsOf: file)) == expected }
    editor.send(.action(name: "undo", argsJson: ""))
    try await eventually(editor, "one undo removes the second phrase from both carets") {
      grid.focusedCompose?.pane.compose.documentLen == UInt64(original.utf8.count + 12)
    }
    editor.send(.action(name: "undo", argsJson: ""))
    try await eventually(editor, "second undo removes the first batch") { grid.focusedCompose?.pane.compose.documentLen == UInt64(original.utf8.count) }
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "save exact original after undoing both batches") { (try? Data(contentsOf: file)) == Data(original.utf8) }
    XCTAssertTrue(editor.uninsertedText.isEmpty)
  }

  @MainActor
  func testReceiptCoordinatesFollowFreshNewlineNormalization() async throws {
    let backend = try backend(); defer { backend.stop() }
    let pasteboard = BackendPasteboard(), editor = editor(pasteboard)
    defer { editor.detachAll() }
    let original = "| A | B |\r\n|---|---|\r\n| alpha | beta |\r\n"
    let file = backend.root.appendingPathComponent("newline-compositions.md")
    try Data(original.utf8).write(to: file)
    try await attach(backend, file: file, editor: editor)
    let grid = try XCTUnwrap(editor.grid), word = try XCTUnwrap(original.range(of: "alpha"))
    let start = UInt64(original[..<word.lowerBound].utf8.count)
    try await click(start, editor: editor)
    for phrase in ["🙂\n", "語"] {
      grid.setMarkedText(phrase, selectedRange: NSRange(location: phrase.utf16.count, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
      grid.insertText(phrase, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    let expected = Data(original.utf8.prefix(Int(start))) + Data("🙂\r\n語".utf8) + Data(original.utf8.dropFirst(Int(start)))
    try await eventually(editor, "Fresh-normalized source and UTF-16 coordinates") {
      grid.focusedCompose?.pane.compose.documentLen == UInt64(expected.count) && grid.focusedCompose?.cursor?.position == start + 9
    }
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "save normalized CRLF with both phrases") { (try? Data(contentsOf: file)) == expected }
    XCTAssertTrue(editor.uninsertedText.isEmpty)
  }

  @MainActor
  func testExplicitPendingReplacementAndFollowingLiteralSaveAndUndoAsThreeTransactions() async throws {
    let backend = try backend(); defer { backend.stop() }
    let editor = editor(BackendPasteboard()); defer { editor.detachAll() }
    let original = "| A | B |\n|---|---|\n| cell | value |\n\nalpha Tail\n"
    let file = backend.root.appendingPathComponent("pending-explicit.md")
    try Data(original.utf8).write(to: file)
    try await attach(backend, file: file, editor: editor)
    let grid = try XCTUnwrap(editor.grid), word = (original as NSString).range(of: "alpha")
    grid.insertText("beta", replacementRange: word)
    XCTAssertFalse(grid.hasMarkedText())
    XCTAssertEqual(grid.selectedRange().location, word.location + 4)
    grid.insertText("theta", replacementRange: NSRange(location: word.location, length: 4))
    grid.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertEqual(grid.selectedRange().location, word.location + 6)
    let expected = Data(original.replacingOccurrences(of: "alpha", with: "theta!").utf8)
    XCTAssertEqual(grid.attributedSubstring(forProposedRange: NSRange(location: word.location, length: 6), actualRange: nil)?.string, "theta!")
    try await eventually(editor, "three source-bound edits acknowledged") {
      grid.focusedCompose?.pane.compose.documentLen == UInt64(expected.count) && grid.focusedCompose?.cursor?.position == UInt64(word.location + 6)
    }
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "save explicit replacement of pending prefix") { (try? Data(contentsOf: file)) == expected }
    for (index, size) in [original.utf8.count, original.utf8.count - 1, original.utf8.count].enumerated() {
      editor.send(.action(name: "undo", argsJson: ""))
      try await eventually(editor, "undo pending transaction \(index + 1)") { grid.focusedCompose?.pane.compose.documentLen == UInt64(size) }
    }
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "save exact original after three undos") { (try? Data(contentsOf: file)) == Data(original.utf8) }
    XCTAssertTrue(editor.uninsertedText.isEmpty)
  }

  @MainActor
  func testCRFilePreviewUsesNormalizedLFAndSaveRetainsCRDiskPolicy() async throws {
    let backend = try backend(); defer { backend.stop() }
    let editor = editor(BackendPasteboard()); defer { editor.detachAll() }
    let original = "| A | B |\r|---|---|\r| alpha | beta |\r"
    let file = backend.root.appendingPathComponent("pending-cr.md")
    try Data(original.utf8).write(to: file)
    try await attach(backend, file: file, editor: editor)
    let grid = try XCTUnwrap(editor.grid), word = (original as NSString).range(of: "alpha")
    try await click(UInt64(word.location), editor: editor)
    XCTAssertEqual(grid.focusedCompose?.pane.compose.nativeNewline, 1)
    grid.insertText("🙂\r", replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertEqual(grid.selectedRange().location, word.location + 3)
    grid.insertText("語", replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertEqual(grid.selectedRange().location, word.location + 4)
    let expected = Data(original.replacingOccurrences(of: "alpha", with: "🙂\r語alpha").utf8)
    try await eventually(editor, "normalized CR buffer coordinates acknowledged") {
      grid.focusedCompose?.pane.compose.documentLen == UInt64(expected.count) && grid.focusedCompose?.cursor?.position == UInt64(word.location + 8)
    }
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "save retains CR disk policy after both phrases") { (try? Data(contentsOf: file)) == expected }
    XCTAssertTrue(editor.uninsertedText.isEmpty)
  }

  @MainActor
  func testExplicitPrimaryThenImmediateBroadcastKeepsEveryOriginalCaretAndUndoBoundary() async throws {
    let backend = try backend(); defer { backend.stop() }
    let editor = editor(BackendPasteboard()); defer { editor.detachAll() }
    let original = "| A | B |\n|---|---|\n| cell | value |\n\nalpha one\nalpha two\n"
    let file = backend.root.appendingPathComponent("mixed-caret-conversions.md")
    try Data(original.utf8).write(to: file)
    try await attach(backend, file: file, editor: editor)
    let grid = try XCTUnwrap(editor.grid), first = try XCTUnwrap(original.range(of: "alpha"))
    try await click(UInt64(original[..<first.lowerBound].utf8.count), editor: editor)
    editor.send(.action(name: "add_cursor_below", argsJson: ""))
    try await eventually(editor, "two original carets before the explicit primary edit") { grid.focusedCompose?.pane.compose.cursors.count == 2 }
    let pane = try XCTUnwrap(grid.focusedCompose), primary = try XCTUnwrap(pane.cursor)
    let secondary = try XCTUnwrap(pane.pane.compose.cursors.first { !$0.primary })
    let ids = Set(pane.pane.compose.cursors.map(\.id))
    var expected = Data(original.utf8)
    let replacements = [(Int(primary.position)..<(Int(primary.position) + 5), Data("日本語".utf8)),
      (Int(secondary.position)..<Int(secondary.position), Data("語".utf8))]
    for (range, text) in replacements.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) { expected.replaceSubrange(range, with: text) }
    grid.insertText("日本", replacementRange: NSRange(location: Int(primary.position), length: 5))
    grid.insertText("語", replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertEqual(grid.attributedSubstring(forProposedRange: NSRange(location: 0, length: 10_000), actualRange: nil)?.string,
      String(decoding: expected, as: UTF8.self), "the unacknowledged document includes both caret operations")
    try await eventually(editor, "mixed explicit/broadcast batch acknowledged") { grid.focusedCompose?.pane.compose.documentLen == UInt64(expected.count) }
    XCTAssertEqual(Set(try XCTUnwrap(grid.focusedCompose).pane.compose.cursors.map(\.id)), ids)
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "save primary replacement and broadcast at both carets") { (try? Data(contentsOf: file)) == expected }
    editor.send(.action(name: "undo", argsJson: ""))
    try await eventually(editor, "one undo removes only the broadcast from both carets") { grid.focusedCompose?.pane.compose.documentLen == UInt64(original.utf8.count + 1) }
    editor.send(.action(name: "undo", argsJson: ""))
    try await eventually(editor, "second undo restores the primary word") { grid.focusedCompose?.pane.compose.documentLen == UInt64(original.utf8.count) }
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "save exact original after both mixed transactions") { (try? Data(contentsOf: file)) == Data(original.utf8) }
    XCTAssertTrue(editor.uninsertedText.isEmpty)
  }

  @MainActor
  func testCompositionBehindNavigationUsesItsResultForActiveAndAlreadyCommittedText() async throws {
    let backend = try backend(); defer { backend.stop() }
    let editor = editor(BackendPasteboard()); defer { editor.detachAll() }
    let original = "| A | B |\n|---|---|\n| cell | value |\n\nalpha Tail\n"
    let file = backend.root.appendingPathComponent("navigation-compose.md")
    try Data(original.utf8).write(to: file)
    try await attach(backend, file: file, editor: editor)
    let grid = try XCTUnwrap(editor.grid), word = (original as NSString).range(of: "alpha")
    let unspecified = NSRange(location: NSNotFound, length: 0)
    for (committed, selection) in [(false, false), (true, false), (true, true)] {
      let expected = Data(original.replacingOccurrences(of: "alpha", with: selection ? "日lpha" : "a日lpha").utf8)
      try await click(UInt64(word.location), editor: editor)
      editor.send(.key(.with { $0.key = "ArrowRight"; $0.shift = selection }))
      grid.setMarkedText("日", selectedRange: NSRange(location: 1, length: 0), replacementRange: unspecified)
      if committed { grid.insertText("日", replacementRange: unspecified) }
      else {
        try await eventually(editor, "active draft follows the acknowledged navigation") {
          grid.hasMarkedText() && grid.markedRange().location == word.location + 1 && grid.focusedCompose?.cursor?.position == UInt64(word.location + 1)
        }
        grid.insertText("日", replacementRange: unspecified)
      }
      try await eventually(editor, "composition committed at the resulting caret") {
        grid.focusedCompose?.pane.compose.documentLen == UInt64(expected.count) && grid.focusedCompose?.cursor?.position == UInt64(word.location + (selection ? 3 : 4))
      }
      editor.send(.action(name: "save", argsJson: ""))
      try await eventually(editor, "save follows navigation rather than the older source cursor") { (try? Data(contentsOf: file)) == expected }
      editor.send(.action(name: "undo", argsJson: ""))
      try await eventually(editor, "undo the composed phrase") { grid.focusedCompose?.pane.compose.documentLen == UInt64(original.utf8.count) }
      editor.send(.action(name: "save", argsJson: ""))
      try await eventually(editor, "save original after undoing navigation-following text") { (try? Data(contentsOf: file)) == Data(original.utf8) }
    }
    XCTAssertTrue(editor.uninsertedText.isEmpty)
  }

  @MainActor
  func testPendingPrefixNavigationAndFollowingCommitKeepSourceOrderAndSeparateUndos() async throws {
    let backend = try backend(); defer { backend.stop() }
    let editor = editor(BackendPasteboard()); defer { editor.detachAll() }
    let original = "| A | B |\n|---|---|\n| cell | value |\n\nalpha Tail\n"
    let file = backend.root.appendingPathComponent("prefix-navigation-compose.md")
    try Data(original.utf8).write(to: file)
    try await attach(backend, file: file, editor: editor)
    let grid = try XCTUnwrap(editor.grid), word = (original as NSString).range(of: "alpha")
    try await click(UInt64(word.location), editor: editor)
    let unspecified = NSRange(location: NSNotFound, length: 0)
    grid.insertText("日本", replacementRange: unspecified)
    editor.send(.key(.with { $0.key = "ArrowLeft" }))
    grid.setMarkedText("語", selectedRange: NSRange(location: 1, length: 0), replacementRange: unspecified)
    grid.insertText("語", replacementRange: unspecified)
    let expected = Data(original.replacingOccurrences(of: "alpha", with: "日語本alpha").utf8)
    try await eventually(editor, "all three queued inputs complete at the measured source caret") {
      grid.focusedCompose?.pane.compose.documentLen == UInt64(expected.count) && grid.focusedCompose?.cursor?.position == UInt64(word.location + 6)
    }
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "save prefix, navigation and following phrase without duplication") { (try? Data(contentsOf: file)) == expected }
    for size in [original.utf8.count + 6, original.utf8.count] {
      editor.send(.action(name: "undo", argsJson: ""))
      try await eventually(editor, "undo one native text transaction") { grid.focusedCompose?.pane.compose.documentLen == UInt64(size) }
    }
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "save exact original after both text undos") { (try? Data(contentsOf: file)) == Data(original.utf8) }
    XCTAssertTrue(editor.uninsertedText.isEmpty)
  }

  @MainActor
  func testCompositionBehindAddCaretUsesTheActionsEntireResultingGroup() async throws {
    let backend = try backend(); defer { backend.stop() }
    let editor = editor(BackendPasteboard()); defer { editor.detachAll() }
    let original = "| A | B |\n|---|---|\n| cell | value |\n\nalpha one\nalpha two\n"
    let file = backend.root.appendingPathComponent("add-caret-compose.md")
    try Data(original.utf8).write(to: file)
    try await attach(backend, file: file, editor: editor)
    let grid = try XCTUnwrap(editor.grid), word = (original as NSString).range(of: "alpha")
    try await click(UInt64(word.location), editor: editor)
    editor.send(.action(name: "add_cursor_below", argsJson: ""))
    grid.setMarkedText("日", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    grid.insertText("日", replacementRange: NSRange(location: NSNotFound, length: 0))
    let expected = Data(original.replacingOccurrences(of: "alpha", with: "日alpha").utf8)
    try await eventually(editor, "new composition uses both action-created carets") {
      grid.focusedCompose?.pane.compose.documentLen == UInt64(expected.count) && grid.focusedCompose?.pane.compose.cursors.count == 2
    }
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "save both new-group insertions") { (try? Data(contentsOf: file)) == expected }
    editor.send(.action(name: "undo", argsJson: ""))
    try await eventually(editor, "one undo removes both insertions") { grid.focusedCompose?.pane.compose.documentLen == UInt64(original.utf8.count) }
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "save exact original after undoing new-group conversion") { (try? Data(contentsOf: file)) == Data(original.utf8) }
    XCTAssertTrue(editor.uninsertedText.isEmpty)
  }

  @MainActor
  func testCompositionBehindClipboardPasteUsesItsResultingSourceAndUndoesSeparately() async throws {
    let backend = try backend(); defer { backend.stop() }
    let editor = editor(BackendPasteboard()); defer { editor.detachAll() }
    let original = "| A | B |\n|---|---|\n| cell | value |\n\nalpha Tail\n"
    let file = backend.root.appendingPathComponent("paste-compose.md")
    try Data(original.utf8).write(to: file)
    try await attach(backend, file: file, editor: editor)
    let grid = try XCTUnwrap(editor.grid), word = (original as NSString).range(of: "alpha")
    try await click(UInt64(word.location), editor: editor)
    editor.send(.paste("base"))
    grid.setMarkedText("日", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    grid.insertText("日", replacementRange: NSRange(location: NSNotFound, length: 0))
    let expected = Data(original.replacingOccurrences(of: "alpha", with: "base日alpha").utf8)
    try await eventually(editor, "paste and following native composition finish in order") {
      grid.focusedCompose?.pane.compose.documentLen == UInt64(expected.count) && grid.focusedCompose?.cursor?.position == UInt64(word.location + 7)
    }
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "save composition after the clipboard paste") { (try? Data(contentsOf: file)) == expected }
    for size in [original.utf8.count + 4, original.utf8.count] {
      editor.send(.action(name: "undo", argsJson: ""))
      try await eventually(editor, "undo one paste/native transaction") { grid.focusedCompose?.pane.compose.documentLen == UInt64(size) }
    }
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "save original after undoing paste and native text") { (try? Data(contentsOf: file)) == Data(original.utf8) }
    XCTAssertTrue(editor.uninsertedText.isEmpty)
  }

}
