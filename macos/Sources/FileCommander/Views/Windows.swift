import ExplainerKit
import FCKit
import SwiftUI

/// Jobs: running, queued and finished, with details, pause, resume, cancel and dismiss.
struct ActivityWindow: View {
  @Environment(AppController.self) private var app
  @State private var selection: UInt64?

  var body: some View {
    NavigationSplitView {
      List(app.engine.jobs, selection: $selection) { job in
        JobRow(job: job).tag(job.id)
          .contextMenu { JobActions(job: job) }
          .explainerAnchor("activity.row[job=\(job.id)]") { selection = job.id }
      }
      .overlay {
        if app.engine.jobs.isEmpty {
          ContentUnavailableView("No Jobs", systemImage: "tray", description: Text("Copies, moves and deletes appear here."))
        }
      }
      .navigationSplitViewColumnWidth(min: 280, ideal: 320)
      .explainerAnchor("activity.list")
    } detail: {
      if let id = selection, let job = app.engine.jobs.first(where: { $0.id == id }) {
        JobDetailView(job: job)
      } else {
        ContentUnavailableView("Select a Job", systemImage: "list.bullet.rectangle")
      }
    }
    .toolbar {
      ToolbarItemGroup {
        if let id = selection, let job = app.engine.jobs.first(where: { $0.id == id }) { JobActions(job: job) }
        Button { app.sheet = .transferSpeed } label: { Label("Transfer Speed", systemImage: "speedometer") }
          .help("Transfer speed: \(Format.rate(app.engine.transferRate))")
      }
    }
    .navigationTitle("Activity")
    .frame(minWidth: 720, minHeight: 400)
    .onAppear { if selection == nil { selection = app.engine.jobs.first?.id } }
    .explainerAnchor("activity")
  }
}

struct JobActions: View {
  let job: JobInfo
  @Environment(AppController.self) private var app

  var body: some View {
    if job.isPaused {
      Button { report(app.engine.resumeJob(job.id)) } label: { Label("Resume", systemImage: "play.fill") }
        .explainerAnchor("activity.resume") { report(app.engine.resumeJob(job.id)) }
    } else if !job.stopped {
      Button { report(app.engine.pauseJob(job.id)) } label: { Label("Pause", systemImage: "pause.fill") }
        .explainerAnchor("activity.pause") { report(app.engine.pauseJob(job.id)) }
    }
    if !job.stopped || job.isPaused {
      Button(role: .destructive) { report(app.engine.cancelJob(job.id)) } label: { Label("Cancel", systemImage: "xmark.circle") }
        .explainerAnchor("activity.cancel") { report(app.engine.cancelJob(job.id)) }
    }
    if job.stopped && !job.isPaused {
      Button { app.engine.dismissJob(job.id) } label: { Label("Dismiss", systemImage: "checkmark.circle") }
        .explainerAnchor("activity.dismiss") { app.engine.dismissJob(job.id) }
    }
  }

  private func report(_ error: String?) { if let error { app.flash(error) } }
}

struct JobRow: View {
  let job: JobInfo
  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: icon).foregroundStyle(color).frame(width: 18)
      VStack(alignment: .leading, spacing: 3) {
        HStack {
          Text(job.title).fontWeight(.medium)
          Spacer()
          Text(job.stateTitle).font(.caption).foregroundStyle(color)
        }
        if !job.stopped || job.isPaused {
          ProgressView(value: min(max(job.percent, 0), 100), total: 100).controlSize(.small)
        }
        Text("\(job.itemsDone) of \(job.itemsTotal) items" + (job.bytesTotal > 0 ? " · \(Format.bytes(job.bytesDone)) of \(Format.bytes(job.bytesTotal))" : "")
             + (job.errors > 0 ? " · \(job.errors) errors" : ""))
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 3)
  }
  private var icon: String {
    switch job.state {
    case "running": return "play.circle.fill"
    case "paused": return "pause.circle.fill"
    case "queued": return "clock"
    case "cancelled": return "xmark.circle"
    case "completed": return "checkmark.circle.fill"
    default: return "exclamationmark.circle.fill"
    }
  }
  private var color: Color {
    switch job.state {
    case "running": return .accentColor
    case "paused": return .orange
    case "completed": return .green
    case "completed_with_errors", "cancelled": return .red
    default: return .secondary
    }
  }
}

