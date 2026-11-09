import AppKit
import Foundation
import Observation

/// What an app provides so its explainers can run: the window to annotate,
/// key presses, conditions on its state, and its own kinds of steps.
@MainActor
public protocol ExplainerHost: AnyObject {
  var hostWindow: NSWindow? { get }
  var overlayStyle: OverlayStyle { get }
  /// Sets up what the script needs (demo files, tabs); throws when it can't run now.
  func prepare(_ script: ExplainerScript) async throws
  /// Undoes what the script changed. `keepTabs` leaves its tabs open.
  func finish(_ script: ExplainerScript, keepTabs: Bool) async
  /// Presses a chord such as "F5" or "Shift+Cmd+P" through the app's own key handling.
  func press(_ chord: String) async throws
  /// Types text into whatever has the keyboard focus.
  func type(_ character: String) async throws
  func evaluate(_ condition: JSONValue) -> Bool
  func describe(_ condition: JSONValue) -> String
  /// Runs a step only the host knows; returns false when it doesn't know it either.
  func perform(_ step: ExplainerStep, runner: ExplainerRunner) async throws -> Bool
  /// A mouse drag from one anchor to another, for anchors without a native action.
  func drag(from: String, to: String, duration: Double) async throws
  /// Called before each step, so conditions can refer to what happens after it starts.
  func willRun(_ step: ExplainerStep, index: Int)
  /// How a key appears on its badge; hosts resolve their own notations (such as "@copy").
  func keyLabel(_ chord: String) -> String
  /// Expands the host's placeholders (such as {home}) in typed text.
  func expand(_ text: String) -> String
}

public struct ExplainerFailure: LocalizedError, Sendable {
  public var script: String, step: Int, message: String
  public init(script: String, step: Int, message: String) {
    self.script = script
    self.step = step
    self.message = message
  }
  public var errorDescription: String? { "\(script), step \(step + 1): \(message)" }
}

/// One moment of a run, for captions, chapters and exports.
public struct TimelineEvent: Codable, Hashable, Sendable {
  public var time: Double
  public var kind: String  // caption, uncaption, chapter, keys, highlight, step, crash
  public var text: String
  public var detail: String = ""
}

/// Plays explainer scripts against a host and drives the annotations.
@MainActor @Observable
public final class ExplainerRunner {
  public enum Mode: String, Sendable { case watch, guided }
  public enum State: Equatable, Sendable {
    case idle, running, paused, waitingForUser(String), finished, failed(String), stopped
  }

  public private(set) var state = State.idle
  public private(set) var script: ExplainerScript?
  public private(set) var stepIndex = 0
  public var mode = Mode.watch
  public var speed = 1.0
  public let overlay = OverlayModel()
  public private(set) var timeline: [TimelineEvent] = []
  /// Called after every step, so the host can checkpoint for restarts.
  @ObservationIgnored public var onStep: ((ExplainerScript, Int) -> Void)?
  /// Export adapters can wait for narration or capture readiness without changing
  /// the host's commands. Hooks run on the same actor and preserve action order.
  @ObservationIgnored public var beforeStep: ((ExplainerScript, ExplainerStep, Int) async throws -> Void)?
  @ObservationIgnored public var afterStep: ((ExplainerScript, ExplainerStep, Int) async throws -> Void)?
  @ObservationIgnored public var afterLesson: ((ExplainerScript) async throws -> Void)?

  @ObservationIgnored private var started = ProcessInfo.processInfo.systemUptime
  @ObservationIgnored private var skipRequested = false
  @ObservationIgnored private var stopRequested = false
  @ObservationIgnored private var showMeRequested = false
  @ObservationIgnored private weak var host: ExplainerHost?

  public init() {}

  public var isActive: Bool {
    switch state {
    case .running, .paused, .waitingForUser: return true
    default: return false
    }
  }

  // MARK: Controls

  public func pause() { if state == .running { state = .paused } }
  public func resume() { if state == .paused { state = .running } }
  public func togglePause() { state == .paused ? resume() : pause() }
  /// Ends the current wait or pause and moves to the next step.
  public func skip() { skipRequested = true; if state == .paused { state = .running } }
  public func stop() { stopRequested = true; if state == .paused { state = .running } }
  public func showMe() { showMeRequested = true }

  // MARK: Running

