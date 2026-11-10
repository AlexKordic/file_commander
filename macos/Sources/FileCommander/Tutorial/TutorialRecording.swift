import AppKit
import CoreGraphics
import ExplainerKit
import Observation
import SwiftUI

private struct TutorialRecordingCatalog: Encodable {
  var schema = 1
  var chapters: [ExplainerChapter]
  var lessons: [ExplainerScript]
}

/// Recording is an export job in separate owned processes. The user's current
/// FC workspace and editor backend are never used as recording fixtures.
@MainActor @Observable
final class TutorialRecordingController {
  unowned let app: AppController
  unowned let tutorial: TutorialCoordinator
  var selected: Set<String> = []
  var appearance = "system"
  var voice = "Samantha"
  var language = "en"
  var speechRate = 180
  var narration = true
  var geometry: TutorialFrameRecorder.Geometry?
  var output: URL?
  var message = "Resize the main app window to choose the recording resolution."
  private(set) var running = false
  private(set) var completed = false
  @ObservationIgnored private var panel: NSWindow?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var process: Process?
  @ObservationIgnored private var poll: Task<Void, Never>?
  var canResume: Bool { output.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("course.json").path) } ?? false }

  init(app: AppController, tutorial: TutorialCoordinator) { self.app = app; self.tutorial = tutorial }

  func show() {
    if selected.isEmpty { selected = Set(tutorial.catalog.scripts.map(\.id)) }
    appearance = app.preferences.appearance.rawValue
    updateGeometry()
    if panel == nil {
      let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 680),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      panel.title = "Record Tutorial"
      panel.isReleasedWhenClosed = false
      panel.contentView = NSHostingView(rootView: TutorialRecordingView(controller: self))
      panel.center()
      self.panel = panel
      for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: tutorial.mainWindow, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { if self?.running == false { self?.updateGeometry() } }
        })
      }
    }
    panel?.makeKeyAndOrderFront(nil)
  }

  func updateGeometry() {
    guard let window = tutorial.mainWindow else { return }
    geometry = .init(frame: window.frame, scale: window.backingScaleFactor)
  }

  func chooseOutput() {
    let picker = NSOpenPanel()
    picker.title = "Choose a folder for tutorial recordings"
    picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.canCreateDirectories = true
    guard picker.runModal() == .OK, let folder = picker.url else { return }
    let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
    output = folder.appendingPathComponent("tutorial-" + formatter.string(from: Date()) + "-" + UUID().uuidString.prefix(6), isDirectory: true)
  }

  func start() {
    guard !running else { return }
    updateGeometry()
    guard let geometry, !selected.isEmpty else { message = "Choose at least one lesson and a visible app window."; return }
    guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
      message = "Enable Screen Recording for File Commander in macOS System Settings, then relaunch the app and retry."
      return
    }
    if output == nil { chooseOutput() }
    guard let output else { return }
    let tools = TutorialMediaTools.command
    let capture = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("tutorial-capture")
    guard FileManager.default.isExecutableFile(atPath: capture.path) else { message = "This build is missing its tutorial recorder. Rebuild the complete app bundle."; return }
    let python = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }
    guard let python else { message = "Tutorial export needs Python 3.11 or later and FFmpeg installed."; return }
    let version = Process()
    version.executableURL = URL(fileURLWithPath: python)
    version.arguments = ["-c", "import sys; sys.exit(sys.version_info < (3,11))"]
    version.standardOutput = FileHandle.nullDevice; version.standardError = FileHandle.nullDevice
    do { try version.run(); version.waitUntilExit() }
    catch { message = "Cannot launch Python: \(error.localizedDescription)"; return }
    guard version.terminationStatus == 0 else { message = "Install Python 3.11 or newer for tutorial export."; return }
    do {
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      let catalog = output.appendingPathComponent("catalog.json")
      try JSONEncoder().encode(TutorialRecordingCatalog(chapters: tutorial.catalog.chapters, lessons: tutorial.catalog.scripts))
        .write(to: catalog, options: .atomic)
      let geometryFile = output.appendingPathComponent("geometry.json")
      try JSONEncoder().encode(geometry).write(to: geometryFile, options: .atomic)
      let hostOptionsFile = output.appendingPathComponent("host-options.json")
      let previousOptions = (try? Data(contentsOf: hostOptionsFile)).flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) }
      let hostOptions = try TutorialPresentation.capture(app: app)
      let presentationChanged = canResume && previousOptions != hostOptions
      let selectedScripts = tutorial.catalog.scripts.filter { selected.contains($0.id) }
      let retakes = canResume ? TutorialPresentation.retakes(root: output, scripts: selectedScripts,
        options: hostOptions, geometry: geometry, presentationChanged: presentationChanged) : []
      try JSONEncoder().encode(hostOptions).write(to: hostOptionsFile, options: .atomic)
      let log = output.appendingPathComponent("recording.log")
      FileManager.default.createFile(atPath: log.path, contents: nil)
      let handle = try FileHandle(forWritingTo: log)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: python)
      process.arguments = [tools.path, "record", "--app", Bundle.main.bundleURL.path, "--capture-bin", capture.path,
                           "--catalog", catalog.path, "--out", output.path, "--geometry", geometryFile.path,
                           "--host-options", hostOptionsFile.path,
                           "--lessons", tutorial.catalog.scripts.filter { selected.contains($0.id) }.map(\.id).joined(separator: ","),
                           "--appearance", appearance, "--title", "File Commander tutorial"]
      if canResume { process.arguments!.append("--resume") }
      if !retakes.isEmpty { process.arguments! += ["--retake", retakes.joined(separator: ",")] }
      if narration {
        process.arguments! += ["--language", language, "--rate", String(speechRate)]
        if !voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { process.arguments! += ["--voice", voice] }
      } else { process.arguments!.append("--silent") }
      var environment = ProcessInfo.processInfo.environment
      for key in ["FC_FRESH_BIN", "FC_NATIVE_RICH_COMPOSE", "FC_NATIVE_MEASURED_TABLES"] { environment.removeValue(forKey: key) }
      environment["PATH"] = "/opt/homebrew/opt/ffmpeg-full/bin:/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
      process.environment = environment
      process.standardOutput = handle; process.standardError = handle
      process.terminationHandler = { [weak self] process in
        try? handle.close()
        Task { @MainActor in
          guard let self else { return }
          self.running = false; self.poll?.cancel(); self.poll = nil
          self.completed = process.terminationStatus == 0
          let detail = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").last.map(String.init)
          self.message = self.completed ? "Recording complete. Open the standalone player to review it." :
            (detail.map { String($0.prefix(600)) } ?? "Recording stopped. See recording.log in the output folder for details.")
          self.process = nil
        }
      }
      try process.run()
      self.process = process; running = true; completed = false
      message = narration ? "Preparing narration, then recording the selected lessons…" : "Preparing the recording…"
      poll = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(500))
          guard let self, self.running else { return }
          if let data = try? Data(contentsOf: output.appendingPathComponent("progress.json")),
             let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if value["status"] as? String == "waiting" { self.message = "Waiting for the other tutorial recording to finish…" }
            else if value["status"] as? String == "encoding" { self.message = "Building the narrated video and offline player…" }
            else if let lesson = value["lesson"] as? String {
              self.message = "Recording \(lesson) · \(value["completed"] as? Int ?? 0) of \(value["total"] as? Int ?? 0) complete"
            }
          }
        }
      }
    } catch { message = error.localizedDescription }
  }

  func stop() { process?.terminate(); message = "Stopping the recording and preserving captured images…" }
  func openOutput() { if let output { NSWorkspace.shared.open(output) } }
  func openPlayer() { if let output { NSWorkspace.shared.open(output.appendingPathComponent("standalone.html")) } }
}

