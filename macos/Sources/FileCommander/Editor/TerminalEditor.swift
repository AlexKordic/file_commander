import AppKit
import FCKit
import SwiftTerm

/// Runs Fresh's attach command in a terminal view, shown in the main window in
/// place of the panes: the fallback for a Fresh session without a scene
/// channel (an older Fresh, or a `fresh_binary_path` override), or when
/// Settings asks for the terminal. The backend lives on in its own session;
/// the switch key detaches, just as the terminal interface does, and the files
/// come back when the attach client exits.
@MainActor
final class TerminalEditor: NSObject, LocalProcessTerminalViewDelegate {
  private(set) var terminal: EditorTerminalView?
  private(set) var running = false
  private weak var app: AppController?
  private var monitor: Any?
  /// Called when the terminal wants to be shown (true) or hidden (false).
  var onPresent: ((Bool) -> Void)?
  /// Called with the terminal's title when Fresh sets it.
  var onTitle: ((String) -> Void)?

  func attach(_ request: AttachRequest, app: AppController?) {
    self.app = app
    let terminal = self.terminal ?? makeView()
    terminal.showingEvent = NSApp.currentEvent.flatMap { $0.type == .keyDown ? $0.timestamp : nil }
    if running {
      // Already attached: Fresh shows the newly opened files itself.
      onPresent?(true)
      return
    }
    applyTheme()
    var environment = request.environment
    for (name, value) in [("TERM", "xterm-256color"), ("COLORTERM", "truecolor"), ("LANG", "en_US.UTF-8")]
    where !environment.contains(where: { $0.hasPrefix(name + "=") }) {
      environment.append("\(name)=\(value)")
    }
    guard let executable = request.argv.first else { return }
    terminal.startProcess(executable: executable, args: Array(request.argv.dropFirst()), environment: environment,
                          execName: nil, currentDirectory: request.cwd)
    running = true
    watch(pid: terminal.process.shellPid)
    onPresent?(true)
  }

  func applyTheme() {
    guard let terminal, let app else { return }
    terminal.font = app.theme.nsFont("editor.terminal")
    terminal.nativeBackgroundColor = app.theme.nsColor("editor.background")
    terminal.nativeForegroundColor = app.theme.nsColor("editor.text")
  }

  /// Gives the terminal the keyboard, once it is in the window.
  func focus() {
    guard running, let terminal, let window = terminal.window, window.firstResponder !== terminal else { return }
    window.makeFirstResponder(terminal)
  }

  func detachAll() {
    guard running else { return }
    if let terminal { kill(terminal.process.shellPid, SIGTERM) }
    running = false
    watcher?.invalidate()
    onPresent?(false)
  }

  private func makeView() -> EditorTerminalView {
    let terminal = EditorTerminalView(frame: NSRect(x: 0, y: 0, width: 980, height: 640))
    terminal.processDelegate = self
    self.terminal = terminal
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      MainActor.assumeIsolated {
        guard let self, let app = self.app, self.running, let terminal = self.terminal, event.window === terminal.window,
              event.window?.firstResponder === terminal, let chord = KeyChord(event: event),
              chord.modifiers.contains(.command), app.keymap.command(for: chord) == "switch_to_file_commander" else { return event }
        // Fresh never sees Cmd chords, so the app detaches for it.
        self.detachAll()
        return nil
      }
    }
    return terminal
  }

  /// Notices when the attach client exits. SwiftTerm's own exit callback doesn't
  /// always arrive, so the PID is checked too; whichever comes first wins.
  private var watcher: Timer?
  private func watch(pid: pid_t) {
    watcher?.invalidate()
    guard pid > 0 else { return }
    watcher = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
      MainActor.assumeIsolated {
        guard let self, self.running else { timer.invalidate(); return }
        var status: Int32 = 0
        let reaped = waitpid(pid, &status, WNOHANG) == pid
        if reaped || (kill(pid, 0) != 0 && errno == ESRCH) {
          timer.invalidate()
          self.clientExited(code: reaped && status & 0x7f == 0 ? (status >> 8) & 0xff : nil)
        }
      }
    }
  }

  private func clientExited(code: Int32?) {
    guard running else { return }
    running = false
    watcher?.invalidate()
    if let code, code != 0 { app?.engine.reportError("The editor exited with status \(code)") }
    onPresent?(false)
  }

  // MARK: LocalProcessTerminalViewDelegate

  nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
  nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
    MainActor.assumeIsolated { onTitle?(title) }
  }
  nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
  nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
    MainActor.assumeIsolated { clientExited(code: exitCode) }
  }

  // MARK: Explainer access

  /// The terminal's visible text, one string per row.
  var screenLines: [String] {
    guard let terminal else { return [] }
    let t = terminal.getTerminal()
    return (0..<t.rows).map { row in t.getLine(row: row)?.translateToString(trimRight: true) ?? "" }
  }

  /// The screen rectangle of columns [col, col+count) on a row.
  func screenRect(row: Int, col: Int, count: Int) -> CGRect? {
    guard running, let terminal, let window = terminal.window else { return nil }
    let t = terminal.getTerminal()
    guard t.cols > 0, t.rows > 0 else { return nil }
    let cellWidth = terminal.bounds.width / CGFloat(t.cols)
    let cellHeight = terminal.bounds.height / CGFloat(t.rows)
    let local = NSRect(x: CGFloat(col) * cellWidth, y: terminal.bounds.height - CGFloat(row + 1) * cellHeight,
                       width: CGFloat(count) * cellWidth, height: cellHeight)
    return window.convertToScreen(terminal.convert(local, to: nil))
  }

  func send(_ text: String) { terminal?.send(txt: text) }
}

/// The terminal editor's view. Keys typed into it go to Fresh ahead of the
/// menus, whose shortcuts would otherwise take F-keys and Control chords; ⌘
/// chords, which Fresh never sees, still reach the menus.
final class EditorTerminalView: LocalProcessTerminalView {
  /// The key press that showed the editor. AppKit can deliver it here again
  /// (as a menu key equivalent), so it is swallowed.
  var showingEvent: TimeInterval?

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard event.type == .keyDown, window?.firstResponder === self, !event.modifierFlags.contains(.command) else {
      return super.performKeyEquivalent(with: event)
    }
    if event.timestamp != showingEvent { keyDown(with: event) }
    return true
  }
}
