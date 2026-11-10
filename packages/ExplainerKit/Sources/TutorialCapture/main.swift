import AppKit
import ExplainerKit
import Foundation

@main
struct CaptureMain {
  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
      do {
        if CommandLine.arguments.dropFirst() == ["--describe-display"] {
          guard let screen = NSScreen.main else { throw TutorialFrameRecorder.Failure.recording("No active display") }
          let frame = screen.visibleFrame
          let info: [String: Any] = ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height,
                                     "scale": screen.backingScaleFactor, "capture_permission": CGPreflightScreenCaptureAccess()]
          FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: info))
          exit(0)
        }
        guard CommandLine.arguments.count == 2 else { throw TutorialFrameRecorder.Failure.recording("Usage: tutorial-capture CONFIG.json") }
        try await capture(URL(fileURLWithPath: CommandLine.arguments[1]))
        exit(0)
      } catch {
        FileHandle.standardError.write(Data("Tutorial capture: \(error.localizedDescription)\n".utf8))
        exit(1)
      }
    }
    app.run()
  }

  @MainActor
  private static func capture(_ configURL: URL) async throws {
    let config = try TutorialCaptureConfiguration.read(configURL)
    let session = URL(fileURLWithPath: config.session, isDirectory: true)
    let recorder = TutorialFrameRecorder()
    func readHost() -> [String: Any]? {
      guard let data = try? Data(contentsOf: session.appendingPathComponent("host.json")) else { return nil }
      return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    func result(_ value: [String: Any]) throws {
      let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
      try data.write(to: session.appendingPathComponent("capture_result.json"), options: .atomic)
    }
    var started = false
    do {
      var pid: pid_t?
      for _ in 0..<2400 {
        if let host = readHost() {
          if host["status"] as? String == "failed" { throw TutorialFrameRecorder.Failure.recording(host["error"] as? String ?? "Host preparation failed") }
          if host["status"] as? String == "ready" { pid = (host["pid"] as? NSNumber)?.int32Value; break }
        }
        try await Task.sleep(for: .milliseconds(25))
      }
      guard var activePID = pid else { throw TutorialFrameRecorder.Failure.recording("Host did not prepare its tutorial window within one minute") }
      func windows(_ host: [String: Any]?) -> Set<UInt32>? {
        (host?["window_ids"] as? [NSNumber]).map { Set($0.map(\.uint32Value)) }
      }
      var activeWindows = windows(readHost())
      try await recorder.start(folder: URL(fileURLWithPath: config.folder), lesson: config.lesson,
                               geometry: config.geometry, fps: config.fps, includingProcessIDs: [activePID],
                               includingWindowIDs: activeWindows)
      started = true
      var ready: [String: Any] = ["schema": 1, "origin_host_ns": recorder.originNanoseconds ?? 0, "pid": getpid(), "host_pid": activePID]
      try JSONSerialization.data(withJSONObject: ready).write(to: session.appendingPathComponent("capture_ready.json"), options: .atomic)
      let requests = try FileHandle(forReadingFrom: session.appendingPathComponent("requests.jsonl"))
      defer { try? requests.close() }
      var pending = Data()
      var missingSince: Date?
      var restarting = false
      func drain() async throws {
        pending.append(try requests.readToEnd() ?? Data())
        while let newline = pending.firstIndex(of: 0x0a) {
          let line = pending[..<newline]
          let raw = try JSONSerialization.jsonObject(with: line) as? [String: Any]
          pending.removeSubrange(...newline)
          guard var event = raw, let type = event.removeValue(forKey: "type") as? String,
                let host = event.removeValue(forKey: "host_ns") as? NSNumber else {
            throw TutorialFrameRecorder.Failure.recording("Malformed tutorial event request")
          }
          if type == "capture_failed" {
            throw TutorialFrameRecorder.Failure.recording(event["message"] as? String ?? "Host invalidated this take")
          }
          if type == "step_started" {
            recorder.setOwner(lesson: config.lesson["id"] ?? "lesson", step: event["id"] as? String ?? "step")
          }
          recorder.event(type, fields: event, hostNanoseconds: host.int64Value)
          if type == "segment_completed" { await recorder.flushFrames() }
        }
      }
      while true {
        try await drain()
        if let failure = recorder.failure { throw TutorialFrameRecorder.Failure.recording(failure) }
        if let host = readHost() {
          let status = host["status"] as? String
          if status == "failed" { throw TutorialFrameRecorder.Failure.recording(host["error"] as? String ?? "Host lesson failed") }
          if status == "complete" {
            try await drain()
            guard pending.isEmpty else { throw TutorialFrameRecorder.Failure.recording("Incomplete final event in capture journal") }
            break
          }
          if status == "restarting", !restarting {
            try await recorder.showRestartCard()
            restarting = true
          }
          if let newPID = (host["pid"] as? NSNumber)?.int32Value, newPID != activePID, status == "ready" {
            guard kill(newPID, 0) == 0 else { throw TutorialFrameRecorder.Failure.recording("Replacement tutorial host is not running") }
            activeWindows = windows(host)
            try await recorder.updateProcesses([newPID], includingWindowIDs: activeWindows, resume: true)
            recorder.event("host_relaunched", fields: ["previous_pid": activePID, "pid": newPID])
            activePID = newPID; missingSince = nil
            restarting = false
            ready["host_pid"] = newPID
            try JSONSerialization.data(withJSONObject: ready).write(to: session.appendingPathComponent("capture_ready.json"), options: .atomic)
          } else if status == "ready", windows(host) != activeWindows {
            activeWindows = windows(host)
            try await recorder.updateProcesses([activePID], includingWindowIDs: activeWindows)
          }
          if kill(activePID, 0) != 0 {
            if status != "restarting" { throw TutorialFrameRecorder.Failure.recording("Tutorial host exited unexpectedly") }
            if missingSince == nil { missingSince = Date() }
            if Date().timeIntervalSince(missingSince!) > 120 { throw TutorialFrameRecorder.Failure.recording("Tutorial host did not return after restart") }
          }
        }
        try await Task.sleep(for: .milliseconds(25))
      }
      await recorder.flushFrames()
      let manifest = try await recorder.stop()
      started = false
      try result(["schema": 1, "status": "complete", "manifest": manifest.path])
    } catch {
      recorder.fail(error.localizedDescription)
      if started { _ = try? await recorder.stop() }
      try? result(["schema": 1, "status": "failed", "error": error.localizedDescription])
      throw error
    }
  }
}
