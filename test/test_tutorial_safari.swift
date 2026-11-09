// Manual macOS qualification of the installed Safari through existing AX access.
// The observed page adds diagnostics, but does not change player behavior or
// Safari privacy settings. Leave its local preview open for review.
import AppKit
import ApplicationServices
import Foundation

private struct Failure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

private func attribute(_ element: AXUIElement, _ name: String) -> Any? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
  return value
}

private func text(_ element: AXUIElement, _ name: String) -> String {
  attribute(element, name) as? String ?? ""
}

private func canPress(_ element: AXUIElement) -> Bool {
  var actions: CFArray?
  return AXUIElementCopyActionNames(element, &actions) == .success &&
    (actions as? [String] ?? []).contains(kAXPressAction)
}

private func find(_ root: AXUIElement, _ predicate: (AXUIElement) -> Bool) -> AXUIElement? {
  var pending = [root], visited = 0
  while let next = pending.popLast(), visited < 12000 {
    visited += 1
    if predicate(next) { return next }
    pending.append(contentsOf: ((attribute(next, kAXChildrenAttribute) as? [AXUIElement]) ?? []).reversed())
  }
  return nil
}

private func eventually<T>(_ label: String, seconds: Double = 30, _ read: () -> T?) throws -> T {
  let deadline = ProcessInfo.processInfo.systemUptime + seconds
  while ProcessInfo.processInfo.systemUptime < deadline {
    if let value = read() { return value }
    Thread.sleep(forTimeInterval: 0.05)
  }
  throw Failure(message: "Timed out: " + label)
}

