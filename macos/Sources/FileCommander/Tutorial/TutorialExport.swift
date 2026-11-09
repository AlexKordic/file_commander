import AppKit
import Foundation

/// Compatibility entry point for existing --export-explainer invocations.
/// Uses the same image-first exporter as Record Tutorial and preserves the
/// current window size. Restart lessons are recorded by the external supervisor.
extension TutorialCoordinator {
  func export(_ which: String, arguments: [String]) {
    func option(_ name: String) -> String? {
      arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }
    let selected = which == "all" || which == "entire" ? Set(catalog.scripts.map(\.id)) : Set(which.split(separator: ",").map(String.init))
    guard !selected.isEmpty, selected.isSubset(of: Set(catalog.scripts.map(\.id))) else {
      FileHandle.standardError.write(Data("Unknown tutorial selection: \(which)\n".utf8)); exit(2)
    }
    let out = URL(fileURLWithPath: option("--out") ?? "build-tutorial-media/export", isDirectory: true)
    let appearance = option("--appearance") ?? app.preferences.appearance.rawValue
    let appearances = appearance == "both" ? ["light", "dark"] : [appearance]
    Task { @MainActor in
      for appearance in appearances {
        recording.selected = selected
        recording.appearance = appearance
        recording.voice = option("--voice") ?? "Samantha"
        recording.narration = !arguments.contains("--silent")
        recording.output = appearances.count == 1 ? out : out.appendingPathComponent(appearance)
        recording.start()
        while recording.running { try? await Task.sleep(for: .milliseconds(100)) }
        guard recording.completed else {
          FileHandle.standardError.write(Data("Tutorial export failed: \(recording.message)\n".utf8))
          app.stop(); exit(1)
        }
      }
      app.stop(); exit(0)
    }
  }
}
