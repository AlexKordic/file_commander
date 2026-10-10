import Foundation

/// Settings only the app uses, kept beside the shared settings.json in the
/// profile as app_settings.json. The terminal interface never reads it, so
/// app key bindings (which may use Cmd) can't break its settings.
struct AppPreferences: Codable, Equatable {
  enum KeyPreset: String, Codable, CaseIterable, Identifiable {
    case commander, mac
    var id: String { rawValue }
    var title: String { self == .commander ? "Commander" : "Mac" }
  }
  enum SelectionStyle: String, Codable, CaseIterable, Identifiable {
    case commander, finder
    var id: String { rawValue }
    var title: String { self == .commander ? "Commander" : "Finder" }
  }
  enum Appearance: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
  }
  enum TutorialMode: String, Codable, CaseIterable, Identifiable {
    case watch, guided
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
  }

  var version = 1
  var keyPreset = KeyPreset.commander
  /// Command ID to chord, per preset; "" unbinds the preset's default.
  var keyOverrides: [String: [String: String]] = [:]
  var selectionStyle = SelectionStyle.commander
  var theme = "Default"
  var appearance = Appearance.system
  var zoom = 1.0
  var welcomeShown = false
  var tutorialMode = TutorialMode.watch
  var tutorialSpeed = 1.0
  var watchedExplainers: [String] = []
  var tutorialPosition = 0  // Next explainer of Entire tutorial.
  var paneSplit = 0.5

  static func load(from url: URL) -> AppPreferences {
    guard let data = try? Data(contentsOf: url) else { return AppPreferences() }
    return (try? JSONDecoder().decode(AppPreferences.self, from: data)) ?? AppPreferences()
  }

  func save(to url: URL) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(self) else { return }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url, options: .atomic)
  }
}