@main
private struct SafariQualification {
  @MainActor static func main() {
    guard CommandLine.arguments.count == 4 || (CommandLine.arguments.count == 5 && CommandLine.arguments[4] == "--cleanup") else {
      fputs("Usage: tutorial-safari-test PAGE.html UNIQUE-TITLE REPORT.json [--cleanup]\n", stderr); exit(2)
    }
    let page = URL(fileURLWithPath: CommandLine.arguments[1])
    let title = CommandLine.arguments[2]
    let reportURL = URL(fileURLWithPath: CommandLine.arguments[3])
    var report: [String: Any] = ["browser": "Safari", "driver": "macOS accessibility", "status": "running", "checks": [String]()]
    var stateElement: AXUIElement?
    var cleanup: (() throws -> Void)?
    var checks: [String] = []
    func state() -> [String: Any]? {
      guard let stateElement, let data = text(stateElement, kAXValueAttribute).data(using: .utf8) else { return nil }
      return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    func check(_ condition: Bool, _ message: String) throws {
      if !condition { throw Failure(message: message) }
    }
    do {
      guard AXIsProcessTrusted() else { throw Failure(message: "Accessibility permission is required; no permission settings were changed") }
      let launch = Process()
      launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      launch.arguments = ["-a", "/Applications/Safari.app", page.path]
      try launch.run(); launch.waitUntilExit()
      guard launch.terminationStatus == 0 else { throw Failure(message: "Cannot open the owned Safari test page") }
      let safari = try eventually("Safari launch") { NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first }
      safari.activate(options: [.activateIgnoringOtherApps])
      let application = AXUIElementCreateApplication(safari.processIdentifier)
      let window: AXUIElement = try eventually("Owned Safari window", seconds: 60) {
        (attribute(application, kAXWindowsAttribute) as? [AXUIElement])?.first { text($0, kAXTitleAttribute).contains(title) }
      }
      let web: AXUIElement = try eventually("Owned document web area", seconds: 60) {
        find(window) { text($0, kAXRoleAttribute) == "AXWebArea" }
      }
      stateElement = try eventually("Read-only diagnostic field", seconds: 60) {
        find(web) { text($0, kAXRoleAttribute) == "AXTextArea" &&
          (text($0, kAXDescriptionAttribute) == "Safari qualification state" || text($0, kAXTitleAttribute) == "Safari qualification state") }
      }
      func press(_ title: String) throws {
        let button: AXUIElement = try eventually("Button " + title) {
          find(web) { (text($0, kAXTitleAttribute) == title || text($0, kAXDescriptionAttribute) == title) && canPress($0) }
        }
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
          throw Failure(message: "Cannot press " + title)
        }
      }
      cleanup = { try press("Finish Safari verification") }
      if CommandLine.arguments.count == 5 {
        try cleanup?(); print("Removed the owned diagnostic observer; preview remains open."); exit(0)
      }
      let initial: [String: Any] = try eventually("Page script") { let s = state(); return s?["ready"] as? Bool == true ? s : nil }
      report["user_agent"] = initial["user_agent"]
      report["source_standalone_sha256"] = initial["source_sha256"]
      let version = Bundle(url: URL(fileURLWithPath: "/Applications/Safari.app"))?.object(forInfoDictionaryKey: "CFBundleShortVersionString")
      report["version"] = version
      try press("Play this step")
      let playing: [String: Any] = try eventually("First user-initiated playback", seconds: 45) {
        let s = state(); return s?["paused"] as? Bool == false ? s : nil
      }
      try check((playing["width"] as? Int ?? 0) > 0 && (playing["height"] as? Int ?? 0) > 0, "Video did not decode")
      checks.append("single-file-embedded-video-decodes-after-native-click")
      let finished: [String: Any] = try eventually("Bounded step finish", seconds: 60) {
        let s = state(); return (s?["status"] as? String ?? "").hasPrefix("Step finished") && s?["paused"] as? Bool == true ? s : nil
      }
      let stop = finished["stop"] as? [String: Any]
      let error = abs(stop?["error_ms"] as? Double ?? .infinity)
      try check(error <= 100, "Safari step boundary exceeded 100 ms: \(error)")
      report["step_boundary_error_ms"] = error
      checks.append("bounded-step-pauses-within-100ms")
      try press("Captions")
      _ = try eventually("File caption Blob track") {
        let s = state(); return s?["captions"] as? String == "showing" && (s?["cues"] as? Int ?? 0) > 0 ? s : nil
      } as [String: Any]
      checks.append("offline-caption-blob-cues")
      let selected = finished["selected"] as? String
      try press("Next step")
      _ = try eventually("Next selects paused frame") {
        let s = state(); return s?["selected"] as? String != selected && s?["paused"] as? Bool == true ? s : nil
      } as [String: Any]
      try press("Previous step")
      _ = try eventually("Previous selects paused frame") {
        let s = state(); return s?["selected"] as? String == selected && s?["paused"] as? Bool == true ? s : nil
      } as [String: Any]
      checks.append("previous-next-select-paused")
      try press("Replay current step")
      _ = try eventually("Replay starts") { let s = state(); return s?["paused"] as? Bool == false ? s : nil } as [String: Any]
      try press("Pause / Resume")
      _ = try eventually("Accessible pause") { let s = state(); return s?["paused"] as? Bool == true ? s : nil } as [String: Any]
      checks.append("replay-and-accessible-pause")
      guard let chapter = (initial["chapters"] as? [[String: Any]])?.last,
            let chapterTitle = chapter["title"] as? String, let start = chapter["start"] as? Double else {
        throw Failure(message: "No chapter metadata")
      }
      try press(chapterTitle)
      _ = try eventually("Chapter seeks and plays") {
        let s = state(), at = s?["time"] as? Double ?? -1
        return s?["paused"] as? Bool == false && at >= start && at < start + 3 ? s : nil
      } as [String: Any]
      try press("Pause / Resume")
      checks.append("chapter-jump-plays")
      let final = state() ?? [:]
      try check((final["external_requests"] as? [String] ?? []).isEmpty, "Page requested external media")
      checks.append("no-http-resources")
      report["status"] = "passed"
      report["width"] = playing["width"]; report["height"] = playing["height"]
      report["duration"] = playing["duration"]
    } catch {
      report["status"] = "failed"; report["error"] = error.localizedDescription
      report["last_state"] = state()
    }
    try? cleanup?()
    report["checks"] = checks
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: reportURL, options: .atomic)
    }
    print("Installed Safari: \(report["status"] ?? "failed")")
    exit(report["status"] as? String == "passed" ? 0 : 1)
  }
}
