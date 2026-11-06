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
    for directory in ["", "home", "config", "data", "cache", "runtime", "session"] {
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
      ("XDG_CACHE_HOME", "cache"), ("XDG_RUNTIME_DIR", "runtime"), ("FRESH_FC_DATA_DIR", "session")] {
      env[key] = root.appendingPathComponent(directory).path
    }
    env["FC_EDITOR_SWITCH_KEY"] = "f10"; env["RUST_LOG"] = "warn"
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
    // Strict known failure until dependent drafts can move from their captured
    // snapshot to the acknowledged preceding commit. Saving below must still
    // prove both phrases reached Fresh in order; no data-loss check is waived.
    XCTExpectFailure("A consecutive marked draft freezes the snapshot from before the preceding native commit") {
      XCTAssertTrue(grid.focusedCompose?.layout.text.projection.text.contains("日本語alpha") == true,
        "the acknowledged first commit must remain visible while composing the next phrase")
      let base = original[..<word.lowerBound].utf16.count
      XCTAssertEqual(grid.markedRange().location, base + "日本".utf16.count)
    }
    grid.insertText("語", replacementRange: NSRange(location: NSNotFound, length: 0))
    let expected = Data(original.utf8.prefix(Int(start))) + Data("日本語".utf8) + Data(original.utf8.dropFirst(Int(start)))
    try await eventually(editor, "consecutive native commits append in source order") {
      grid.focusedCompose?.pane.compose.documentLen == UInt64(expected.count)
    }
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "save both phrases without reversing or replacing either") { (try? Data(contentsOf: file)) == expected }
    XCTAssertTrue(editor.uninsertedText.isEmpty)
  }

}
