import AppKit
import ExplainerKit
import FCKit
import FreshKit

/// The editor window: Fresh's session drawn natively, over the session's scene
/// channel. Fresh lays out and renders; this window draws the cells and Fresh's
/// chrome with native controls, shows Fresh's menus in the menu bar, and sends
/// keys, mouse and menu choices back. Switching back to File Commander hides
/// the window and keeps the connection, so the next switch is instant.
@MainActor
final class NativeEditor: NSObject, NSWindowDelegate, CellGridDelegate {
  let store = SceneStore()
  private(set) var window: NSWindow?
  private(set) var grid: CellGridView?
  private var chrome: ChromeView?
  private var socket: SceneSocket?
  private weak var app: AppController?
  private var menus: FreshMenus?
  private var clipboardSequence: Int?
  private var pendingShow = false

  /// Connected to the session's scene.
  var connected: Bool { socket?.isOpen == true }
  /// The window is on screen.
  var visible: Bool { window?.isVisible == true }

  override init() {
    super.init()
    store.onChange = { [weak self] change in self?.sceneChanged(change) }
  }

  // MARK: Attaching

  /// Shows the editor for the session serving `path`, connecting first if needed.
  func attach(socketPath path: String, app: AppController?) {
    self.app = app
    if let socket, socket.isOpen, socket.path == path {
      Trace.write("editor: showing the connected window")
      show()
      return
    }
    Trace.write("editor: connecting to \(path)")
    disconnect()
    let socket = SceneSocket(path: path)
    socket.onMessage = { [weak self] message in self?.store.apply(message) }
    socket.onClose = { [weak self, weak socket] reason in
      guard let self, let socket, self.socket === socket else { return }
      self.connectionEnded(reason)
    }
    self.socket = socket
    pendingShow = true
    let window = self.window ?? makeWindow()
    applyTheme()
    Task.detached {
      do {
        try socket.open(query: "?grid=1&menus=native")
        await MainActor.run { [weak self] in
          Trace.write("editor: connected")
          guard let self, self.socket === socket else { return }
          self.grid?.resendSize()
          if self.pendingShow { self.show() }
        }
      } catch {
        await MainActor.run { [weak self] in
          guard let self, self.socket === socket else { return }
          self.socket = nil
          window.orderOut(nil)
          Trace.write("editor: connect failed: \(error)")
          self.app?.engine.reportError("Can't connect to the editor: \(error)")
        }
      }
    }
  }

  func show() {
    pendingShow = false
    guard let window else { return }
    grid?.showingEvent = NSApp.currentEvent.flatMap { $0.type == .keyDown ? $0.timestamp : nil }
    window.makeKeyAndOrderFront(nil)
    if let grid { window.makeFirstResponder(grid) }
    Trace.write("editor: shown, visible \(window.isVisible) key \(window.isKeyWindow)")
  }

  /// Hides the window and brings File Commander back; the session stays connected.
  func switchBack() {
    pendingShow = false
    window?.orderOut(nil)
    showFileCommander()
  }

  /// Disconnects and hides the window. The session keeps running on its own.
  func detachAll() {
    pendingShow = false
    disconnect()
    window?.orderOut(nil)
  }

  private func disconnect() {
    socket?.close()
    socket = nil
  }

  private func connectionEnded(_ reason: String?) {
    socket = nil
    let wasVisible = visible
    window?.orderOut(nil)
    if wasVisible { showFileCommander() }
    if let reason { Trace.write("editor connection ended: \(reason)") }
  }

  private func showFileCommander() {
    NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
    if let app { app.focusPane(app.engine.focusedSide) }
  }

  // MARK: Window

