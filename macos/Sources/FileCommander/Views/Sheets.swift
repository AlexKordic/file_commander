import AppKit
import ExplainerKit
import FCKit
import SwiftUI

struct SheetHost: View {
  let kind: SheetKind
  var body: some View {
    switch kind {
    case .copy(let request): CopySheet(request: request)
    case .move(let request): MoveSheet(request: request)
    case .delete(let request): DeleteSheet(request: request)
    case .mkdir(let request): MkdirSheet(request: request)
    case .rename(let request): RenameSheet(request: request)
    case .connectSSH: ConnectSheet()
    case .restartEditor: RestartEditorSheet()
    case .transferSpeed: TransferSpeedView(inPopover: false).padding(20).frame(width: 380)
    case .askpass(let prompt): AskpassSheet(prompt: prompt)
    case .welcome: WelcomeSheet()
    case .confirmCrash(let text): ConfirmCrashSheet(text: text)
    }
  }
}

/// Sheet chrome: a title, content, and buttons at the bottom right.
struct SheetFrame<Content: View, Buttons: View>: View {
  let title: String
  var subtitle = ""
  var width: CGFloat = 520
  @ViewBuilder let content: Content
  @ViewBuilder let buttons: Buttons
  @Environment(AppController.self) private var app

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.title3.weight(.semibold))
        if !subtitle.isEmpty { Text(subtitle).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle) }
      }
      content
      HStack { Spacer(); buttons }
    }
    .font(app.theme.font("sheet.body"))
    .padding(20)
    .frame(width: width)
  }
}

private func itemList(_ paths: [String]) -> some View {
  List(paths, id: \.self) { path in
    Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "doc")
      .lineLimit(1)
      .help(path)
  }
  .listStyle(.bordered(alternatesRowBackgrounds: true))
  .frame(height: min(CGFloat(paths.count) * 24 + 12, 180))
}

// MARK: Copy

struct CopySheet: View {
  let request: DialogRequest
  @Environment(AppController.self) private var app
  @State private var destination = ""
  @State private var followLinks = false
  @State private var keepRelative = true
  @State private var conflict = 0
  @State private var session: UInt64 = 0
  @State private var discovery = Discovery.empty
  @State private var preview: [PreviewRow] = []
  @State private var startWhenReady = false
  @State private var error = ""
  @State private var timer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()
  @State private var discovered = ""
  @FocusState private var destinationFocused: Bool

