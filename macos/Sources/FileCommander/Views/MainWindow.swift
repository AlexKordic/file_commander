import ExplainerKit
import FCKit
import SwiftUI

struct MainWindow: View {
  @Environment(AppController.self) private var app
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    @Bindable var app = app
    NavigationSplitView(columnVisibility: $app.sidebarVisible) {
      Sidebar()
        .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 280)
    } detail: {
      VStack(spacing: 0) {
        if let error = app.startError {
          StartFailure(message: error)
        } else {
          PanesView()
          ErrorLines()
          JobBar()
        }
      }
      .overlay(alignment: .top) { PaletteOverlay() }
      .overlay(alignment: .bottom) { Hud() }
    }
    .toolbar { MainToolbar() }
    .navigationTitle(windowTitle)
    .navigationSubtitle(app.engine.focusedPane.path)
    .sheet(item: $app.sheet) { sheet in SheetHost(kind: sheet) }
    .onAppear {
      app.openWindowAction = openWindow
      app.openSettingsAction = { openSettings() }
    }
    .background(WindowAccessor { window in app.tutorial.mainWindow = window })
  }
}

extension MainWindow {
  /// The focused pane's folder, as Finder titles its windows.
  var windowTitle: String {
    let path = app.engine.focusedPane.path
    guard !path.isEmpty else { return "File Commander" }
    let name = (path as NSString).lastPathComponent
    return name.isEmpty ? path : name
  }
}

struct StartFailure: View {
  let message: String
  var body: some View {
    ContentUnavailableView {
      Label("File Commander can't start", systemImage: "exclamationmark.triangle")
    } description: {
      Text(message)
    } actions: {
      Button("Quit") { NSApp.terminate(nil) }
    }
  }
}

/// Two panes side by side with a draggable divider, or the focused pane alone.
struct PanesView: View {
  @Environment(AppController.self) private var app

  var body: some View {
    let single = app.engine.singlePane
    let focused = app.engine.focusedSide
    GeometryReader { geometry in
      HStack(spacing: 0) {
        if !single || focused == 0 {
          PaneView(side: 0)
            .frame(width: single ? geometry.size.width : max(220, geometry.size.width * app.preferences.paneSplit))
        }
        if !single {
          PaneDivider(width: geometry.size.width)
        }
        if !single || focused == 1 {
          PaneView(side: 1)
        }
      }
      // Exactly the space given, so the error lines and job bar below stay visible.
      .frame(width: geometry.size.width, height: geometry.size.height)
      .clipped()
    }
    .animation(.easeInOut(duration: 0.22), value: single)
  }
}

struct PaneDivider: View {
  let width: Double
  @Environment(AppController.self) private var app
  @State private var start: Double?

  var body: some View {
    Rectangle()
      .fill(Color(nsColor: .separatorColor))
      .frame(width: 1)
      .overlay(Rectangle().fill(.clear).frame(width: 9).contentShape(Rectangle()))
      .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
      .gesture(DragGesture(minimumDistance: 1)
        .onChanged { value in
          let base = start ?? app.preferences.paneSplit
          if start == nil { start = base }
          app.preferences.paneSplit = min(0.85, max(0.15, base + value.translation.width / max(width, 1)))
        }
        .onEnded { _ in start = nil })
      .explainerAnchor("panes.divider")
  }
}

struct Sidebar: View {
  @Environment(AppController.self) private var app

