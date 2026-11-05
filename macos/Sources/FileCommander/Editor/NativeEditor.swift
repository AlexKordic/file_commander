import AppKit
import ExplainerKit
import FCKit
import FreshKit
import SwiftProtobuf

/// The native editor: Fresh's session drawn by the app, over the session's
/// scene channel. Fresh lays out and renders; this view draws the cells and
/// Fresh's chrome with native controls, puts Fresh's menus in the menu bar
/// while it is shown, and sends keys, mouse and menu choices back. It is shown
/// in the main window in place of the panes; switching back to the files hides
/// it and keeps the connection, so the next switch is instant.
@MainActor
final class NativeEditor: NSObject, CellGridDelegate {
  let store = SceneStore()
  private(set) var view: EditorHostView?
  var grid: CellGridView? { view?.grid }
  private var chrome: ChromeView? { view?.chrome }
  private var socket: SceneSocket?
  /// The scroll benchmark's stand-in for a slow app: extra main-thread time
  /// each frame takes.
  var benchFrameDelay: TimeInterval = 0
  /// The benchmark's watch for a frame that first shows some text: when one
  /// is applied, a `bench` record with `mark` notes when.
  var benchWatch: (text: String, mark: String)?
  /// The last `ack` of a frame's timing (telemetry on): how many of the
  /// messages sent Fresh had applied.
  private(set) var lastAck = 0
  private var ackWaiters: [UUID: (target: Int, continuation: CheckedContinuation<Bool, Never>)] = [:]
  private weak var app: AppController?
  private var menus: FreshMenus?
  private var clipboardSequence: Int?
  private var pendingShow = false
  private var menusWanted = false
  private var observers: [NSObjectProtocol] = []
  // Development gate until measured navigation, images and recovery pass the
  // plan's end-to-end checks. The shipped path remains the existing grid.
  private let richCompose = ProcessInfo.processInfo.environment["FC_NATIVE_RICH_COMPOSE"] == "1"
  private enum PendingInput {
    case message(SceneInput)
    case pointer(ComposePresentation.Identity, CGPoint, extend: Bool, count: Int)
  }
  private var composeQueue: [PendingInput] = []
  private var nextComposeID: UInt64 = 0
  private var pendingComposeID: UInt64?
  private var pendingComposePane: ComposePresentation.Identity?
  private var composeInFlight = false
  private var pendingComposeLayout = false
  private var pendingComposeY: CGFloat?
  private var pendingComposeRegion: UInt64?
  private var composeRegionSent = false

  /// Connected to the session's scene.
  var connected: Bool { socket?.isOpen == true }
  /// Shown in the main window.
  private(set) var shown = false
  /// Called when the editor wants to be shown (true) or hidden (false).
  var onPresent: ((Bool) -> Void)?
  /// Called with the active tab's name when it changes.
  var onTitle: ((String) -> Void)?