  var body: some View {
    SheetFrame(title: "Copy \(request.selected.count) \(request.selected.count == 1 ? "item" : "items")",
               subtitle: request.selected.count == 1 ? request.selected[0] : request.origin, width: 600) {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("To:")
          TextField("Destination folder", text: $destination)
            .textFieldStyle(.roundedBorder)
            .focused($destinationFocused)
            .font(app.theme.font("sheet.field"))
            .onSubmit(restart)
            .explainerAnchor("sheet.copy.destination")
        }
        if destination.lowercased().hasSuffix(".7z") {
          Label("Creates a 7z archive with the selection", systemImage: "archivebox").font(.callout).foregroundStyle(.secondary)
        }
        HStack(alignment: .top, spacing: 28) {
          VStack(alignment: .leading, spacing: 6) {
            Toggle("Follow links in the source", isOn: $followLinks).explainerAnchor("sheet.copy.follow") { followLinks.toggle() }
            Toggle("Keep relative links", isOn: $keepRelative).explainerAnchor("sheet.copy.relative") { keepRelative.toggle() }
          }
          Picker("When the destination exists:", selection: $conflict) {
            Text("Replace existing").tag(0).explainerAnchor("sheet.copy.conflict[mode=replace]") { conflict = 0 }
            Text("Update if newer").tag(1).explainerAnchor("sheet.copy.conflict[mode=update]") { conflict = 1 }
            Text("Skip existing").tag(2).explainerAnchor("sheet.copy.conflict[mode=skip]") { conflict = 2 }
          }
          .pickerStyle(.radioGroup)
          .explainerAnchor("sheet.copy.conflict")
          .onKeyPress(characters: .decimalDigits) { press in
            guard let n = Int(press.characters), (1...3).contains(n) else { return .ignored }
            conflict = n - 1
            return .handled
          }
        }
        .onChange(of: followLinks) { restart() }
        .onChange(of: keepRelative) { restart() }
        .onChange(of: conflict) { restart() }
        HStack(spacing: 8) {
          if discovery.running { ProgressView().controlSize(.small) }
          Text(status).foregroundStyle(.secondary).font(.callout.monospacedDigit())
        }
        .explainerAnchor("sheet.copy.status")
        List(preview, id: \.self) { row in
          HStack {
            Image(systemName: row.kind == "folder" ? "folder" : row.kind == "link" ? "arrow.up.right.square" : "doc")
              .foregroundStyle(.secondary)
            Text(row.source).lineLimit(1).truncationMode(.head)
            Spacer()
            if !row.message.isEmpty { Text(row.message).foregroundStyle(.orange).lineLimit(1) }
            if row.kind == "file" { Text(Format.bytes(row.bytes)).foregroundStyle(.secondary).font(.callout.monospacedDigit()) }
          }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
        .frame(height: 170)
        .explainerAnchor("sheet.copy.preview")
        if !error.isEmpty { Text(error).foregroundStyle(.red) }
      }
    } buttons: {
      Button("Cancel") { close() }.keyboardShortcut(.cancelAction).explainerAnchor("sheet.copy.cancel", action: close)
      Button(startWhenReady ? "Preparing…" : "Copy", action: start)
        .keyboardShortcut(.defaultAction)
        .explainerAnchor("sheet.copy.start", action: start)
      Button("", action: start).keyboardShortcut(KeyChord("F5")!.shortcut!).hidden().frame(width: 0)
    }
    .onAppear {
      destination = request.target
      restart()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { destinationFocused = true }
    }
    .onReceive(timer) { _ in poll() }
    .onDisappear { if session != 0 { app.engine.discoveryCancel(session) } }
  }

  private var status: String {
    let size = Format.bytes(discovery.bytes)
    let base = "\(discovery.files) files, \(discovery.dirs) folders, \(size)"
    if discovery.running { return "Scanning… \(base)" }
    return discovery.errors > 0 ? "\(base), \(discovery.errors) unreadable" : base
  }

  private func restart() {
    if session != 0 { app.engine.discoveryCancel(session) }
    var options = CopyOptions()
    options.sources = request.selected
    options.destination = destination.isEmpty ? request.target : destination
    discovered = options.destination
    options.followLinks = followLinks
    options.keepRelativeLinks = keepRelative
    options.conflict = conflict
    session = app.engine.copyDiscover(options)
    preview = []
    poll()
  }

  private func poll() {
    guard session != 0 else { return }
    discovery = app.engine.discovery(session)
    if preview.count < 300, Int64(preview.count) < discovery.steps {
      preview += app.engine.discoveryPreview(session, from: preview.count, count: 300 - preview.count)
    }
    if startWhenReady && !discovery.running { start() }
  }

  private func start() {
    // An edited destination needs a new plan before anything is copied.
    if (destination.isEmpty ? request.target : destination) != discovered {
      restart()
      startWhenReady = true
      return
    }
    if discovery.running {
      startWhenReady = true
      return
    }
    startWhenReady = false
    if let problem = app.engine.copyStart(session, side: request.side) {
      error = problem
      return
    }
    session = 0
    app.sheet = nil
    app.focusPane(request.side)
  }

  private func close() {
    app.sheet = nil
    app.focusPane(request.side)
  }

}

// MARK: Move, delete, new folder, rename

struct MoveSheet: View {
  let request: DialogRequest
  @Environment(AppController.self) private var app
  @State private var error = ""

  var body: some View {
    SheetFrame(title: "Move \(request.selected.count) \(request.selected.count == 1 ? "item" : "items")",
               subtitle: "To \(Engine.displayLocation(request.target))") {
      itemList(request.selected)
      Text("Within one disk a move is a rename. Across disks the items are copied first and removed only when the copy is complete.")
        .font(.callout).foregroundStyle(.secondary)
      if !error.isEmpty { Text(error).foregroundStyle(.red) }
    } buttons: {
      Button("Cancel") { app.sheet = nil; app.focusPane(request.side) }.keyboardShortcut(.cancelAction)
      Button("Move", action: move).keyboardShortcut(.defaultAction).explainerAnchor("sheet.move.start", action: move)
    }
  }

  private func move() {
    let result = app.engine.submitMove(request.selected, to: request.target, side: request.side)
    if let problem = result.error { error = problem; return }
    app.sheet = nil
    app.focusPane(request.side)
  }
}

