import AppKit
import ExplainerKit
import SwiftUI

@main
struct ExampleMain {
  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    Task { @MainActor in
      guard let index = CommandLine.arguments.firstIndex(of: "--record-session"), index + 1 < CommandLine.arguments.count else {
        FileHandle.standardError.write(Data("Use tutorial_media.py record with the example's Lessons catalog.\n".utf8)); exit(2)
      }
      let configurationURL = URL(fileURLWithPath: CommandLine.arguments[index + 1])
      do {
        let config = try TutorialCaptureConfiguration.read(configurationURL)
        if config.appearance == "dark" { app.appearance = NSAppearance(named: .darkAqua) }
        if config.appearance == "light" { app.appearance = NSAppearance(named: .aqua) }
        let host = CounterHost(geometry: config.geometry)
        let scriptURL = config.scriptPath.map { URL(fileURLWithPath: $0) } ?? Bundle.module.url(forResource: "Lessons/counter", withExtension: "json")!
        let script = try JSONDecoder().decode(ExplainerScript.self, from: Data(contentsOf: scriptURL))
        let runner = ExplainerRunner(), annotations = AnnotationWindowController()
        let client = try TutorialCaptureClient(configuration: config)
        annotations.show(over: host.window, runner: runner, style: .init(), controlsView: AnyView(EmptyView()))
        try client.announceReady(window: host.window)
        try await client.waitForRecorder()
        client.connect(runner)
        do {
          try await runner.run(script, host: host)
          try await Task.sleep(for: .milliseconds(450))
          try await client.finish()
          annotations.hide(); host.window.close(); exit(0)
        } catch {
          try? await client.finish(error: error.localizedDescription)
          throw error
        }
      } catch {
        FileHandle.standardError.write(Data("Example recording: \(error.localizedDescription)\n".utf8)); exit(1)
      }
    }
    app.run()
  }
}

@MainActor
private final class CounterHost: NSObject, ExplainerHost, AnchorResolver {
  let window: NSWindow
  private let counter = NSTextField(labelWithString: "0")
  private let name = NSTextField(string: "")
  private let add = NSButton(title: "Add One", target: nil, action: nil)
  private var value = 0

  init(geometry: TutorialFrameRecorder.Geometry) {
    window = NSWindow(contentRect: geometry.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    super.init()
    window.title = "ExplainerKit example"
    window.isReleasedWhenClosed = false
    window.setFrame(geometry.frame, display: false)
    let title = NSTextField(labelWithString: "A tutorial in another application")
    title.font = .systemFont(ofSize: 28, weight: .semibold)
    counter.font = .monospacedDigitSystemFont(ofSize: 64, weight: .medium)
    name.placeholderString = "Your name"
    name.font = .systemFont(ofSize: 22)
    name.widthAnchor.constraint(equalToConstant: 360).isActive = true
    add.target = self; add.action = #selector(increment)
    add.controlSize = .large
    let stack = NSStackView(views: [title, counter, add, NSTextField(labelWithString: "Name"), name])
    stack.orientation = .vertical; stack.spacing = 20; stack.alignment = .centerX
    stack.translatesAutoresizingMaskIntoConstraints = false
    window.contentView!.addSubview(stack)
    NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor),
                                 stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 55)])
    AnchorRegistry.shared.register(resolver: self, prefix: "example.increment")
    AnchorRegistry.shared.register(resolver: self, prefix: "example.name")
    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func increment() { value += 1; counter.stringValue = String(value) }
  var hostWindow: NSWindow? { window }
  var overlayStyle: OverlayStyle { .init() }
  func prepare(_ script: ExplainerScript) async throws {}
  func finish(_ script: ExplainerScript, keepTabs: Bool) async {}
  func press(_ chord: String) async throws {}
  func type(_ character: String) async throws { name.stringValue += character }
  func evaluate(_ condition: JSONValue) -> Bool {
    if let count = condition["count"]?.number { return value == Int(count) }
    if let text = condition["name"]?.string { return name.stringValue == text }
    return false
  }
  func describe(_ condition: JSONValue) -> String { "the counter or name to match" }
  func perform(_ step: ExplainerStep, runner: ExplainerRunner) async throws -> Bool {
    if step.action == "resize_window" {
      var frame = window.frame
      frame.size.width += step.value.number ?? 40
      window.setFrame(frame, display: true)
      return true
    }
    return false
  }
  func drag(from: String, to: String, duration: Double) async throws {}
  func willRun(_ step: ExplainerStep, index: Int) {}
  func keyLabel(_ chord: String) -> String { chord }
  func expand(_ text: String) -> String { text }
  func screenRect(for id: String) -> CGRect? {
    let view: NSView = id == "example.increment" ? add : name
    return window.convertToScreen(view.convert(view.bounds, to: nil))
  }
  func perform(anchor id: String) -> Bool {
    if id == "example.increment" { add.performClick(nil); return true }
    if id == "example.name" { window.makeFirstResponder(name); return true }
    return false
  }
}
