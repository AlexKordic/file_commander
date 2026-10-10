import AppKit
import FCKit
import SwiftTerm

/// Runs Fresh's attach command in a terminal view in its own window. The
/// backend lives on in its own session; closing the window or pressing the
/// switch key detaches, just as the terminal interface does.
@MainActor
final class EditorController: NSObject, LocalProcessTerminalViewDelegate, NSWindowDelegate {
  private(set) var terminal: LocalProcessTerminalView?
  private(set) var window: NSWindow?
  private(set) var running = false
  private weak var app: AppController?
  private var monitor: Any?

  func attach(_ request: AttachRequest, app: AppController?) {
    self.app = app
    let window = self.window ?? makeWindow()
    guard let terminal else { return }
    if running {
      // Already attached: Fresh shows the newly opened files itself.
      window.makeKeyAndOrderFront(nil)
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
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(terminal)
  }

  func applyTheme() {
    guard let terminal, let app else { return }
    terminal.font = app.theme.nsFont("editor.terminal")
    terminal.nativeBackgroundColor = app.theme.nsColor("editor.background")
    terminal.nativeForegroundColor = app.theme.nsColor("editor.text")
  }

  /// Brings File Commander's window back to the front.
  func showFileCommander() {
    NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
    if let app { app.focusPane(app.engine.focusedSide) }
  }

  func detachAll() {
    if running, let terminal {
      kill(terminal.process.shellPid, SIGTERM)
    }
    running = false
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = "Editor — Fresh"
    window.identifier = NSUserInterfaceItemIdentifier("editor")
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.setFrameAutosaveName("FileCommanderEditor")
    if window.frame.origin == .zero { window.center() }
    let terminal = LocalProcessTerminalView(frame: window.contentView!.bounds)
    terminal.autoresizingMask = [.width, .height]
    terminal.processDelegate = self
    window.contentView = terminal
    self.window = window
    self.terminal = terminal
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      MainActor.assumeIsolated {
        guard let self, let app = self.app, event.window === self.window, let chord = KeyChord(event: event),
              chord.modifiers.contains(.command), app.keymap.command(for: chord) == "switch_to_file_commander" else { return event }
        // Fresh never sees Cmd chords, so the app detaches for it.
        self.detachAll()
        return nil
      }
    }
    return window
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
    window?.orderOut(nil)
    if let code, code != 0 { app?.engine.reportError("The editor exited with status \(code)") }
    showFileCommander()
  }

  // MARK: LocalProcessTerminalViewDelegate

  nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
  nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
    MainActor.assumeIsolated { window?.title = title.isEmpty ? "Editor — Fresh" : "\(title) — Fresh" }
  }
  nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
  nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
    MainActor.assumeIsolated { clientExited(code: exitCode) }
  }

  // MARK: NSWindowDelegate

  nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
    MainActor.assumeIsolated {
      detachAll()
      sender.orderOut(nil)
      showFileCommander()
    }
    return false
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
    guard let terminal, let window = terminal.window else { return nil }
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