  var body: some View {
    List {
      Section("Bookmarks") {
        ForEach(app.engine.bookmarks) { bookmark in
          SidebarRow(title: bookmark.title, subtitle: bookmark.path, icon: icon(bookmark.kind, fallback: "bookmark")) {
            app.engine.navigate(app.engine.focusedSide, to: bookmark.encoded)
          }
          .contextMenu {
            Button("Open in Left Pane") { app.engine.navigate(0, to: bookmark.encoded) }
            Button("Open in Right Pane") { app.engine.navigate(1, to: bookmark.encoded) }
            Button("Open in New Tab") { app.engine.newTab(app.engine.focusedSide, location: bookmark.encoded) }
            Divider()
            Button("Remove Bookmark", role: .destructive) { app.engine.removeBookmark(bookmark.encoded) }
          }
          .explainerAnchor("sidebar.bookmark[name=\(bookmark.title)]") {
            app.engine.navigate(app.engine.focusedSide, to: bookmark.encoded)
          }
        }
        Button {
          app.run("add_bookmark")
        } label: {
          Label("Bookmark This Folder", systemImage: "plus")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .explainerAnchor("sidebar.add_bookmark") { app.run("add_bookmark") }
      }
      .explainerAnchor("sidebar.bookmarks")
      let servers = recentServers
      if !servers.isEmpty {
        Section("Servers") {
          ForEach(servers, id: \.encoded) { tab in
            SidebarRow(title: tab.title, subtitle: tab.path, icon: "server.rack") {
              app.engine.newTab(app.engine.focusedSide, location: tab.encoded)
            }
          }
        }
      }
      Section("Locations") {
        SidebarRow(title: "Home", subtitle: NSHomeDirectory(), icon: "house") {
          app.engine.navigate(app.engine.focusedSide, to: NSHomeDirectory())
        }
        ForEach(volumes, id: \.path) { volume in
          SidebarRow(title: (try? volume.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? volume.lastPathComponent, subtitle: volume.path,
                     icon: volume.path == "/" ? "internaldrive" : "externaldrive") {
            app.engine.navigate(app.engine.focusedSide, to: volume.path)
          }
        }
      }
    }
    .listStyle(.sidebar)
  }

  private var recentServers: [TabInfo] {
    var seen = Set<String>()
    return (app.engine.left.tabs + app.engine.right.tabs).filter { $0.kind == .remote && seen.insert($0.encoded).inserted }
  }

  private var volumes: [URL] {
    FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
  }

  private func icon(_ kind: LocationKind, fallback: String) -> String {
    switch kind {
    case .remote: return "server.rack"
    case .archive: return "archivebox"
    case .local: return "folder"
    }
  }
}

struct SidebarRow: View {
  let title: String
  let subtitle: String
  let icon: String
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Label(title, systemImage: icon).lineLimit(1)
    }
    .buttonStyle(.plain)
    .help(subtitle)
  }
}

struct MainToolbar: ToolbarContent {
  @Environment(AppController.self) private var app

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      ToolbarButton(id: "copy", title: "Copy", icon: "doc.on.doc")
      ToolbarButton(id: "move", title: "Move", icon: "arrow.right.doc.on.clipboard")
      ToolbarButton(id: "mkdir", title: "New Folder", icon: "folder.badge.plus")
      ToolbarButton(id: "delete", title: "Delete", icon: "trash")
      ToolbarButton(id: "find", title: "Find", icon: "magnifyingglass")
    }
    ToolbarItemGroup(placement: .primaryAction) {
      ActivityButton()
      if app.engine.errorCount > 0 {
        Button {
          app.run("toggle_errors")
        } label: {
          Label("\(app.engine.errorCount) Errors", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        }
        .help("Show the errors from file operations")
        .explainerAnchor("toolbar.errors") { app.run("toggle_errors") }
      }
      ToolbarButton(id: "command_palette", title: "Commands", icon: "command")
      ToolbarButton(id: "help", title: "Help", icon: "graduationcap")
    }
  }
}

struct ToolbarButton: View {
  let id: String
  let title: String
  let icon: String
  @Environment(AppController.self) private var app

  var body: some View {
    Button {
      app.run(id)
    } label: {
      Label(title, systemImage: icon)
    }
    .help(helpText)
    .explainerAnchor("toolbar.\(id)") { app.run(id) }
  }

  private var helpText: String {
    let shortcut = app.keymap.chord(for: id).map { " (\($0.symbols))" } ?? ""
    return (app.engine.command(id)?.help ?? title) + shortcut
  }
}

struct ActivityButton: View {
  @Environment(AppController.self) private var app

  var body: some View {
    Button {
      app.run("toggle_job_list")
    } label: {
      ZStack {
        if let job = app.engine.runningJob {
          ProgressView(value: job.percent, total: 100)
            .progressViewStyle(.circular)
            .controlSize(.small)
        } else {
          Image(systemName: "arrow.down.circle")
        }
      }
      .frame(width: 22, height: 22)
    }
    .help(app.engine.runningJob.map { "\($0.title): \(Int($0.percent))%" } ?? "Activity")
    .explainerAnchor("toolbar.activity") { app.run("toggle_job_list") }
  }
}

/// Recent errors above the job bar, with a clear button.
struct ErrorLines: View {
  @Environment(AppController.self) private var app

  var body: some View {
    let errors = Array(app.engine.recentErrors.prefix(3))
    if !errors.isEmpty {
      HStack(alignment: .top, spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(errors) { error in
            Label(error.message, systemImage: "exclamationmark.circle.fill")
              .lineLimit(1)
              .truncationMode(.middle)
              .font(app.theme.font("bottom.errors"))
              .foregroundStyle(app.theme.color("bottom.error"))
          }
        }
        Spacer()
        Button("All Errors…") { app.run("toggle_errors") }.buttonStyle(.link)
        Button {
          app.engine.clearErrors()
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.borderless)
        .help("Clear the errors")
        .explainerAnchor("errors.clear") { app.engine.clearErrors() }
      }
      .padding(.horizontal, 12).padding(.vertical, 6)
      .background(app.theme.color("bottom.error").opacity(0.08))
      .overlay(alignment: .top) { Divider() }
      .explainerAnchor("errors.lines")
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }
}