struct DeleteSheet: View {
  let request: DialogRequest
  @Environment(AppController.self) private var app

  var body: some View {
    SheetFrame(title: "Delete \(request.selected.count) \(request.selected.count == 1 ? "item" : "items") permanently?") {
      itemList(request.selected)
      Label("There is no trash: deleted files are gone. Links are removed, not what they point to.", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
    } buttons: {
      Button("Cancel") { app.sheet = nil; app.focusPane(request.side) }
        .keyboardShortcut(.cancelAction)
        .explainerAnchor("sheet.delete.cancel") { app.sheet = nil }
      Button("Delete", role: .destructive, action: delete)
        .explainerAnchor("sheet.delete.start", action: delete)
    }
  }

  private func delete() {
    let result = app.engine.submitDelete(request.selected, side: request.side)
    if let problem = result.error { app.engine.reportError(problem) }
    app.sheet = nil
    app.focusPane(request.side)
  }
}

/// Waits for a small job (new folder, rename) to finish, so its sheet can show the error.
@MainActor
private func awaitJob(_ app: AppController, _ job: UInt64) async -> JobDetail {
  for _ in 0..<400 {
    let detail = app.engine.jobDetail(job)
    if detail.info.stopped || detail.info.state.hasPrefix("completed") || detail.info.state == "cancelled" { return detail }
    try? await Task.sleep(for: .milliseconds(25))
  }
  return app.engine.jobDetail(job)
}

struct MkdirSheet: View {
  let request: DialogRequest
  @Environment(AppController.self) private var app
  @State private var name = ""
  @State private var error = ""
  @State private var working = false
  @FocusState private var focused: Bool

  var body: some View {
    SheetFrame(title: "New Folder", subtitle: "In \(Engine.displayLocation(request.origin))", width: 420) {
      TextField("Name", text: $name)
        .textFieldStyle(.roundedBorder)
        .font(app.theme.font("sheet.field"))
        .focused($focused)
        .onSubmit(create)
        .onChange(of: name) { error = "" }
        .explainerAnchor("sheet.mkdir.name")
      if !error.isEmpty { Text(error).foregroundStyle(.red) }
    } buttons: {
      Button("Cancel") { app.sheet = nil; app.focusPane(request.side) }.keyboardShortcut(.cancelAction)
      Button("Create", action: create).keyboardShortcut(.defaultAction).disabled(working)
        .explainerAnchor("sheet.mkdir.create", action: create)
    }
    .onAppear { focused = true }
  }

  private func create() {
    let result = app.engine.submitMkdir(in: request.origin, name: name)
    if let problem = result.error { error = problem; return }
    working = true
    Task {
      let detail = await awaitJob(app, result.job)
      working = false
      if detail.info.state == "completed" {
        app.sheet = nil
        app.focusPane(request.side)
      } else {
        error = detail.errors.first ?? "Couldn't create the folder"
      }
    }
  }
}

struct RenameSheet: View {
  let request: DialogRequest
  @Environment(AppController.self) private var app
  @State private var names: [String] = []
  @State private var error = ""
  @FocusState private var focused: Int?

  var body: some View {
    SheetFrame(title: request.selected.count == 1 ? "Rename" : "Rename \(request.selected.count) items", width: 480) {
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(names.indices, id: \.self) { index in
            VStack(alignment: .leading, spacing: 3) {
              Text(URL(fileURLWithPath: request.selected[index]).lastPathComponent).font(.caption).foregroundStyle(.secondary)
              TextField("New name", text: $names[index])
                .textFieldStyle(.roundedBorder)
                .font(app.theme.font("sheet.field"))
                .focused($focused, equals: index)
                .onSubmit(rename)
                .explainerAnchor("sheet.rename.name[\(index + 1)]")
            }
          }
        }
      }
      .frame(maxHeight: 260)
      if !error.isEmpty { Text(error).foregroundStyle(.red) }
    } buttons: {
      Button("Cancel") { app.sheet = nil; app.focusPane(request.side) }.keyboardShortcut(.cancelAction)
      Button("Rename", action: rename).keyboardShortcut(.defaultAction).explainerAnchor("sheet.rename.start", action: rename)
    }
    .onAppear {
      names = request.selected.map { URL(fileURLWithPath: $0).lastPathComponent }
      focused = 0
    }
  }

  private func rename() {
    let result = app.engine.submitRename(request.selected, names: names)
    if let problem = result.error { error = problem; return }
    Task {
      let detail = await awaitJob(app, result.job)
      if detail.errors.isEmpty {
        app.engine.clearSelection(request.side)
        app.sheet = nil
        app.focusPane(request.side)
      } else {
        error = detail.errors.joined(separator: "\n")
      }
    }
  }
}