  /// Plays `script` from `startIndex`; returns normally when it finished.
  public func run(_ script: ExplainerScript, host: ExplainerHost, from startIndex: Int = 0, prepared: Bool = false) async throws {
    self.script = script
    self.host = host
    stopRequested = false
    skipRequested = false
    started = ProcessInfo.processInfo.systemUptime
    timeline = []
    overlay.reset()
    overlay.title = script.title
    state = .running
    do {
      if !prepared { try await host.prepare(script) }
      stepIndex = startIndex
      while stepIndex < script.steps.count {
        try await gate()
        let step = script.steps[stepIndex]
        try await beforeStep?(script, step, stepIndex)
        overlay.progress = "\(stepIndex + 1)/\(script.steps.count)"
        record("step", step.action)
        if Trace.enabled {
          Trace.write("explainer \(script.id) step \(stepIndex + 1): \(step.action) \(step.value)\n")
        }
        host.willRun(step, index: stepIndex)
        do {
          try await execute(step, host: host)
        } catch let error as ExplainerFailure {
          throw error
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          throw ExplainerFailure(script: script.id, step: stepIndex, message: error.localizedDescription)
        }
        if step.hold > 0 { try await sleep(step.hold) }
        try await afterStep?(script, step, stepIndex)
        stepIndex += 1
        onStep?(script, stepIndex)
      }
      try await afterLesson?(script)
      overlay.caption = nil
      overlay.highlights = []
      overlay.spotlight = nil
      state = .finished
    } catch let error as ExplainerFailure {
      state = .failed(error.localizedDescription)
      throw error
    } catch {
      state = stopRequested ? .stopped : .failed(error.localizedDescription)
      throw error
    }
  }

  public func record(_ kind: String, _ text: String, _ detail: String = "") {
    timeline.append(TimelineEvent(time: ProcessInfo.processInfo.systemUptime - started, kind: kind, text: text, detail: detail))
  }

  /// Sleeps for script time, honouring speed, pause, skip and stop.
  public func sleep(_ seconds: Double) async throws {
    var remaining = seconds / max(speed, 0.1)
    while remaining > 0 {
      try await gate()
      if skipRequested { skipRequested = false; return }
      let slice = min(remaining, 0.05)
      try await Task.sleep(for: .seconds(slice))
      remaining -= slice
    }
  }

  private func gate() async throws {
    while state == .paused && !stopRequested { try await Task.sleep(for: .milliseconds(50)) }
    if stopRequested || Task.isCancelled { throw CancellationError() }
  }

