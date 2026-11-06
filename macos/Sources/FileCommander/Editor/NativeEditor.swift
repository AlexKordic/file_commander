import AppKit
import ExplainerKit
import FCKit
import FreshKit
import SwiftProtobuf

/// Clipboard access is injectable so socket/input tests do not depend on, or
/// overwrite, the logged-in user's pasteboard.
@MainActor
protocol EditorPasteboard {
  var editorText: String? { get }
  func replaceEditorText(_ text: String)
}

extension NSPasteboard: EditorPasteboard {
  var editorText: String? { string(forType: .string) }
  func replaceEditorText(_ text: String) {
    clearContents()
    setString(text, forType: .string)
  }
}

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
  private let pasteboard: any EditorPasteboard
  private var pendingShow = false
  private var receivedHello = false
  private var menusWanted = false
  private var observers: [NSObjectProtocol] = []
  // Development gate until measured navigation, images and recovery pass the
  // plan's end-to-end checks. The shipped path remains the existing grid.
  private let richCompose, measuredTables: Bool
  private enum PendingInput {
    case message(SceneInput)
    case pointer(ComposePointer)
    case replacement(ComposeReplacement)
    case pendingText(ComposePendingText)
    case pendingPointer(ComposePendingPointer, after: UUID)
  }
  private struct InputTarget {
    var identity: ComposePresentation.Identity
    var scope: WireComposeScope
    var epoch: UInt64
    @MainActor init(_ pane: ComposePresentation) {
      identity = pane.identity; scope = pane.scope; epoch = pane.pane.compose.viewport.epoch
    }
  }
  private struct CompositionChain {
    let predecessor: UUID
    let initial, text: ComposePendingText
    let afterAction: Bool
  }
  private struct QueuedInput {
    let token = UUID()
    var input: PendingInput
    var scrollGeneration: UInt64
    var target: InputTarget?
    var chain: CompositionChain?
    var preview: ComposePendingText?
    var snapshot: ComposePresentation?
    var pointerPreview: ComposePointer.Preview?
    var virtualPrefix: ComposeVirtualSelections?
  }
  private var composeQueue: [QueuedInput] = []
  private var nextComposeID: UInt64 = 0
  private var pendingComposeID: UInt64?
  private var pendingComposePane: ComposePresentation.Identity?
  private var composeInFlight = false
  private var completingComposeInput = false
  private var pendingComposeLayout = false
  private var pendingComposeY: CGFloat?
  private var pendingComposeRegion: UInt64?
  private var composeRegionSent = false
  private var pendingComposeProjection: WireComposePane?
  private var pendingComposeBefore: (revision: UInt64, cursors: [WireComposeSelection])?
  private var viewportRefreshQueued = false
  private var lastComposeCancellation: String?
  private(set) var uninsertedText: [String] = [] { didSet { onUninsertedTextChanged?(!uninsertedText.isEmpty) } }
  var onUninsertedTextChanged: ((Bool) -> Void)?
  private var pendingCaretReveal: (target: InputTarget, scrollGeneration: UInt64)?
  private struct FormattingFailure: Equatable {
    var window, buffer, epoch: UInt64
    var message: String
  }
  private var formattingFailures: [UInt64: FormattingFailure] = [:]
  private lazy var composeViewports = ComposeViewportController { [weak self] request in
    self?.socket?.send(.composeViewport(request))
  }
  private lazy var composeImages = ComposeImageController { [weak self] request in
    self?.socket?.send(.composeAsset(request))
  }

  /// Connected to the session's scene.
  var connected: Bool { receivedHello && socket?.isOpen == true }
  /// Shown in the main window.
  private(set) var shown = false
  /// Called when the editor wants to be shown (true) or hidden (false).
  var onPresent: ((Bool) -> Void)?
  /// Called with the active tab's name when it changes.
  var onTitle: ((String) -> Void)?

  override convenience init() { self.init(pasteboard: NSPasteboard.general) }

  init(pasteboard: any EditorPasteboard, environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.pasteboard = pasteboard
    richCompose = environment["FC_NATIVE_RICH_COMPOSE"] == "1"
    measuredTables = richCompose && environment["FC_NATIVE_MEASURED_TABLES"] == "1"
    super.init()
    composeImages.onChange = { [weak self] in
      self?.grid?.refreshComposeImages(geometryChanged: true)
      self?.updateImageDemands()
      self?.scheduleViewportContinuation()
    }
    composeViewports.onChange = { [weak self] in
      self?.grid?.refreshComposeImages()
      self?.updateImageDemands()
      self?.scheduleViewportContinuation()
    }
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
    hide()
    let socket = SceneSocket(path: path)
    socket.onMessage = { [weak self, weak socket] message in
      guard let self, let socket, self.socket === socket else { return }
      self.received(message)
    }
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
        try socket.open(telemetry: EditorTelemetry.shared.isOn, richCompose: self.richCompose, measuredTables: self.measuredTables, paragraphWindows: self.richCompose)
        await MainActor.run { [weak self] in
          Trace.write("editor: connected")
          guard let self, self.socket === socket else { return }
          self.grid?.resendSize()
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
    guard receivedHello else { pendingShow = true; return }
    pendingShow = false
    grid?.showingEvent = NSApp.currentEvent.flatMap { $0.type == .keyDown ? $0.timestamp : nil }
    shown = true
    updateImageDemands(revalidate: true)
    scheduleViewportContinuation()
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
    grid?.finishComposition()
    shown = false
    composeImages.update([])
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
    recoverPendingText()
    composeImages.reset()
    composeViewports.reset()
    socket?.close()
    socket = nil
    receivedHello = false
    composeQueue.removeAll()
    pendingComposeID = nil
    pendingComposePane = nil
    composeInFlight = false
    nextComposeID = 0
    pendingComposeLayout = false
    pendingComposeY = nil
    pendingComposeRegion = nil
    composeRegionSent = false
    pendingComposeProjection = nil
    pendingComposeBefore = nil
    lastComposeCancellation = nil
    pendingCaretReveal = nil
    formattingFailures.removeAll()
    grid?.invalidateAccessibleImages()
  }

  private func connectionEnded(_ reason: String?) {
    recoverPendingText()
    composeImages.reset()
    composeViewports.reset()
    socket = nil
    receivedHello = false
    grid?.invalidateAccessibleImages()
    hide()
    if let reason { Trace.write("editor connection ended: \(reason)") }
  }

  // MARK: View

  /// The editor's view, made once and kept.
  private func makeView() -> EditorHostView {
    if let view { return view }
    let view = EditorHostView(store: store) { [weak self] input in self?.sendFromPanel(input) }
    view.grid.delegate = self
    view.grid.composeImageController = composeImages
    view.grid.composeViewportController = composeViewports
    self.view = view
    let menus = FreshMenus(store: store) { [weak self] action, argsJson in self?.send(.action(name: action, argsJson: argsJson)) }
    menus.openSettings = { [weak self] in self?.app?.openSettings(tab: .editor) }
    menus.showFiles = { [weak self] in self?.switchBack() }
    menus.hasUninsertedText = { [weak self] in self?.uninsertedText.isEmpty == false }
    menus.copyUninsertedText = { [weak self] in self?.copyUninsertedText() }
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
    grid.composePalette = .init(link: grid.caretColor.cgColor,
      quote: (theme.muted.map(NSColor.init(scene:)) ?? grid.defaultForeground.withAlphaComponent(0.75)).cgColor,
      code: grid.defaultForeground.cgColor, codeBackground: grid.defaultForeground.withAlphaComponent(0.07).cgColor)
    grid.setComposePreferences(app.preferences.compose, zoom: app.preferences.zoom)
    view?.applyLook(dark: theme.isDark)
    chrome?.themeChanged()
    grid.needsDisplay = true
    updateImageDemands()
    scheduleViewportContinuation()
  }

  // MARK: Scene

  private func received(_ message: SceneMessage) {
    let started = ProcessInfo.processInfo.systemUptime
    if message.isHello { receivedHello = true }
    var acceptedSource: WireComposeEditReceipt?
    if message.frame.hasInputReply, message.frame.inputReply.id == pendingComposeID,
       message.frame.inputReply.accepted, let target = composeQueue.first?.target {
      let reply = message.frame.inputReply
      let window = message.frame.hasWindowID ? message.frame.windowID : UInt64(store.windowID)
      acceptedSource = [reply.hasEdit ? reply.edit : nil, reply.hasResult ? reply.result : nil].compactMap { $0 }.first {
        $0.window == window && $0.matches(target.scope, epoch: target.epoch, notBefore: store.composeAcceptances[$0.leaf])
      }
    }
    store.apply(message, acceptedCompose: acceptedSource)
    reportFormattingFailures()
    composeViewports.observe(window: UInt64(store.windowID), panes: store.panes,
      reply: message.frame.hasViewportReply ? message.frame.viewportReply : nil)
    if message.isHello, pendingShow { show() }
    composeImages.receive(message.frame.composeAssets)
    if benchFrameDelay > 0 { Thread.sleep(forTimeInterval: benchFrameDelay) }
    // Fresh sends only a couple of frames ahead of what was applied, so a slow
    // moment here gets the newest scene next rather than every one in between.
    if message.isHello { lastAck = 0 }
    socket?.send(.applied(seq: UInt64(message.sequence)))
    if message.frame.hasInputReply, message.frame.inputReply.id == pendingComposeID {
      composeInFlight = false
      completingComposeInput = true
      defer { completingComposeInput = false }
      let reply = message.frame.inputReply
      if reply.accepted || reply.cancelled {
        let identity = pendingComposePane
        if reply.accepted { grid?.applyComposeCarets(reply.carets, identity: identity) }
        if reply.accepted, let identity, let queued = composeQueue.first, let target = queued.target,
           queued.scrollGeneration == composeViewports.userScrollGeneration,
           let before = pendingComposeBefore,
           let pane = store.panes.first(where: { $0.leaf == identity.leaf && $0.hasBuffer && $0.buffer == identity.buffer && $0.hasCompose }),
           before.revision != pane.compose.bufferRevision || before.cursors != pane.compose.cursors {
          pendingCaretReveal = (target, queued.scrollGeneration)
        }
        if reply.cancelled, !reply.error.isEmpty, lastComposeCancellation != reply.error {
          lastComposeCancellation = reply.error
          app?.engine.reportError(reply.error)
          Trace.write("editor input cancelled: \(reply.error)")
        } else if reply.accepted { lastComposeCancellation = nil }
        if reply.cancelled, let first = composeQueue.first, let grid {
          if let preview = first.preview { for text in preview.recoveryTexts { self.grid(grid, recover: text) } }
          else if case .replacement(let replacement) = first.input { for text in replacement.texts { self.grid(grid, recover: text) } }
        }
        resolveCompositionChains(edit: reply.accepted && reply.hasEdit ? reply.edit : nil,
          result: reply.accepted && reply.hasResult ? reply.result : nil)
        if !composeQueue.isEmpty { composeQueue.removeFirst() }
        grid?.refreshComposeImages()
        pendingComposeID = nil
        pendingComposePane = nil
        pendingComposeLayout = false
        pendingComposeY = nil
        pendingComposeRegion = nil
        pendingComposeProjection = nil
        pendingComposeBefore = nil
      } else if reply.needsLayout {
        if reply.hasCompose { pendingComposeProjection = reply.compose }
        pendingComposeLayout = true
        if composeRegionSent { pendingComposeRegion = nil; pendingComposeY = nil }
        if reply.hasNeedY { pendingComposeY = CGFloat(reply.needY) }
        if reply.hasNeedRegion, let identity = pendingComposePane,
           let pane = pendingComposeProjection.flatMap({ grid?.composeMeasurement(identity: identity, projection: $0) }) ?? grid?.composePanes[identity.leaf] {
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
    attemptCaretReveal()
    pumpComposeInput()
    scheduleViewportContinuation()
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
        pasteboard.replaceEditorText(copy.text)
      }
      clipboardSequence = copy.sequence
    } else if change.isHello && clipboardSequence == nil {
      clipboardSequence = store.clipboard?.sequence ?? 0
    }
    updateImageDemands()
  }

  private func updateImageDemands(revalidate: Bool = false) {
    let demands = shown && richCompose ? grid?.composeImageDemands() ?? [] : []
    composeImages.update(demands.filter { demand in
      store.panes.contains { pane in pane.leaf == demand.scope.leaf && pane.hasBuffer && pane.buffer == demand.scope.buffer
        && pane.hasCompose && pane.compose.projectionUsable && pane.compose.bufferRevision == demand.scope.bufferRevision }
    }, revalidate: revalidate)
  }

  private func reportFormattingFailures() {
    let leaves = Set(store.panes.map(\.leaf))
    formattingFailures = formattingFailures.filter { leaves.contains($0.key) }
    for pane in store.panes where pane.hasCompose && pane.compose.formattingReady {
      guard !pane.compose.error.isEmpty else { formattingFailures.removeValue(forKey: pane.leaf); continue }
      let failure = FormattingFailure(window: UInt64(store.windowID), buffer: pane.buffer,
        epoch: pane.compose.viewport.epoch, message: pane.compose.error)
      if formattingFailures[pane.leaf] != failure {
        formattingFailures[pane.leaf] = failure
        app?.engine.reportError(failure.message)
        Trace.write("editor formatting unavailable: \(failure.message)")
      }
    }
  }

  /// A source window can finish before the bottom of a tall pane. Fetch its
  /// adjacent window without redrawing a guessed height or recursive reflow.
  private func scheduleViewportContinuation() {
    guard richCompose, receivedHello, !viewportRefreshQueued else { return }
    viewportRefreshQueued = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.viewportRefreshQueued = false
      guard self.receivedHello, self.shown else { return }
      // Completed formatting may still replace retained decorations and change
      // the measured height. Do not page merely to fill that provisional gap.
      // Current-source projections remain available for input and drawing.
      for pane in self.grid?.composePanes.values.map({ $0 }) ?? [] where pane.pane.compose.hasViewport && pane.pane.compose.formattingReady {
        if let next = pane.scrolling.continuation(pane.viewport) {
          self.composeViewports.move(scope: pane.scope, from: pane.viewport, to: next, user: false)
        }
      }
    }
  }

  private func revealComposeCaret(_ pane: ComposePresentation) {
    guard pane.pane.compose.hasViewport, let cursor = pane.cursor else { return }
    let next: WireComposeViewport?
    if let rect = pane.caret {
      next = pane.scrolling.revealing(caret: rect.offsetBy(dx: -pane.origin.x, dy: -pane.origin.y), from: pane.viewport)
    } else {
      next = pane.scrolling.revealing(cursor.position, affinity: pane.cursorAffinity, from: pane.viewport)
    }
    if let next {
      composeViewports.move(scope: pane.scope, from: pane.viewport, to: next, user: false)
    }
  }

  private func attemptCaretReveal() {
    guard let pending = pendingCaretReveal else { return }
    let identity = pending.target.identity
    guard pending.scrollGeneration == composeViewports.userScrollGeneration,
          identity.window == UInt64(store.windowID),
          let current = store.panes.first(where: { $0.leaf == identity.leaf && $0.hasBuffer && $0.buffer == identity.buffer && $0.hasCompose }),
          current.compose.viewport.epoch == pending.target.epoch else { pendingCaretReveal = nil; return }
    guard current.compose.projectionUsable, let pane = grid?.composePanes[identity.leaf], pane.identity == identity,
          pane.pane.compose.bufferRevision == current.compose.bufferRevision else { return }
    pendingCaretReveal = nil
    revealComposeCaret(pane)
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
    guard receivedHello, let hit = pane.hit(at: point) else { return }
    if let displayed = pane.layout.composition,
       let position = pane.layout.text.hitUTF16(at: CGPoint(x: point.x - pane.origin.x, y: point.y - pane.origin.y)),
       pane.layout.containsProvisionalRegion(displayPosition: position),
       let unit = pane.layout.provisionalDocumentPosition(position) {
      guard let pending = self.grid(grid, pendingTextFor: pane.pane), let text = pending.text,
            let basis = text.provisionalSelections(over: pending.virtualPrefix, pane: pending.target.pane.compose),
            let capture = text.pointer(scope: pane.scope, epoch: pane.pane.compose.viewport.epoch, displayed: displayed,
              point: unit, basis: basis, affinity: hit.affinity, extend: extend, count: count,
              nativeNewline: pane.pane.compose.nativeNewline) else {
        reportPendingPointerCancellation(); return
      }
      enqueueCompose(.pendingPointer(capture, after: pending.prefixToken ?? pending.token), target: pane)
      return
    }
    guard let pointer = ComposePointer(scope: pane.scope, epoch: pane.pane.compose.viewport.epoch, hit: hit, extend: extend, count: count) else { return }
    let predictable = pane.layout.composition == nil && composeQueue.allSatisfy {
      $0.pointerPreview != nil && $0.target?.identity == pane.identity
        && $0.target?.epoch == pane.pane.compose.viewport.epoch && $0.target?.scope.bufferRevision == pane.scope.bufferRevision
    }
    enqueueCompose(.pointer(pointer), target: pane, pointerPreview: predictable ? pointer.preview(in: pane.pane.compose) : nil)
  }

  func grid(_ grid: CellGridView, scroll delta: CGPoint, in pane: ComposePresentation) {
    guard receivedHello, let next = pane.scrolling.moved(pane.viewport, by: delta.y, horizontally: delta.x,
      fallback: pane.bounds.minY + 12 - pane.origin.y) else { return }
    composeViewports.move(scope: pane.scope, from: pane.viewport, to: next, user: true)
  }

  func grid(_ grid: CellGridView, revealCaretIn pane: ComposePresentation) {
    guard receivedHello else { return }
    revealComposeCaret(pane)
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
    guard let text = pasteboard.editorText, !text.isEmpty else { return }
    send(.paste(text))
  }

  func grid(_ grid: CellGridView, replace text: String, range: NSRange, in pane: ComposePresentation) {
    guard receivedHello, let cursor = pane.cursor,
          let source = pane.sourceRange(forTextServiceRange: range),
          let replacement = ComposeReplacement(scope: pane.scope, epoch: pane.pane.compose.viewport.epoch, source: source, cursor: cursor.id, text: text) else { return }
    enqueueCompose(.replacement(replacement), target: pane)
  }

  func grid(_ grid: CellGridView, pendingTextFor pane: WirePane) -> ComposePendingPreview? {
    guard let last = composeQueue.last, let target = last.snapshot,
          target.identity == .init(window: UInt64(store.windowID), leaf: pane.leaf, buffer: pane.buffer),
          pane.hasCompose, pane.compose.viewport.epoch == target.pane.compose.viewport.epoch else { return nil }
    if let text = last.preview {
      return ComposePendingPreview(token: last.token, target: target, text: text, afterAction: false, prefixToken: nil, virtualPrefix: last.virtualPrefix)
    }
    var prefix: QueuedInput?
    for queued in composeQueue.dropLast().reversed() {
      guard queued.target?.identity == last.target?.identity, queued.target?.epoch == last.target?.epoch else { break }
      if queued.preview != nil { prefix = queued; break }
    }
    var virtualSelection: ComposeVirtualSelections?
    if let prefix, let text = prefix.preview, let basis = text.provisionalSelections(over: prefix.virtualPrefix, pane: prefix.snapshot?.pane.compose),
       let start = composeQueue.firstIndex(where: { $0.token == prefix.token }) {
      virtualSelection = basis
      for queued in composeQueue.dropFirst(start + 1) {
        guard let previous = virtualSelection else { break }
        switch queued.input {
        case .pendingPointer(let capture, let predecessor) where predecessor == prefix.token:
          virtualSelection = capture.preview(basis: basis, updating: previous)
        case .pointer(let pointer) where pointer.scope.bufferRevision == prefix.snapshot?.scope.bufferRevision:
          virtualSelection = pointer.preview(in: previous)
        default: virtualSelection = nil
        }
      }
    }
    let selection = last.pointerPreview.flatMap { preview in
      pane.compose.bufferRevision == preview.pane.bufferRevision && pane.compose.assetDocument == preview.pane.assetDocument
        && pane.compose.assetAuthority == preview.pane.assetAuthority
        && (pane.compose.cursors.first(where: \.primary) ?? pane.compose.cursors.first)?.id == preview.caret.id
        && pane.compose.focused && pane.compose.keyboard ? preview : nil
    }
    return ComposePendingPreview(token: last.token, target: prefix?.snapshot ?? target,
      text: prefix?.preview, afterAction: true, prefixToken: prefix?.token, selection: selection, virtualSelection: virtualSelection, virtualPrefix: prefix?.virtualPrefix)
  }

  func grid(_ grid: CellGridView, commit text: ComposePendingText, initial: ComposePendingText,
            after: UUID?, afterAction: Bool, virtualPrefix: ComposeVirtualSelections?, in pane: ComposePresentation) {
    guard receivedHello else { for value in text.recoveryTexts { self.grid(grid, recover: value) }; return }
    let chain = after.map { CompositionChain(predecessor: $0, initial: initial, text: text, afterAction: afterAction) }
    if let after, !composeQueue.contains(where: { $0.token == after }) {
      for value in text.recoveryTexts { self.grid(grid, recover: value) }; return
    }
    let input: PendingInput
    if after != nil { input = .pendingText(text) }
    else if let replacement = text.replacement(scope: pane.scope, epoch: pane.pane.compose.viewport.epoch) { input = .replacement(replacement) }
    else { for value in text.recoveryTexts { self.grid(grid, recover: value) }; return }
    enqueueCompose(input, target: pane, chain: chain, preview: text, virtualPrefix: virtualPrefix)
  }

  /// Rebase only descendants of this acknowledged native edit. Its immutable
  /// receipt remains valid even if the same frame includes a newer scene.
  private func resolveCompositionChains(edit: WireComposeEditReceipt?, result: WireComposeEditReceipt?) {
    guard let first = composeQueue.first else { return }
    func valid(_ receipt: WireComposeEditReceipt?) -> WireComposeEditReceipt? {
      guard let receipt, let target = first.target,
            receipt.matches(target.scope, epoch: target.epoch, notBefore: store.composeAcceptances[receipt.leaf]) else { return nil }
      return receipt
    }
    let edit = valid(edit), result = valid(result ?? edit)
    var failed: Set<UUID> = edit == nil && result == nil ? [first.token] : []
    var retained = [first]
    var prediction = result?.pane
    let predictionIdentity = first.target?.identity
    for var queued in composeQueue.dropFirst() {
      if case .pendingPointer(let capture, let predecessor) = queued.input,
         predecessor == first.token || failed.contains(predecessor) {
        if predecessor == first.token, let edit, let pointer = capture.resolved(edit), let original = queued.snapshot {
          var pane = original.pane; pane.compose = edit.pane
          queued.input = .pointer(pointer); queued.target?.scope = edit.scope
          queued.snapshot = grid?.composeSnapshot(pane)
        } else {
          failed.insert(queued.token); reportPendingPointerCancellation(); continue
        }
      }
      // A source point outside the draft already has a valid server rebase
      // path. When this edit also proves its derived position, carry that
      // proof forward for continuous selection feedback across the reply.
      if case .pointer(let pointer) = queued.input, let edit, let text = first.preview,
         pointer.scope.windowID == edit.window, pointer.scope.leaf == edit.leaf, pointer.scope.buffer == edit.buffer,
         pointer.scope.bufferRevision == first.snapshot?.scope.bufferRevision,
         queued.target?.epoch == edit.epoch {
        let captured = pointer.input(id: 0)
        if !captured.hasAttachmentStart, let basis = text.provisionalSelections(over: first.virtualPrefix, pane: first.snapshot?.pane.compose),
           let point = basis.position(forSource: captured.position),
           let capture = text.pointer(scope: pointer.scope, epoch: edit.epoch, displayed: text.presentation,
             point: point, basis: basis, affinity: captured.affinity == 1 ? .upstream : .downstream,
             extend: captured.extend, count: Int(captured.clickCount), nativeNewline: edit.pane.nativeNewline),
           let rebound = capture.resolved(edit) {
          queued.input = .pointer(rebound); queued.target?.scope = rebound.scope
        }
      }
      if let chain = queued.chain, chain.predecessor == first.token || failed.contains(chain.predecessor) {
        if let receipt = chain.afterAction ? result : edit, chain.predecessor == first.token, let target = queued.target,
           receipt.matches(target.scope, epoch: target.epoch),
           let text = chain.afterAction ? chain.text.afterAction(chain.initial, pane: receipt.pane)
             : chain.text.resolved(pane: receipt.pane, edited: receipt.cursors, preserved: receipt.preservedCursors),
           let replacement = text.replacement(scope: receipt.scope, epoch: receipt.epoch),
           let original = queued.snapshot {
          var pane = original.pane; pane.compose = receipt.pane
          queued.input = .replacement(replacement); queued.target?.scope = receipt.scope; queued.chain = nil
          queued.preview = text; queued.snapshot = grid?.composeSnapshot(pane); queued.virtualPrefix = nil
        } else {
          failed.insert(queued.token)
          if let grid { for text in chain.text.recoveryTexts { self.grid(grid, recover: text) } }
          continue
        }
      }
      if case .pointer(let pointer) = queued.input, let pane = prediction,
         queued.target?.identity == predictionIdentity, queued.target?.epoch == pane.viewport.epoch {
        queued.pointerPreview = pointer.preview(in: pane)
        prediction = queued.pointerPreview?.pane
      } else { prediction = nil }
      retained.append(queued)
    }
    composeQueue = retained
    grid?.resolveComposition(after: first.token, edit: edit, result: result)
    for token in failed where token != first.token { grid?.resolveComposition(after: token, edit: nil, result: nil) }
  }

  private func reportPendingPointerCancellation() {
    let message = "The text for this editor click could not be confirmed. Click again."
    guard lastComposeCancellation != message else { return }
    lastComposeCancellation = message
    app?.engine.reportError(message)
    Trace.write("editor input cancelled: \(message)")
  }

  func grid(_ grid: CellGridView, recover text: String) {
    guard !text.isEmpty else { return }
    uninsertedText.append(text)
    app?.engine.reportError("Editor text was not inserted. Use Edit > Copy Uninserted Text to recover it.")
  }

  func copyUninsertedText() {
    guard !uninsertedText.isEmpty else { return }
    pasteboard.replaceEditorText(uninsertedText.joined(separator: "\n\n"))
  }

  private func recoverPendingText() {
    grid?.cancelComposition(recover: true)
    for queued in composeQueue {
      if let grid {
        if let preview = queued.preview { for text in preview.recoveryTexts { self.grid(grid, recover: text) } }
        else if case .replacement(let replacement) = queued.input { for text in replacement.texts { self.grid(grid, recover: text) } }
      }
    }
    composeQueue.removeAll()
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
    if case .action = input { grid?.finishComposition() }
    switch input {
    case .key, .mouse, .paste, .text, .action, .widget, .settingsClick, .kbEditClick:
      guard receivedHello else { return }
    default: break
    }
    guard richCompose else { socket?.send(input); return }
    // A modal that appeared while navigation awaited geometry must remain
    // usable. Its ordinary input does not replace the deferred document action.
    if !composeQueue.isEmpty, let identity = pendingComposePane {
      let pane = grid?.composePanes[identity.leaf]
      if pane?.identity != identity || pane?.pane.compose.keyboard != true {
        socket?.send(input)
        return
      }
    }
    switch input {
    case .key, .mouse, .paste, .text, .action, .widget, .settingsClick, .kbEditClick:
      let target: ComposePresentation?
      switch input {
      case .key, .paste, .text, .action: target = grid?.focusedCompose
      default: target = nil
      }
      if case .text(let text) = input, let target {
        let unspecified = NSRange(location: NSNotFound, length: 0)
        let pending = grid.flatMap { self.grid($0, pendingTextFor: target.pane) }
        let prefix = pending?.text
        let root = pending.flatMap { $0.text == nil ? nil : $0.target } ?? target
        let draft: ComposePendingText?
        if let selection = pending?.virtualSelection {
          draft = ComposePendingText(afterAction: selection, pane: root.pane.compose,
            text: NSAttributedString(string: text), selected: NSRange(location: text.utf16.count, length: 0), replacement: unspecified)
        } else {
          draft = prefix.flatMap {
            ComposePendingText(following: $0, pane: root.pane.compose,
              text: NSAttributedString(string: text), selected: NSRange(location: text.utf16.count, length: 0), replacement: unspecified, virtualBase: pending?.virtualPrefix)
          } ?? (prefix == nil ? ComposePendingText(pane: root.pane.compose, text: NSAttributedString(string: text),
            selected: NSRange(location: text.utf16.count, length: 0), replacement: unspecified) : nil)
        }
        if let draft, let preview = draft.committed(nativeNewline: root.pane.compose.nativeNewline) {
          let chain = pending.map { CompositionChain(predecessor: $0.token, initial: draft, text: preview, afterAction: $0.afterAction) }
          enqueueCompose(chain == nil ? .message(input) : .pendingText(preview), target: root, chain: chain, preview: preview,
            virtualPrefix: pending?.virtualSelection ?? pending?.virtualPrefix)
        } else {
          // Older peers or opaque queued actions still use Fresh's ordinary
          // ordered input path; there is no guessed multiline preview.
          enqueueCompose(.message(input), target: target)
        }
      } else { enqueueCompose(.message(input), target: target) }
    default:
      socket?.send(input)
    }
  }

  private func enqueueCompose(_ input: PendingInput, target: ComposePresentation?, chain: CompositionChain? = nil,
                              preview: ComposePendingText? = nil, pointerPreview: ComposePointer.Preview? = nil, virtualPrefix: ComposeVirtualSelections? = nil) {
    if composeQueue.isEmpty { lastComposeCancellation = nil }
    composeQueue.append(.init(input: input, scrollGeneration: composeViewports.userScrollGeneration,
      target: target.map(InputTarget.init), chain: chain,
      preview: preview, snapshot: target, pointerPreview: pointerPreview, virtualPrefix: virtualPrefix))
    grid?.refreshComposeImages()
    pumpComposeInput()
  }

  /// Send one event, wait for its scene/reply, then bind the next event to the
  /// resulting source map. A stale event keeps its id and is measured again.
  private func pumpComposeInput() {
    guard receivedHello, let socket, socket.isOpen, !composeInFlight, !completingComposeInput, let queued = composeQueue.first else { return }
    switch queued.input {
    case .pendingText, .pendingPointer: return // The predecessor must supply real source coordinates.
    default: break
    }
    if pendingComposeID == nil {
      nextComposeID += 1
      pendingComposeID = nextComposeID
      pendingComposePane = queued.target?.identity
    }
    let needsGeometry: Bool
    switch queued.input {
    case .replacement: needsGeometry = false // Real source ranges already belong to a captured receipt.
    case .message(.text): needsGeometry = false
    default: needsGeometry = true
    }
    if needsGeometry, let identity = pendingComposePane,
       let current = store.panes.first(where: { $0.leaf == identity.leaf && $0.hasBuffer && $0.buffer == identity.buffer && $0.hasCompose }) {
      guard current.compose.projectionUsable else { return }
      if let projection = pendingComposeProjection {
        if projection.bufferRevision != current.compose.bufferRevision || projection.selectionRevision != current.compose.selectionRevision
            || projection.assetDocument != current.compose.assetDocument {
          pendingComposeProjection = nil; pendingComposeY = nil; pendingComposeRegion = nil
        } else if !projection.projectionUsable { return }
      }
    }
    var input = WireComposeInput()
    input.id = pendingComposeID ?? 0
    switch queued.input {
    case .pendingText, .pendingPointer: return
    case .message(let message):
      input.kind = UInt32(message.kind.rawValue)
      input.payload = Data(message.payload())
      if case .text = message {
        input.textInput = true
        input.observedCursors = queued.preview?.observedCursors ?? []
      }
      if let identity = pendingComposePane {
        input.bufferEpoch = queued.target?.epoch ?? 0
        guard var visible = grid?.composePanes[identity.leaf], visible.identity == identity else {
          // A modal can temporarily hide a still-open Compose view. Its raw
          // UI input remains usable; Fresh proactively cancels this request if
          // its tab, buffer lifetime, presentation or keyboard focus changes.
          if pendingComposeLayout { return }
          input.scope = queued.target?.scope ?? WireComposeScope()
          composeInFlight = true
          socket.send(.composeInput(input))
          return
        }
        if visible.pane.compose.viewport.epoch != input.bufferEpoch {
          input.cancel = true
          break
        }
        if visible.layout.composition != nil || visible.pendingSelection, let actual = store.panes.first(where: { $0.leaf == identity.leaf && $0.hasBuffer && $0.buffer == identity.buffer }),
           let measured = grid?.composeInputSnapshot(actual) { visible = measured }
        let pane = pendingComposeProjection.flatMap { grid?.composeMeasurement(identity: identity, projection: $0) } ?? visible
        pendingComposeBefore = (visible.pane.compose.bufferRevision, visible.pane.compose.cursors)
        if pane.pane.compose.keyboard {
          input.scope = pane.scope
          if let region = pendingComposeRegion {
            input.region = region
            composeRegionSent = true
          } else if !input.textInput {
            let layout = pendingComposeLayout ? pane.measuredNavigation(aroundY: pendingComposeY) : pane.navigation
            input.layoutID = layout?.id ?? 0
            if pendingComposeLayout {
              guard let layout else { return }
              input.layout = layout
            }
          }
        } else {
          if pendingComposeLayout { return }
          input.scope = queued.target?.scope ?? pane.scope
        }
      }
    case .pointer(let pointer):
      input = pointer.input(id: input.id)
      if let identity = pendingComposePane, let actual = store.panes.first(where: {
        $0.leaf == identity.leaf && $0.hasBuffer && $0.buffer == identity.buffer && $0.hasCompose
      }) {
        pendingComposeBefore = (actual.compose.bufferRevision, actual.compose.cursors)
      }
    case .replacement(let replacement):
      input = replacement.input(id: input.id)
      if let identity = pendingComposePane, let pane = grid?.composePanes[identity.leaf], pane.identity == identity {
        if pendingComposeLayout, pane.pane.compose.viewport.epoch == input.bufferEpoch,
           !pane.pane.compose.keyboard || grid?.composeInputAllowed == false { return }
        pendingComposeBefore = (pane.pane.compose.bufferRevision, pane.pane.compose.cursors)
      }
    }
    if input.textInput, queued.preview != nil, let scope = queued.target?.scope { input.scope = scope }
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