  private func makeWindow() -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = "Editor"
    window.identifier = NSUserInterfaceItemIdentifier("editor")
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.tabbingMode = .disallowed
    window.setFrameAutosaveName("FileCommanderNativeEditor")
    if window.frame.origin == .zero { window.center() }
    let content = NSView(frame: window.contentView!.bounds)
    content.autoresizingMask = [.width, .height]
    let grid = CellGridView(store: store)
    grid.frame = content.bounds
    grid.autoresizingMask = [.width, .height]
    grid.delegate = self
    content.addSubview(grid)
    let chrome = ChromeView(store: store, grid: grid)
    chrome.frame = content.bounds
    chrome.autoresizingMask = [.width, .height]
    content.addSubview(chrome)
    window.contentView = content
    window.initialFirstResponder = grid
    self.window = window
    self.grid = grid
    self.chrome = chrome
    let menus = FreshMenus(store: store) { [weak self] action, args in self?.runAction(action, args: args) }
    menus.openSettings = { [weak self] in self?.app?.openSettings(tab: .editor) }
    menus.switchBack = { [weak self] in self?.switchBack() }
    self.menus = menus
    return window
  }

  /// Fonts and colors: the text font is the theme's editor font; colors come
  /// from Fresh's theme, so the cells and the chrome match the user's Fresh.
  func applyTheme() {
    guard let grid, let app else { return }
    grid.setFont(app.theme.nsFont("editor.terminal"))
    let theme = store.theme
    grid.defaultBackground = theme.background.map(NSColor.init(scene:)) ?? app.theme.nsColor("editor.background")
    grid.defaultForeground = theme.foreground.map(NSColor.init(scene:)) ?? app.theme.nsColor("editor.text")
    grid.caretColor = theme.accent.map(NSColor.init(scene:)) ?? .controlAccentColor
    window?.backgroundColor = grid.defaultBackground
    window?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
    chrome?.themeChanged()
    grid.needsDisplay = true
  }

  // MARK: Scene

  private func sceneChanged(_ change: SceneChange) {
    if change.themeChanged { applyTheme() }
    grid?.apply(change)
    chrome?.apply(change)
    if change.regions.contains("panes") || change.isHello { updateTitle() }
    if change.regions.contains("menus") { menus?.menusChanged() }
    if let copy = store.clipboard, copy.sequence != clipboardSequence {
      // The hello reports the editor's last copy; only later copies reach the pasteboard.
      if clipboardSequence != nil || !change.isHello {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copy.text, forType: .string)
      }
      clipboardSequence = copy.sequence
    } else if change.isHello && clipboardSequence == nil {
      clipboardSequence = store.clipboard?.sequence ?? 0
    }
  }

  /// "name — Editor", from the active tab of the focused pane.
  private func updateTitle() {
    let active = store.panes.compactMap { pane -> String? in
      (pane["tabs"] as? [[String: Any]])?.first { $0["active"] as? Bool == true }?["label"] as? String
    }.first
    window?.title = active.map { "\($0) — Editor" } ?? "Editor"
  }

  private func runAction(_ action: String, args: [String: Any]) {
    var message: [String: Any] = ["type": "action", "action": action]
    if !args.isEmpty { message["args"] = args }
    socket?.send(message)
  }

  // MARK: CellGridDelegate

  func grid(_ grid: CellGridView, send message: [String: Any]) { socket?.send(message) }

  func gridDidResize(_ grid: CellGridView, columns: Int, rows: Int) {
    socket?.send(["type": "resize", "cols": columns, "rows": rows])
  }

  func grid(_ grid: CellGridView, handleAppChord event: NSEvent) -> Bool {
    guard let app, let chord = KeyChord(event: event) else { return false }
    if app.keymap.command(for: chord) == "switch_to_file_commander" {
      switchBack()
      return true
    }
    return false
  }

  func gridPaste(_ grid: CellGridView) {
    guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
    socket?.send(["type": "paste", "text": text])
  }

  var optionAsAlt: Bool { app?.preferences.optionAsAlt ?? false }

  // MARK: NSWindowDelegate

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    switchBack()
    return false
  }

  func windowDidBecomeKey(_ notification: Notification) { menus?.install() }
  func windowDidResignKey(_ notification: Notification) {
    menus?.uninstall()
    grid?.needsDisplay = true
  }

  // MARK: Explainer access

  var screenLines: [String] { store.lines }

  func screenRect(row: Int, col: Int, count: Int) -> CGRect? {
    guard let grid, let window = grid.window else { return nil }
    return window.convertToScreen(grid.convert(grid.rect(column: col, row: row, count: count), to: nil))
  }

  func send(_ message: [String: Any]) { socket?.send(message) }

  /// The cells a native surface covers: "tabs", "status", "palette", "popup" or "explorer".
  func surfaceCells(_ surface: String) -> [CellRect] {
    let regions = store.regions
    switch surface {
    case "tabs": return store.panes.compactMap { CellRect($0["tabBar"]) }
    case "status": return [CellRect((regions["statusbar"] as? [String: Any])?["rect"])].compactMap { $0 }
    case "palette":
      let palette = regions["palette"] as? [String: Any]
      return [CellRect(palette?["outerRect"]) ?? CellRect(palette?["listRect"])].compactMap { $0 }
    case "popup": return (regions["popups"] as? [[String: Any]] ?? []).compactMap { CellRect($0["rect"]) }
    case "explorer": return [CellRect((regions["fileExplorer"] as? [String: Any])?["rect"])].compactMap { $0 }
    default: return []
    }
  }

  /// The screen rectangle around a native surface, for explainer highlights.
  func surfaceRect(_ surface: String) -> CGRect? {
    let rects = surfaceCells(surface).compactMap { cells -> CGRect? in
      guard let row = screenRect(row: cells.y, col: cells.x, count: cells.width) else { return nil }
      let height = row.height * CGFloat(cells.height)
      return CGRect(x: row.minX, y: row.maxY - height, width: row.width, height: height)
    }
    guard let first = rects.first else { return nil }
    return rects.dropFirst().reduce(first) { $0.union($1) }
  }
}
