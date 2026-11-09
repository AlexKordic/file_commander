import AppKit
import CoreMedia
import Foundation

/// Language-neutral filesystem protocol between a tutorial host and its
/// external recorder. One owned host writes requests; the recorder survives a
/// host restart and continues using the same monotonic clock.
public struct TutorialCaptureConfiguration: Codable, Sendable {
  public var schema: Int = 1
  public var folder: String
  public var session: String
  public var lesson: [String: String]
  public var geometry: TutorialFrameRecorder.Geometry
  public var fps: Int = 30
  public var narration: String?
  public var scriptPath: String?
  public var appearance: String?
  public var initialPath: String?
  public init(folder: String, session: String, lesson: [String: String], geometry: TutorialFrameRecorder.Geometry,
              fps: Int = 30, narration: String? = nil, scriptPath: String? = nil, appearance: String? = nil, initialPath: String? = nil) {
    self.folder = folder; self.session = session; self.lesson = lesson
    self.geometry = geometry; self.fps = fps; self.narration = narration
    self.scriptPath = scriptPath
    self.appearance = appearance
    self.initialPath = initialPath
  }
  public static func read(_ url: URL) throws -> Self {
    let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    guard value.schema == 1, (1...60).contains(value.fps), value.geometry.width > 0, value.geometry.height > 0 else {
      throw TutorialFrameRecorder.Failure.recording("Unsupported or invalid capture configuration")
    }
    return value
  }
}

public enum TutorialMediaTools {
  public static var command: URL { Bundle.module.url(forResource: "MediaTools", withExtension: nil)!.appendingPathComponent("tutorial_media_cli.py") }
}

@MainActor
public final class TutorialCaptureClient {
  public let configuration: TutorialCaptureConfiguration
  /// Host adapter arranges sheets/auxiliary windows before adding them to capture.
  public var prepareCaptureWindows: (() throws -> Void)?
  private let session: URL
  private var requests: FileHandle?
  private var clips: [String: [String: Any]] = [:]
  private var activeSegment: (id: String, started: Int64, duration: Int64, trailing: Double)?
  private var activeActions: [String] = []
  private weak var runner: ExplainerRunner?
  private var geometryWatch: Task<Void, Never>?
  private var captureFailure: String?
  private var announcedWindows: [Int] = []

  private var visibleWindows: [Int] {
    NSApp.windows.filter { $0.isVisible && $0.identifier?.rawValue != "explainer-controls" }.map(\.windowNumber).sorted()
  }

  public init(configuration: TutorialCaptureConfiguration) throws {
    self.configuration = configuration
    session = URL(fileURLWithPath: configuration.session, isDirectory: true)
    if let narration = configuration.narration {
      let data = try Data(contentsOf: URL(fileURLWithPath: narration))
      let record = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      guard record?["schema"] as? Int == 1, let clips = record?["clips"] as? [String: [String: Any]] else {
        throw TutorialFrameRecorder.Failure.recording("Unsupported narration manifest")
      }
      self.clips = clips
    }
  }