/// The running job on one row: what, progress, speed, Pause/Resume and Cancel.
struct JobBar: View {
  @Environment(AppController.self) private var app
  @State private var speedPopover = false

  var body: some View {
    if let job = app.engine.runningJob {
      HStack(spacing: 10) {
        Image(systemName: icon(job.type)).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 1) {
          HStack(spacing: 6) {
            Text(job.title).fontWeight(.semibold)
            if app.engine.queuedJobs > 0 {
              Text("+\(app.engine.queuedJobs) queued").foregroundStyle(.secondary)
            }
            if job.isPaused { Text("Paused").foregroundStyle(.orange) }
            Text(URL(fileURLWithPath: job.current).lastPathComponent)
              .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
          }
          ProgressView(value: min(max(job.percent, 0), 100), total: 100)
            .tint(app.theme.color("bottom.progress"))
            .explainerAnchor("jobs.bar.progress")
        }
        .frame(maxWidth: .infinity)
        Text(detail(job)).foregroundStyle(.secondary).lineLimit(1)
        Button {
          speedPopover.toggle()
        } label: {
          Label(app.engine.transferRate == 0 ? String(format: "%.1f MB/s", job.mbps / 8) : Format.rate(app.engine.transferRate),
                systemImage: "speedometer")
        }
        .buttonStyle(.borderless)
        .help("Transfer speed limit: \(Format.rate(app.engine.transferRate)). Click to change it.")
        .popover(isPresented: $speedPopover, arrowEdge: .top) { TransferSpeedView(inPopover: true).padding() }
        .explainerAnchor("jobs.bar.speed") { speedPopover = true }
        Button(job.isPaused ? "Resume" : "Pause") {
          if job.isPaused { app.engine.resumeJob(job.id) } else { app.engine.pauseJob(job.id) }
        }
        .buttonStyle(TintedButtonStyle(color: app.theme.color("bottom.pause")))
        .explainerAnchor("jobs.bar.pause") {
          if job.isPaused { app.engine.resumeJob(job.id) } else { app.engine.pauseJob(job.id) }
        }
        Button("Cancel", role: .destructive) { app.engine.cancelJob(job.id) }
          .buttonStyle(TintedButtonStyle(color: app.theme.color("bottom.cancel")))
          .explainerAnchor("jobs.bar.cancel") { app.engine.cancelJob(job.id) }
      }
      .font(app.theme.font("bottom.jobs"))
      .padding(.horizontal, 12).padding(.vertical, 6)
      .background(app.theme.color("bottom.background"))
      .overlay(alignment: .top) { Divider() }
      .explainerAnchor("jobs.bar")
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }

  private func detail(_ job: JobInfo) -> String {
    if job.type == "COPY" || job.type == "DELETE" || job.type == "MOVE" {
      if job.bytesTotal > 0 { return "\(Format.bytes(job.bytesDone)) of \(Format.bytes(job.bytesTotal))" }
    }
    return "\(job.itemsDone) of \(job.itemsTotal) items"
  }

  private func icon(_ type: String) -> String {
    switch type {
    case "COPY": return "doc.on.doc"
    case "MOVE": return "arrow.right.doc.on.clipboard"
    case "DELETE": return "trash"
    case "ARCHIVE": return "archivebox"
    default: return "gearshape"
    }
  }
}

struct TintedButtonStyle: ButtonStyle {
  let color: Color
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .padding(.horizontal, 10).padding(.vertical, 3)
      .foregroundStyle(.white)
      .background(color.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 6))
  }
}

/// A short confirmation at the bottom of the window, such as "8 paths copied to clipboard".
struct Hud: View {
  @Environment(AppController.self) private var app
  var body: some View {
    if let text = app.hud {
      Text(text)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(app.theme.color("hud.text"))
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(app.theme.color("hud.background"), in: Capsule())
        .shadow(radius: 10)
        .padding(.bottom, 64)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .explainerAnchor("hud")
        .animation(.spring(duration: 0.3), value: app.hud)
    }
  }
}

/// Hands the hosting NSWindow to a closure once the view is in a window.
struct WindowAccessor: NSViewRepresentable {
  let found: (NSWindow) -> Void
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async { if let window = view.window { found(window) } }
    return view
  }
  func updateNSView(_ view: NSView, context: Context) {
    DispatchQueue.main.async { if let window = view.window { found(window) } }
  }
}
