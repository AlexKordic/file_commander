import AppKit
import SwiftTerm

/// Runs `fc run <script>` (the terminal interface driven by a Lua script) in
/// a terminal window. Scripts keep working exactly as the scripting guide
/// describes; the window stays open afterwards to show the result.
@MainActor
final class ScriptWindow: NSObject, LocalProcessTerminalViewDelegate {
  private var window: NSWindow?
  private var terminal: LocalProcessTerminalView?
  private(set) var running = false
  private(set) var exitCode: Int32?

  func run(script: String, theme: ThemeStore) {
    let fc = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("fc").path
    guard FileManager.default.isExecutableFile(atPath: fc) else {
      let alert = NSAlert()
      alert.messageText = "The terminal interface isn't in this build"
      alert.informativeText = "Run Lua Script needs the fc program next to File Commander. Build the app with macos/build_app.sh."
      alert.runModal()
      return
    }
    let window = self.window ?? makeWindow()
    guard let terminal else { return }
    terminal.font = theme.nsFont("editor.terminal")
    terminal.nativeBackgroundColor = theme.nsColor("editor.background")
    terminal.nativeForegroundColor = theme.nsColor("editor.text")
    var environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
    environment.removeAll { $0.hasPrefix("TERM=") }
    environment += ["TERM=xterm-256color", "COLORTERM=truecolor"]
    let folder = (script as NSString).deletingLastPathComponent
    exitCode = nil
    running = true
    window.title = "Script — \((script as NSString).lastPathComponent)"
    terminal.startProcess(executable: fc, args: ["run", (script as NSString).lastPathComponent], environment: environment,
                          execName: nil, currentDirectory: folder)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(terminal)
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.identifier = NSUserInterfaceItemIdentifier("script")
    window.isReleasedWhenClosed = false
    window.center()
    let terminal = LocalProcessTerminalView(frame: window.contentView!.bounds)
    terminal.autoresizingMask = [.width, .height]
    terminal.processDelegate = self
    window.contentView = terminal
    self.window = window
    self.terminal = terminal
    return window
  }

  nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
  nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
  nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
  nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
    MainActor.assumeIsolated {
      running = false
      self.exitCode = exitCode
      window?.title += exitCode == 0 ? " — finished" : " — failed (exit \(exitCode ?? -1))"
    }
  }
}
