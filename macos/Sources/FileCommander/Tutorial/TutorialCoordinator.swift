import AppKit
import ExplainerKit
import FCKit
import SwiftUI

/// Runs explainers in the app: builds the demo world, opens tutorial tabs,
/// presses keys through the app's own key handling, answers conditions about
/// the engine, and puts everything back afterwards.
@MainActor
final class TutorialCoordinator: ExplainerHost {
  static let entireID = "entire"

  unowned let app: AppController
  let runner = ExplainerRunner()
  let annotations = AnnotationWindowController()
  let world = TutorialWorld()
  weak var mainWindow: NSWindow?
  private(set) lazy var catalog: ExplainerCatalog = TutorialCoordinator.loadCatalog()

  private var task: Task<Void, Never>?
  private var snapshot: Snapshot?
  private var namedJobs: [String: UInt64] = [:]
  private var pendingJobName: String?
  private var jobMark: UInt64 = 0
  private var startedJobs: Set<UInt64> = []
  /// Jobs with a higher ID were started while the tutorial ran; cleanup removes them.
  private var jobFloor: UInt64?
  private var events: [EngineEvent] = []
  private var eventMark: UInt64 = 0
  private var observer: UUID?
  private var synthetic: Set<TimeInterval> = []
  private var syntheticCounter = 0.0
  private var crashDecision: CheckedContinuation<Bool, Never>?
  private var crashConfirmed = false
  /// Set by --run-explainer: exit with the result when done.
  var quitWhenDone = false
  private(set) var lastFailure: String?
  private let editorAnchors = EditorAnchors()
  private var rememberedTabs = [0, 0]
  private var lastEditorTrace = ""

