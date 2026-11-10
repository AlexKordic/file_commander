import AppKit
import ExplainerKit
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
        if let path = option("--geometry") {
          do {
            let geometry = try JSONDecoder().decode(TutorialFrameRecorder.Geometry.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            mainWindow?.setFrame(geometry.frame, display: true)
          } catch {
            FileHandle.standardError.write(Data("Invalid recording geometry: \(error.localizedDescription)\n".utf8))
            app.stop(); exit(2)
          }
        }
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
