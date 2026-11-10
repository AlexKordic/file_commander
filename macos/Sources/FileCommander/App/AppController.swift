import AppKit
import ExplainerKit
import FCKit
import Observation
import SwiftUI

/// A sheet on the main window.
enum SheetKind: Identifiable {
  case copy(DialogRequest)
  case move(DialogRequest)
  case delete(DialogRequest)
  case mkdir(DialogRequest)
  case rename(DialogRequest)
  case extract(DialogRequest)
  case connectSSH
  case restartEditor
  case transferSpeed
  case askpass(AskpassPrompt)
  case welcome
  case confirmCrash(String)

  var id: String {
    switch self {
    case .copy: return "copy"
    case .move: return "move"
    case .delete: return "delete"
    case .mkdir: return "mkdir"
    case .rename: return "rename"
    case .extract: return "extract"
    case .connectSSH: return "ssh"
    case .restartEditor: return "restart"
    case .transferSpeed: return "speed"
    case .askpass(let p): return "askpass-\(p.id)"
    case .welcome: return "welcome"
    case .confirmCrash: return "crash"
    }
  }
}

enum PaletteMode: Equatable {
  case commands
  case help
}

/// The running job as the Transfers menu shows it.
struct MenuJob: Equatable {
  var id: UInt64
  var title: String
  var isPaused: Bool
}

/// What a glob popover is for.
struct GlobRequest: Equatable {
  var side: Int
  var select: Bool
}

/// The app's state outside the engine: preferences, keys, theme, what is
/// presented, and the bridges to windows, the editor and explainers.
@MainActor @Observable
final class AppController {
  static let shared = AppController()

  let engine = Engine.shared
  let theme = ThemeStore()
  var preferences = AppPreferences() {
    didSet {
      guard preferences != oldValue else { return }
      savePreferences()
      if preferences.appearance != oldValue.appearance { applyAppearance() }
      if preferences.zoom != oldValue.zoom || preferences.compose != oldValue.compose { editor.applyTheme() }
      if preferences.editorTelemetry != oldValue.editorTelemetry { applyTelemetry() }
      if preferences.terminalEditor != oldValue.terminalEditor {
        // The next attach takes the other route; close the editor shown the old way.
        engine.setEditorSceneAttach(!preferences.terminalEditor)
        editor.detachAll()
      }
    }
  }

  /// Light, Dark or the system's, for every window of the app.
  func applyAppearance() {
    // The app starts before NSApplication exists; the delegate applies it again at launch.
    guard let application = NSApp else { return }
    switch preferences.appearance {
    case .system: application.appearance = nil
    case .light: application.appearance = NSAppearance(named: .aqua)
    case .dark: application.appearance = NSAppearance(named: .darkAqua)
    }
  }
  var sheet: SheetKind?
  var paletteMode: PaletteMode?
  var glob: GlobRequest?
  var hud: String?
  var startError: String?
  var sidebarVisible = NavigationSplitViewVisibility.all {
    // Remembered across launches, except the fold while the editor is shown.
    didSet {
      let shown = sidebarVisible != .detailOnly
      if !editorShown, preferences.sidebarShown != shown { preferences.sidebarShown = shown }
    }
  }
  @ObservationIgnored private var sidebarBeforeEditor: NavigationSplitViewVisibility?
  var findRoot = ""
  /// Bumped to ask a pane to take keyboard focus (after the focused side changes).
  var focusRequest = 0
  var rebinding: String?  // Command waiting for a new key in the palette.
  var paletteSelection: String?  // The palette's highlighted command, for ⌃K.

  @ObservationIgnored var openWindowAction: OpenWindowAction?
  /// The two file lists, so focus can move to them directly.
  @ObservationIgnored private var listings: [Int: WeakListing] = [:]
  private struct WeakListing { weak var table: ListingTableView? }
  func register(listing table: ListingTableView, side: Int) { listings[side] = WeakListing(table: table) }
  func listing(_ side: Int) -> ListingTableView? { listings[side]?.table }
  @ObservationIgnored var openSettingsAction: (() -> Void)?
  @ObservationIgnored private var hudTask: Task<Void, Never>?
  @ObservationIgnored private var lastKeyRun: (time: TimeInterval, id: String)?
  @ObservationIgnored private var preferencesURL: URL?
  @ObservationIgnored let editor = EditorController()
  @ObservationIgnored let askpass = AskpassServer()
  @ObservationIgnored let scripts = ScriptWindow()
  @ObservationIgnored private(set) var keyRouter: KeyRouter?
  @ObservationIgnored lazy var tutorial = TutorialCoordinator(app: self)