  init(app: AppController) {
    self.app = app
    let world = self.world
    AnchorRegistry.shared.alias = { [weak app] raw in
      guard let app else { return raw }
      let id = world.expand(raw)
      let focused = app.engine.focusedSide == 0 ? "left" : "right"
      let other = focused == "left" ? "right" : "left"
      return id.replacingOccurrences(of: "pane.focused", with: "pane.\(focused)").replacingOccurrences(of: "pane.other", with: "pane.\(other)")
    }
    editorAnchors.app = app
    AnchorRegistry.shared.register(resolver: editorAnchors, prefix: "editor.text")
    // Keys only reach an active app, so an explainer waits while you are in another one.
    NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, !self.quitWhenDone, self.runner.state == .running else { return }
        self.runner.pause()
        self.autoPaused = true
      }
    }
    NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.autoPaused else { return }
        self.autoPaused = false
        self.runner.resume()
      }
    }
  }
  private var autoPaused = false

  static func loadCatalog() -> ExplainerCatalog {
    guard let folder = Bundle.module.url(forResource: "Explainers", withExtension: nil) else {
      return ExplainerCatalog(chapters: [], scripts: [])
    }
    do { return try ExplainerCatalog.load(from: folder) } catch {
      NSLog("File Commander: explainers failed to load: \(error)")
      return ExplainerCatalog(chapters: [], scripts: [])
    }
  }

  var isRunning: Bool { task != nil }

  // MARK: Starting and stopping

  func start(_ id: String) {
    let queue: [String]
    if id == TutorialCoordinator.entireID {
      let all = catalog.scripts.map(\.id)
      let position = app.preferences.tutorialPosition < all.count ? app.preferences.tutorialPosition : 0
      queue = Array(all[position...])
    } else {
      queue = [id]
    }
    begin(queue: queue, entire: id == TutorialCoordinator.entireID, resume: nil)
  }

  private func begin(queue: [String], entire: Bool, resume: ResumeRecord?) {
    task?.cancel()
    runner.stop()
    task = Task { [weak self] in
      await self?.run(queue: queue, entire: entire, resume: resume)
    }
  }

  func stop() { runner.stop() }

  func stopForQuit() {
    guard task != nil else { return }
    runner.stop()
    restore(closeTabs: true)
  }

  private func run(queue: [String], entire: Bool, resume: ResumeRecord?) async {
    entireRun = entire
    if snapshot == nil { snapshot = resume?.snapshot ?? takeSnapshot() }
    // After a restart, jobs restored from the journal are the user's unless the explainer adopts them.
    if jobFloor == nil { jobFloor = app.engine.jobs.map(\.id).max() ?? 0 }
    if observer == nil {
      observer = app.engine.observeEvents { [weak self] batch in self?.events.append(contentsOf: batch) }
    }
    guard let window = mainWindow ?? NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) else { return }
    mainWindow = window
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    runner.mode = app.preferences.tutorialMode == .guided ? .guided : .watch
    runner.speed = app.preferences.tutorialSpeed
    annotations.show(over: window, runner: runner, style: overlayStyle, controlsView: AnyView(RunnerControls(coordinator: self)))
    var keepTabs = false
    var failed = false
    for (offset, id) in queue.enumerated() {
      guard let script = catalog.script(id) else { continue }
      do {
        if let resume, offset == 0 {
          runner.overlay.chip = "Restarted after the crash"
          try await runner.run(script, host: self, from: resume.step, prepared: true)
        } else {
          try await runner.run(script, host: self)
        }
        if !app.preferences.watchedExplainers.contains(id) { app.preferences.watchedExplainers.append(id) }
        if entire, let index = catalog.scripts.firstIndex(where: { $0.id == id }) {
          app.preferences.tutorialPosition = index + 1 >= catalog.scripts.count ? 0 : index + 1
        }
        await finish(script, keepTabs: true)
      } catch is CancellationError {
        keepTabs = await askKeepTabs()
        break
      } catch {
        failed = true
        lastFailure = error.localizedDescription
        await finish(script, keepTabs: true)
        if !quitWhenDone {
          let alert = NSAlert()
          alert.messageText = "The explainer stopped"
          alert.informativeText = error.localizedDescription
          alert.runModal()
        }
        break
      }
    }
    if entire && !failed && runner.state == .finished {
      runner.overlay.caption = OverlayModel.Caption(title: "That's the tour", subtitle: "Press F1 and type a command name to find anything else. Help explains any feature again.")
      try? await Task.sleep(for: .seconds(3.5 / max(runner.speed, 0.5)))
    }
    annotations.hide()
    restore(closeTabs: !keepTabs)
    task = nil
    if quitWhenDone {
      if let failure = lastFailure, failed {
        FileHandle.standardError.write(Data("explainer failed: \(failure)\n".utf8))
        Trace.write("explainer failed: \(failure)")
      }
      exit(failed ? 1 : 0)
    }
  }

  private func askKeepTabs() async -> Bool {
    guard !quitWhenDone else { return false }
    let alert = NSAlert()
    alert.messageText = "Keep the tutorial tabs?"
    alert.informativeText = "They show the demo files, which are removed when you close the tabs."
    alert.addButton(withTitle: "Close Them")
    alert.addButton(withTitle: "Keep Them")
    return alert.runModal() == .alertSecondButtonReturn
  }

  /// Handles the user's keys while an explainer plays: in Watch mode only
  /// Esc (stop) and Space (pause) do anything, so a stray key can't derail it.
  func handleKey(_ event: NSEvent) -> Bool {
    if synthetic.remove(event.timestamp) != nil { return false }
    guard runner.isActive, runner.mode == .watch, event.window === mainWindow, event.window?.attachedSheet == nil else { return false }
    if event.keyCode == 53 { runner.stop(); return true }
    if event.keyCode == 49 { runner.togglePause(); return true }
    return true
  }

  // MARK: Snapshot and restore

  struct Snapshot: Codable {
    var transferRate: UInt64
    var keyPreset: AppPreferences.KeyPreset
    var keyOverrides: [String: [String: String]]
    var selectionStyle: AppPreferences.SelectionStyle
    var theme: String
    var appearance: AppPreferences.Appearance
    var zoom: Double
    var singlePane: Bool
    var focusedSide: Int
    var paneSplit: Double
    var bookmarks: [String] = []
  }

  private func takeSnapshot() -> Snapshot {
    let p = app.preferences
    return Snapshot(transferRate: app.engine.transferRate, keyPreset: p.keyPreset, keyOverrides: p.keyOverrides,
                    selectionStyle: p.selectionStyle, theme: p.theme, appearance: p.appearance, zoom: p.zoom,
                    singlePane: app.engine.singlePane, focusedSide: app.engine.focusedSide, paneSplit: p.paneSplit,
                    bookmarks: app.engine.bookmarks.map(\.encoded))
  }

  private func restore(closeTabs: Bool) {
    if let observer { app.engine.stopObserving(observer) }
    observer = nil
    if let s = snapshot {
      app.engine.setTransferRate(s.transferRate, persist: false)
      app.preferences.keyPreset = s.keyPreset
      app.preferences.keyOverrides = s.keyOverrides
      app.preferences.selectionStyle = s.selectionStyle
      app.preferences.appearance = s.appearance
      app.preferences.zoom = s.zoom
      app.preferences.paneSplit = s.paneSplit
      app.theme.zoom = s.zoom
      if app.preferences.theme != s.theme || app.theme.active.name != s.theme {
        app.preferences.theme = s.theme
        app.theme.activate(s.theme)
      }
      app.engine.setSinglePane(s.singlePane)
      app.engine.setFocusedSide(s.focusedSide)
      for bookmark in app.engine.bookmarks where !s.bookmarks.contains(bookmark.encoded) { app.engine.removeBookmark(bookmark.encoded) }
    }
    snapshot = nil
    app.engine.setKeepTutorialTabs(false)
    if FileManager.default.fileExists(atPath: world.profile.path) { stopTutorialEditor(removeHome: closeTabs) }
    app.engine.setEditorSession(store: "", environment: [])
    Engine.setEndpointCommand(host: TutorialWorld.demoHost, command: "")
    for job in app.engine.jobs where startedJobs.contains(job.id) || job.id > (jobFloor ?? .max) {
      if !job.stopped || job.isPaused { app.engine.cancelJob(job.id) }
      app.engine.dismissJob(job.id)
    }
    startedJobs = []
    jobFloor = nil
    namedJobs = [:]
    if app.sheet != nil { app.sheet = nil }
    app.paletteMode = nil
    app.glob = nil
    if closeTabs {
      app.engine.closeTutorialTabs()
      world.remove()
    }
    try? FileManager.default.removeItem(at: resumeURL)
    crashConfirmed = false
  }

  // MARK: ExplainerHost

  var hostWindow: NSWindow? { mainWindow }

  var overlayStyle: OverlayStyle {
    var s = OverlayStyle()
    let t = app.theme
    s.captionBackground = t.color("caption.background")
    s.captionTitle = t.color("caption.title")
    s.captionSubtitle = t.color("caption.subtitle")
    s.highlight = t.color("explainer.highlight")
    s.pointer = t.color("explainer.pointer")
    s.badgeBackground = t.color("explainer.badge")
    s.badgeText = t.color("explainer.badge.text")
    s.crash = t.color("explainer.crash")
    s.spotlight = t.color("explainer.spotlight")
    s.titleFont = t.font("caption.title")
    s.subtitleFont = t.font("caption.subtitle")
    s.badgeFont = t.font("badge")
    s.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    return s
  }

  func prepare(_ script: ExplainerScript) async throws {
    if script.needs("idle_queue"), let job = app.engine.runningJob, !startedJobs.contains(job.id) {
      throw ExplainerFailure(script: script.id, step: 0,
                             message: "A \(job.title.lowercased()) job is running. This explainer pauses the job queue, so finish or cancel the job first.")
    }
    if script.needs("crash") && !crashConfirmed && !quitWhenDone {
      app.sheet = .confirmCrash("“\(script.title)” stops File Commander the hard way, with SIGKILL, and starts it again to show what comes back.")
      let go = await withCheckedContinuation { crashDecision = $0 }
      guard go else { throw CancellationError() }
      crashConfirmed = true
    }
    app.sheet = nil
    app.paletteMode = nil
    app.glob = nil
    let sevenZip = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("7zr").path
    // Each editor explainer starts with a new Fresh session, without old unsaved buffers.
    if script.needs("editor") { stopTutorialEditor(removeHome: true) }
    try world.build(sevenZip: sevenZip)
    Engine.setEndpointCommand(host: TutorialWorld.demoHost, command: world.demoSSH.path)
    if script.needs("editor") {
      app.engine.setEditorSession(store: world.profile.appendingPathComponent("editor_session.json").path,
                                  environment: ["HOME=\(world.profile.path)"])
    }
    app.engine.setKeepTutorialTabs(script.needs("crash") || script.needs("restart"))
    app.engine.setTransferRate(0, persist: false)
    namedJobs = [:]
    mainWindow?.makeKeyAndOrderFront(nil)
    try await Task.sleep(for: .milliseconds(150))
  }

  func finish(_ script: ExplainerScript, keepTabs: Bool) async {
    for id in startedJobs {
      if let job = app.engine.jobs.first(where: { $0.id == id }), !job.stopped || job.isPaused { app.engine.cancelJob(id) }
    }
    app.engine.setTransferRate(snapshot?.transferRate ?? 0, persist: false)
    if app.editor.running && script.needs("editor") { app.editor.detachAll() }
    for id in ["activity", "errors", "find"] {
      NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(id) == true }?.close()
    }
    if script.needs("settings"), let settings = NSApp.windows.first(where: { $0.isVisible && TutorialCoordinator.matches($0, "settings") }) {
      settings.close()
    }
    app.sheet = nil
    app.paletteMode = nil
    runner.overlay.highlights = []
    runner.overlay.spotlight = nil
    runner.overlay.stamp = nil
    runner.overlay.chip = nil
  }

  func willRun(_ step: ExplainerStep, index: Int) {
    eventMark = events.last?.sequence ?? eventMark
    if let name = step.option("as_job")?.string {
      pendingJobName = name
      jobMark = app.engine.jobs.map(\.id).max() ?? 0
    }
  }

  func expand(_ text: String) -> String { world.expand(text) }

  /// Stops the tutorial's Fresh backend (it runs on in its own session otherwise).
  func stopTutorialEditor(removeHome: Bool) {
    if app.editor.running { app.editor.detachAll() }
    let store = world.profile.appendingPathComponent("editor_session.json")
    if let data = try? Data(contentsOf: store),
       let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = record["id"] as? String, !id.isEmpty {
      let pkill = Process()
      pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
      pkill.arguments = ["-f", "--session-name \(id)"]
      try? pkill.run()
      pkill.waitUntilExit()
    }
    if removeHome { try? FileManager.default.removeItem(at: world.profile) }
  }

  /// "@copy" is the key the active preset binds to the copy command.
  func keyLabel(_ chord: String) -> String {
    if chord.hasPrefix("@") {
      let id = String(chord.dropFirst())
      return app.keymap.chord(for: id)?.symbols ?? app.engine.command(id)?.title ?? id
    }
    return KeyChord(chord)?.symbols ?? chord
  }

  /// A sheet or popover that is closing stays key for its animation; keys wait for it.
  private func settleKeyWindow() async {
    for _ in 0..<40 {
      guard let key = NSApp.keyWindow else { return }
      let closingSheet = key.sheetParent != nil && app.sheet == nil
      let closingPopover = key.className.contains("Popover") && app.glob == nil && app.paletteMode == nil
      if !closingSheet && !closingPopover { return }
      try? await Task.sleep(for: .milliseconds(50))
    }
  }

  func press(_ chord: String) async throws {
    await settleKeyWindow()
    if chord.hasPrefix("@") {
      let id = String(chord.dropFirst())
      if let bound = app.keymap.chord(for: id) {
        post(bound, characters: nil)
      } else if !app.run(id) {
        throw ExplainerFailure(script: runner.script?.id ?? "", step: runner.stepIndex, message: "Command \(id) is not available")
      }
      try await Task.sleep(for: .milliseconds(80))
      return
    }
    guard let parsed = KeyChord(chord) else { throw ExplainerFailure(script: runner.script?.id ?? "", step: runner.stepIndex, message: "Bad key \(chord)") }
    post(parsed, characters: nil)
    try await Task.sleep(for: .milliseconds(60))
  }

  func type(_ character: String) async throws {
    guard let c = character.first else { return }
    await settleKeyWindow()
    let shifted = c.isUppercase || "~!@#$%^&*()_+{}|:\"<>?".contains(c)
    post(KeyChord(modifiers: shifted ? [.shift] : [], key: String(c)), characters: character)
  }

  /// Posts a key event to the key window, so it goes through menus, the key
  /// router and text fields exactly as a real key press does.
  private func post(_ chord: KeyChord, characters: String?) {
    if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
    let window = NSApp.keyWindow ?? mainWindow
    let (code, chars, plain) = KeyboardMap.event(for: chord, characters: characters)
    var flags: NSEvent.ModifierFlags = []
    if chord.modifiers.contains(.control) { flags.insert(.control) }
    if chord.modifiers.contains(.option) { flags.insert(.option) }
    if chord.modifiers.contains(.shift) { flags.insert(.shift) }
    if chord.modifiers.contains(.command) { flags.insert(.command) }
    if chord.isFunctionKey || ["Up", "Down", "Left", "Right", "Home", "End", "PageUp", "PageDown", "Delete"].contains(chord.key) {
      flags.insert(.function)
    }
    syntheticCounter += 1
    let timestamp = 1_000_000 + syntheticCounter
    synthetic.insert(timestamp)
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: timestamp, windowNumber: window?.windowNumber ?? 0,
                                      context: nil, characters: chars, charactersIgnoringModifiers: plain, isARepeat: false, keyCode: code) {
        NSApp.postEvent(event, atStart: false)
      }
    }
  }

  func drag(from rawFrom: String, to rawTo: String, duration: Double) async throws {
    let from = world.expand(rawFrom), to = world.expand(rawTo)
    guard from.hasPrefix("editor.text") else { return }
    guard let start = editorAnchors.cell(from), let end = editorAnchors.cell(to, after: true) else {
      throw ExplainerFailure(script: runner.script?.id ?? "", step: runner.stepIndex, message: "Can't find \(rawFrom) in the editor")
    }
    let row = start.row + 1
    app.editor.send("\u{1b}[<0;\(start.col + 1);\(row)M")
    let steps = max(1, end.col - start.col)
    for col in start.col + 1...max(start.col + 1, end.col) {
      try await Task.sleep(for: .seconds(duration / Double(steps)))
      app.editor.send("\u{1b}[<32;\(col + 1);\(row)M")
    }
    app.editor.send("\u{1b}[<0;\(end.col + 1);\(row)m")
  }

  // MARK: Host steps

  func perform(_ step: ExplainerStep, runner: ExplainerRunner) async throws -> Bool {
    let v = step.value
    switch step.action {
    case "open_tabs":
      for (key, side) in [("left", 0), ("right", 1)] {
        guard let location = v[key]?.string.map(world.expand) else { continue }
        let pane = app.engine.pane(side)
        if pane.tabs.indices.contains(pane.activeTab), pane.tabs[pane.activeTab].tutorial {
          app.engine.navigate(side, to: location)
        } else if let index = pane.tabs.firstIndex(where: \.tutorial) {
          app.engine.switchTab(side, to: index)
          app.engine.navigate(side, to: location)
        } else {
          app.engine.newTab(side, location: location, tutorial: true)
        }
      }
      app.focusPane(v["focus"]?.string == "right" ? 1 : 0)
      try await runner.waitFor("the tutorial tabs to load", timeout: 10) {
        !app.engine.left.loading && !app.engine.right.loading
      }
    case "navigate":
      let side = sideOf(v["side"])
      app.engine.navigate(side, to: world.expand(v["to"]?.string ?? ""), focus: world.expand(v["focus"]?.string ?? ""))
      try await runner.waitFor("the folder to load", timeout: 10) { !app.engine.pane(side).loading }
    case "focus":
      app.focusPane(sideOf(v))
    case "cursor":
      let side = sideOf(v["side"])
      let name = v["name"]?.string ?? ""
      try await runner.waitFor("\(name) in the list", timeout: 10) { app.engine.rowNamed(side, name) != nil }
      if let row = app.engine.rowNamed(side, name) { app.engine.setCursor(side, row: row) }
    case "command":
      let id = v.string ?? ""
      if let title = app.engine.command(id)?.title { runner.overlay.badge(title) }
      runner.record("keys", id)
      guard app.run(id) || id == "command_palette" || id == "help" else {
        throw ExplainerFailure(script: runner.script?.id ?? "", step: runner.stepIndex, message: "Command \(id) is not available")
      }
      try await Task.sleep(for: .milliseconds(120))
    case "set_transfer_speed":
      let bytes = UInt64(v.number ?? 0) != 0 ? UInt64(v.number ?? 0) : TutorialCoordinator.parseRate(v.string ?? "0")
      app.engine.setTransferRate(bytes, persist: false)
    case "set_preference":
      for (key, value) in v.object ?? [:] {
        switch key {
        case "selection": app.preferences.selectionStyle = AppPreferences.SelectionStyle(rawValue: value.string ?? "") ?? .commander
        case "keys": app.preferences.keyPreset = AppPreferences.KeyPreset(rawValue: value.string ?? "") ?? .commander
        case "appearance": app.preferences.appearance = AppPreferences.Appearance(rawValue: value.string ?? "") ?? .system
        case "theme":
          app.preferences.theme = value.string ?? "Default"
          app.theme.activate(app.preferences.theme)
        case "zoom":
          app.preferences.zoom = value.number ?? 1
          app.theme.zoom = app.preferences.zoom
        default: break
        }
      }
    case "open_window":
      let id = v.string ?? ""
      if id == "settings" {
        app.openSettings(tab: SettingsTab(rawValue: step.option("note")?.string ?? "appearance") ?? .appearance)
      } else {
        app.openWindowAction?(id: id)
      }
      try await Task.sleep(for: .milliseconds(400))
    case "close_window":
      let id = v.string ?? ""
      NSApp.windows.first { $0.isVisible && TutorialCoordinator.matches($0, id) }?.close()
      mainWindow?.makeKeyAndOrderFront(nil)
      app.focusRequest &+= 1
    case "front":
      mainWindow?.makeKeyAndOrderFront(nil)
      app.focusRequest &+= 1
    case "dismiss_sheet":
      app.sheet = nil
    case "touch":
      let path = world.expand(v.string ?? "")
      guard world.contains(path) else { throw ExplainerFailure(script: runner.script?.id ?? "", step: runner.stepIndex, message: "\(path) is outside the demo files") }
      FileManager.default.createFile(atPath: path, contents: Data("changed by the tutorial\n".utf8))
    case "crash":
      try await crash(message: v.string ?? "")
    case "relaunch":
      try await relaunch()
    case "editor_type":
      let text = v.string ?? ""
      runner.overlay.badge("⌨ " + text)
      for character in text {
        app.editor.send(String(character))
        try await runner.sleep(0.05)
      }
    case "notice":
      app.flash(world.expand(v.string ?? ""))
    case "editor_keys":
      // Sent as terminal bytes, so they reach Fresh whatever has the focus.
      let gap = (step.option("gap")?.number ?? 200) / 1000
      for chord in v.strings {
        runner.overlay.badge(keyLabel(chord))
        runner.record("keys", chord)
        guard let bytes = TerminalKeys.bytes(for: chord) else {
          throw ExplainerFailure(script: runner.script?.id ?? "", step: runner.stepIndex, message: "No terminal sequence for \(chord)")
        }
        app.editor.send(bytes)
        try await runner.sleep(gap)
      }
    case "remove_bookmark":
      if let bookmark = app.engine.bookmarks.first(where: { $0.title == v.string }) { app.engine.removeBookmark(bookmark.encoded) }
    case "remember":
      rememberedTabs = [app.engine.left.tabs.count, app.engine.right.tabs.count]
    case "run_script":
      app.runScript(world.expand(v.string ?? ""))
    default:
      return false
    }
    return true
  }

  /// Windows by name: SwiftUI's window IDs start with the scene ID; Settings has its own.
  static func matches(_ window: NSWindow, _ id: String) -> Bool {
    let identifier = window.identifier?.rawValue ?? ""
    if id == "settings" { return identifier.localizedCaseInsensitiveContains("settings") }
    return identifier.hasPrefix(id)
  }

  static func parseRate(_ text: String) -> UInt64 {
    let parts = text.split(separator: " ")
    guard let n = Double(parts.first ?? "0") else { return 0 }
    switch parts.dropFirst().first?.lowercased() {
    case "kib", "kb": return UInt64(n * 1024)
    case "mib", "mb": return UInt64(n * 1_048_576)
    case "gib", "gb": return UInt64(n * 1_073_741_824)
    default: return UInt64(n)
    }
  }

  private func sideOf(_ value: JSONValue?) -> Int {
    switch value?.string {
    case "right": return 1
    case "left": return 0
    case "other": return 1 - app.engine.focusedSide
    default: return app.engine.focusedSide
    }
  }

  // MARK: Conditions

  private func job(named name: String) -> JobInfo? {
    if name == "running" { return app.engine.runningJob }
    if name == "paused", let job = app.engine.jobs.first(where: { $0.isPaused }) {
      startedJobs.insert(job.id)  // The explainer's own copy, restored after its crash.
      return job
    }
    if namedJobs[name] == nil, pendingJobName == name, let id = app.engine.jobs.map(\.id).filter({ $0 > jobMark }).min() {
      namedJobs[name] = id
      startedJobs.insert(id)
      pendingJobName = nil
    }
    guard let id = namedJobs[name] else { return nil }
    return app.engine.jobs.first { $0.id == id }
  }

  func evaluate(_ condition: JSONValue) -> Bool {
    // Jobs the explainer starts are its own, so cleanup can dismiss them.
    if let running = app.engine.runningJob, let floor = jobFloor, running.id > floor { startedJobs.insert(running.id) }
    guard let object = condition.object, let (key, value) = object.first else { return condition.bool ?? false }
    switch key {
    case "all": return (value.array ?? []).allSatisfy(evaluate)
    case "any": return (value.array ?? []).contains(where: evaluate)
    case "not": return !evaluate(value)
    case "rows", "listing":
      let side = sideOf(value["side"])
      if let name = value["contains"]?.string { return app.engine.rowNamed(side, world.expand(name)) != nil }
      if let name = value["lacks"]?.string { return app.engine.rowNamed(side, name) == nil }
      if let n = value["at_least"]?.number { return app.engine.rowCount(side) >= Int(n) }
      if let n = value["count"]?.number { return app.engine.rowCount(side) == Int(n) }
      return false
    case "selected":
      let pane = app.engine.pane(sideOf(value["side"]))
      if let n = value["count"]?.number { return pane.itemsSelected == Int64(n) }
      if let n = value["at_least"]?.number { return pane.itemsSelected >= Int64(n) }
      return pane.itemsSelected > 0
    case "cursor":
      let side = sideOf(value["side"])
      let pane = app.engine.pane(side)
      guard pane.cursorRow >= 0 else { return false }
      return app.engine.row(side, Int(pane.cursorRow)).name == value["name"]?.string
    case "path":
      let pane = app.engine.pane(sideOf(value["side"]))
      if let suffix = value["ends_with"]?.string { return pane.path.hasSuffix(suffix) && !pane.loading }
      if let text = value["contains"]?.string { return pane.path.contains(world.expand(text)) && !pane.loading }
      return false
    case "filter": return app.engine.pane(sideOf(value["side"])).filter == (value["is"]?.string ?? "")
    case "loaded": return !app.engine.pane(sideOf(value)).loading
    case "loading": return app.engine.pane(sideOf(value["side"])).loading == (value["is"]?.bool ?? true)
    case "tabs":
      let pane = app.engine.pane(sideOf(value["side"]))
      if let n = value["count"]?.number { return pane.tabs.count == Int(n) }
      if let n = value["active"]?.number { return pane.activeTab == Int(n) - 1 }
      if let n = value["added"]?.number { return pane.tabs.count - rememberedTabs[sideOf(value["side"])] == Int(n) }
      return false
    case "focused": return app.engine.focusedSide == sideOf(value)
    case "single": return app.engine.singlePane == (value.bool ?? true)
    case "sort": return app.engine.pane(sideOf(value["side"])).sort.rawValue == ["name", "name_desc", "size", "size_desc", "date", "date_desc"].firstIndex(of: value["is"]?.string ?? "")
    case "columns":
      let pane = app.engine.pane(sideOf(value["side"]))
      return pane.showPermissions == (value["permissions"]?.bool ?? pane.showPermissions) && pane.showOwnerGroup == (value["owner"]?.bool ?? pane.showOwnerGroup)
    case "sheet":
      if value == .null { return app.sheet == nil && mainWindow?.attachedSheet == nil }
      return app.sheet?.id == value.string
    case "palette":
      if value == .null { return app.paletteMode == nil }
      return value.string == "help" ? app.paletteMode == .help : app.paletteMode == .commands
    case "glob": return (app.glob != nil) == (value.bool ?? true)
    case "text_focus":
      // A text field is being edited in the key window (the field editor has the focus).
      let editing = NSApp.keyWindow?.firstResponder is NSTextView && !(NSApp.keyWindow?.firstResponder is ListingTableView)
      if Trace.enabled {
        Trace.write("focus: key \(String(describing: NSApp.keyWindow)) responder \(String(describing: NSApp.keyWindow?.firstResponder)) active \(NSApp.isActive)\n")
      }
      return editing == (value.bool ?? true)
    case "anchor": return AnchorRegistry.shared.exists(world.expand(value.string ?? ""))
    case "job":
      guard let job = job(named: value["name"]?.string ?? "running") else { return value["state"]?.string == "none" }
      if let state = value["state"]?.string, job.state != state, !(state == "finished" && job.stopped && !job.isPaused) { return false }
      if let p = value["progress_at_least"]?.number, job.percent < p * 100 { return false }
      if let n = value["errors_at_least"]?.number, job.errors < Int64(n) { return false }
      if let note = value["note"]?.bool, note != !job.recoveryNote.isEmpty { return false }
      return true
    case "running_job": return (app.engine.runningJob != nil) == (value.bool ?? true)
    case "queued_at_least": return app.engine.queuedJobs >= Int64(value.number ?? 1)
    case "event":
      let name = value["name"]?.string ?? value.string ?? ""
      let detail = value["detail"]?.string
      return events.contains { $0.sequence > eventMark && $0.name == name && (detail == nil || $0.detail.contains(detail!)) }
    case "clipboard":
      let text = NSPasteboard.general.string(forType: .string) ?? ""
      return text.contains(world.expand(value["contains"]?.string ?? ""))
    case "hud": return app.hud?.contains(value.string ?? "") ?? false
    case "errors_at_least": return app.engine.errorCount >= Int64(value.number ?? 1)
    case "no_errors": return app.engine.errorCount == 0
    case "window":
      let id = value.string ?? ""
      return NSApp.windows.contains { $0.isVisible && TutorialCoordinator.matches($0, id) }
    case "editor":
      if Trace.enabled {
        let lines = app.editor.screenLines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let summary = "editor running \(app.editor.running) lines \(lines.count): " + lines.prefix(18).joined(separator: "\n  ")
        if summary != lastEditorTrace { lastEditorTrace = summary; Trace.write(summary) }
      }
      if let running = value["running"]?.bool { return app.editor.running == running }
      guard let pattern = value["contains"]?.string, let regex = try? NSRegularExpression(pattern: pattern) else { return false }
      let text = app.editor.screenLines.joined(separator: "\n")
      return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    case "bookmark": return app.engine.bookmarks.contains { $0.title == value.string || $0.path.hasSuffix(value.string ?? "\u{0}") }
    case "no_bookmark": return !app.engine.bookmarks.contains { $0.title == value.string }
    case "transfer_rate": return app.engine.transferRate == TutorialCoordinator.parseRate(value.string ?? "\(Int(value.number ?? 0))")
    case "file":
      let path = world.expand(value["exists"]?.string ?? value["missing"]?.string ?? "")
      return FileManager.default.fileExists(atPath: path) == (value["exists"] != nil)
    case "theme": return app.theme.active.name == value.string
    case "font_size":
      return app.theme.active.font(value["element"]?.string ?? "listing.name").size == value["is"]?.number
    default:
      return false
    }
  }

  func describe(_ condition: JSONValue) -> String {
    guard let data = try? JSONEncoder().encode(condition), let text = String(data: data, encoding: .utf8) else { return "a condition" }
    return text
  }

  // MARK: Crash and relaunch

  private struct ResumeRecord: Codable {
    var queue: [String]
    var entire: Bool
    var step: Int
    var snapshot: Snapshot
    var jobs: [UInt64]
    var time: Date
  }

  private var resumeURL: URL { world.root.deletingLastPathComponent().appendingPathComponent("tutorial_resume.json") }

  func confirmCrash(_ go: Bool) {
    crashDecision?.resume(returning: go)
    crashDecision = nil
  }

  /// The hidden simulate_crash command: crashes only inside an explainer, which resumes after the restart.
  func simulateCrash() {
    guard runner.isActive else {
      app.flash("Simulate Crash only runs inside the crash recovery explainer")
      return
    }
    Task { try? await crash(message: "Simulate Crash") }
  }

  private func crash(message: String) async throws {
    guard let script = runner.script else { return }
    runner.overlay.stamp = "KILLED"
    runner.record("crash", message)
    try await Task.sleep(for: .milliseconds(900))
    try writeResume(script: script)
    try spawnRelauncher()
    // A real crash: no checkpoint, no goodbye. Recovery must work from what is on disk.
    kill(getpid(), SIGKILL)
  }

  private func relaunch() async throws {
    guard let script = runner.script else { return }
    runner.overlay.caption = OverlayModel.Caption(title: "Quitting…", subtitle: "File Commander saves the workspace and starts again")
    try await Task.sleep(for: .milliseconds(600))
    try writeResume(script: script)
    try spawnRelauncher()
    annotations.hide()
    app.engine.stop()
    exit(0)
  }

  private func writeResume(script: ExplainerScript) throws {
    var queue = [script.id]
    if let index = catalog.scripts.firstIndex(where: { $0.id == script.id }), app.preferences.tutorialPosition > 0 || runnerIsEntire {
      queue += catalog.scripts[(index + 1)...].map(\.id)
    }
    let record = ResumeRecord(queue: queue, entire: runnerIsEntire, step: runner.stepIndex + 1, snapshot: snapshot ?? takeSnapshot(),
                              jobs: Array(startedJobs), time: Date())
    let data = try JSONEncoder().encode(record)
    try data.write(to: resumeURL, options: .atomic)
  }

  private var runnerIsEntire: Bool { entireRun }
  var entireRun = false

  private func spawnRelauncher() throws {
    let executable = Bundle.main.executableURL!
    let helper = executable.deletingLastPathComponent().appendingPathComponent("fc-relaunch")
    let bundle = Bundle.main.bundleURL
    let target = bundle.pathExtension == "app" ? bundle.path : executable.path
    let process = Process()
    process.executableURL = helper
    // The same profile and options as now, minus the explainer that started it.
    var kept: [String] = []
    var rest = Array(CommandLine.arguments.dropFirst())
    while !rest.isEmpty {
      let arg = rest.removeFirst()
      if arg == "--run-explainer" || arg == "--speed" { if !rest.isEmpty { rest.removeFirst() }; continue }
      if arg == "--resume-explainer" || arg == "--run-quit" || arg.hasPrefix("-NS") || arg.hasPrefix("-psn") { continue }
      kept.append(arg)
    }
    process.arguments = ["\(getpid())", target] + kept + ["--resume-explainer"] + (quitWhenDone ? ["--run-quit"] : [])
    try process.run()
  }

  func resumeAfterRelaunch() {
    guard let data = try? Data(contentsOf: resumeURL), let record = try? JSONDecoder().decode(ResumeRecord.self, from: data) else { return }
    try? FileManager.default.removeItem(at: resumeURL)
    guard Date().timeIntervalSince(record.time) < 120 else {
      app.flash("The tutorial was interrupted; open Help to continue it")
      snapshot = record.snapshot
      restore(closeTabs: true)
      return
    }
    if CommandLine.arguments.contains("--run-quit") { quitWhenDone = true }
    startedJobs = Set(record.jobs)
    entireRun = record.entire
    crashConfirmed = true
    snapshot = record.snapshot
    app.engine.adoptTutorialTabs(prefix: world.root.path)
    Engine.setEndpointCommand(host: TutorialWorld.demoHost, command: world.demoSSH.path)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
      self?.begin(queue: record.queue, entire: record.entire, resume: ResumeRecord(queue: record.queue, entire: record.entire, step: record.step,
                                                                                    snapshot: record.snapshot, jobs: record.jobs, time: record.time))
    }
  }
}