struct JobDetailView: View {
  let job: JobInfo
  @Environment(AppController.self) private var app
  @State private var detail = JobDetail.empty

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Text(job.title).font(.title2.weight(.semibold))
          Text(job.stateTitle).foregroundStyle(.secondary)
          Spacer()
        }
        if !job.recoveryNote.isEmpty {
          Label(job.recoveryNote, systemImage: "arrow.clockwise.circle")
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .explainerAnchor("activity.recovery")
        }
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
          GridRow { Text("Items").foregroundStyle(.secondary); Text("\(job.itemsDone) of \(job.itemsTotal), \(job.itemsFailed) failed, \(job.itemsSkipped) skipped") }
          GridRow { Text("Bytes").foregroundStyle(.secondary); Text("\(Format.bytes(job.bytesDone)) of \(Format.bytes(job.bytesTotal))") }
          if job.isRunning {
            GridRow { Text("Speed").foregroundStyle(.secondary); Text(String(format: "%.1f MB/s now, %.1f MB/s average", job.mbps / 8, job.averageMbps / 8)) }
          }
          if !job.current.isEmpty { GridRow { Text("Current").foregroundStyle(.secondary); Text(job.current).lineLimit(1).truncationMode(.middle) } }
          GridRow { Text("Duration").foregroundStyle(.secondary); Text(duration) }
        }
        if !detail.errors.isEmpty {
          Text("Errors").font(.headline)
          ForEach(detail.errors, id: \.self) { error in
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
          }
        }
        Text("Items").font(.headline)
        if detail.expired { Text("Details expired under history limits; the summary is kept.").foregroundStyle(.secondary) }
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(Array(detail.items.prefix(500).enumerated()), id: \.offset) { _, item in
            Text(item).font(.callout).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
          }
        }
      }
      .padding(20)
    }
    .onAppear { detail = app.engine.jobDetail(job.id) }
    .onChange(of: job) { detail = app.engine.jobDetail(job.id) }
  }

  private var duration: String {
    guard job.started > 0 else { return "Not started" }
    guard job.finished > 0 else { return "Running" }
    let seconds = max(0, job.finished - job.started)
    return seconds < 60 ? String(format: "%.1f s", seconds) : "\(Int(seconds) / 60) min \(Int(seconds) % 60) s"
  }
}

/// Every error from file operations, newest first.
struct ErrorsWindow: View {
  @Environment(AppController.self) private var app

  var body: some View {
    let errors = app.engine.errors(count: 1000)
    List(errors) { error in
      VStack(alignment: .leading, spacing: 2) {
        Text(error.message).textSelection(.enabled)
      }
      .padding(.vertical, 2)
    }
    .overlay {
      if errors.isEmpty {
        ContentUnavailableView("No Errors", systemImage: "checkmark.seal", description: Text("Failed items are skipped and listed here; jobs keep going."))
      }
    }
    .toolbar {
      ToolbarItemGroup {
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(errors.map(\.message).joined(separator: "\n"), forType: .string)
        } label: { Label("Copy All", systemImage: "doc.on.doc") }
        Button(role: .destructive) { app.engine.clearErrors() } label: { Label("Clear", systemImage: "trash") }
          .explainerAnchor("errors.window.clear") { app.engine.clearErrors() }
      }
    }
    .navigationTitle("Errors")
    .frame(minWidth: 560, minHeight: 300)
    .explainerAnchor("errors.window")
  }
}

/// Finds files by name below a folder, on its own thread.
struct FindWindow: View {
  @Environment(AppController.self) private var app
  @State private var root = ""
  @State private var pattern = ""
  @State private var info = FindInfo.empty
  @State private var results: [String] = []
  @State private var selection: String?
  @State private var timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()
  @FocusState private var patternFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      Form {
        TextField("Search in", text: $root).explainerAnchor("find.root")
        TextField("Name", text: $pattern, prompt: Text("*.jpg — * and ? work, case is ignored"))
          .focused($patternFocused)
          .onSubmit(search)
          .explainerAnchor("find.pattern")
      }
      .padding()
      HStack {
        if info.running { ProgressView().controlSize(.small) }
        Text(summary).foregroundStyle(.secondary).font(.callout.monospacedDigit())
        Spacer()
        Button(info.running ? "Stop" : "Find") { info.running ? app.engine.findStop() : search() }
          .keyboardShortcut(.defaultAction)
          .explainerAnchor("find.start", action: search)
        Button("Show in Pane", action: reveal).disabled(selection == nil)
          .explainerAnchor("find.reveal", action: reveal)
      }
      .padding(.horizontal).padding(.bottom, 8)
      List(results, id: \.self, selection: $selection) { path in
        Label(path, systemImage: "doc").lineLimit(1).truncationMode(.head)
          .explainerAnchor("find.result[name=\(URL(fileURLWithPath: path).lastPathComponent)]") { selection = path }
      }
      .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { _ in reveal() }
      .explainerAnchor("find.results")
    }
    .navigationTitle("Find")
    .frame(minWidth: 560, minHeight: 420)
    .onAppear {
      root = app.findRoot
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { patternFocused = true }
    }
    .onChange(of: app.findRoot) { _, new in root = new; results = []; info = FindInfo.empty }
    .onReceive(timer) { _ in poll() }
    .explainerAnchor("find")
  }

  private var summary: String {
    if !info.status.isEmpty { return info.status }
    var text = "\(info.matches) matches in \(info.dirs) folders, \(info.files) files"
    if info.errors > 0 { text += ", \(info.errors) unreadable" }
    if info.truncated { text += " — stopped at 100,000 entries" }
    return text
  }

  private func search() {
    results = []
    selection = nil
    if let problem = app.engine.findStart(root: root, pattern: pattern) { info.status = problem; return }
    poll()
  }

  private func poll() {
    info = app.engine.findInfo()
    if results.count < Int(info.matches) {
      results += app.engine.findResults(from: results.count, count: min(2000, Int(info.matches) - results.count))
    }
  }

  private func reveal() {
    guard let path = selection else { return }
    let side = app.engine.focusedSide
    app.engine.findReveal(side, path: path)
    NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
    app.focusPane(side)
  }
}