// MARK: SSH

struct ConnectSheet: View {
  @Environment(AppController.self) private var app
  @State private var host = ""
  @State private var path = "/"
  @State private var error = ""
  @State private var connecting = false
  @FocusState private var hostFocused: Bool

  var body: some View {
    SheetFrame(title: "Connect to Server", subtitle: "Opens a folder on an SSH host in a new tab. The host needs only python3.", width: 460) {
      Form {
        TextField("Host", text: $host, prompt: Text("alias, host or user@host"))
          .focused($hostFocused)
          .explainerAnchor("sheet.ssh.host")
        TextField("Folder", text: $path, prompt: Text("/var/log"))
          .explainerAnchor("sheet.ssh.path")
      }
      let aliases = SSHConfig.aliases()
      if !aliases.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack {
            ForEach(aliases, id: \.self) { alias in
              Button(alias) { host = alias }.buttonStyle(.bordered).controlSize(.small)
            }
          }
        }
      }
      if connecting { HStack { ProgressView().controlSize(.small); Text("Connecting…") } }
      if !error.isEmpty { Text(error).foregroundStyle(.red) }
    } buttons: {
      Button("Cancel") { app.sheet = nil }.keyboardShortcut(.cancelAction)
      Button("Connect", action: connect).keyboardShortcut(.defaultAction).disabled(host.isEmpty || connecting)
        .explainerAnchor("sheet.ssh.connect", action: connect)
    }
    .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { hostFocused = true } }
  }

  private func connect() {
    let host = host.trimmingCharacters(in: .whitespaces)
    let path = path.isEmpty ? "/" : path
    guard path.hasPrefix("/") else { error = "Enter an absolute folder, such as /var/log"; return }
    connecting = true
    error = ""
    Task.detached {
      let rc = Engine.sshAuthenticate(host)
      await MainActor.run {
        connecting = false
        if rc != 0 {
          error = "SSH authentication failed (exit \(rc)). Check the host alias in your SSH config."
          return
        }
        if let problem = app.engine.sshOpen(host: host, path: path) { error = problem; return }
        app.sheet = nil
      }
    }
  }
}

enum SSHConfig {
  /// Host aliases from ~/.ssh/config, without wildcards.
  static func aliases() -> [String] {
    let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/config")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    var out: [String] = []
    for line in text.split(separator: "\n") {
      let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true)
      guard parts.first?.lowercased() == "host" else { continue }
      for alias in parts.dropFirst() where !alias.contains("*") && !alias.contains("?") { out.append(String(alias)) }
    }
    return out
  }
}

// MARK: Editor restart

struct RestartEditorSheet: View {
  @Environment(AppController.self) private var app
  @State private var message = "Fresh saves its recovery data, stops, and starts again with the new version. Unsaved text survives."
  @State private var needsLegacy = false

  var body: some View {
    SheetFrame(title: "Restart Editor Backend?", subtitle: message, width: 440) {
      EmptyView()
    } buttons: {
      Button("Cancel") { app.sheet = nil }.keyboardShortcut(.cancelAction)
      Button(needsLegacy ? "Import and Restart" : "Restart", action: restart).keyboardShortcut(.defaultAction)
        .explainerAnchor("sheet.restart.confirm", action: restart)
    }
  }

  private func restart() {
    let result = app.engine.restartEditor(allowLegacy: needsLegacy)
    switch result.status {
    case 0:
      app.sheet = nil
      if let error = app.engine.switchToEditor() { app.engine.reportError(error) }
    case 1:
      needsLegacy = true
      message = "The editor has a checkpoint from an older version. Import it and restart?"
    default:
      message = result.error.isEmpty ? "The restart failed." : result.error
    }
  }
}

// MARK: Transfer speed

struct TransferSpeedView: View {
  let inPopover: Bool
  @Environment(AppController.self) private var app
  @State private var megabytes = 0.0
  @State private var persist = true