private struct TutorialRecordingView: View {
  @Bindable var controller: TutorialRecordingController
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Record a narrated tutorial").font(.title2.bold())
      Text("Resize the main window before recording. A separate app session will demonstrate the selected lessons on demo files.")
        .font(.callout).foregroundStyle(.secondary)
      if let geometry = controller.geometry {
        HStack(spacing: 16) {
          RoundedRectangle(cornerRadius: 5).stroke(.secondary, lineWidth: 2)
            .aspectRatio(geometry.pointsWidth / geometry.pointsHeight, contentMode: .fit).frame(width: 140, height: 90)
          VStack(alignment: .leading) {
            Text("\(Int(geometry.pointsWidth)) × \(Int(geometry.pointsHeight)) points")
            Text("\(geometry.width) × \(geometry.height) video pixels").fontWeight(.semibold)
            Text("Native \(geometry.scale, specifier: "%.1f")× display scale").font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      Text(controller.app.preferences.sidebarShown ? "The recording starts with the sidebar shown." : "The recording starts with the sidebar hidden.")
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("All Lessons") { controller.selected = Set(controller.tutorial.catalog.scripts.map(\.id)) }
        Button("Pilot Lessons") { controller.selected = ["navigate", "copy", "editor_basics"] }
        Button("Clear") { controller.selected = [] }
      }.disabled(controller.running)
      List {
        ForEach(controller.tutorial.catalog.chapters) { chapter in
          Section(chapter.title) {
            ForEach(controller.tutorial.catalog.scripts(in: chapter.id)) { script in
              Toggle(script.title, isOn: Binding(get: { controller.selected.contains(script.id) }, set: { enabled in
                if enabled { controller.selected.insert(script.id) } else { controller.selected.remove(script.id) }
              }))
            }
          }
        }
      }.disabled(controller.running).frame(minHeight: 180)
      HStack {
        Picker("Appearance", selection: $controller.appearance) {
          Text("Current system").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
        }
        Toggle("Voice narration", isOn: $controller.narration)
      }.disabled(controller.running)
      if controller.narration {
        HStack {
          TextField("Voice (blank chooses an installed language match)", text: $controller.voice)
          TextField("Language", text: $controller.language).frame(width: 80)
          Stepper("\(controller.speechRate) words/min", value: $controller.speechRate, in: 80...300, step: 10)
        }.disabled(controller.running)
      }
      HStack {
        Button("Output Folder…", action: controller.chooseOutput).disabled(controller.running)
        Text(controller.output?.lastPathComponent ?? "Choose where to save images, video, and the player").font(.caption).lineLimit(1)
      }
      Text(controller.message).font(.callout).fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("Show Output", action: controller.openOutput).disabled(controller.output == nil)
        if controller.completed { Button("Open Player", action: controller.openPlayer) }
        Spacer()
        if controller.running { ProgressView().controlSize(.small); Button("Stop", action: controller.stop) }
        else { Button(controller.canResume ? "Resume Recording" : "Start Recording", action: controller.start).buttonStyle(.borderedProminent).disabled(controller.selected.isEmpty) }
      }
    }.padding(20).frame(minWidth: 600, minHeight: 620)
  }
}