  public static func hostNanoseconds() -> Int64 {
    CMTimeConvertScale(CMClockGetTime(CMClockGetHostTimeClock()), timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
  }

  public func announceReady(window: NSWindow) throws {
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    let url = session.appendingPathComponent("requests.jsonl")
    if !FileManager.default.fileExists(atPath: url.path) {
      guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        throw TutorialFrameRecorder.Failure.recording("Cannot create capture requests")
      }
    }
    requests = try FileHandle(forWritingTo: url)
    try requests?.seekToEnd()
    try prepareCaptureWindows?()
    try status("ready")
    geometryWatch = Task { [weak self, weak window] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(100))
        guard !Task.isCancelled, let self, let window else { return }
        let expected = self.configuration.geometry
        let actual = TutorialFrameRecorder.Geometry(frame: window.frame, scale: window.backingScaleFactor)
        if abs(actual.x - expected.x) > 0.5 || abs(actual.y - expected.y) > 0.5 ||
           abs(actual.pointsWidth - expected.pointsWidth) > 0.5 || abs(actual.pointsHeight - expected.pointsHeight) > 0.5 ||
           actual.scale != expected.scale {
          let reason = "The recording window changed size or display. Choose the desired size and start a new take."
          self.captureFailure = reason
          try? self.event("capture_failed", fields: ["message": reason])
          self.runner?.stop()
          return
        }
        if self.visibleWindows != self.announcedWindows {
          do { try self.prepareCaptureWindows?(); try self.status("ready") }
          catch {
            self.captureFailure = error.localizedDescription
            try? self.event("capture_failed", fields: ["message": error.localizedDescription])
            self.runner?.stop()
            return
          }
        }
      }
    }
  }

  public func waitForRecorder() async throws {
    let ready = session.appendingPathComponent("capture_ready.json")
    for _ in 0..<1200 {
      try checkFailure()
      if let data = try? Data(contentsOf: ready), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         (value["host_pid"] as? NSNumber)?.int32Value == getpid() { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    throw TutorialFrameRecorder.Failure.recording("The external recorder did not become ready within 30 seconds")
  }

  private func checkFailure() throws {
    if let captureFailure { throw TutorialFrameRecorder.Failure.recording(captureFailure) }
    let url = session.appendingPathComponent("capture_result.json")
    if let data = try? Data(contentsOf: url), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       value["status"] as? String == "failed" {
      throw TutorialFrameRecorder.Failure.recording(value["error"] as? String ?? "The recorder failed")
    }
  }

  private func event(_ type: String, fields: [String: Any] = [:]) throws {
    guard let requests else { throw TutorialFrameRecorder.Failure.recording("The capture session is closed") }
    var value = fields
    value["type"] = type; value["host_ns"] = Self.hostNanoseconds()
    var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    data.append(0x0a)
    try requests.write(contentsOf: data)
  }

  private func status(_ value: String, error: String? = nil) throws {
    announcedWindows = visibleWindows
    var record: [String: Any] = ["schema": 1, "status": value, "pid": getpid(), "host_ns": Self.hostNanoseconds(),
                                 "window_ids": announcedWindows]
    if let error { record["error"] = error }
    let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    try data.write(to: session.appendingPathComponent("host.json"), options: .atomic)
  }

  public func connect(_ runner: ExplainerRunner) {
    self.runner = runner
    runner.beforeStep = { [weak self] script, step, index in
      guard let self else { throw CancellationError() }
      try self.checkFailure()
      if let presentation = step.presentation {
        try await self.finishSegment()
        let identity = presentation["id"]?.string ?? step.id ?? "\(script.id).step-\(index)"
        let text = presentation["narration"]?.string ?? ""
        if self.configuration.narration != nil, self.clips[identity] == nil {
          throw TutorialFrameRecorder.Failure.recording("Narration was not prepared for \(identity)")
        }
        let duration = (self.clips[identity]?["duration_ns"] as? NSNumber)?.int64Value ?? 0
        self.activeSegment = (identity, Self.hostNanoseconds(), duration, presentation["trailing_hold"]?.number ?? 0.35)
        try self.event("segment_started", fields: ["id": identity, "title": presentation["title"]?.string ?? script.title, "text": text])
        if step.action == "caption" {
          runner.overlay.caption = .init(title: step.value.string ?? "", subtitle: step.option("sub")?.string ?? "")
        }
        let lead = presentation["lead_in"]?.number ?? 0.12
        if lead > 0 { try await Task.sleep(for: .seconds(lead)) }
      }
      let identity = step.id ?? "\(script.id).step-\(index)"
      self.activeActions.append(identity)
      try self.event("step_started", fields: ["id": identity, "action": step.action, "lesson": script.id])
    }
    runner.afterStep = { [weak self] _, _, _ in
      guard let self else { throw CancellationError() }
      try self.checkFailure()
      if let identity = self.activeActions.popLast() {
        try self.event("step_completed", fields: ["id": identity])
      }
    }
    runner.afterLesson = { [weak self] _ in try await self?.finishSegment() }
  }

  private func finishSegment() async throws {
    guard let active = activeSegment else { return }
    let deadline = max(Self.hostNanoseconds(), active.started + active.duration) + Int64(active.trailing * 1_000_000_000)
    while Self.hostNanoseconds() < deadline {
      try checkFailure(); try Task.checkCancellation()
      try await Task.sleep(for: .milliseconds(25))
    }
    try event("segment_completed", fields: ["id": active.id])
    activeSegment = nil
  }

  /// Close the currently executing crash/relaunch action before the process
  /// exits. The external recorder and its image timeline continue uninterrupted.
  public func prepareRelaunch() async throws {
    try await finishSegment()
    for identity in activeActions.reversed() { try event("step_completed", fields: ["id": identity]) }
    activeActions = []
    geometryWatch?.cancel()
    try status("restarting")
    try requests?.synchronize()
  }

  public func finish(error: String? = nil) async throws {
    geometryWatch?.cancel(); geometryWatch = nil
    runner?.beforeStep = nil; runner?.afterStep = nil; runner?.afterLesson = nil
    if error == nil { try await finishSegment() }
    if let error { try? event("capture_failed", fields: ["message": error]) }
    try requests?.synchronize()
    try requests?.close(); requests = nil
    try status(error == nil ? "complete" : "failed", error: error)
    for _ in 0..<800 {
      let result = session.appendingPathComponent("capture_result.json")
      if let data = try? Data(contentsOf: result), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if value["status"] as? String == "failed" { throw TutorialFrameRecorder.Failure.recording(value["error"] as? String ?? "Recording failed") }
        return
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    throw TutorialFrameRecorder.Failure.recording("The recorder did not finalize the take within 20 seconds")
  }
}
