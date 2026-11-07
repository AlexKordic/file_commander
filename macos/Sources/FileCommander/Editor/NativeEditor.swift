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
  /// Complete logical value shared by every rich accessibility query family.
  lazy var composeDocument = ComposeDocumentController(quietNanoseconds: documentQuietNanoseconds) { [weak self] request in
    self?.socket?.send(.composeDocument(request))
  }
  let composeFlow = ComposeFlowController()
  private var accessibilitySnapshot: ComposeCompleteAccessibility?
  private var documentBindings: [UUID: ComposeDocumentBinding] = [:]
  private var publishedBindings: [UUID: UUID] = [:]
  private var publishedBindingOrder: [UUID] = []
  private struct SourceTransition {
    let sequence: UInt64
    let token: UUID
    let value: ComposeDocumentAction.Transition?
  }
  private var sourceTransitions: [SourceTransition] = []
  private var transitionSequence: UInt64 = 0
  private var composeFlowOwner: WireComposeIndexOwner?
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
  private let documentQuietNanoseconds: UInt64
  private enum PendingInput {
    case message(SceneInput)
    case pointer(ComposePointer)
    case replacement(ComposeReplacement)
    case selection(ComposeSelectionChange)
    case pendingText(ComposePendingText)
    case pendingPointer(ComposePendingPointer, after: UUID)
    case document(ComposeDocumentAction, after: UUID)
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
    let token: UUID
    var input: PendingInput
    var scrollGeneration: UInt64
    var target: InputTarget?
    var chain: CompositionChain?
    var preview: ComposePendingText? { didSet { origins = preview?.origins() } }
    var origins: ComposePendingText.Origins?
    var snapshot: ComposePresentation?
    var pointerPreview: ComposePointer.Preview?
    var virtualPrefix: ComposeVirtualSelections?
    var selectionPredecessor: UUID?
    var documentSelectionPreview: ComposeVirtualSelections?
    var isSourceSelection: Bool {
      switch input { case .selection: return true; case .document(let action,_): return action.isSelection; default: return false }
    }
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
  private let decodeComposeImage: @Sendable (Data, Int) throws -> ComposeImageAsset
  private lazy var composeImages = ComposeImageController(decode: decodeComposeImage) { [weak self] request in
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

  init(pasteboard: any EditorPasteboard, environment: [String: String] = ProcessInfo.processInfo.environment,
       documentQuietNanoseconds: UInt64 = 80_000_000,
       decodeComposeImage: @escaping @Sendable (Data, Int) throws -> ComposeImageAsset = { try ComposeImageAsset.decode($0, maximumDimension: $1) }) {
    self.pasteboard = pasteboard
    self.documentQuietNanoseconds = documentQuietNanoseconds
    self.decodeComposeImage = decodeComposeImage
    richCompose = environment["FC_NATIVE_RICH_COMPOSE"] == "1"
    measuredTables = richCompose && environment["FC_NATIVE_MEASURED_TABLES"] == "1"
    super.init()
    composeDocument.onChange = { [weak self] in self?.updateCompleteFlow() }
    composeFlow.onChange = { [weak self] in
      self?.accessibilitySnapshot = nil
      self?.recordPublishedDocumentBinding()
      self?.grid?.completeAccessibilityChanged()
    }
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
    socket.onIndexChunk = { [weak self, weak socket] chunk in
      guard let self, let socket, self.socket === socket else { return }
      self.grid?.composeNavigation.controller.receive(chunk)
    }
    socket.onDocumentChunk = { [weak self, weak socket] chunk in
      guard let self, let socket, self.socket === socket else { return }
      self.composeDocument.receive(chunk)
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
    updateDocumentDemand()
    grid?.composeNavigation.update()
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
    updateDocumentDemand()
    grid?.composeNavigation.update()
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
    resetDocumentBindings()
    composeFlow.reset(); composeFlowOwner = nil
    composeDocument.reset()
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
    resetDocumentBindings()
    composeFlow.reset(); composeFlowOwner = nil
    composeDocument.reset()
    let failedToAttach = !receivedHello && pendingShow
    recoverPendingText()
    composeImages.reset()
    composeViewports.reset()
    socket = nil
    receivedHello = false
    pendingShow = false
    grid?.invalidateAccessibleImages()
    hide()
    if let reason {
      Trace.write("editor connection ended: \(reason)")
      if failedToAttach { app?.engine.reportError("Can't connect to the editor: \(reason)") }
    }
  }

  // MARK: View

  /// The editor's view, made once and kept.
  private func makeView() -> EditorHostView {
    if let view { return view }
    let view = EditorHostView(store: store) { [weak self] input in self?.sendFromPanel(input) }
    view.grid.delegate = self
    view.grid.richPopupProjection = richCompose
    view.grid.composeImageController = composeImages
    view.grid.composeViewportController = composeViewports
    view.grid.onComposePresentationChanged = { [weak self] in self?.updateCompleteFlow() }
    view.grid.sendComposeIndex = { [weak self] request in self?.socket?.send(.composeIndex(request)) }
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
        let completedToken = composeQueue.first?.token
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
          for text in recoveryTexts(for: first) { self.grid(grid, recover: text) }
        }
        resolveCompositionChains(edit: reply.accepted && reply.hasEdit ? reply.edit : nil,
          result: reply.accepted && reply.hasResult ? reply.result : nil)
        if !composeQueue.isEmpty { composeQueue.removeFirst() }
        grid?.refreshComposeImages()
        if let completedToken { composeFlow.confirmSelection(completedToken) }
        composeFlow.retainSelection(while: Set(composeQueue.map(\.token)))
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
    if message.frame.hasInputReply {
      let reply = message.frame.inputReply
      fields["compose_input"] = ["id": reply.id, "accepted": reply.accepted, "cancelled": reply.cancelled,
        "needs_layout": reply.needsLayout, "edit": reply.hasEdit, "result": reply.hasResult,
        "need_region": reply.hasNeedRegion, "need_y": reply.hasNeedY] as [String: Any]
    }
    if message.frame.hasViewportReply {
      fields["compose_viewport"] = ["id": message.frame.viewportReply.id, "accepted": message.frame.viewportReply.accepted] as [String: Any]
    }
    fields["compose_panes"] = store.panes.filter(\.hasCompose).map { pane -> [String: Any] in
      let value = pane.compose
      return ["leaf": pane.leaf, "buffer": pane.buffer, "revision": value.bufferRevision,
        "projection": value.projectionRevision, "ready": value.ready, "current": value.currentProjection,
        "source_start": value.sourceStart, "source_end": value.sourceEnd, "document_bytes": value.documentLen,
        "projection_bytes": value.text.utf8.count, "images": value.images.count, "tables": value.tables.count]
    }
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
    updateDocumentDemand()
  }

  private func updateDocumentDemand() {
    let pane = shown && richCompose ? store.panes.first(where: { $0.hasCompose && $0.compose.focused }) : nil
    let owner = pane.flatMap { pane -> WireComposeIndexOwner? in
      guard store.composeDocumentUpdates, pane.hasBuffer, pane.compose.hasViewport, pane.compose.viewport.epoch != 0,
            pane.compose.documentLen <= UInt64(ComposeDocumentReceiver.maximumSource) else { return nil }
      return .with {
        $0.window = UInt64(store.windowID); $0.leaf = pane.leaf; $0.buffer = pane.buffer
        $0.epoch = pane.compose.viewport.epoch; $0.revision = pane.compose.bufferRevision
        $0.authority = pane.compose.assetAuthority; $0.document = pane.compose.assetDocument; $0.length = pane.compose.documentLen
      }
    }
    let sameDocument = owner.map { composeFlowOwner?.isSameDocument(as: $0) == true } ?? false
    if !sameDocument { resetDocumentBindings(); composeFlow.reset() }
    composeFlowOwner = owner
    composeDocument.update(window: UInt64(store.windowID), pane: pane, supported: store.composeDocumentUpdates)
    updateCompleteFlow()
  }

  private func updateCompleteFlow() {
    if accessibilitySnapshot?.pane !== grid?.focusedCompose { accessibilitySnapshot = nil }
    guard shown, richCompose, let snapshot = composeDocument.snapshot, let pane = grid?.focusedCompose,
          snapshot.document.owns(window: UInt64(store.windowID), pane: pane.pane) else {
      composeFlow.update(snapshot: nil, environment: nil); return
    }
    var overlay: ComposeDocumentOverlay?
    if pane.pendingSelection || pane.layout.composition != nil || pane.layout.virtualInsertion != nil || pane.virtualSelections != nil {
      guard let value = ComposeDocumentOverlay(window: UInt64(store.windowID), pane: pane.pane,
        composition: pane.layout.composition, virtualInsertion: pane.layout.virtualInsertion, virtualSelections: pane.virtualSelections) else {
        composeFlow.update(snapshot: nil, environment: nil); return
      }
      overlay = value
    }
    // Read already known dimensions for the whole document without demanding
    // offscreen bytes or retaining decoded pixels in the measurement worker.
    var images: [UInt64: ComposeImageState] = [:]
    for image in snapshot.pane.images {
      images[image.start] = composeImages.state(scope: pane.scope, image: image,
        authority: snapshot.pane.assetAuthority, document: snapshot.pane.assetDocument)
    }
    let context = captureDocumentBinding(snapshot, overlay: overlay, pane: pane)
    composeFlow.update(snapshot: snapshot, environment: pane.layout.measurementEnvironment(images: images), overlay: overlay,
      context: context)
    trimDocumentBindings()
  }

  private func resetDocumentBindings() {
    documentBindings.removeAll(); publishedBindings.removeAll(); publishedBindingOrder.removeAll()
    sourceTransitions.removeAll(); transitionSequence = 0
  }

  private func trimDocumentBindings() {
    while publishedBindingOrder.count > 4 {
      publishedBindings.removeValue(forKey: publishedBindingOrder.removeFirst())
    }
    var keep = Set(publishedBindings.values)
    if let id = composeFlow.targetContext { keep.insert(id) }
    if let id = composeFlow.presentationContext { keep.insert(id) }
    documentBindings = documentBindings.filter { keep.contains($0.key) }
  }

  private func recordPublishedDocumentBinding() {
    guard let model = composeFlow.presentation, let context = composeFlow.presentationContext,
          documentBindings[context] != nil else { return }
    if publishedBindings[model.id] == nil { publishedBindingOrder.append(model.id) }
    publishedBindings[model.id] = context
    trimDocumentBindings()
  }

  private func captureDocumentBinding(_ snapshot: ComposeDocumentSnapshot, overlay: ComposeDocumentOverlay?, pane: ComposePresentation) -> UUID? {
    let nodes = composeQueue.filter { $0.target?.identity == pane.identity && $0.target?.epoch == pane.pane.compose.viewport.epoch }
    let active = grid?.pendingComposition
    let actual = store.panes.first { $0.leaf == pane.identity.leaf && $0.hasBuffer && $0.buffer == pane.identity.buffer }
    let ownsActual = actual.map { snapshot.document.owns(window: pane.identity.window, pane: $0) } ?? false
    for id in [composeFlow.targetContext, composeFlow.presentationContext].compactMap({ $0 }) {
      guard let binding = documentBindings[id], binding.matches(snapshot, overlay: overlay) else { continue }
      if !ownsActual || binding.nodes.map(\.token) == nodes.map(\.token) && binding.active?.token == active?.token { return id }
    }
    guard ownsActual, let primary = pane.cursor?.id else { return nil }
    let captured = nodes.map { node -> ComposeDocumentBinding.Node in
      let group = node.preview.map { text in text.presentation.values.keys.sorted {
        if ($0 == text.presentation.primaryID) != ($1 == text.presentation.primaryID) { return $0 == text.presentation.primaryID }
        return $0 < $1
      } } ?? []
      return .init(token: node.token, revision: node.target?.scope.bufferRevision ?? pane.scope.bufferRevision,
        predecessor: node.chain?.predecessor, selector: node.isSourceSelection, origins: node.origins, hasText: node.preview != nil, cursors: group)
    }
    let id = UUID()
    documentBindings[id] = .init(document: ObjectIdentifier(snapshot.document), overlay: overlay, scope: pane.scope,
      marker: transitionSequence, nodes: captured, latest: nodes.last(where: { $0.preview != nil })?.preview,
      active: active, displayed: pane.layout.composition, primary: primary, newline: pane.pane.compose.nativeNewline)
    return id
  }

  private func recordSourceTransition(first: QueuedInput, edit: WireComposeEditReceipt?, result: WireComposeEditReceipt?) {
    guard let target = first.target, let owner = composeFlowOwner,
          target.identity.window == owner.window, target.identity.leaf == owner.leaf, target.identity.buffer == owner.buffer,
          target.epoch == owner.epoch else { return }
    let receipt = edit ?? result
    var ids: [UInt64]?
    if case .selection(let selector) = first.input, let receipt {
      let count = selector.input(id: 0).selectionTargets.count
      if receipt.pane.cursors.count == count, receipt.pane.cursors.filter(\.primary).count == 1,
         Set(receipt.pane.cursors.map(\.id)).count == count {
        ids = receipt.pane.cursors.sorted { a,b in a.primary != b.primary ? a.primary : a.id < b.id }.map(\.id)
      }
    }
    transitionSequence += 1
    sourceTransitions.append(.init(sequence: transitionSequence, token: first.token,
      value: receipt.flatMap { .init($0, original: target.scope, epoch: target.epoch, selectedIDs: ids) }))
    if sourceTransitions.count > 64 { sourceTransitions.removeFirst(sourceTransitions.count - 64) }
  }

  func gridAccessibility(_ grid: CellGridView, activate: Bool) -> ComposeCompleteAccessibility? {
    guard receivedHello, shown, richCompose, let pane = grid.focusedCompose else { return nil }
    if activate { composeDocument.activate() }
    guard let model = composeFlow.presentation else { return nil }
    if let value = accessibilitySnapshot, value.model === model, value.pane === pane { return value }
    let value = ComposeCompleteAccessibility(model: model, pane: pane, flow: composeFlow.flow)
    accessibilitySnapshot = value
    return value
  }

  func grid(_ grid: CellGridView, selectDocument ranges: [NSRange], in model: ComposeDocumentPresentation) -> Bool {
    selectDocument(ranges, in: model)
  }

  func grid(_ grid: CellGridView, replaceDocumentSelection text: String, in model: ComposeDocumentPresentation) -> Bool {
    replaceDocumentSelection(text, in: model)
  }

  func grid(_ grid: CellGridView, documentActionsAvailable model: ComposeDocumentPresentation) -> Bool {
    documentActionsAvailable(model)
  }

  private func updateImageDemands(revalidate: Bool = false) {
    let demands = shown && richCompose ? grid?.composeImageDemands() ?? [] : []
    let current = demands.filter { demand in
      store.panes.contains { pane in pane.leaf == demand.scope.leaf && pane.hasBuffer && pane.buffer == demand.scope.buffer
        && pane.hasCompose && pane.compose.projectionUsable && pane.compose.bufferRevision == demand.scope.bufferRevision }
    }
    // Provisional input can temporarily omit attachment geometry even when
    // the latest backend frame is usable. Live documents retain received
    // decodes only; source-scoped requests still require current demands.
    let documents: [ComposeImageController.DocumentIdentity] = shown && richCompose ? store.panes.compactMap { pane in
      guard pane.hasBuffer, pane.hasCompose else { return nil }
      return .init(window: UInt64(store.windowID), buffer: pane.buffer,
        authority: pane.compose.assetAuthority, document: pane.compose.assetDocument)
    } : []
    composeImages.update(current, retainingDocuments: documents, revalidate: revalidate)
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

  func grid(_ grid: CellGridView, select ranges: [Range<Int>], in pane: ComposePresentation) {
    guard receivedHello, store.composeSourceSelections,
          let change = ComposeSelectionChange(scope: pane.scope, epoch: pane.pane.compose.viewport.epoch, ranges: ranges) else { return }
    enqueueCompose(.selection(change), target: pane)
  }

  func grid(_ grid: CellGridView, replaceSource range: Range<Int>, with text: String, in pane: ComposePresentation) {
    guard receivedHello, let cursor = pane.cursor,
          let replacement = ComposeReplacement(scope: pane.scope, epoch: pane.pane.compose.viewport.epoch,
            source: range, cursor: cursor.id, text: text) else { return }
    let predecessor: UUID?
    if let last = composeQueue.last, last.isSourceSelection,
       last.target?.identity == pane.identity, last.target?.epoch == pane.pane.compose.viewport.epoch { predecessor = last.token }
    else { predecessor = nil }
    enqueueCompose(.replacement(replacement), target: pane, selectionPredecessor: predecessor)
  }

  /// Complete-value entry points. Publication uses these only when its entire
  /// AX coordinate family moves together; queue routing never clips a range
  /// to the drawing crop or sends a temporary region/caret identity.
  @discardableResult
  func selectDocument(_ ranges: [NSRange], in model: ComposeDocumentPresentation) -> Bool {
    let queued = enqueueDocumentAction(ranges,in: model,replacement: nil)
    if !queued { reportDocumentActionCancellation() }; return queued
  }

  @discardableResult
  func replaceDocumentSelection(_ text: String, in model: ComposeDocumentPresentation) -> Bool {
    let queued = model.selectedRanges?.first.map { enqueueDocumentAction([$0],in: model,replacement: text) } ?? false
    if !queued { if let grid { self.grid(grid,recover: text) }; reportDocumentActionCancellation() }
    return queued
  }

  private func enqueueDocumentAction(_ ranges: [NSRange], in model: ComposeDocumentPresentation, replacement: String?) -> Bool {
    guard receivedHello, store.composeSourceSelections, let grid, let pane = grid.focusedCompose,
          composeDocument.snapshot?.document === model.document || publishedBindings[model.id] != nil,
          replacement == nil || pane.pane.compose.editable,
          !ranges.isEmpty, ranges.count <= 1024 else { return false }
    let capturedOverlay: ComposeDocumentOverlay?
    if pane.pendingSelection || pane.layout.composition != nil || pane.layout.virtualInsertion != nil || pane.virtualSelections != nil {
      guard let captured = ComposeDocumentOverlay(window: UInt64(store.windowID),pane: pane.pane,
        composition: pane.layout.composition,virtualInsertion: pane.layout.virtualInsertion,virtualSelections: pane.virtualSelections) else { return false }
      capturedOverlay = captured
    } else { capturedOverlay = nil }
    let sameOverlay: Bool
    switch (model.overlay,capturedOverlay) {
    case (nil,nil): sameOverlay = true
    case (let a?,let b?): sameOverlay = a.isEquivalent(to:b)
    default: sameOverlay = false
    }
    let actual = store.panes.first { $0.leaf == pane.identity.leaf && $0.hasBuffer && $0.buffer == pane.identity.buffer }
    let current = sameOverlay && model.document.owns(window: pane.identity.window, pane: pane.pane)
      && actual.map { model.document.owns(window: pane.identity.window, pane: $0) } == true
    if !current {
      return enqueueRetainedDocumentAction(ranges, in: model, replacement: replacement, pane: pane)
    }
    let sorted = ranges.sorted { ($0.location,$0.length) < ($1.location,$1.length) }
    guard ranges.allSatisfy({ $0.location >= 0 && $0.location != NSNotFound && $0.length >= 0
      && $0.location <= model.characterCount && $0.length <= model.characterCount-$0.location }),
      zip(sorted,sorted.dropFirst()).allSatisfy({ NSMaxRange($0) <= $1.location && $0.location != $1.location }) else { return false }
    var endpoints: [(ComposeDocumentPresentation.Endpoint,ComposeDocumentPresentation.Endpoint)] = []
    for range in ranges {
      guard let start = model.endpoint(atUTF16: range.location),
            let end = model.endpoint(atUTF16: NSMaxRange(range),affinity: range.length == 0 ? .downstream : .upstream) else { return false }
      endpoints.append((start,end))
    }
    let displayed = pane.layout.composition
    grid.finishComposition()
    let nodes = composeQueue.filter { $0.target?.identity == pane.identity && $0.target?.epoch == pane.pane.compose.viewport.epoch }
    let latest = nodes.last(where: { $0.preview != nil })
    let basis = latest.flatMap { node in node.preview?.provisionalSelections(over: node.virtualPrefix,pane: node.snapshot?.pane.compose) }
    func cursor(_ id: UInt64, for node: QueuedInput) -> ComposeDocumentAction.Cursor {
      var current: QueuedInput? = node, visited: Set<UUID> = []
      while let value = current, visited.insert(value.token).inserted, let chain = value.chain,
            let predecessor = nodes.first(where: { $0.token == chain.predecessor }) {
        if predecessor.isSourceSelection, let text = node.preview {
          let group = text.presentation.values.keys.sorted {
            if ($0 == text.presentation.primaryID) != ($1 == text.presentation.primaryID) { return $0 == text.presentation.primaryID }
            return $0 < $1
          }
          if let ordinal = group.firstIndex(of: id) { return .selectedGroup(predecessor.token,ordinal: ordinal) }
        }
        current = predecessor
      }
      return .known(id)
    }
    var proposed: [NSRange] = [], bound: [ComposeDocumentAction.Bounds] = []
    func position(_ endpoint: ComposeDocumentPresentation.Endpoint, affinity: ComposeProjection.Affinity) -> (ComposeDocumentAction.Position,Int?)? {
      if case .source(let byte) = endpoint.location {
        return (.source(byte,affinity: affinity),basis?.position(forSource: UInt64(byte)))
      }
      guard let original = model.provisionalPosition(of: endpoint), let latest, let text = latest.preview, let displayed,
            let normalized = text.normalizedPosition(original,displayed: displayed,nativeNewline: pane.pane.compose.nativeNewline) else { return nil }
      var point = normalized
      for node in nodes.reversed() {
        guard let prefix = node.preview else { continue }
        guard let origin = prefix.origin(atProvisionalUTF16: point,affinity: affinity) else { return nil }
        switch origin {
        case .inserted(let id,let inserted): return (.inserted(node.token,cursor: cursor(id,for: node),position: inserted,affinity: affinity),normalized)
        case .before(let before): point = before
        }
      }
      for node in nodes where node.target?.scope.bufferRevision == model.document.owner.revision {
        if let byte = node.preview?.sourcePosition(beforePendingAtUTF16: point,documentLength: model.document.owner.length) {
          return (.source(byte,affinity: affinity),normalized)
        }
      }
      return nil
    }
    for (index, pair) in endpoints.enumerated() {
      guard let a = position(pair.0,affinity: .downstream),
            let b = position(pair.1,affinity: ranges[index].length == 0 ? .downstream : .upstream) else {
        reportDocumentActionCancellation(); return false
      }
      bound.append(.init(start: a.0,end: b.0))
      if let start = a.1, let end = b.1, start <= end { proposed.append(NSRange(location: start,length: end-start)) }
    }
    let kind: ComposeDocumentAction.Kind
    if let replacement {
      guard let primary = pane.cursor else { return false }
      let owner: ComposeDocumentAction.Cursor = nodes.last.flatMap { $0.isSourceSelection ? .selectedGroup($0.token,ordinal: 0) : nil }
        ?? latest.map { cursor(primary.id,for: $0) } ?? .known(primary.id)
      kind = .replacement(replacement,cursor: owner)
    } else { kind = .selection }
    guard let action = ComposeDocumentAction(owner: model.document.owner,scope: pane.scope,bounds: bound,kind: kind) else { return false }
    if let barrier = composeQueue.last?.token {
      let preview = replacement == nil && proposed.count == ranges.count ? basis?.replacingGroup(with: proposed) : nil
      enqueueCompose(.document(action,after: barrier),target: pane,documentSelectionPreview: preview)
      return true
    }
    guard let ready = action.ready() else { return false }
    switch ready {
    case .selection(let change): enqueueCompose(.selection(change),target: pane)
    case .replacement(let change): enqueueCompose(.replacement(change),target: pane)
    }
    return true
  }

  private func replayDocumentHistory(_ original: ComposeDocumentAction, after marker: UInt64) -> ComposeDocumentAction? {
    guard marker <= transitionSequence,
          sourceTransitions.first.map({ marker >= $0.sequence - 1 }) ?? (marker == transitionSequence) else { return nil }
    var action = original
    for event in sourceTransitions where event.sequence > marker {
      if let value = event.value {
        guard let next = action.resolving(value, token: event.token) else { return nil }; action = next
      } else if action.depends(on: event.token) { return nil }
    }
    return action
  }

  private func currentDocumentOwner(_ model: ComposeDocumentPresentation) -> WirePane? {
    guard connected, shown, let owner = composeFlowOwner, owner.isSameDocument(as: model.document.owner),
          composeDocument.snapshot?.document === model.document || publishedBindings[model.id] != nil,
          UInt64(store.windowID) == owner.window else { return nil }
    return store.panes.first { $0.leaf == owner.leaf && $0.hasBuffer && $0.buffer == owner.buffer && $0.hasCompose
      && $0.compose.hasViewport && $0.compose.viewport.epoch == owner.epoch
      && $0.compose.assetAuthority == owner.authority && $0.compose.assetDocument == owner.document }
  }

  private func action(_ action: ComposeDocumentAction, owns pane: WirePane) -> Bool {
    action.owner.revision == pane.compose.bufferRevision && action.owner.length == pane.compose.documentLen
      && action.scope.selectionRevision == pane.compose.selectionRevision
      && action.owner.epoch == pane.compose.viewport.epoch && action.owner.authority == pane.compose.assetAuthority
      && action.owner.document == pane.compose.assetDocument
  }

  func documentActionsAvailable(_ model: ComposeDocumentPresentation) -> Bool {
    guard let pane = currentDocumentOwner(model) else { return false }
    if model.document.owns(window: UInt64(store.windowID), pane: pane) { return true }
    guard let id = publishedBindings[model.id], let binding = documentBindings[id], let length = Int(exactly: model.document.owner.length),
          let captured = ComposeDocumentAction(owner: model.document.owner, scope: binding.scope,
            bounds: [.init(start: .source(length, affinity: .upstream), end: .source(length, affinity: .upstream))], kind: .selection),
          let rebased = replayDocumentHistory(captured, after: binding.marker) else { return false }
    return action(rebased, owns: pane)
  }

  private func enqueueRetainedDocumentAction(_ ranges: [NSRange], in model: ComposeDocumentPresentation,
                                            replacement: String?, pane: ComposePresentation) -> Bool {
    guard let actual = currentDocumentOwner(model), let id = publishedBindings[model.id], let binding = documentBindings[id],
          let captured = binding.action(ranges, in: model, replacement: replacement), let grid else { return false }
    grid.finishComposition()
    guard let rebased = replayDocumentHistory(captured, after: binding.marker), action(rebased, owns: actual) else { return false }
    let target = grid.composeSnapshot(actual) ?? pane
    let token = UUID()
    if let barrier = composeQueue.last?.token {
      enqueueCompose(.document(rebased, after: barrier), target: target, token: token)
      if replacement == nil { publishRetainedSelection(ranges, in: model, binding: binding, token: token) }
      return true
    }
    guard let ready = rebased.ready() else { return false }
    switch ready {
    case .selection(let change):
      enqueueCompose(.selection(change), target: target, token: token)
      publishRetainedSelection(ranges, in: model, binding: binding, token: token)
    case .replacement(let change): enqueueCompose(.replacement(change), target: target, token: token)
    }
    return true
  }

  private func publishRetainedSelection(_ ranges: [NSRange], in model: ComposeDocumentPresentation,
                                        binding: ComposeDocumentBinding, token: UUID) {
    guard composeFlow.presentation === model else { return }
    let context = UUID()
    var selected = binding; selected.selectedBy = token
    documentBindings[context] = selected
    _ = composeFlow.select(ranges, in: model, context: context, until: token)
    trimDocumentBindings()
  }

  private func reportDocumentActionCancellation() {
    let message = "The editor selection changed before it could be confirmed. Select the text again."
    guard lastComposeCancellation != message else { return }
    lastComposeCancellation = message; app?.engine.reportError(message); Trace.write("editor input cancelled: \(message)")
  }

  func grid(_ grid: CellGridView, pendingTextFor pane: WirePane) -> ComposePendingPreview? {
    guard let last = composeQueue.last, let target = last.snapshot,
          target.identity == .init(window: UInt64(store.windowID), leaf: pane.leaf, buffer: pane.buffer),
          pane.hasCompose, pane.compose.viewport.epoch == target.pane.compose.viewport.epoch else { return nil }
    if let text = last.preview {
      return ComposePendingPreview(token: last.token, target: target, text: text, afterAction: false, prefixToken: nil, virtualPrefix: last.virtualPrefix)
    }
    if case .selection(let change) = last.input {
      return ComposePendingPreview(token: last.token, target: target, text: nil, afterAction: true,
        prefixToken: nil, selectionGroup: change.preview(in: pane.compose), sourceSelection: true)
    }
    var prefix: QueuedInput?
    for queued in composeQueue.dropLast().reversed() {
      guard queued.target?.identity == last.target?.identity, queued.target?.epoch == last.target?.epoch else { break }
      if queued.preview != nil { prefix = queued; break }
    }
    if case .document(let action,_) = last.input, action.isSelection {
      var group: WireComposePane?
      if prefix == nil, case .selection(let change)? = action.ready() { group = change.preview(in: pane.compose) }
      return ComposePendingPreview(token: last.token,target: prefix?.snapshot ?? target,text: prefix?.preview,
        afterAction: true,prefixToken: prefix?.token,virtualSelection: last.documentSelectionPreview,
        virtualPrefix: prefix?.virtualPrefix,selectionGroup: group,sourceSelection: true)
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
      text: prefix?.preview, afterAction: true, prefixToken: prefix?.token, selection: selection, virtualSelection: virtualSelection,
      virtualPrefix: prefix?.virtualPrefix,sourceSelection: last.selectionPredecessor != nil)
  }

  func grid(_ grid: CellGridView, commit text: ComposePendingText, initial: ComposePendingText,
            token: UUID, after: UUID?, afterAction: Bool, virtualPrefix: ComposeVirtualSelections?, in pane: ComposePresentation) {
    guard receivedHello else { for value in text.recoveryTexts { self.grid(grid, recover: value) }; return }
    let chain = after.map { CompositionChain(predecessor: $0, initial: initial, text: text, afterAction: afterAction) }
    if let after, !composeQueue.contains(where: { $0.token == after }) {
      for value in text.recoveryTexts { self.grid(grid, recover: value) }; return
    }
    let input: PendingInput
    if after != nil { input = .pendingText(text) }
    else if let replacement = text.replacement(scope: pane.scope, epoch: pane.pane.compose.viewport.epoch) { input = .replacement(replacement) }
    else { for value in text.recoveryTexts { self.grid(grid, recover: value) }; return }
    enqueueCompose(input, target: pane, chain: chain, preview: text, virtualPrefix: virtualPrefix, token: token)
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
    recordSourceTransition(first: first, edit: edit, result: result)
    var failed: Set<UUID> = edit == nil && result == nil ? [first.token] : []
    var retained = [first]
    var prediction = result?.pane
    let predictionIdentity = first.target?.identity
    for var queued in composeQueue.dropFirst() {
      if case .document(let captured,let barrier) = queued.input {
        var action = captured
        let owned = first.target?.identity == queued.target?.identity && first.target?.epoch == queued.target?.epoch
        var invalid = failed.contains(barrier)
        if owned {
          if let receipt = edit ?? result {
            let count: Int?
            if case .selection(let selector) = first.input { count = selector.input(id: 0).selectionTargets.count }
            else { count = nil }
            var selectedIDs: [UInt64]?
            if let count, receipt.pane.cursors.count == count, receipt.pane.cursors.filter(\.primary).count == 1,
               Set(receipt.pane.cursors.map(\.id)).count == count {
              selectedIDs = receipt.pane.cursors.sorted { a,b in a.primary != b.primary ? a.primary : a.id < b.id }.map(\.id)
            }
            if let resolved = action.resolving(receipt,token: first.token,selectedIDs: selectedIDs) { action = resolved }
            else { invalid = true }
            if receipt.pane.bufferRevision != captured.owner.revision || receipt.pane.documentLen != captured.owner.length {
              // This preview's raw contexts belong to the preceding source
              // generation. The bound action survives; stale contexts do not.
              queued.documentSelectionPreview = nil
            }
          } else { invalid = true }
        }
        if !invalid, barrier == first.token {
          if let ready = action.ready() {
            switch ready {
            case .selection(let change): queued.input = .selection(change)
            case .replacement(let change): queued.input = .replacement(change)
            }
            queued.target?.scope = action.scope
            if let receipt = edit ?? result, owned, let original = queued.snapshot {
              var pane = original.pane; pane.compose = receipt.pane; queued.snapshot = grid?.composeSnapshot(pane)
            }
            queued.documentSelectionPreview = nil
          } else { invalid = true }
        } else if !invalid { queued.input = .document(action,after: barrier) }
        if invalid {
          failed.insert(queued.token); reportDocumentActionCancellation()
          if let grid { for text in captured.recoveryTexts { self.grid(grid,recover: text) } }
          continue
        }
      }
      if let predecessor = queued.selectionPredecessor, predecessor == first.token || failed.contains(predecessor) {
        let valid = predecessor == first.token && result.map { receipt in
          queued.target.map { receipt.matches($0.scope, epoch: $0.epoch) } ?? false
        } == true
        var replacement: ComposeReplacement?
        if valid, let result {
          switch queued.input {
          case .replacement(let captured) where result.pane.cursors.contains(where: { $0.primary && $0.id == captured.input(id: 0).replacementCursor }):
            replacement = captured
          case .message(.text(let text)), .message(.paste(let text)):
            replacement = ComposeReplacement(scope: result.scope, epoch: result.epoch, pane: result.pane, text: text)
          default: break
          }
        }
        guard let replacement else {
          failed.insert(queued.token)
          if let grid {
            switch queued.input {
            case .replacement(let replacement): for text in replacement.texts { self.grid(grid, recover: text) }
            case .message(.text(let text)), .message(.paste(let text)): self.grid(grid, recover: text)
            default: break
            }
          }
          continue
        }
        queued.input = .replacement(replacement)
        queued.target?.scope = replacement.scope
        queued.selectionPredecessor = nil
        if let result, let original = queued.snapshot {
          var pane = original.pane; pane.compose = result.pane; queued.snapshot = grid?.composeSnapshot(pane)
        }
      }
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
        for text in recoveryTexts(for: queued) { self.grid(grid, recover: text) }
      }
    }
    composeQueue.removeAll()
  }

  private func recoveryTexts(for queued: QueuedInput) -> [String] {
    if let preview = queued.preview { return preview.recoveryTexts }
    switch queued.input {
    case .replacement(let replacement): return replacement.texts
    case .document(let action,_): return action.recoveryTexts
    case .message(.text(let text)), .message(.paste(let text)): return queued.selectionPredecessor != nil ? [text] : []
    default: return []
    }
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
    case .key, .mouse, .popupPointer, .paste, .text, .action, .widget, .settingsClick, .kbEditClick:
      guard receivedHello else { return }
    default: break
    }
    guard richCompose else { socket?.send(input); return }
    // A modal that appeared while navigation awaited geometry must remain
    // usable. Its ordinary input does not replace the deferred document action.
    let popupGesturePending = composeQueue.contains { queued in
      if case .message(.popupPointer) = queued.input { return true }
      return false
    }
    if !composeQueue.isEmpty, !popupGesturePending, let identity = pendingComposePane {
      let pane = grid?.composePanes[identity.leaf]
      if pane?.identity != identity || pane?.pane.compose.keyboard != true {
        socket?.send(input)
        return
      }
    }
    switch input {
    case .key, .mouse, .popupPointer, .paste, .text, .action, .widget, .settingsClick, .kbEditClick:
      let target: ComposePresentation?
      switch input {
      case .text, .paste:
        if let focused = grid?.focusedCompose { target = focused }
        else if let last = composeQueue.last, case .message(.popupPointer(let pointer)) = last.input,
                pointer.mouse.kind == .up, let identity = last.target?.identity,
                let pane = grid?.composePanes[identity.leaf], pane.identity == identity {
          // A click accepting a completion can still be awaiting its reply
          // while the popup has the keyboard. Following text belongs to that
          // captured action's result, including its cancellation/recovery.
          target = pane
        } else { target = nil }
      case .key, .action: target = grid?.focusedCompose
      case .popupPointer(let pointer):
        target = store.popups.first { $0.instance == pointer.instance && $0.version == pointer.version }
          .flatMap { $0.hasSourceAnchor ? grid?.composePanes[$0.sourceAnchor.leaf] : nil }
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
          enqueueCompose(.message(input), target: target,
            selectionPredecessor: pending?.sourceSelection == true ? pending?.token : nil)
        }
      } else {
        let pending = target.flatMap { pane in grid.flatMap { self.grid($0, pendingTextFor: pane.pane) } }
        let predecessor: UUID?
        if case .paste = input, pending?.sourceSelection == true { predecessor = pending?.token }
        else { predecessor = nil }
        enqueueCompose(.message(input), target: target,
          selectionPredecessor: predecessor)
      }
    default:
      socket?.send(input)
    }
  }

  private func enqueueCompose(_ input: PendingInput, target: ComposePresentation?, chain: CompositionChain? = nil,
                              preview: ComposePendingText? = nil, pointerPreview: ComposePointer.Preview? = nil,
                              virtualPrefix: ComposeVirtualSelections? = nil, selectionPredecessor: UUID? = nil,
                              documentSelectionPreview: ComposeVirtualSelections? = nil, token: UUID = UUID()) {
    if composeQueue.isEmpty { lastComposeCancellation = nil }
    composeQueue.append(.init(token: token, input: input, scrollGeneration: composeViewports.userScrollGeneration,
      target: target.map(InputTarget.init), chain: chain,
      preview: preview, origins: preview?.origins(), snapshot: target, pointerPreview: pointerPreview, virtualPrefix: virtualPrefix,
      selectionPredecessor: selectionPredecessor,documentSelectionPreview: documentSelectionPreview))
    grid?.refreshComposeImages()
    pumpComposeInput()
  }

  /// Send one event, wait for its scene/reply, then bind the next event to the
  /// resulting source map. A stale event keeps its id and is measured again.
  private func pumpComposeInput() {
    guard receivedHello, let socket, socket.isOpen, !composeInFlight, !completingComposeInput, let queued = composeQueue.first else { return }
    switch queued.input {
    case .pendingText, .pendingPointer, .document: return // The predecessor must supply real source coordinates.
    default: break
    }
    if pendingComposeID == nil {
      nextComposeID += 1
      pendingComposeID = nextComposeID
      pendingComposePane = queued.target?.identity
    }
    let needsGeometry: Bool
    switch queued.input {
    case .replacement, .selection: needsGeometry = false // Captured real source ranges need no screen geometry.
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
    case .pendingText, .pendingPointer, .document: return
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
           let measured = grid?.composeInputSnapshot(actual, measuredBase: queued.snapshot) { visible = measured }
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
    case .selection(let change):
      input = change.input(id: input.id)
      if pendingComposeLayout, let identity = pendingComposePane {
        let actual = store.panes.first { $0.leaf == identity.leaf && $0.hasBuffer && $0.buffer == identity.buffer }
        if UInt64(store.windowID) != identity.window || actual == nil
            || actual.map({ $0.hasCompose && $0.compose.viewport.epoch != input.bufferEpoch }) == true {
          input.cancel = true
        } else {
          guard let pane = grid?.composePanes[identity.leaf], pane.identity == identity,
                pane.pane.compose.keyboard, grid?.composeInputAllowed == true else { return }
        }
      }
      if let identity = pendingComposePane, let actual = store.panes.first(where: {
        $0.leaf == identity.leaf && $0.hasBuffer && $0.buffer == identity.buffer && $0.hasCompose
      }) { pendingComposeBefore = (actual.compose.bufferRevision, actual.compose.cursors) }
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
    if surface == "popup", let grid, let window = grid.window {
      let rectangles = store.popups.compactMap { grid.popupPresentation($0)?.placement.clip }
        .map { window.convertToScreen(grid.convert($0, to: nil)) }
      guard let first = rectangles.first else { return nil }
      return rectangles.dropFirst().reduce(first) { $0.union($1) }
    }
    let rects = surfaceCells(surface).compactMap { cells -> CGRect? in
      guard let row = screenRect(row: cells.y, col: cells.x, count: cells.width) else { return nil }
      let height = row.height * CGFloat(cells.height)
      return CGRect(x: row.minX, y: row.maxY - height, width: row.width, height: height)
    }
    guard let first = rects.first else { return nil }
    return rects.dropFirst().reduce(first) { $0.union($1) }
  }
}
