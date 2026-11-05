import AppKit
import ExplainerKit
import FCKit
import FreshKit
import Observation

/// The editor, whichever way it runs: natively over the session's scene
/// channel (`NativeEditor`), or in a terminal view running `fresh -a`
/// (`TerminalEditor`) when the session has no scene channel or Settings asks
/// for the terminal. The main window shows `view` in place of the panes while
/// `shown`; explainers drive either editor through this one interface.
@MainActor @Observable
final class EditorController {
  @ObservationIgnored let native = NativeEditor()
  @ObservationIgnored let terminal = TerminalEditor()
  @ObservationIgnored weak var app: AppController?
  @ObservationIgnored private var showingNative = true

  /// The editor is shown in the main window in place of the panes.
  private(set) var shown = false
  /// The active tab's name, for the window title; empty when unknown.
  private(set) var title = ""
  /// The view the main window shows for the editor.
  private(set) var view: NSView?
  private(set) var hasUninsertedText = false

  init() {
    native.onPresent = { [weak self] shown in self?.present(shown, native: true) }
    native.onTitle = { [weak self] title in self?.setTitle(title) }
    native.onUninsertedTextChanged = { [weak self] available in self?.hasUninsertedText = available }
    terminal.onPresent = { [weak self] shown in self?.present(shown, native: false) }
    terminal.onTitle = { [weak self] title in self?.setTitle(title) }
  }

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

  private func present(_ shown: Bool, native: Bool) {
    if shown, let view = native ? self.native.view : terminal.terminal, view !== self.view {
      self.view = view
    }
    guard self.shown != shown else { return }
    self.shown = shown
    app?.editorShownChanged(shown)
  }

  /// Set only on a change: the main window redraws its title bar for each.
  private func setTitle(_ title: String) {
    if self.title != title { self.title = title }
  }

  /// The editor is showing.
  var running: Bool { shown }

  /// Shown natively rather than in a terminal view.
  var isNative: Bool { showingNative }

  /// The window the editor is shown in.
  var window: NSWindow? { shown ? view?.window : nil }

  /// Shows the files again. The native editor stays connected; the terminal
  /// detaches, as the switch key does in it.
  func showFiles() {
    if showingNative { native.switchBack() } else { terminal.detachAll() }
  }

  /// Gives the editor the keyboard, once its view is on screen.
  func focus() {
    if showingNative { native.focus() } else { terminal.focus() }
  }

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
      showFiles()
      return true
    }
    if showingNative {
      guard let key = EditorController.key(for: chord) else { return false }
      native.send(.key(key))
      return true
    }
    guard let bytes = TerminalKeys.bytes(for: chord) else { return false }
    terminal.send(bytes)
    return true
  }

  /// Types text into the editor.
  func type(_ text: String) {
    if showingNative {
      for key in SceneKeys.typing(text) { native.send(.key(key)) }
    } else {
      terminal.send(text)
    }
  }

  /// Presses the mouse on a cell of a row, drags to another column and releases.
  func drag(row: Int, from start: Int, to end: Int, duration: Double) async {
    let steps = max(1, end - start)
    if showingNative {
      let mouse = { (kind: WireMouseKind, column: Int) in
        SceneInput.mouse(WireMouse.with {
          $0.kind = kind
          $0.col = UInt32(clamping: column)
          $0.row = UInt32(clamping: row)
          $0.n = 1
          $0.count = 1
        })
      }
      native.send(mouse(.down, start))
      for column in (start + 1)...max(start + 1, end) {
        try? await Task.sleep(for: .seconds(duration / Double(steps)))
        native.send(mouse(.drag, column))
      }
      native.send(mouse(.up, end))
      return
    }
    terminal.send("\u{1b}[<0;\(start + 1);\(row + 1)M")
    for column in (start + 1)...max(start + 1, end) {
      try? await Task.sleep(for: .seconds(duration / Double(steps)))
      terminal.send("\u{1b}[<32;\(column + 1);\(row + 1)M")
    }
    terminal.send("\u{1b}[<0;\(end + 1);\(row + 1)m")
  }

  /// The scene key for a chord in the app's notation.
  static func key(for chord: String) -> WireKey? {
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
    return WireKey.with {
      $0.key = key
      $0.ctrl = parsed.modifiers.contains(.control)
      $0.alt = parsed.modifiers.contains(.option)
      $0.meta = parsed.modifiers.contains(.command)
      $0.shift = shift
    }
  }
}