  private let presets: [(String, UInt64)] = [("Unlimited", 0), ("100 MB/s", 100 << 20), ("10 MB/s", 10 << 20), ("2 MB/s", 2 << 20), ("1 MB/s", 1 << 20)]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Transfer Speed").font(.headline)
      Text("Limits copies, moves between disks and SSH transfers. A change applies to a running copy at once.")
        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack {
        ForEach(presets, id: \.1) { title, value in
          Button(title) { apply(value) }
            .buttonStyle(.bordered)
            .tint(app.engine.transferRate == value ? .accentColor : nil)
            .explainerAnchor("speed.preset[\(title)]") { apply(value) }
        }
      }
      HStack {
        Slider(value: $megabytes, in: 0...200, step: 1) { Text("Custom") } onEditingChanged: { editing in
          if !editing { apply(UInt64(megabytes) << 20) }
        }
        Text(megabytes == 0 ? "Unlimited" : "\(Int(megabytes)) MB/s").monospacedDigit().frame(width: 90, alignment: .trailing)
      }
      Toggle("Keep for future sessions", isOn: $persist)
        .help("Off: the limit lasts until File Commander quits.")
      if !inPopover {
        HStack { Spacer(); Button("Done") { app.sheet = nil }.keyboardShortcut(.defaultAction) }
      }
    }
    .frame(width: 400)
    .onAppear { megabytes = Double(app.engine.transferRate >> 20) }
    .explainerAnchor("speed")
  }

  private func apply(_ value: UInt64) {
    megabytes = Double(value >> 20)
    app.engine.setTransferRate(value, persist: persist)
  }
}

// MARK: Welcome and confirmations

struct WelcomeSheet: View {
  @Environment(AppController.self) private var app

  var body: some View {
    @Bindable var app = app
    SheetFrame(title: "Welcome to File Commander", subtitle: "Two panes, background jobs that survive crashes, SSH and archives.", width: 560) {
      Form {
        Picker("Keys", selection: $app.preferences.keyPreset) {
          Text("Commander — F5 copy, F6 move, Tab switches panes").tag(AppPreferences.KeyPreset.commander)
          Text("Mac — Finder's shortcuts where Finder has them").tag(AppPreferences.KeyPreset.mac)
        }
        .pickerStyle(.radioGroup)
        Picker("Selection", selection: $app.preferences.selectionStyle) {
          Text("Commander — arrows move a cursor, Space marks items").tag(AppPreferences.SelectionStyle.commander)
          Text("Finder — arrows select, ⌘-click adds").tag(AppPreferences.SelectionStyle.finder)
        }
        .pickerStyle(.radioGroup)
      }
      GroupBox {
        Label {
          Text("F-keys: on most Mac keyboards they control brightness and volume unless you hold Fn. Turn on **Use F1, F2, etc. keys as standard function keys** in System Settings › Keyboard › Keyboard Shortcuts › Function Keys. macOS also uses F11 (Show Desktop) and ⌃← ⌃→ (Spaces) unless you turn those off.")
            .fixedSize(horizontal: false, vertical: true)
        } icon: { Image(systemName: "keyboard") }
      }
      Text("The tutorial runs real operations on demo files in their own tabs, and leaves your files alone.")
        .font(.callout).foregroundStyle(.secondary)
    } buttons: {
      Button("Open Keyboard Settings") {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
      }
      Button("Not Now") { app.preferences.welcomeShown = true; app.sheet = nil }.keyboardShortcut(.cancelAction)
      Button("Start the Tutorial") {
        app.preferences.welcomeShown = true
        app.sheet = nil
        DispatchQueue.main.async { app.tutorial.start(TutorialCoordinator.entireID) }
      }
      .keyboardShortcut(.defaultAction)
    }
  }
}

struct ConfirmCrashSheet: View {
  let text: String
  @Environment(AppController.self) private var app

  var body: some View {
    SheetFrame(title: "This explainer crashes File Commander", subtitle: text, width: 480) {
      Label("Your tabs are saved every half second and transfers are journaled, so they come back as after any crash. The editor runs separately and keeps your text.",
            systemImage: "info.circle")
        .fixedSize(horizontal: false, vertical: true)
    } buttons: {
      Button("Skip This Explainer") { app.sheet = nil; app.tutorial.confirmCrash(false) }.keyboardShortcut(.cancelAction)
      Button("Continue") { app.sheet = nil; app.tutorial.confirmCrash(true) }.keyboardShortcut(.defaultAction)
    }
  }
}
