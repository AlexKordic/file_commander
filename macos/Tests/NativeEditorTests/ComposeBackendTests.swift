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
  func testCompleteMeasuredFlowCertifiesFreshDrawingAtTheStartAndAtAnOffscreenSecondTable() async throws {
    let backend = try backend(); defer { backend.captureDiagnostics("complete-flow"); backend.stop() }
    let editor = editor(BackendPasteboard()); defer { editor.detachAll() }
    let table = "| Key | Value |\r\n| --- | --- |\r\n| café | 東京 |\r\n\r\n"
    let tail = "## Final heading\r\n\r\n" + table + "![picture](missing.png)\r\n"
    let source = "# Complete flow\r\n\r\n" + table
      + String(repeating: "Paragraph **bold** café 👩🏽‍💻 العربية אבג and a [link](target.md).\r\n\r\n", count: 1800) + tail
    let file = backend.root.appendingPathComponent("flow.md"); try Data(source.utf8).write(to: file)
    try await attach(backend, file: file, editor: editor)
    let controller = editor.composeDocument; controller.activate()
    try await eventually(editor, "complete projection for measured flow", timeout: 20) { controller.status == .ready }
    let snapshot = try XCTUnwrap(controller.snapshot), grid = try XCTUnwrap(editor.grid)
    let first = try XCTUnwrap(grid.focusedCompose)
    try await eventually(editor, "native complete flow coordinator", timeout: 20) { editor.composeFlow.status == .ready }
    let flow = try XCTUnwrap(editor.composeFlow.flow)
    XCTAssertTrue(flow.document === snapshot.document)
    XCTAssertFalse(flow.usage.retainedGlyphs); XCTAssertGreaterThan(flow.lines.count, 1800)
    XCTAssertLessThanOrEqual(flow.usage.maximumContextUnits, 16_384)
    XCTAssertEqual(flow.tables.count, 2); XCTAssertFalse(flow.attachments.isEmpty)
    XCTAssertTrue(flow.fonts.contains { $0.size > 20 }); XCTAssertFalse(flow.styles.isEmpty)
    XCTAssertEqual(flow.correspondence(window: UInt64(editor.store.windowID), pane: first.pane, layout: first.layout), .zero)
    XCTAssertEqual(first.pane.compose.viewport.position, 0, "measurement must not move the drawing viewport")
    // The same real producer payload is also the serial old/new renderer fixture.
    try snapshot.baseline.data.write(to: backend.root.appendingPathComponent("complete-flow.pb"))
    let anchor = UInt64(source.utf8.count-tail.utf8.count)
    editor.send(.composeViewport(.with {
      $0.id = 90_001; $0.scope = first.scope; $0.position = anchor; $0.epoch = first.pane.compose.viewport.epoch
    }))
    try await eventually(editor, "drawing crop containing the offscreen second table", timeout: 20) {
      guard let current = grid.focusedCompose else { return false }
      return current.pane.compose.viewport.position == anchor && current.pane.compose.sourceStart > 0
        && current.pane.compose.formattingReady && !current.layout.text.tables.isEmpty
    }
    let current = try XCTUnwrap(grid.focusedCompose)
    let visible = try XCTUnwrap(snapshot.document.range(of: UInt64(editor.store.windowID), pane: current.pane))
    XCTAssertGreaterThan(visible.location, 16_384)
    let translation = try XCTUnwrap(flow.correspondence(window: UInt64(editor.store.windowID), pane: current.pane, layout: current.layout))
    XCTAssertLessThan(translation.y, 0)
    let heading = (snapshot.document.text as NSString).range(of: "Final heading", options: .literal)
    XCTAssertNotEqual(heading.location, NSNotFound); XCTAssertNotNil(flow.bounds(for: heading))
    grid.setComposePreferences(.init(), zoom: 1.25)
    XCTAssertNil(editor.composeFlow.flow, "a new font environment retires the old measured generation")
    try await eventually(editor, "complete flow after native zoom", timeout: 20) { editor.composeFlow.status == .ready }
    let zoomed = try XCTUnwrap(editor.composeFlow.flow), shown = try XCTUnwrap(grid.focusedCompose)
    XCTAssertNotEqual(zoomed.geometryGeneration, flow.geometryGeneration)
    XCTAssertNotNil(zoomed.correspondence(window: UInt64(editor.store.windowID), pane: shown.pane, layout: shown.layout))
    let localHeading = (shown.layout.text.projection.text as NSString).range(of: "Final heading", options: .literal)
    XCTAssertNotEqual(localHeading.location, NSNotFound)
    let selection = zoomed.document.selectionRevision
    grid.setAccessibilitySelectedTextRange(localHeading)
    XCTAssertNil(editor.composeFlow.flow, "a pending local selection retires the previous logical generation")
    try await eventually(editor, "current source selection and complete geometry", timeout: 20) {
      editor.composeFlow.status == .ready && editor.composeFlow.flow?.document.selectionRevision != selection
    }
    let selected = try XCTUnwrap(editor.composeFlow.flow), selectedPane = try XCTUnwrap(grid.focusedCompose)
    XCTAssertTrue(selected.document.owns(window: UInt64(editor.store.windowID), pane: selectedPane.pane))
    XCTAssertNotNil(selected.correspondence(window: UInt64(editor.store.windowID), pane: selectedPane.pane, layout: selectedPane.layout))
    let selectedCursor = try XCTUnwrap(selectedPane.cursor)
    let selectedSource = Int(min(selectedCursor.position,selectedCursor.anchor))..<Int(max(selectedCursor.position,selectedCursor.anchor))
    let replacementRange = try XCTUnwrap(selected.presentation.displayedRange(for: selectedSource))
    XCTAssertEqual(selected.presentation.string(for: replacementRange),"Final heading")
    let phrase = "日本 👩🏽‍💻 العربية", unspecified = NSRange(location: NSNotFound, length: 0)
    grid.setMarkedText(phrase, selectedRange: NSRange(location: 0, length: 2), replacementRange: unspecified)
    try await eventually(editor, "complete provisional flow over the offscreen Fresh selection", timeout: 20) {
      editor.composeFlow.status == .ready && editor.composeFlow.flow?.presentation.overlay != nil
    }
    let marked = try XCTUnwrap(editor.composeFlow.flow), markedPane = try XCTUnwrap(grid.focusedCompose)
    XCTAssertEqual(markedPane.layout.composition?.primary.source,selectedSource)
    let expected = (selected.presentation.text as NSString).replacingCharacters(in: replacementRange, with: phrase)
    XCTAssertTrue(marked.presentation.text.utf8.elementsEqual(expected.utf8))
    XCTAssertEqual(marked.presentation.selectedRanges?.first, NSRange(location: replacementRange.location, length: 2))
    XCTAssertNotNil(marked.correspondence(window: UInt64(editor.store.windowID), pane: markedPane.pane, layout: markedPane.layout))
    let endpoint = try XCTUnwrap(marked.presentation.endpoint(atUTF16: replacementRange.location+1))
    guard case .draft = endpoint.location else { return XCTFail("a complete provisional endpoint must not be a Fresh source byte") }
    grid.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
    try await eventually(editor, "cancelled draft restores the complete Fresh baseline", timeout: 20) {
      editor.composeFlow.status == .ready && editor.composeFlow.flow?.presentation.overlay == nil
    }
    XCTAssertTrue(editor.composeFlow.flow?.presentation.text.utf8.elementsEqual(selected.presentation.text.utf8) == true)
    XCTAssertEqual(try Data(contentsOf: file), Data(source.utf8))
    let metrics: [String: Any] = ["source_bytes": source.utf8.count, "projection_utf16": snapshot.document.characterCount,
      "measured_lines": flow.textIndex.lineCount, "normalized_styles": flow.textIndex.styles.count,
      "offscreen_crop_utf16_start": visible.location, "start_and_tail_certified": true,
      "zoom_remeasured": true, "source_selection_replaced_ownership": true, "source_bytes_unchanged": true,
      "complete_provisional_text_and_clause_selection": true, "provisional_crop_glyphs_certified": true,
      "cancel_restored_complete_baseline": true]
    try JSONSerialization.data(withJSONObject: metrics, options: .prettyPrinted).write(to: backend.root.appendingPathComponent("flow-metrics.json"))
    editor.switchBack(); XCTAssertNil(editor.composeFlow.flow); XCTAssertEqual(editor.composeFlow.status, .idle)
  }

  @MainActor
  func testCompleteDocumentCoordinatorKeepsCaretAndEditUpdatesIncrementalAcrossFreshUndo() async throws {
    let backend = try backend(); defer { backend.captureDiagnostics("document-updates"); backend.stop() }
    let editor = editor(BackendPasteboard()); defer { editor.detachAll() }
    let source = "# Complete document\r\n\r\n| Key | Value |\r\n| --- | --- |\r\n| one | two |\r\n\r\n"
      + String(repeating: "Paragraph with **bold** café 👩🏽‍💻 and a [link](target.md).\r\n\r\n",count:1800)
      + "## Final heading\r\n\r\n![picture](missing.png)\r\n"
    let file = backend.root.appendingPathComponent("incremental.md");try Data(source.utf8).write(to:file)
    try await attach(backend,file:file,editor:editor)
    XCTAssertTrue(editor.store.composeDocumentUpdates)
    let controller = editor.composeDocument;controller.activate()
    try await eventually(editor,"initial complete generation",timeout:20) {controller.status == .ready}
    let first = try XCTUnwrap(controller.snapshot), initialBytes = controller.lastTransferBytes
    XCTAssertGreaterThan(initialBytes,64 << 10);XCTAssertFalse(first.pane.tables.isEmpty);XCTAssertFalse(first.pane.images.isEmpty)
    XCTAssertEqual(initialBytes,first.baseline.data.count)
    editor.send(.key(.with {$0.key="ArrowRight"}))
    try await eventually(editor,"caret movement updates the complete model",timeout:20) {
      controller.status == .ready && controller.snapshot?.baseline.id != first.baseline.id
    }
    let moved = try XCTUnwrap(controller.snapshot), caretBytes = controller.lastTransferBytes
    XCTAssertEqual(controller.lastEncoding,1);XCTAssertLessThan(caretBytes,2048,"unchanged projected text must stay off the wire")
    XCTAssertEqual(moved.document.owner.revision,first.document.owner.revision)
    XCTAssertEqual(moved.pane.cursors.first(where:\.primary)?.position,1)
    XCTAssertEqual(moved.document.text,first.document.text)
    editor.send(.text("X"))
    try await eventually(editor,"an edit updates the same complete stream",timeout:20) {
      controller.status == .ready && (controller.snapshot?.document.owner.revision ?? 0)>moved.document.owner.revision
    }
    let edited = try XCTUnwrap(controller.snapshot), editBytes = controller.lastTransferBytes
    XCTAssertEqual(controller.lastEncoding,1);XCTAssertLessThan(editBytes,edited.baseline.data.count)
    XCTAssertEqual(edited.document.owner.length,UInt64(source.utf8.count+1))
    XCTAssertFalse(edited.document.text.contains("**bold**"),"an edit must keep offscreen formatting in the complete value")
    let pane = try XCTUnwrap(editor.store.panes.first(where:{$0.hasCompose && $0.compose.focused}))
    XCTAssertNotNil(edited.document.range(of:UInt64(editor.store.windowID),pane:pane))
    XCTAssertEqual(pane.compose.viewport.position,0,"complete reads and updates must not scroll the native view")
    editor.send(.action(name:"save",argsJson:""))
    let expected = Data(source.utf8.prefix(1))+Data("X".utf8)+Data(source.utf8.dropFirst(1))
    try await eventually(editor,"the normal Fresh save retains exact CRLF bytes") {(try? Data(contentsOf:file))==expected}
    editor.send(.action(name:"undo",argsJson:""));editor.send(.action(name:"save",argsJson:""))
    try await eventually(editor,"one Fresh undo restores the original source and complete projection",timeout:20) {
      controller.status == .ready && controller.snapshot?.document.text == first.document.text
        && (try? Data(contentsOf:file)) == Data(source.utf8)
    }
    XCTAssertEqual(controller.lastEncoding,1)
    let metrics:[String:Any] = ["source_bytes":source.utf8.count,"initial_body_bytes":initialBytes,
      "caret_delta_bytes":caretBytes,"edit_delta_bytes":editBytes,"undo_delta_bytes":controller.lastTransferBytes,
      "caret_encoding":1,"source_bytes_restored":true]
    try JSONSerialization.data(withJSONObject:metrics,options:.prettyPrinted).write(to:backend.root.appendingPathComponent("update-metrics.json"))
    editor.switchBack();XCTAssertNil(controller.snapshot);XCTAssertEqual(controller.status,.idle)
  }

  @MainActor
  func testIndependentCompleteReadUsesFreshFormattingAndCertifiesTheUnmovedDrawingCrop() async throws {
    let backend = try backend(); defer { backend.captureDiagnostics("complete-document-stream"); backend.stop() }
    let editor = editor(BackendPasteboard()); defer { editor.detachAll() }
    let tail = "## Final heading\r\n\r\n![last image](missing.png)\r\n"
    let original = "# Reading\r\n\r\n| Key | Value |\r\n| --- | --- |\r\n| one | two |\r\n\r\n"
      + String(repeating: "Paragraph with **bold** café 👩🏽‍💻 and a [link](target.md).\r\n\r\n", count: 1800) + tail
    let file = backend.root.appendingPathComponent("complete-stream.md")
    try Data(original.utf8).write(to: file)
    try await attach(backend, file: file, editor: editor)
    let ensure = try await backend.command(["ensure", backend.name])
    let record = try XCTUnwrap(try JSONSerialization.jsonObject(with: ensure) as? [String: Any])
    let reader = SceneSocket(path: try XCTUnwrap(record["scene"] as? String)), store = SceneStore()
    defer { reader.close() }
    var receiver: ComposeDocumentReceiver?, received: Data?, receivedDecoration: UInt64?, failure: Error?
    reader.onMessage = { [weak reader] message in
      store.apply(message); reader?.send(.applied(seq: UInt64(message.sequence)))
    }
    reader.onDocumentChunk = { [weak reader] chunk in
      guard var current = receiver else { return }
      receiver = nil
      do {
        let complete = try current.receive(chunk)
        reader?.send(.composeDocument(.with { $0.id = chunk.id; $0.appliedSequence = chunk.sequence }))
        if let complete { received = complete; receivedDecoration = current.decorationRevision }
        else { receiver = current }
      } catch { failure = error; reader?.send(.composeDocument(.with { $0.id = chunk.id; $0.cancel = true })) }
    }
    try reader.open(telemetry: false, richCompose: true, measuredTables: true, paragraphWindows: true)
    try await eventually(editor, "independent reader capability and ready source") {
      store.composeDocumentText && store.panes.first?.compose.formattingReady == true
    }
    let first = try XCTUnwrap(store.panes.first)
    let scope = WireComposeScope.with {
      $0.windowID = UInt64(store.windowID); $0.leaf = first.leaf; $0.buffer = first.buffer
      $0.bufferRevision = first.compose.bufferRevision; $0.projectionRevision = first.compose.projectionRevision
      $0.selectionRevision = first.compose.selectionRevision
    }
    let anchor = UInt64(original.utf8.count-tail.utf8.count)
    reader.send(.composeViewport(.with { $0.id = 1; $0.scope = scope; $0.position = anchor; $0.epoch = first.compose.viewport.epoch }))
    try await eventually(editor, "independent reader drawing crop near EOF") {
      store.panes.first?.compose.viewport.position == anchor && (store.panes.first?.compose.sourceStart ?? 0) > 0
    }
    let crop = try XCTUnwrap(store.panes.first)
    let owner = WireComposeIndexOwner.with {
      $0.window = UInt64(store.windowID); $0.leaf = crop.leaf; $0.buffer = crop.buffer
      $0.epoch = crop.compose.viewport.epoch; $0.revision = crop.compose.bufferRevision; $0.authority = crop.compose.assetAuthority
      $0.document = crop.compose.assetDocument; $0.length = crop.compose.documentLen
    }
    let selection = crop.compose.selectionRevision
    receiver = .init(id: 1, owner: owner, selection: selection)
    reader.send(.composeDocument(.with { $0.id = 1; $0.owner = owner; $0.selectionRevision = selection }))
    try await eventually(editor, "complete authoritative projection arrives independently", timeout: 20) { received != nil || failure != nil }
    XCTAssertNil(failure)
    let bytes = try XCTUnwrap(received), decoration = try XCTUnwrap(receivedDecoration)
    let document = try await Task.detached { try ComposeDocumentReceiver.decode(bytes, owner: owner, selection: selection, decoration: decoration) }.value
    XCTAssertTrue(document.text.contains("Final heading")); XCTAssertTrue(document.text.contains("café 👩🏽‍💻"))
    XCTAssertFalse(document.text.contains("**bold**")); XCTAssertTrue(document.text.contains("\u{fffc}"))
    XCTAssertEqual(document.owner.length, UInt64(original.utf8.count))
    let current = try XCTUnwrap(store.panes.first)
    let visible = try XCTUnwrap(document.range(of: UInt64(store.windowID), pane: current))
    XCTAssertGreaterThan(visible.location, 0)
    XCTAssertEqual(document.string(for: visible)?.utf8.count, current.compose.text.utf8.count)
    XCTAssertEqual(current.compose.viewport.position, anchor)
    XCTAssertEqual(editor.store.panes.first?.compose.viewport.position, 0, "a reader cannot move the other native client's viewport")
    XCTAssertEqual(try Data(contentsOf: file), Data(original.utf8))
  }

  @MainActor
  func testCompleteAccessibleTextUsesTheRealFreshProjectionAndExpiresOnSelectionReveal() async throws {
    let backend = try backend(); defer { backend.captureDiagnostics("accessible-document"); backend.stop() }
    let editor = editor(BackendPasteboard()); defer { editor.detachAll() }
    let original = "# Accessible\r\n\r\nCafé 👩🏽‍💻 **bold** and [link](target.md).\r\n\r\n"
      + "![picture](missing.png)\r\n\r\n| Key | Value |\r\n| --- | --- |\r\n| one | two |\r\n\r\nEnd\r\n"
    let file = backend.root.appendingPathComponent("complete-accessible.md")
    try Data(original.utf8).write(to: file)
    try await attach(backend, file: file, editor: editor)
    let grid = try XCTUnwrap(editor.grid), pane = try XCTUnwrap(grid.focusedCompose)
    XCTAssertEqual(pane.pane.compose.sourceStart, 0)
    XCTAssertEqual(pane.pane.compose.sourceEnd, UInt64(original.utf8.count))
    let model = try XCTUnwrap(ComposeAccessibleDocument(window: UInt64(editor.store.windowID), pane: pane.pane))
    XCTAssertEqual(Array(model.text.utf8), Array(try XCTUnwrap(grid.accessibilityValue() as? String).utf8))
    XCTAssertEqual(model.characterCount, grid.accessibilityNumberOfCharacters())
    XCTAssertEqual(model.range(of: UInt64(editor.store.windowID), pane: pane.pane), NSRange(location: 0, length: model.characterCount))
    XCTAssertEqual(model.selectedRanges(window: UInt64(editor.store.windowID), pane: pane.pane), grid.accessibilitySelectedTextRanges()?.map(\.rangeValue))
    let image = (model.text as NSString).range(of: "\u{fffc}")
    XCTAssertNotEqual(image.location, NSNotFound)
    let source = try XCTUnwrap(model.sourceRange(for: image))
    XCTAssertEqual(String(decoding: Array(original.utf8)[source], as: UTF8.self), "![picture](missing.png)")
    grid.setAccessibilitySelectedTextRange(image)
    try await eventually(editor, "source selection changes the captured projection owner") {
      editor.store.panes.first?.compose.selectionRevision != model.selectionRevision
    }
    let selected = try XCTUnwrap(grid.focusedCompose)
    XCTAssertFalse(model.owns(window: UInt64(editor.store.windowID), pane: selected.pane))
    XCTAssertNil(model.range(of: UInt64(editor.store.windowID), pane: selected.pane))
    XCTAssertEqual(try Data(contentsOf: file), Data(original.utf8))
  }

  @MainActor
  func testDocumentRotorsRevealOffscreenSourceAndKeepFreshEditingAndUndoOwnership() async throws {
    let backend = try backend(); defer { backend.captureDiagnostics("semantic-navigation"); backend.stop() }
    let editor = editor(BackendPasteboard()); defer { editor.detachAll() }
    let original = "# Start\r\n\r\n| Key | Value |\r\n| --- | --- |\r\n| one | two |\r\n\r\n"
      + String(repeating: "Ordinary paragraph **with emphasis** and words.\r\n\r\n", count: 2400)
      + "## Offscreen Café 東京\r\n\r\n[Final link](target.md) ![Final image](missing.png)\r\n"
    let file = backend.root.appendingPathComponent("navigation.md")
    try Data(original.utf8).write(to: file)
    try await attach(backend, file: file, editor: editor)
    let grid = try XCTUnwrap(editor.grid)
    XCTAssertTrue(editor.store.composeSemanticIndex)
    XCTAssertTrue(grid.accessibilityCustomRotors().isEmpty)
    try await eventually(editor, "complete parser navigation") { grid.composeNavigation.controller.status == .ready }
    let index = try XCTUnwrap(grid.composeNavigation.controller.index)
    let ordinal = try XCTUnwrap(index.find(kind: 0, after: nil, forward: true, filter: "OFFSCREEN CAFE"))
    let entry = index.entries[ordinal]
    XCTAssertGreaterThan(entry.source.lowerBound, Int(try XCTUnwrap(grid.focusedCompose).pane.compose.sourceEnd))
    let rotor = try XCTUnwrap(grid.accessibilityCustomRotors().first { $0.type == .heading })
    let parameters = NSAccessibilityCustomRotor.SearchParameters()
    parameters.searchDirection = .next; parameters.filterString = "OFFSCREEN CAFE"
    let result = try XCTUnwrap(grid.composeNavigation.rotor(rotor, resultFor: parameters))
    let element = try XCTUnwrap(grid.composeNavigation.accessibilityElement(withToken: try XCTUnwrap(result.itemLoadingToken)))
    XCTAssertEqual((element as? NSAccessibilityElement)?.accessibilityLabel(), "Offscreen Café 東京")
    try await eventually(editor, "Fresh selects and reveals the offscreen source entry") {
      guard let pane = grid.focusedCompose, let cursor = pane.pane.compose.cursors.first(where: \.primary) else { return false }
      return cursor.hasAnchor && cursor.anchor == UInt64(entry.source.lowerBound) && cursor.position == UInt64(entry.source.upperBound)
        && pane.pane.compose.sourceStart <= cursor.position && cursor.position <= pane.pane.compose.sourceEnd
        && pane.caret?.intersects(pane.bounds) == true
    }
    XCTAssertEqual(try Data(contentsOf: file), Data(original.utf8), "navigation does not rewrite source")
    let replacement = "## Replacement\r\n"
    var expected = Data(original.utf8); expected.replaceSubrange(entry.source, with: replacement.utf8)
    grid.insertText(replacement, replacementRange: NSRange(location: NSNotFound, length: 0))
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "normal source edit after rotor selection") { (try? Data(contentsOf: file)) == expected }
    XCTAssertFalse((element as? NSAccessibilityElement)?.isAccessibilityElement() ?? true)
    editor.send(.action(name: "undo", argsJson: "")); editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "one Fresh undo restores exact CRLF Markdown") { (try? Data(contentsOf: file)) == Data(original.utf8) }
  }

  @MainActor
  func testAccessibilitySourceSelectionsAndImmediateTypingPreserveMarkdownAndOneUndoHistory() async throws {
    let backend = try backend(); defer { backend.captureDiagnostics("accessibility-source-actions"); backend.stop() }
    let pasteboard = BackendPasteboard(), editor = editor(pasteboard); defer { editor.detachAll() }
    let original = "# Accessibility\r\n\r\nalpha **café** and 👩🏽‍💻 omega.\r\n\r\n"
      + "![mark](missing.png)\r\n\r\n| Key | Value |\r\n| --- | --- |\r\n| one | two |\r\n\r\nend\r\n"
    let file = backend.root.appendingPathComponent("accessible.md")
    try Data(original.utf8).write(to: file)
    try await attach(backend, file: file, editor: editor)
    let grid = try XCTUnwrap(editor.grid)
    try await eventually(editor, "source selection capability") { editor.store.composeSourceSelections && grid.focusedCompose?.pane.compose.editable == true }
    let display = try XCTUnwrap(grid.accessibilityValue() as? String) as NSString
    grid.setAccessibilitySelectedTextRanges([NSValue(range: display.range(of: "👩🏽‍💻")), NSValue(range: display.range(of: "café"))])
    grid.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
    editor.send(.action(name: "save", argsJson: ""))
    let expected = original.replacingOccurrences(of: "café", with: "X").replacingOccurrences(of: "👩🏽‍💻", with: "X")
    try await eventually(editor, "immediate text at both source selections") { (try? Data(contentsOf: file)) == Data(expected.utf8) }
    editor.send(.action(name: "undo", argsJson: "")); editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "one undo restores both selections' exact CRLF Markdown") { (try? Data(contentsOf: file)) == Data(original.utf8) }
    let current = try XCTUnwrap(grid.accessibilityValue() as? String) as NSString
    grid.setAccessibilitySelectedTextRange(current.range(of: "alpha"))
    grid.setAccessibilitySelectedText("ALPHA")
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "AXSelectedText replaces the confirmed primary range") {
      (try? Data(contentsOf: file)) == Data(original.replacingOccurrences(of: "alpha", with: "ALPHA").utf8)
    }
    editor.send(.action(name: "undo", argsJson: "")); editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "AX replacement has the same Fresh undo history") { (try? Data(contentsOf: file)) == Data(original.utf8) }
    try await eventually(editor, "rendered image exposes one AX object character") {
      (grid.accessibilityValue() as? String)?.contains("\u{fffc}") == true
    }
    let image = (try XCTUnwrap(grid.accessibilityValue() as? String) as NSString).range(of: "\u{fffc}")
    grid.setAccessibilitySelectedTextRange(image)
    grid.setAccessibilitySelectedText("")
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "AX object deletion removes only its exact image source") {
      (try? Data(contentsOf: file)) == Data(original.replacingOccurrences(of: "![mark](missing.png)", with: "").utf8)
    }
    editor.send(.action(name: "undo", argsJson: "")); editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "image AX deletion undoes to exact original Markdown") { (try? Data(contentsOf: file)) == Data(original.utf8) }
    XCTAssertNil(pasteboard.editorText)
  }

  @MainActor
  func testParsedLinkDestinationsFollowGlyphsAndSourceEditsThroughSaveAndUndo() async throws {
    let backend = try backend(); defer { backend.captureDiagnostics("link-targets"); backend.stop() }
    let editor = editor(BackendPasteboard()); defer { editor.detachAll() }
    let original = "# Destinations\r\n\r\n[**café 👩🏽‍💻**](docs/a\\(b\\).md) and [東京][ref].\r\n\r\n"
      + "<user@example.invalid>\r\n\r\n[ref]: <docs/a b.md>\r\n\r\n"
      + "| Key | Value |\r\n| --- | --- |\r\n| one | two |\r\n\r\nend\r\n"
    let file = backend.root.appendingPathComponent("links.md")
    try Data(original.utf8).write(to: file)
    try await attach(backend, file: file, editor: editor)
    let grid = try XCTUnwrap(editor.grid)
    try await eventually(editor, "parser-owned link destinations") {
      Set(grid.focusedCompose?.layout.links.map(\.target) ?? []) == Set(["docs/a(b).md", "docs/a b.md", "mailto:user@example.invalid"])
    }
    let shown = try XCTUnwrap(grid.focusedCompose)
    let label = (shown.layout.text.projection.text as NSString).range(of: "café")
    let rect = try XCTUnwrap(ComposeAccessibilityText(pane: shown).bounds(for: label))
    XCTAssertEqual(grid.composeLinkDescription(at: CGPoint(x: rect.midX, y: rect.midY)), "docs/a(b).md")
    let range = (original as NSString).range(of: "docs/a\\(b\\).md")
    editor.grid(grid, replace: "docs/second.md", range: range, in: shown)
    try await eventually(editor, "updated destination after editing its raw source") {
      grid.focusedCompose?.layout.links.contains { $0.target == "docs/second.md" } == true
    }
    editor.send(.action(name: "save", argsJson: ""))
    let expected = original.replacingOccurrences(of: "docs/a\\(b\\).md", with: "docs/second.md")
    try await eventually(editor, "exact link source saved") { (try? Data(contentsOf: file)) == Data(expected.utf8) }
    editor.send(.action(name: "undo", argsJson: "")); editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "link undo preserves original CRLF spelling") { (try? Data(contentsOf: file)) == Data(original.utf8) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: backend.root.appendingPathComponent("docs").path))
  }

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
  private func editor(_ pasteboard: BackendPasteboard,
                      decodeImage: @escaping @Sendable (Data, Int) throws -> ComposeImageAsset = { try ComposeImageAsset.decode($0, maximumDimension: $1) }) -> NativeEditor {
    _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
    return NativeEditor(pasteboard: pasteboard,
      environment: ["FC_NATIVE_RICH_COMPOSE": "1", "FC_NATIVE_MEASURED_TABLES": "1"], decodeComposeImage: decodeImage)
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
  func testRealCompletionPopupUsesMeasuredHeadingCaretAndRetainedRowsAndSavesQueuedText() async throws {
    let backend = try backend(); defer { backend.captureDiagnostics("native-popup"); backend.stop() }
    let editor = editor(BackendPasteboard()); defer { editor.detachAll() }
    let original = "# Large heading\r\n\r\n## Second heading\r\n\r\n### Third heading\r\n\r\n"
      + "#### Fourth heading\r\n\r\n##### Fifth heading\r\n\r\n###### Sixth heading\r\n\r\n"
      + "| Key | Value |\r\n| --- | --- |\r\n| café | 東京 |\r\n\r\n"
      + "alphabet alpine\r\n\r\nalp"
    let file = backend.root.appendingPathComponent("popup.md")
    try Data(original.utf8).write(to: file)
    try await attach(backend, file: file, editor: editor)
    try await click(UInt64(original.utf8.count), editor: editor)
    let grid = try XCTUnwrap(editor.grid)
    editor.send(.action(name: "lsp_completion", argsJson: ""))
    try await eventually(editor, "real source-anchored completion popup") {
      guard let popup = editor.store.popups.last else { return false }
      return popup.kind == "completion" && popup.hasSourceAnchor && popup.hasGrid
        && grid.popupPresentation(popup)?.relocated == true
    }
    let popup = try XCTUnwrap(editor.store.popups.last)
    let shown = try XCTUnwrap(grid.popupPresentation(popup))
    let pane = try XCTUnwrap(grid.composePanes[popup.sourceAnchor.leaf])
    let caret = try XCTUnwrap(pane.caret)
    XCTAssertEqual(popup.sourceAnchor.caret, UInt64(original.utf8.count))
    XCTAssertTrue(shown.placement.frame.minY == caret.maxY || shown.placement.frame.maxY == caret.minY,
      "below or flipped above the measured fragment")
    XCTAssertGreaterThan(abs(shown.placement.frame.minY - shown.placement.original.minY), grid.cellHeight)
    XCTAssertTrue(popup.grid.rows.contains { $0.text.contains("alphabet") || $0.text.contains("alpine") })
    if let path = ProcessInfo.processInfo.environment["FC_COMPOSE_ARTIFACT_DIR"] {
      let output = URL(fileURLWithPath: path)
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      let host = try XCTUnwrap(editor.view)
      let window = NSWindow(contentRect: host.bounds, styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.contentView = host
      defer { window.contentView = nil; window.close() }
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("real-popup.png"))
      func rect(_ value: CGRect) -> [Double] { [value.minX, value.minY, value.width, value.height].map(Double.init) }
      let report: [String: Any] = ["native_caret": rect(caret), "original_popup": rect(shown.placement.original),
        "native_popup": rect(shown.placement.frame), "retained_rows": popup.grid.rows.map(\.text),
        "scope": "Real private Fresh backend, Markdown parser, native layout and offscreen Chrome drawing"]
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("real-popup.json"))
    }
    guard case .list(let content) = popup.content.content else { return XCTFail("Expected completion rows") }
    let expectedWord = try XCTUnwrap(content.items.first).text
    XCTAssertTrue(["alphabet", "alpine"].contains(expectedWord))
    let x = CGFloat(popup.contentRect.x - popup.rect.x) + 2.5
    let y = CGFloat(popup.contentRect.y - popup.rect.y) + 0.5
    let point = CGPoint(x: shown.placement.frame.minX + x * grid.cellWidth,
                        y: shown.placement.frame.minY + y * grid.cellHeight)
    XCTAssertTrue(grid.sendPopupMouse(.down, point: point, flags: []))
    XCTAssertTrue(grid.sendPopupMouse(.up, point: point, flags: []))
    editor.send(.text("!")) // Arrives while Fresh still owns the completion keyboard.
    let completed = String(original.dropLast(3)) + expectedWord
    let expected = completed + "!"
    try await eventually(editor, "completion accepted through scoped popup input") {
      editor.store.popups.isEmpty && grid.focusedCompose?.pane.compose.documentLen == UInt64(expected.utf8.count)
    }
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "exact completion source saved") { (try? Data(contentsOf: file)) == Data(expected.utf8) }
    editor.send(.action(name: "undo", argsJson: ""))
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "queued text undo preserves accepted completion") { (try? Data(contentsOf: file)) == Data(completed.utf8) }
    editor.send(.action(name: "undo", argsJson: ""))
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "completion undo restores original CRLF source") { (try? Data(contentsOf: file)) == Data(original.utf8) }
  }

  @MainActor
  func testManySeparateTablesKeepUnicodeImageAndSourceGeometryThroughReflowAndUndoSave() async throws {
    let backend = try backend(); defer {
      backend.captureDiagnostics("many-tables")
      backend.stop()
    }
    let editor = editor(BackendPasteboard()); defer { editor.detachAll() }
    let pixels = try XCTUnwrap(CGContext(data: nil, width: 80, height: 24, bitsPerComponent: 8,
      bytesPerRow: 320, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    pixels.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.3, alpha: 1)); pixels.fill(CGRect(x: 0, y: 0, width: 80, height: 24))
    let png = try XCTUnwrap(CGImageDestinationCreateWithURL(backend.root.appendingPathComponent("tiny.png") as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(png, try XCTUnwrap(pixels.makeImage()), nil); XCTAssertTrue(CGImageDestinationFinalize(png))
    let count = 128
    var original = "1) An image ![tiny](tiny.png) and a measured hanging marker.\r\n\r\n"
    original += String(repeating: "Proportional café 👩🏽‍💻 and שלום before the tables.\r\n\r\n", count: 256)
    for index in 0..<count {
      original += "## Section \(index)\r\n\r\n| Name | Detail |\r\n|:---|---:|\r\n| **café-\(index) 👩🏽‍💻** | `value-\(index)` 東京 שלום |\r\n\r\n"
    }
    let file = backend.root.appendingPathComponent("many-tables.md")
    try Data(original.utf8).write(to: file)
    try await attach(backend, file: file, editor: editor)
    let grid = try XCTUnwrap(editor.grid)
    try await eventually(editor, "all separate tables and native image metrics") {
      guard let pane = grid.focusedCompose else { return false }
      return pane.layout.text.tables.count == count && pane.layout.text.attachments.first?.rect.width == 80
        && pane.layout.text.attachments.first?.rect.height == 24
    }
    let initial = try XCTUnwrap(grid.focusedCompose)
    var local = initial.pane.compose
    for index in local.tables.indices {
      local.tables[index].measurementID = 0; local.tables[index].clearMeasurement()
    }
    if let path = ProcessInfo.processInfo.environment["FC_COMPOSE_ARTIFACT_DIR"] {
      let output = URL(fileURLWithPath: path)
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      try initial.pane.compose.serializedData().write(to: output.appendingPathComponent("many-tables.pb"))
      try local.serializedData().write(to: output.appendingPathComponent("many-tables-local.pb"))
    }
    func verify(_ layout: ComposeTextLayout) throws {
      XCTAssertEqual(layout.tables.count, count)
      for index in [0, count / 2, count - 1] {
        let word = "café-\(index) ", token = word + "👩🏽‍💻"
        let range = try XCTUnwrap(original.range(of: token))
        let start = original[..<range.lowerBound].utf8.count + word.utf8.count
        let unit = try XCTUnwrap(layout.utf16Position(for: start))
        XCTAssertEqual(layout.sourceRange(forUTF16: NSRange(location: unit, length: "👩🏽‍💻".utf16.count)), start..<(start + "👩🏽‍💻".utf8.count))
        let caret = try XCTUnwrap(layout.caret(for: start))
        let hit = try XCTUnwrap(layout.hit(at: CGPoint(x: caret.minX + 0.01, y: caret.midY)))
        XCTAssertEqual(hit.source, start)
        XCTAssertTrue(layout.tables[index].rect.insetBy(dx: -1, dy: -1).contains(caret))
        XCTAssertNotEqual(layout.tables[index].columns[0], layout.tables[index].columns[1])
      }
      let image = try XCTUnwrap(layout.attachments.first)
      let imageIndex = try XCTUnwrap(layout.utf16Position(for: image.attachment.source.lowerBound))
      let fragment = try XCTUnwrap(layout.fragments.first { $0.range.contains(imageIndex) })
      XCTAssertGreaterThanOrEqual(fragment.rect.height, image.rect.height,
        "final shaping must include image run delegates added after table measurement")
    }
    try verify(initial.layout.text)
    let image = try XCTUnwrap(local.images.first)
    let asset = try ComposeImageAsset.decode(Data(contentsOf: backend.root.appendingPathComponent("tiny.png")), maximumDimension: 1024)
    let localLayout = try XCTUnwrap(ComposePaneLayout(pane: local, body: CTFontCreateWithName("Helvetica" as CFString, 18, nil),
      monospace: CTFontCreateWithName("Menlo" as CFString, 18, nil), width: 620, images: [image.start: .ready(asset)]))
    try verify(localLayout.text)
    var preferences = ComposePreferences(); preferences.bodySize = 22
    grid.setComposePreferences(preferences, zoom: 1)
    grid.setFrameSize(CGSize(width: 480, height: 420))
    try await eventually(editor, "font and width change preserves every table") {
      guard let pane = grid.focusedCompose else { return false }
      return pane.layout.text.tables.count == count && pane.layout.text.size.height != initial.layout.text.size.height
    }
    try verify(try XCTUnwrap(grid.focusedCompose).layout.text)
    editor.send(.text("Prefix "))
    let changed = Data("Prefix ".utf8) + Data(original.utf8)
    try await eventually(editor, "prefix insertion") { grid.focusedCompose?.pane.compose.documentLen == UInt64(changed.count) }
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "save changed exact CRLF source") { (try? Data(contentsOf: file)) == changed }
    editor.send(.action(name: "undo", argsJson: ""))
    try await eventually(editor, "undo insertion") { grid.focusedCompose?.pane.compose.documentLen == UInt64(original.utf8.count) }
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "save original exact CRLF source") { (try? Data(contentsOf: file)) == Data(original.utf8) }
    XCTAssertTrue(editor.uninsertedText.isEmpty)
  }

  @MainActor
  func testRealBackendDenseInlineImagesKeepMeasuredPagingResizeAndEditSaveUndo() async throws {
    let backend = try backend(); defer {
      backend.captureDiagnostics("dense-inline-images")
      backend.stop()
    }
    let editor = editor(BackendPasteboard()); defer { editor.detachAll() }
    let timing = ProcessInfo.processInfo.environment["FC_COMPOSE_TEST_TIMING"] == "1"
    if timing {
      let path = try XCTUnwrap(ProcessInfo.processInfo.environment["FC_COMPOSE_ARTIFACT_DIR"])
      EditorTelemetry.shared.start(directory: URL(fileURLWithPath: path).appendingPathComponent("dense-image-timing"))
      EditorTelemetry.shared.record(["ev": "compose_backend", "pid": backend.server.processIdentifier,
        "owner": ProcessInfo.processInfo.processIdentifier])
    }
    defer { if timing { EditorTelemetry.shared.stop() } }
    func phase(_ name: String, _ event: String) {
      if timing { EditorTelemetry.shared.record(["ev": "compose_phase", "name": name, "phase": event]) }
    }
    let pixels = try XCTUnwrap(CGContext(data: nil, width: 80, height: 20, bitsPerComponent: 8,
      bytesPerRow: 320, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    pixels.setFillColor(CGColor(red: 0.1, green: 0.65, blue: 0.35, alpha: 1)); pixels.fill(CGRect(x: 0, y: 0, width: 80, height: 20))
    let image = backend.root.appendingPathComponent("tiny.png")
    let png = try XCTUnwrap(CGImageDestinationCreateWithURL(image as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(png, try XCTUnwrap(pixels.makeImage()), nil); XCTAssertTrue(CGImageDestinationFinalize(png))
    let header = "| A | B |\r\n|---|---|\r\n| one | two |\r\n\r\n# Dense images\r\n\r\n"
    let body = (0..<4000).map { "word\($0) café ![tiny](tiny.png) more text. " }.joined()
    let original = header + body + "\r\n\r\nTail\r\n"
    let file = backend.root.appendingPathComponent("dense-images.md")
    try Data(original.utf8).write(to: file)
    phase("open", "begin")
    try await attach(backend, file: file, editor: editor)
    let grid = try XCTUnwrap(editor.grid)
    try await eventually(editor, "complete dense paragraph and shared inline image pixels") {
      guard let pane = grid.focusedCompose, let first = pane.pane.compose.images.first else { return false }
      return pane.layout.text.attachments.count == 4000 && pane.layout.imageDescription(first) == "tiny"
        && pane.layout.text.attachments.first?.rect.width == 80
    }
    phase("open", "observed")
    let initial = try XCTUnwrap(grid.focusedCompose)
    if let path = ProcessInfo.processInfo.environment["FC_COMPOSE_ARTIFACT_DIR"] {
      let output = URL(fileURLWithPath: path)
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      try initial.pane.compose.serializedData().write(to: output.appendingPathComponent("dense-images.pb"))
    }
    XCTAssertGreaterThan(original.utf8.count, 128 << 10)
    XCTAssertLessThanOrEqual(initial.pane.compose.sourceStart, UInt64(header.utf8.count))
    XCTAssertGreaterThanOrEqual(initial.pane.compose.sourceEnd, UInt64(header.utf8.count + body.utf8.count))
    var positions: [UInt64] = []
    for (index, action) in ["move_page_down", "move_page_down", "move_page_down", "move_page_up"].enumerated() {
      let before = try XCTUnwrap(grid.focusedCompose?.cursor?.position)
      let label = "\(index)-\(action)"
      phase(label, "begin")
      editor.send(.action(name: action, argsJson: ""))
      phase(label, "invoked")
      try await eventually(editor, "measured \(action) within the complete dense paragraph") {
        guard let after = grid.focusedCompose?.cursor?.position else { return false }
        return action == "move_page_up" ? after < before : after > before
      }
      phase(label, "observed")
      positions.append(try XCTUnwrap(grid.focusedCompose?.cursor?.position))
    }
    let position = try XCTUnwrap(positions.last), width = try XCTUnwrap(grid.focusedCompose?.layout.width)
    XCTAssertGreaterThan(position, UInt64(header.utf8.count))
    phase("resize", "begin")
    grid.setFrameSize(CGSize(width: 460, height: 420))
    phase("resize", "invoked")
    try await eventually(editor, "resize keeps the dense paragraph's source caret") {
      grid.focusedCompose?.cursor?.position == position && (grid.focusedCompose?.layout.width ?? width) < width
    }
    phase("resize", "observed")
    let prefix = Data(original.utf8.prefix(Int(position))), suffix = Data(original.utf8.dropFirst(Int(position)))
    XCTAssertEqual(grid.selectedRange(), NSRange(location: String(decoding: prefix, as: UTF8.self).utf16.count, length: 0))
    let insertion = "追加👩🏽‍💻"
    phase("insert_and_save", "begin")
    grid.insertText(insertion, replacementRange: NSRange(location: NSNotFound, length: 0))
    phase("insert_and_save", "invoked")
    editor.send(.action(name: "save", argsJson: ""))
    try await eventually(editor, "dense inline-image source saves exact Unicode and CRLF bytes") { (try? Data(contentsOf: file)) == prefix + Data(insertion.utf8) + suffix }
    phase("insert_and_save", "observed")
    phase("undo_and_save", "begin")
    editor.send(.action(name: "undo", argsJson: "")); editor.send(.action(name: "save", argsJson: ""))
    phase("undo_and_save", "invoked")
    try await eventually(editor, "one undo restores every dense image reference") { (try? Data(contentsOf: file)) == Data(original.utf8) }
    phase("undo_and_save", "observed")
    phase("document_start", "begin")
    editor.send(.action(name: "move_document_start", argsJson: ""))
    phase("document_start", "invoked")
    try await eventually(editor, "all image attachments return after source editing and undo") {
      guard let pane = grid.focusedCompose else { return false }
      return pane.cursor?.position == 0 && pane.layout.text.attachments.count == 4000
        && pane.layout.text.attachments.first?.rect.width == 80
    }
    phase("document_start", "observed")
    XCTAssertTrue(editor.uninsertedText.isEmpty); XCTAssertTrue(backend.server.isRunning)
    let report: [String: Any] = ["source_bytes": original.utf8.count, "attachments": 4000, "page_positions": positions,
      "initial_width": Double(width), "resized_width": Double(try XCTUnwrap(grid.focusedCompose?.layout.width))]
    try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: backend.root.appendingPathComponent("dense-image-report.json"))
    let accessible = try XCTUnwrap(grid.accessibilityChildren() as? [NSAccessibilityElement])
    XCTAssertEqual(accessible.count, 4000, "every attachment remains available to accessibility")
    XCTAssertEqual(accessible.compactMap { $0.accessibilityLabel() }, Array(repeating: "tiny", count: 4000))
  }

  @MainActor
  func testRealBackendTypingRetainsReceivedInlineImageThroughSourceRevisionsAndSaveUndo() async throws {
    let backend = try backend(); defer {
      backend.captureDiagnostics("image-decode-lifetime")
      backend.stop()
    }
    let started = expectation(description: "Fresh delivered the image bytes")
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let editor = editor(BackendPasteboard(), decodeImage: { bytes, dimension in
      XCTAssertFalse(Thread.isMainThread)
      started.fulfill(); release.wait()
      return try ComposeImageAsset.decode(bytes, maximumDimension: dimension)
    })
    defer { editor.detachAll() }
    let pixels = try XCTUnwrap(CGContext(data: nil, width: 80, height: 20, bitsPerComponent: 8,
      bytesPerRow: 320, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    pixels.setFillColor(CGColor(red: 0.1, green: 0.65, blue: 0.35, alpha: 1)); pixels.fill(CGRect(x: 0, y: 0, width: 80, height: 20))
    let image = backend.root.appendingPathComponent("tiny.png")
    let png = try XCTUnwrap(CGImageDestinationCreateWithURL(image as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(png, try XCTUnwrap(pixels.makeImage()), nil); XCTAssertTrue(CGImageDestinationFinalize(png))
    let original = "| A | B |\n|---|---|\n| one | two |\n\n# Received images\n\nBefore ![tiny](tiny.png) after.\n\n"
      + String(repeating: "Later café 東京 👩🏽‍💻 paragraph.\n\n", count: 3000)
    XCTAssertGreaterThan(original.utf8.count, 64 << 10)
    let file = backend.root.appendingPathComponent("decode.md")
    try Data(original.utf8).write(to: file)
    try await attach(backend, file: file, editor: editor)
    await fulfillment(of: [started], timeout: 5)
    let grid = try XCTUnwrap(editor.grid)
    let index = try XCTUnwrap(original.range(of: "Before"))
    let start = UInt64(original[..<index.lowerBound].utf8.count)
    try await click(start, editor: editor)
    var insertion = ""
    for text in ["日", "本", "👩🏽‍💻", " café "] {
      let before = try XCTUnwrap(editor.store.panes.first(where: { $0.hasCompose })).compose.bufferRevision
      grid.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)); insertion += text
      let expected = start + UInt64(insertion.utf8.count)
      try await eventually(editor, "typing commits while the image decode is held") {
        editor.store.panes.contains { $0.hasCompose && $0.compose.bufferRevision > before
          && $0.compose.cursors.contains { $0.primary && $0.position == expected } }
      }
    }
    release.signal()
    try await eventually(editor, "received image becomes visible after intervening source edits") {
      grid.focusedCompose?.layout.text.attachments.first?.rect.width == 80
    }
    editor.send(.action(name: "save", argsJson: ""))
    let prefix = Data(original.utf8.prefix(Int(start))), suffix = Data(original.utf8.dropFirst(Int(start)))
    try await eventually(editor, "save source after decode and typing") { (try? Data(contentsOf: file)) == prefix + Data(insertion.utf8) + suffix }
    editor.send(.action(name: "undo", argsJson: "")); editor.send(.action(name: "save", argsJson: ""))
    let earlier = ["日", "本", "👩🏽‍💻"].joined()
    try await eventually(editor, "undo the final phrase without undoing image presentation") { (try? Data(contentsOf: file)) == prefix + Data(earlier.utf8) + suffix }
    XCTAssertEqual(grid.focusedCompose?.layout.text.attachments.first?.rect.width, 80)
    XCTAssertTrue(editor.uninsertedText.isEmpty); XCTAssertTrue(backend.server.isRunning)
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
    defer { backend.captureDiagnostics("page-selection") }
    let pasteboard = BackendPasteboard(), editor = editor(pasteboard)
    defer {
      if let directory = ProcessInfo.processInfo.environment["FC_COMPOSE_ARTIFACT_DIR"], let pane = editor.grid?.focusedCompose {
        let compose = pane.pane.compose
        let record: [String: Any] = ["source_start": compose.sourceStart, "source_end": compose.sourceEnd,
          "document_length": compose.documentLen, "cursor": pane.cursor?.position ?? 0,
          "viewport_position": pane.viewport.position, "viewport_offset": pane.viewport.offset,
          "backend_viewport_position": compose.viewport.position, "backend_viewport_offset": compose.viewport.offset,
          "layout_height": pane.layout.text.size.height, "pane_height": pane.bounds.height,
          "tables": pane.layout.text.tables.count, "ready": compose.formattingReady]
        let output = URL(fileURLWithPath: directory).appendingPathComponent("page-window-" + backend.root.lastPathComponent + ".json")
        try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output) }
      }
      editor.detachAll()
    }
    let original = "| Head | Image |\n|---|---|\n| tiny | ![p](" + String(repeating: "x", count: 90_000)
      + ".png) |\n\n" + (0..<1000).map { "Paragraph \($0) with measured words and café 👩🏽‍💻.\n\n" }.joined()
    let file = backend.root.appendingPathComponent("page.md")
    try Data(original.utf8).write(to: file)
    try await attach(backend, file: file, editor: editor)
    let paragraph = try XCTUnwrap(original.range(of: "Paragraph 0"))
    let tableEnd = UInt64(original[..<paragraph.lowerBound].utf8.count)
    try await eventually(editor, "automatic filling retains the first table and its visible anchor") {
      guard let pane = editor.grid?.focusedCompose else { return false }
      return pane.pane.compose.sourceEnd > tableEnd && pane.pane.compose.sourceStart == 0
        && !pane.layout.text.tables.isEmpty && pane.viewport.position == 0 && pane.viewport.offset == 0
    }
    let grid = try XCTUnwrap(editor.grid), initial = try XCTUnwrap(grid.focusedCompose)
    let origin = UInt64(2), edge = initial.pane.compose.sourceEnd
    XCTAssertLessThan(edge, initial.pane.compose.documentLen)
    if let directory = ProcessInfo.processInfo.environment["FC_COMPOSE_ARTIFACT_DIR"] {
      let output = URL(fileURLWithPath: directory)
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      try initial.pane.compose.serializedData().write(to: output.appendingPathComponent("page-initial-window.pb"))
      let record: [String: Any] = ["source_start": initial.pane.compose.sourceStart, "source_end": edge,
        "cursor": initial.cursor?.position ?? 0, "viewport_position": initial.viewport.position,
        "viewport_offset": initial.viewport.offset, "probe": initial.viewport.region, "tables": initial.layout.text.tables.count]
      try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("page-initial-window.json"))
      let width = Int(ceil(initial.bounds.maxX)), height = Int(ceil(initial.bounds.maxY))
      let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
      initial.draw(in: context, dirty: initial.bounds, foreground: .black, background: .white, selection: .blue)
      let png = try XCTUnwrap(CGImageDestinationCreateWithURL(output.appendingPathComponent("page-initial-window.png") as CFURL, "public.png" as CFString, 1, nil))
      CGImageDestinationAddImage(png, try XCTUnwrap(context.makeImage()), nil); XCTAssertTrue(CGImageDestinationFinalize(png))
    }
    try await click(origin, editor: editor)
    // The stable initial view already includes its measured fill region.
    // Keep selecting pages until crossing that actual captured source window.
    var pages = 0
    while (grid.focusedCompose?.cursor?.position ?? 0) < edge && pages < 128 {
      let before = try XCTUnwrap(grid.focusedCompose?.cursor).position
      editor.send(.action(name: "select_page_down", argsJson: "")); pages += 1
      try await eventually(editor, "Page Down advances the captured selection") {
        guard let cursor = grid.focusedCompose?.cursor else { return false }
        return cursor.position > before && cursor.anchor == origin
      }
    }
    let end = try XCTUnwrap(grid.focusedCompose?.cursor).position
    XCTAssertGreaterThanOrEqual(end, edge, "the selection must cross the initially loaded window")
    if let directory = ProcessInfo.processInfo.environment["FC_COMPOSE_ARTIFACT_DIR"] {
      let record: [String: Any] = ["pages": pages, "initial_source_end": edge, "selection_start": origin, "selection_end": end]
      try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: directory).appendingPathComponent("page-selection.json"))
    }
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