/// The runner's controls, in a small panel over the window's top right.
struct RunnerControls: View {
  let coordinator: TutorialCoordinator
  var body: some View {
    let runner = coordinator.runner
    HStack(spacing: 10) {
      Image(systemName: "graduationcap.fill").foregroundStyle(.purple)
      VStack(alignment: .leading, spacing: 1) {
        Text(runner.script?.title ?? "Tutorial").font(.callout.weight(.semibold)).lineLimit(1)
        Text(status(runner)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      .frame(width: 170, alignment: .leading)
      if case .waitingForUser = runner.state {
        Button("Show Me") { runner.showMe() }.controlSize(.small)
      }
      Button { runner.togglePause() } label: { Image(systemName: runner.state == .paused ? "play.fill" : "pause.fill") }
        .help(runner.state == .paused ? "Continue (Space)" : "Pause (Space)")
      Button { runner.skip() } label: { Image(systemName: "forward.end.fill") }.help("Next step")
      Button { runner.stop() } label: { Image(systemName: "xmark") }.help("Stop the tutorial (Esc)")
    }
    .buttonStyle(.borderless)
    .padding(.horizontal, 14).padding(.vertical, 9)
    .background(.regularMaterial, in: Capsule())
    .overlay(Capsule().stroke(Color.primary.opacity(0.1)))
    .fixedSize()
  }

  private func status(_ runner: ExplainerRunner) -> String {
    switch runner.state {
    case .paused: return "Paused · step \(runner.overlay.progress)"
    case .waitingForUser(let task): return "Your turn: \(task)"
    case .failed(let error): return error
    default: return "Step \(runner.overlay.progress)"
    }
  }
}

/// Anchors in the editor's terminal: "editor.text[<regex>]" is the first match on screen.
@MainActor
final class EditorAnchors: AnchorResolver {
  weak var app: AppController?

  func cell(_ id: String, after: Bool = false) -> (row: Int, col: Int)? {
    guard let app, let open = id.firstIndex(of: "["), id.hasSuffix("]") else { return nil }
    let pattern = String(id[id.index(after: open)..<id.index(before: id.endIndex)])
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    for (row, line) in app.editor.screenLines.enumerated() {
      let ns = line as NSString
      if let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
        let prefix = ns.substring(to: match.range.location)
        let col = prefix.count + (after ? ns.substring(with: match.range).count : 0)
        return (row, col)
      }
    }
    return nil
  }

  func screenRect(for id: String) -> CGRect? {
    guard let app, let start = cell(id), let end = cell(id, after: true) else { return nil }
    return app.editor.screenRect(row: start.row, col: start.col, count: max(1, end.col - start.col))
  }

  func perform(anchor id: String) -> Bool { false }
}

/// US keyboard key codes, so synthetic events look like real ones.
enum KeyboardMap {
  static let named: [String: (UInt16, Int?)] = [
    "Enter": (36, 13), "Esc": (53, 27), "Tab": (48, 9), "Space": (49, 32), "Backspace": (51, 127), "Delete": (117, NSDeleteFunctionKey),
    "Up": (126, NSUpArrowFunctionKey), "Down": (125, NSDownArrowFunctionKey), "Left": (123, NSLeftArrowFunctionKey),
    "Right": (124, NSRightArrowFunctionKey), "Home": (115, NSHomeFunctionKey), "End": (119, NSEndFunctionKey),
    "PageUp": (116, NSPageUpFunctionKey), "PageDown": (121, NSPageDownFunctionKey),
    "F1": (122, NSF1FunctionKey), "F2": (120, NSF2FunctionKey), "F3": (99, NSF3FunctionKey), "F4": (118, NSF4FunctionKey),
    "F5": (96, NSF5FunctionKey), "F6": (97, NSF6FunctionKey), "F7": (98, NSF7FunctionKey), "F8": (100, NSF8FunctionKey),
    "F9": (101, NSF9FunctionKey), "F10": (109, NSF10FunctionKey), "F11": (103, NSF11FunctionKey), "F12": (111, NSF12FunctionKey),
  ]
  static let characters: [Character: UInt16] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
    "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
    "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
    "n": 45, "m": 46, ".": 47, "`": 50, "+": 24, "?": 44, "*": 28, "\"": 39, "_": 27, ":": 41, "<": 43, ">": 47, "!": 18, "@": 19,
    "#": 20, "$": 21, "%": 23, "^": 22, "&": 26, "(": 25, ")": 29, "{": 33, "}": 30, "|": 42, "~": 50, " ": 49,
  ]