  /// Polls a condition until it holds; throws after the timeout.
  public func waitFor(_ description: String, timeout: Double, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      try await gate()
      if skipRequested { skipRequested = false; return }
      if Date() > deadline { throw ExplainerFailure(script: script?.id ?? "", step: stepIndex, message: "Timed out waiting for \(description)") }
      try await Task.sleep(for: .milliseconds(40))
    }
  }

  private func execute(_ step: ExplainerStep, host: ExplainerHost) async throws {
    let value = step.value
    switch step.action {
    case "caption":
      let title = value.string ?? value["title"]?.string ?? ""
      let sub = step.option("sub")?.string ?? value["sub"]?.string ?? ""
      overlay.caption = OverlayModel.Caption(title: title, subtitle: sub)
      record("caption", title, sub)
    case "uncaption":
      overlay.caption = nil
      record("uncaption", "")
    case "chapter":
      overlay.chip = value.string
      record("chapter", value.string ?? "")
    case "highlight":
      overlay.highlights = value.strings
      if Trace.enabled {
        for id in value.strings { Trace.write("anchor \(id) = \(String(describing: AnchorRegistry.shared.screenRect(id)))") }
      }
      record("highlight", value.strings.joined(separator: ","))
    case "unhighlight":
      overlay.highlights = []
    case "spotlight":
      overlay.spotlight = value.string
    case "unspotlight":
      overlay.spotlight = nil
    case "stamp":
      overlay.stamp = value.string
    case "point":
      try await movePointer(to: value.string ?? "", approach: step.option("approach_ms")?.number ?? 600)
    case "click":
      let anchor = value.string ?? ""
      try await movePointer(to: anchor, approach: step.option("approach_ms")?.number ?? 600)
      overlay.clickPulse &+= 1
      try await sleep(0.12)
      guard AnchorRegistry.shared.perform(anchor) else {
        throw ExplainerFailure(script: script?.id ?? "", step: stepIndex, message: "Can't click \(anchor)")
      }
    case "drag":
      let from = value["from"]?.string ?? "", to = value["to"]?.string ?? ""
      let duration = (step.option("ms")?.number ?? 900) / 1000
      try await movePointer(to: from, approach: step.option("approach_ms")?.number ?? 600, leading: true)
      overlay.dragging = true
      if let target = AnchorRegistry.shared.screenRect(to) {
        overlay.pointerDuration = duration / max(speed, 0.1)
        overlay.pointer = CGPoint(x: target.minX + 2, y: target.midY)
      }
      try await host.drag(from: from, to: to, duration: duration / max(speed, 0.1))
      overlay.dragging = false
    case "keys":
      let chords = value.strings
      let gap = (step.option("gap")?.number ?? 380) / 1000
      for (i, chord) in chords.enumerated() {
        overlay.badge(host.keyLabel(chord))
        record("keys", chord)
        try await host.press(chord)
        if i < chords.count - 1 { try await sleep(gap) }
      }
    case "type":
      let text = host.expand(value.string ?? "")
      overlay.badge("⌨ " + text)
      record("keys", text)
      var generator = SeededRandom(seed: UInt64(stepIndex + 7))
      for character in text {
        try await host.type(String(character))
        try await sleep(0.045 + 0.06 * generator.next())
      }
    case "pause":
      try await sleep((value.number ?? 1000) / 1000)
    case "wait":
      try await waitFor(host.describe(value), timeout: step.timeout) { host.evaluate(value) }
    case "wait_not":
      try await waitFor("not " + host.describe(value), timeout: step.timeout) { !host.evaluate(value) }
    case "expect":
      if !host.evaluate(value) {
        throw ExplainerFailure(script: script?.id ?? "", step: stepIndex, message: "Expected \(host.describe(value))")
      }
    case "try":
      try await tryStep(value, host: host)
    default:
      if !(try await host.perform(step, runner: self)) {
        throw ExplainerFailure(script: script?.id ?? "", step: stepIndex, message: "Unknown step \(step.action)")
      }
    }
  }

  private func tryStep(_ value: JSONValue, host: ExplainerHost) async throws {
    let task = value["do"]?.string ?? "Your turn"
    let accept = value["accept"] ?? .null
    let fallback = (value["show"]?.array ?? []).compactMap { try? JSONDecoder().decode(ExplainerStep.self, from: JSONEncoder().encode($0)) }
    if mode == .guided {
      let previous = overlay.caption
      overlay.caption = OverlayModel.Caption(title: "Your turn", subtitle: task)
      overlay.highlights = value["hint"]?.strings ?? overlay.highlights
      state = .waitingForUser(task)
      showMeRequested = false
      defer { if case .waitingForUser = state { state = .running } }
      while !host.evaluate(accept) {
        if stopRequested { throw CancellationError() }
        if skipRequested { skipRequested = false; break }
        if showMeRequested {
          showMeRequested = false
          state = .running
          for (index, step) in fallback.enumerated() { try await fallbackStep(step, index: index, host: host) }
          break
        }
        try await Task.sleep(for: .milliseconds(60))
      }
      overlay.caption = previous
    } else {
      for (index, step) in fallback.enumerated() { try await fallbackStep(step, index: index, host: host) }
      if accept != .null { try await waitFor(host.describe(accept), timeout: 15) { host.evaluate(accept) } }
    }
  }

  private func fallbackStep(_ value: ExplainerStep, index: Int, host: ExplainerHost) async throws {
    var step = value
    if let script {
      if step.id == nil {
        let parent = script.steps[stepIndex].id ?? "\(script.id).step-\(stepIndex)"
        step.options["id"] = .string("\(parent).show-\(index)")
      }
      try await beforeStep?(script, step, stepIndex)
      try await execute(step, host: host)
      if step.hold > 0 { try await sleep(step.hold) }
      try await afterStep?(script, step, stepIndex)
    } else { try await execute(step, host: host) }
  }

  private func movePointer(to anchor: String, approach: Double, leading: Bool = false) async throws {
    var rect: CGRect?
    try await waitFor("anchor \(anchor)", timeout: 5) {
      rect = AnchorRegistry.shared.screenRect(anchor)
      return rect != nil
    }
    guard let rect else { return }
    overlay.pointerDuration = approach / 1000 / max(speed, 0.1)
    overlay.pointerVisible = true
    overlay.pointer = leading ? CGPoint(x: rect.minX + 4, y: rect.midY) : CGPoint(x: rect.midX, y: rect.midY)
    try await sleep(approach / 1000)
  }
}

/// A tiny deterministic generator, so every take types at the same rhythm.
struct SeededRandom {
  var state: UInt64
  init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
  mutating func next() -> Double {
    state ^= state << 13
    state ^= state >> 7
    state ^= state << 17
    return Double(state % 10_000) / 10_000
  }
}

public enum KeyBadgeText {
  public static func text(for chord: String) -> String {
    var parts = chord == "+" ? ["+"] : chord.split(separator: "+").map(String.init)
    if chord.hasSuffix("++") { parts = parts.filter { !$0.isEmpty } + ["+"] }
    let glyph: [String: String] = ["ctrl": "⌃", "control": "⌃", "opt": "⌥", "option": "⌥", "alt": "⌥", "shift": "⇧", "cmd": "⌘", "command": "⌘"]
    var out = ""
    for (i, part) in parts.enumerated() {
      if i < parts.count - 1, let g = glyph[part.lowercased()] { out += g } else { out += part }
    }
    return out
  }
}