  override init() {
    super.init()
    store.onChange = { [weak self] change in self?.sceneChanged(change) }
    let center = NotificationCenter.default
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
        MainActor.assumeIsolated { self?.updateMenus() }
      })
    }
  }

  // MARK: Attaching

  /// Shows the editor for the session serving `path`, connecting first if needed.
  func attach(socketPath path: String, app: AppController?) {
    self.app = app
    if let socket, socket.isOpen, socket.path == path {
      Trace.write("editor: showing the connected editor")
      show()
      return
    }
    Trace.write("editor: connecting to \(path)")
    disconnect()
    let socket = SceneSocket(path: path)
    socket.onMessage = { [weak self] message in self?.received(message) }
    socket.onSent = { number, type, kind, bytes, at in
      var fields: [String: Any] = ["ev": "send", "t": EditorTelemetry.ms(at), "n": number, "type": type, "bytes": bytes]
      if let kind { fields["kind"] = kind }
      EditorTelemetry.shared.record(fields)
    }
    socket.onClose = { [weak self, weak socket] reason in
      guard let self, let socket, self.socket === socket else { return }
      self.connectionEnded(reason)
    }
    self.socket = socket
    pendingShow = true
    _ = makeView()
    applyTheme()
    Task.detached {
      do {
        try socket.open(telemetry: EditorTelemetry.shared.isOn, richCompose: self.richCompose)
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
          self.pendingShow = false
          Trace.write("editor: connect failed: \(error)")
          self.app?.engine.reportError("Can't connect to the editor: \(error)")
        }
      }
    }
  }

  func show() {
    pendingShow = false
    grid?.showingEvent = NSApp.currentEvent.flatMap { $0.type == .keyDown ? $0.timestamp : nil }
    shown = true
    onPresent?(true)
    updateMenus()
    Trace.write("editor: shown")
  }

  /// Shows the files again; the session stays connected.
  func switchBack() {
    pendingShow = false
    hide()
  }

  /// Disconnects and hides the editor. The session keeps running on its own.
  func detachAll() {
    pendingShow = false
    disconnect()
    hide()
  }

  private func hide() {
    guard shown else { return }
    shown = false
    onPresent?(false)
    updateMenus()
  }

  /// Gives the editor the keyboard, once its view is in the window.
  func focus() {
    defer { updateMenus() }
    guard shown, let grid, let window = grid.window, window.firstResponder !== grid else { return }
    window.makeFirstResponder(grid)
  }

  private func disconnect() {
    socket?.close()
    socket = nil
    composeQueue.removeAll()
    pendingComposeID = nil
    pendingComposePane = nil
    composeInFlight = false
    nextComposeID = 0
    pendingComposeLayout = false
    pendingComposeY = nil
    pendingComposeRegion = nil
    composeRegionSent = false
  }

  private func connectionEnded(_ reason: String?) {
    socket = nil
    hide()
    if let reason { Trace.write("editor connection ended: \(reason)") }
  }

  // MARK: View

  /// The editor's view, made once and kept.
  private func makeView() -> EditorHostView {
    if let view { return view }
    let view = EditorHostView(store: store) { [weak self] input in self?.sendFromPanel(input) }
    view.grid.delegate = self
    self.view = view
    let menus = FreshMenus(store: store) { [weak self] action, argsJson in self?.send(.action(name: action, argsJson: argsJson)) }
    menus.openSettings = { [weak self] in self?.app?.openSettings(tab: .editor) }
    menus.showFiles = { [weak self] in self?.switchBack() }
    self.menus = menus
    return view
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
    view?.applyLook(dark: theme.isDark)
    chrome?.themeChanged()
    grid.needsDisplay = true
  }

  // MARK: Scene

  private func received(_ message: SceneMessage) {
    let started = ProcessInfo.processInfo.systemUptime
    store.apply(message)
    if benchFrameDelay > 0 { Thread.sleep(forTimeInterval: benchFrameDelay) }
    // Fresh sends only a couple of frames ahead of what was applied, so a slow
    // moment here gets the newest scene next rather than every one in between.
    if message.isHello { lastAck = 0 }
    socket?.send(.applied(seq: UInt64(message.sequence)))
    if message.frame.hasInputReply, message.frame.inputReply.id == pendingComposeID {
      composeInFlight = false
      let reply = message.frame.inputReply
      if reply.accepted {
        let identity: ComposePresentation.Identity?
        if case .pointer(let target, _, _, _) = composeQueue.first { identity = target }
        else { identity = pendingComposePane }
        grid?.applyComposeCarets(reply.carets, identity: identity)
        if !composeQueue.isEmpty { composeQueue.removeFirst() }
        pendingComposeID = nil
        pendingComposePane = nil
        pendingComposeLayout = false
        pendingComposeY = nil
        pendingComposeRegion = nil
      } else if reply.needsLayout {
        pendingComposeLayout = true
        if composeRegionSent { pendingComposeRegion = nil; pendingComposeY = nil }
        if reply.hasNeedY { pendingComposeY = CGFloat(reply.needY) }
        if reply.hasNeedRegion, let identity = pendingComposePane, let pane = grid?.composePanes[identity.leaf] {
          let requested = reply.needRegion
          let projection = pane.layout.text.projection.source
          if let source = Int(exactly: requested), source >= projection.lowerBound,
             source < projection.upperBound || (source == projection.upperBound && requested == pane.pane.compose.documentLen) {
            pendingComposeY = pane.layout.text.caret(for: source)?.midY
          } else {
            pendingComposeRegion = requested
            pendingComposeY = nil
          }
        }
      }
      composeRegionSent = false
    }
    pumpComposeInput()
    if let ack = message.timing?.ack { noteAck(ack) }
    if let watch = benchWatch, store.lines.contains(where: { $0.contains(watch.text) }) {
      benchWatch = nil
      EditorTelemetry.shared.record(["ev": "bench", "mark": watch.mark, "t": EditorTelemetry.ms(started)])
    }
    guard EditorTelemetry.shared.isOn else { return }
    grid?.shownSequence = message.sequence
    var fields: [String: Any] = [
      "ev": "frame", "t": EditorTelemetry.ms(message.receivedAt), "seq": message.sequence, "bytes": message.bytes,
      "parse": EditorTelemetry.ms(message.parseSeconds), "applied": EditorTelemetry.ms(started),
      "apply": EditorTelemetry.ms(ProcessInfo.processInfo.systemUptime - started), "rows": message.gridRows.count,
      "copied": message.gridCopies.reduce(0) { $0 + $1.count }, "appcpu": EditorTelemetry.processCPU(),
    ]
    if let timing = message.timing {
      fields["ack"] = timing.ack
      fields["build"] = timing.buildMs
      fields["render"] = timing.renderMs
      fields["grid"] = timing.gridMs
      fields["diff"] = timing.diffMs
      fields["queued"] = timing.queued
      fields["ahead"] = timing.ahead
      fields["owed"] = timing.owed
      fields["top"] = timing.top
      fields["cpu"] = timing.cpuMs
      if let allocs = timing.prevAllocs { fields["pallocs"] = allocs }
      if let bytes = timing.prevAllocBytes { fields["pbytes"] = bytes }
    }
    EditorTelemetry.shared.record(fields)
  }

  /// Messages sent to Fresh so far.
  var requestedMessages: Int { socket?.requested ?? 0 }

  /// Waits until a frame shows every message up to `target` (telemetry on),
  /// or `timeout` passes; true for a frame.
  func waitForAck(_ target: Int, timeout: TimeInterval) async -> Bool {
    if lastAck >= target { return true }
    let id = UUID()
    return await withCheckedContinuation { continuation in
      ackWaiters[id] = (target, continuation)
      DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
        MainActor.assumeIsolated { self?.ackWaiters.removeValue(forKey: id)?.continuation.resume(returning: false) }
      }
    }
  }

  private func noteAck(_ ack: Int) {
    lastAck = ack
    for (id, waiter) in ackWaiters where waiter.target <= ack {
      ackWaiters.removeValue(forKey: id)
      waiter.continuation.resume(returning: true)
    }
  }

  /// Asks Fresh for frame timing, or to stop sending it, after the setting changed.
  func telemetryChanged() {
    socket?.send(.configure(telemetry: EditorTelemetry.shared.isOn))
  }

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

  /// The active tab of the focused pane, for the window title.
  private func updateTitle() {
    let active = store.panes.lazy.compactMap { $0.tabBar.tabs.first(where: \.active)?.label }.first
    grid?.title = active ?? "Editor"
    onTitle?(active ?? "")
  }

  // MARK: CellGridDelegate

  func grid(_ grid: CellGridView, send input: SceneInput) { send(input) }

  func grid(_ grid: CellGridView, point: CGPoint, in pane: ComposePresentation, extend: Bool, count: Int) {
    composeQueue.append(.pointer(pane.identity, point, extend: extend, count: count))
    pumpComposeInput()
  }

  func gridDidResize(_ grid: CellGridView, columns: Int, rows: Int) {
    socket?.send(.resize(cols: columns, rows: rows))
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
    send(.paste(text))
  }

  var optionAsAlt: Bool { app?.preferences.optionAsAlt ?? false }

  // MARK: Menus

  /// Fresh's menus are in the menu bar while the editor is shown in the key window.
  private func updateMenus() {
    let wanted = shown && view?.window?.isKeyWindow == true
    grid?.needsDisplay = true  // The caret shows whether the editor has the keyboard.
    guard wanted != menusWanted else { return }
    menusWanted = wanted
    Trace.write(wanted ? "menus: Fresh's" : "menus: the app's")
    if wanted {
      app?.menusHeld = true
      menus?.install()
      applyTheme()  // picks up font changes made in Settings meanwhile
    } else {
      menus?.uninstall()
      app?.menusHeld = false
    }
  }

  // MARK: Explainer access

  var screenLines: [String] { store.lines }

  func screenRect(row: Int, col: Int, count: Int) -> CGRect? {
    guard shown, let grid, let window = grid.window else { return nil }
    return window.convertToScreen(grid.convert(grid.rect(column: col, row: row, count: count), to: nil))
  }

  func send(_ input: SceneInput) {
    guard richCompose else { socket?.send(input); return }
    // A modal that appeared while navigation awaited geometry must remain
    // usable. Its ordinary input does not replace the deferred document action.
    if pendingComposeLayout, let identity = pendingComposePane {
      let pane = grid?.composePanes[identity.leaf]
      if pane?.identity != identity || pane?.pane.compose.keyboard != true {
        socket?.send(input)
        return
      }
    }
    switch input {
    case .key, .mouse, .paste, .action, .widget, .settingsClick, .kbEditClick:
      composeQueue.append(.message(input))
      pumpComposeInput()
    default:
      socket?.send(input)
    }
  }

  /// Send one event, wait for its scene/reply, then bind the next event to the
  /// resulting source map. A stale event keeps its id and is measured again.
  private func pumpComposeInput() {
    guard let socket, socket.isOpen, !composeInFlight, let queued = composeQueue.first else { return }
    if pendingComposeID == nil {
      nextComposeID += 1
      pendingComposeID = nextComposeID
      if case .message(let input) = queued {
        switch input {
        case .key, .paste, .action:
          pendingComposePane = grid?.focusedCompose.flatMap { $0.pane.compose.keyboard ? $0.identity : nil }
        default: break
        }
      }
    }
    var input = WireComposeInput()
    input.id = pendingComposeID ?? 0
    switch queued {
    case .message(let message):
      input.kind = UInt32(message.kind.rawValue)
      input.payload = Data(message.payload())
      if let identity = pendingComposePane {
        guard let pane = grid?.composePanes[identity.leaf], pane.identity == identity else { return }
        if pane.pane.compose.keyboard {
          input.scope = pane.scope
          if let region = pendingComposeRegion {
            input.region = region
            composeRegionSent = true
          } else {
            let layout = pendingComposeLayout ? pane.measuredNavigation(aroundY: pendingComposeY) : pane.navigation
            input.layoutID = layout?.id ?? 0
            if pendingComposeLayout {
              guard let layout else { return }
              input.layout = layout
            }
          }
        } else {
          if pendingComposeLayout { return }
          pendingComposePane = nil
        }
      }
    case .pointer(let identity, let location, let extend, let count):
      guard let pane = grid?.composePanes[identity.leaf], pane.identity == identity,
            let hit = pane.hit(at: location) else { return }
      input.scope = pane.scope
      input.position = UInt64(hit.source)
      input.affinity = hit.affinity == .upstream ? 1 : 0
      input.extend = extend
      input.clickCount = UInt32(clamping: count)
    }
    composeInFlight = true
    socket.send(.composeInput(input))
  }

  /// A click on a native panel: sent to Fresh, and the keyboard stays with the editor.
  private func sendFromPanel(_ input: SceneInput) {
    send(input)
    focus()
  }

  /// The cells a native surface covers: "tabs", "status", "palette", "popup" or "explorer".
  func surfaceCells(_ surface: String) -> [CellRect] {
    switch surface {
    case "tabs": return store.panes.filter(\.tabBar.hasBar).map { CellRect($0.tabBar.bar) }
    case "status": return store.statusBar.map { [CellRect($0.rect)] } ?? []
    case "palette":
      guard let palette = store.palette else { return [] }
      return [CellRect(palette.hasOuterRect ? palette.outerRect : palette.listRect)]
    case "popup": return store.popups.map { CellRect($0.rect) }
    case "explorer": return store.fileExplorer.map { [CellRect($0.rect)] } ?? []
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