  var keymap: Keymap {
    Keymap(preset: preferences.keyPreset, overrides: preferences.keyOverrides[preferences.keyPreset.rawValue] ?? [:],
           commands: engine.commands)
  }

  private init() {}

  var isTutorialRecording: Bool { CommandLine.arguments.contains("--record-session") }
  var presentedHomeDirectory: String { isTutorialRecording ? tutorial.world.home.path : NSHomeDirectory() }

  // MARK: Lifecycle

  func start(arguments: [String]) {
    var options = Engine.StartOptions()
    var paths: [String] = []
    var resumeExplainer = false
    var index = 0
    while index < arguments.count {
      let arg = arguments[index]
      if arg == "--profile", index + 1 < arguments.count {
        setenv("XDG_CONFIG_HOME", arguments[index + 1], 1)
        index += 1
      } else if arg == "--resume-explainer" {
        resumeExplainer = true
      } else if ["--export-explainer", "--run-explainer", "--out", "--appearance", "--speed", "--trace", "--voice", "--record-session", "--record-take", "--tutorial-world", "--geometry"].contains(arg) {
        index += 1  // Handled by the exporter.
      } else if arg.hasPrefix("-") {
        // AppKit and Xcode pass their own -NS... options.
        if arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") { index += 1 }
      } else {
        paths.append(arg.hasPrefix("ssh://") ? arg : URL(fileURLWithPath: arg).standardizedFileURL.path)
      }
      index += 1
    }
    if paths.count > 0 { options.left = paths[0] }
    if paths.count > 1 { options.right = paths[1] }
    let capture: TutorialCaptureConfiguration?
    if let flag = arguments.firstIndex(of: "--record-session"), flag + 1 < arguments.count {
      capture = try? TutorialCaptureConfiguration.read(URL(fileURLWithPath: arguments[flag + 1]))
    } else { capture = nil }
    if !resumeExplainer, let initial = capture?.initialPath {
      options.left = initial; options.right = initial
    }
    options.toolDirectory = Bundle.main.executableURL?.deletingLastPathComponent().path ?? ""
    askpass.start(app: self)
    if let error = engine.start(options) {
      startError = error
      return
    }
    let profile = URL(fileURLWithPath: engine.profileDirectory)
    preferencesURL = profile.appendingPathComponent("app_settings.json")
    preferences = AppPreferences.load(from: preferencesURL!)
    let presentation = capture?.hostOptions?["appPresentation"].flatMap {
      try? TutorialPresentation.decode(TutorialAppPresentation.self, from: $0)
    }
    if !resumeExplainer, let options = capture?.hostOptions {
      if let shown = options["sidebarShown"]?.bool { preferences.sidebarShown = shown }
      if let sections = options["collapsedSidebarSections"]?.array {
        preferences.collapsedSidebarSections = sections.compactMap(\.string)
      }
      if let presentation {
        preferences.theme = presentation.theme.name
        preferences.zoom = presentation.zoom
        preferences.paneSplit = presentation.paneSplit
        preferences.optionAsAlt = presentation.optionAsAlt
        preferences.compose = presentation.compose
      }
    }
    sidebarVisible = preferences.sidebarShown ? .all : .detailOnly
    applyTelemetry()
    theme.zoom = preferences.zoom
    theme.load(profile: profile, activeName: preferences.theme)
    if let presentation {
      theme.registerRecordingTheme(presentation.theme)
      theme.activate(preferences.theme)
    }
    applyAppearance()
    engine.onDialog = { [weak self] in self?.handle($0) }
    engine.onNotice = { [weak self] in self?.flash($0) }
    engine.onPassword = { [weak self] question in
      guard let self else { return }
      let name = (question.archive as NSString).lastPathComponent
      let text = question.wrong ? "That password is wrong. Enter the password for “\(name)”." : "“\(name)” is encrypted. Enter its password."
      self.askpass.ask(text: text, kind: .secret, title: "Archive Password", field: "Password") { [weak self] answer in
        self?.engine.answerPassword(question.id, answer)
      }
    }
    editor.app = self
    watchJobForMenus()
    engine.onAttach = { [weak self] in self?.editor.attach($0, app: self) }
    engine.setEditorSwitchKey(editorSwitchKey)
    engine.setEditorSceneAttach(!preferences.terminalEditor)
    keyRouter = KeyRouter(app: self)
    if arguments.contains("--record-session") {
      // The recording adapter owns resume and suppresses the welcome sheet in
      // this disposable profile. It starts once the main window is ready.
    } else if resumeExplainer {
      tutorial.resumeAfterRelaunch()
    } else if !preferences.welcomeShown && !arguments.contains("--run-explainer") && !arguments.contains("--export-explainer") {
      sheet = .welcome
    } else if preferences.editorWasOpen && !arguments.contains("--run-explainer") && !arguments.contains("--export-explainer") {
      // The editor comes back as it was left at quit.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
        if let error = self?.engine.switchToEditor() { self?.engine.reportError(error) }
      }
    }
  }

  func stop() {
    tutorial.stopForQuit()
    if !CommandLine.arguments.contains("--run-explainer") { preferences.editorWasOpen = editor.running }
    editor.detachAll()
    EditorTelemetry.shared.stop()
    engine.stop()
    askpass.stop()
  }

  private func savePreferences() {
    guard let url = preferencesURL else { return }
    preferences.save(to: url)
  }

  /// Fresh's switch key, in Fresh's notation.
  var editorSwitchKey: String {
    // Fresh can't see Cmd chords; then the app detaches for it and Fresh keeps F10.
    guard let chord = keymap.chord(for: "switch_to_file_commander"), !chord.modifiers.contains(.command) else { return "f10" }
    var parts: [String] = []
    if chord.modifiers.contains(.control) { parts.append("ctrl") }
    if chord.modifiers.contains(.option) { parts.append("alt") }
    if chord.modifiers.contains(.shift) { parts.append("shift") }
    parts.append(chord.key.lowercased())
    return parts.joined(separator: "+")
  }

  // MARK: Commands

  /// Runs a command the way a key, a menu item, the palette or an explainer does.
  @discardableResult
  func run(_ id: String, keyEvent: NSEvent? = nil) -> Bool {
    // A local event monitor may run before NSApp.currentEvent advances.
    // Deduplicate the actual key being routed, rather than a previous event.
    let triggeringEvent = keyEvent ?? NSApp.currentEvent
    Trace.write("run \(id) sheet \(sheet?.id ?? "-") palette \(String(describing: paletteMode))")
    // A menu shortcut while the palette is open or a key is being captured: those keys are theirs.
    if triggeringEvent?.type == .keyDown, paletteMode != nil || rebinding != nil { return false }
    // Keys typed into the editor are the editor's, even when a menu has the same shortcut.
    if let event = triggeringEvent, event.type == .keyDown, let window = editor.window, event.window === window { return false }
    // One key press runs a command once, even when both the key router and a menu see it.
    if let event = triggeringEvent, event.type == .keyDown {
      if lastKeyRun?.time == event.timestamp && lastKeyRun?.id == id { return true }
      lastKeyRun = (event.timestamp, id)
    }
    switch id {
    case "command_palette":
      paletteMode = paletteMode == .commands ? nil : .commands
      return true
    case "help":
      paletteMode = .help
      return true
    default:
      break
    }
    paletteMode = nil
    if sheet != nil { return false }
    let before = engine.focusedSide
    let ran = engine.execute(id)
    // The keyboard goes with the focused pane, unless a text field is being edited.
    if engine.focusedSide != before, !editorShown, let table = listing(engine.focusedSide), let window = table.window,
       window.firstResponder is ListingTableView || !(window.firstResponder is NSText) {
      window.makeFirstResponder(table)
    }
    Trace.write("ran \(id): \(ran), focused side \(engine.focusedSide)")
    return ran
  }

  func handle(_ request: DialogRequest) {
    switch request.name {
    case "Copy": sheet = .copy(request)
    case "Move": sheet = .move(request)
    case "Delete": sheet = .delete(request)
    case "Mkdir": sheet = .mkdir(request)
    case "Rename": sheet = .rename(request)
    case "Extract": sheet = .extract(request)
    case "Find":
      findRoot = request.origin
      openWindowAction?(id: "find")
    case "GlobSelect": glob = GlobRequest(side: request.side, select: true)
    case "GlobDeselect": glob = GlobRequest(side: request.side, select: false)
    case "ErrorList": openWindowAction?(id: "errors")
    case "JobList": openWindowAction?(id: "activity")
    case "Bookmarks": sidebarVisible = .all
    case "ThemeColors": openSettings(tab: .appearance)
    case "CommandPalette": paletteMode = .commands
    case "Help": paletteMode = .help
    case "TransferSpeed": sheet = .transferSpeed
    case "ConnectSSH": sheet = .connectSSH
    case "RestartEditor": sheet = .restartEditor
    case "SimulateCrash": tutorial.simulateCrash()
    case "RunScript": runScript("")
    default: engine.reportError("Unknown dialog \(request.name)")
    }
  }

  /// Runs a Lua script in a terminal window; an empty path asks for one.
  func runScript(_ path: String) {
    var script = path
    if script.isEmpty {
      let panel = NSOpenPanel()
      panel.allowedContentTypes = [.init(filenameExtension: "lua") ?? .plainText]
      panel.message = "Choose a Lua script. It runs with fc run, which opens File Commander's terminal interface."
      guard panel.runModal() == .OK, let url = panel.url else { return }
      script = url.path
    }
    scripts.run(script: script, theme: theme)
  }

  var settingsTab = SettingsTab.general
  func openSettings(tab: SettingsTab) {
    settingsTab = tab
    openSettingsAction?()
  }

  func flash(_ text: String) {
    hud = text
    hudTask?.cancel()
    hudTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(2.2))
      if !Task.isCancelled { self?.hud = nil }
    }
  }

  // MARK: Telemetry

  /// Where editor timing recordings go.
  var telemetryDirectory: URL { URL(fileURLWithPath: engine.profileDirectory).appendingPathComponent("telemetry") }

  /// Starts or stops recording the editor's timing, as Settings asks.
  private func applyTelemetry() {
    if preferences.editorTelemetry {
      if !EditorTelemetry.shared.isOn { EditorTelemetry.shared.start(directory: telemetryDirectory) }
    } else {
      EditorTelemetry.shared.stop()
    }
    editor.native.telemetryChanged()
  }

  // MARK: Menus

  /// The running job for the Transfers menu. It changes when a job starts,
  /// ends or pauses, not with its progress, and holds still while `menusHeld`.
  private(set) var menuJob: MenuJob?

  /// The editor's menus are in the menu bar. SwiftUI writes changes to the
  /// app's commands into whatever menu bar is installed, so they wait until
  /// the app's own menus are back.
  @ObservationIgnored var menusHeld = false {
    didSet { if !menusHeld { refreshMenuJob() } }
  }

  private func watchJobForMenus() {
    withObservationTracking {
      _ = engine.runningJob
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          self?.refreshMenuJob()
          self?.watchJobForMenus()
        }
      }
    }
  }

  private func refreshMenuJob() {
    guard !menusHeld else { return }
    let job = engine.runningJob.map { MenuJob(id: $0.id, title: $0.title, isPaused: $0.isPaused) }
    if job != menuJob { menuJob = job }
  }

  // MARK: Editor

  /// The editor is shown in the main window in place of the panes.
  var editorShown: Bool { editor.shown }

  /// The main window, where the panes and the editor are shown.
  var mainWindow: NSWindow? { NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true } }

  /// Shows or hides the sidebar of the files view; while the editor is shown,
  /// it takes effect when the files come back.
  func setSidebarShown(_ shown: Bool) {
    if editorShown {
      sidebarBeforeEditor = shown ? .all : .detailOnly
      preferences.sidebarShown = shown
    } else {
      sidebarVisible = shown ? .all : .detailOnly
    }
  }

  /// The main window switches between the panes and the editor.
  func editorShownChanged(_ shown: Bool) {
    // The sidebar folds away while editing: Fresh has its own, and bookmarks
    // would move panes that can't be seen. No animation, so Fresh is resized once.
    var instant = Transaction()
    instant.disablesAnimations = true
    if shown {
      paletteMode = nil
      glob = nil
      withTransaction(instant) {
        sidebarBeforeEditor = sidebarVisible
        sidebarVisible = .detailOnly
      }
      if let window = mainWindow, !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
    } else {
      withTransaction(instant) {
        if let before = sidebarBeforeEditor { sidebarVisible = before }
        sidebarBeforeEditor = nil
      }
      focusPane(engine.focusedSide)
    }
  }

  func focusPane(_ side: Int) {
    engine.setFocusedSide(side)
    if let table = listing(side), let window = table.window, window.firstResponder !== table {
      window.makeFirstResponder(table)
    }
    focusRequest &+= 1
  }

  /// Binds a key for the active preset; returns why it can't, or nil.
  func rebind(_ id: String, to chord: KeyChord?) -> String? {
    let preset = preferences.keyPreset.rawValue
    if let chord, let problem = keymap.conflict(binding: chord, to: id) { return problem }
    var overrides = preferences.keyOverrides[preset] ?? [:]
    overrides[id] = chord?.description ?? ""
    preferences.keyOverrides[preset] = overrides
    if id == "switch_to_file_commander" { engine.setEditorSwitchKey(editorSwitchKey) }
    return nil
  }

  func resetKeys() {
    preferences.keyOverrides[preferences.keyPreset.rawValue] = nil
    engine.setEditorSwitchKey(editorSwitchKey)
  }
}

enum SettingsTab: String, Hashable {
  case general, keys, appearance, transfers, editor, tutorial
}
