import AppKit
import ExplainerKit
import FCKit
import FreshKit

/// The editor, whichever way it is shown: natively over the session's scene
/// channel (`NativeEditor`), or in a terminal view running `fresh -a`
/// (`TerminalEditor`) when the session has no scene channel or Settings asks
/// for the terminal. Explainers drive either through this one interface.
@MainActor
final class EditorController {
  let native = NativeEditor()
  let terminal = TerminalEditor()
  private var showingNative = true

  func attach(_ request: AttachRequest, app: AppController?) {
    Trace.write("editor attach: " + (request.sceneSocket.isEmpty ? "terminal \(request.argv.joined(separator: " "))" : "scene \(request.sceneSocket)"))
    if !request.sceneSocket.isEmpty {
      if terminal.running { terminal.detachAll() }
      showingNative = true
      native.attach(socketPath: request.sceneSocket, app: app)
    } else {
      if native.connected { native.detachAll() }
      showingNative = false
      terminal.attach(request, app: app)
    }
  }

  /// The editor window is showing.
  var running: Bool { showingNative ? native.visible : terminal.running }

  /// Shown natively rather than in a terminal view.
  var isNative: Bool { showingNative }

  func detachAll() {
    native.detachAll()
    terminal.detachAll()
  }

  func applyTheme() {
    native.applyTheme()
    terminal.applyTheme()
  }

  // MARK: Explainer access

  /// The editor's visible text, one string per row.
  var screenLines: [String] { showingNative ? native.screenLines : terminal.screenLines }

  /// Whether a native surface ("palette", "explorer", "popup", ...) is showing.
  func shows(_ surface: String) -> Bool { showingNative && running && !native.surfaceCells(surface).isEmpty }

  /// The screen rectangle around a native surface.
  func surfaceRect(_ surface: String) -> CGRect? { showingNative ? native.surfaceRect(surface) : nil }

  /// The screen rectangle of columns [col, col+count) on a row.
  func screenRect(row: Int, col: Int, count: Int) -> CGRect? {
    showingNative ? native.screenRect(row: row, col: col, count: count) : terminal.screenRect(row: row, col: col, count: count)
  }

  /// Presses a key chord ("End", "Ctrl+V", "F10") in the editor. The switch key
  /// goes back to File Commander, as it does when typed. False when the chord
  /// can't be sent.
  @discardableResult
  func press(_ chord: String, app: AppController) -> Bool {
    if let parsed = KeyChord(chord), app.keymap.command(for: parsed) == "switch_to_file_commander", showingNative {
      native.switchBack()
      return true
    }
    if showingNative {
      guard let message = EditorController.message(for: chord) else { return false }
      native.send(message)
      return true
    }
    guard let bytes = TerminalKeys.bytes(for: chord) else { return false }
    terminal.send(bytes)
    return true
  }

  /// Types text into the editor.
  func type(_ text: String) {
    if showingNative {
      for message in SceneKeys.typing(text) { native.send(message) }
    } else {
      terminal.send(text)
    }
  }

  /// Presses the mouse on a cell of a row, drags to another column and releases.
  func drag(row: Int, from start: Int, to end: Int, duration: Double) async {
    let steps = max(1, end - start)
    if showingNative {
      native.send(["type": "mouse", "kind": "down", "button": "left", "col": start, "row": row])
      for column in (start + 1)...max(start + 1, end) {
        try? await Task.sleep(for: .seconds(duration / Double(steps)))
        native.send(["type": "mouse", "kind": "drag", "button": "left", "col": column, "row": row])
      }
      native.send(["type": "mouse", "kind": "up", "button": "left", "col": end, "row": row])
      return
    }
    terminal.send("\u{1b}[<0;\(start + 1);\(row + 1)M")
    for column in (start + 1)...max(start + 1, end) {
      try? await Task.sleep(for: .seconds(duration / Double(steps)))
      terminal.send("\u{1b}[<32;\(column + 1);\(row + 1)M")
    }
    terminal.send("\u{1b}[<0;\(end + 1);\(row + 1)m")
  }

  /// The scene key message for a chord in the app's notation.
  static func message(for chord: String) -> [String: Any]? {
    guard let parsed = KeyChord(chord) else { return nil }
    let names: [String: String] = [
      "Enter": "Enter", "Return": "Enter", "Tab": "Tab", "Esc": "Escape", "Escape": "Escape", "Backspace": "Backspace",
      "Delete": "Delete", "Space": " ", "Up": "ArrowUp", "Down": "ArrowDown", "Left": "ArrowLeft", "Right": "ArrowRight",
      "Home": "Home", "End": "End", "PageUp": "PageUp", "PageDown": "PageDown", "Insert": "Insert",
    ]
    var key = names[parsed.key] ?? parsed.key
    if key.count > 1, !key.hasPrefix("F"), names[parsed.key] == nil { return nil }
    let shift = parsed.modifiers.contains(.shift)
    if key.count == 1, !shift { key = key.lowercased() }
    return [
      "type": "key", "key": key, "ctrl": parsed.modifiers.contains(.control), "alt": parsed.modifiers.contains(.option),
      "meta": parsed.modifiers.contains(.command), "shift": shift,
    ]
  }
}