  static func event(for chord: KeyChord, characters: String?) -> (UInt16, String, String) {
    if let (code, scalar) = named[chord.key] {
      let text = scalar.flatMap { UnicodeScalar($0) }.map { String(Character($0)) } ?? ""
      return (code, text, text)
    }
    let base = (characters ?? chord.key).first ?? " "
    let lower = Character(base.lowercased())
    let code = KeyboardMap.characters[lower] ?? 0
    var text = characters ?? (chord.modifiers.contains(.shift) ? chord.key.uppercased() : chord.key.lowercased())
    var plain = text
    if chord.modifiers.contains(.control), let ascii = lower.asciiValue, lower.isLetter {
      text = String(UnicodeScalar(ascii - 96))
      plain = String(lower)
    } else if chord.modifiers.contains(.command) {
      plain = chord.modifiers.contains(.shift) ? String(base).uppercased() : String(lower)
      text = plain
    }
    return (code, text, plain)
  }
}

/// Terminal byte sequences for keys, as an xterm sends them.
enum TerminalKeys {
  static func bytes(for chord: String) -> String? {
    let named: [String: String] = [
      "Enter": "\r", "Tab": "\t", "Esc": "\u{1b}", "Backspace": "\u{7f}", "Space": " ", "Delete": "\u{1b}[3~",
      "Up": "\u{1b}[A", "Down": "\u{1b}[B", "Right": "\u{1b}[C", "Left": "\u{1b}[D", "Home": "\u{1b}[H", "End": "\u{1b}[F",
      "PageUp": "\u{1b}[5~", "PageDown": "\u{1b}[6~", "F1": "\u{1b}OP", "F2": "\u{1b}OQ", "F3": "\u{1b}OR", "F4": "\u{1b}OS",
      "F5": "\u{1b}[15~", "F6": "\u{1b}[17~", "F7": "\u{1b}[18~", "F8": "\u{1b}[19~", "F9": "\u{1b}[20~", "F10": "\u{1b}[21~",
      "F11": "\u{1b}[23~", "F12": "\u{1b}[24~",
    ]
    guard let parsed = KeyChord(chord) else { return nil }
    if parsed.modifiers.isEmpty { return named[parsed.key] ?? parsed.key.lowercased() }
    if parsed.modifiers == [.control], parsed.key.count == 1, let ascii = parsed.key.uppercased().first?.asciiValue, (64...95).contains(ascii) {
      return String(UnicodeScalar(ascii - 64))
    }
    if parsed.modifiers == [.shift], parsed.key.count == 1 { return parsed.key.uppercased() }
    if parsed.modifiers == [.shift], parsed.key == "Tab" { return "\u{1b}[Z" }
    if parsed.modifiers == [.option], parsed.key.count == 1 { return "\u{1b}" + parsed.key.lowercased() }
    return nil
  }
}
