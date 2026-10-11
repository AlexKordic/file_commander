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
  /// How far from the pane's edge keyboard moves keep the cursor: 0 lets it reach
  /// the edge, 10 keeps it in the middle (until the list's start or end).
  var scrollMargin = 3
  /// In the editor, Option sends Alt (for Fresh's Alt shortcuts) instead of typing its character.
  var optionAsAlt = false
  /// Show the editor in a terminal view instead of drawing it natively.
  var terminalEditor = false
  /// The editor window was open when the app quit; it opens again at launch.
  var editorWasOpen = false

  init() {}

  /// Every field is optional, so a file from an older version keeps its values.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = AppPreferences()
    version = try c.decodeIfPresent(Int.self, forKey: .version) ?? d.version
    keyPreset = try c.decodeIfPresent(KeyPreset.self, forKey: .keyPreset) ?? d.keyPreset
    keyOverrides = try c.decodeIfPresent([String: [String: String]].self, forKey: .keyOverrides) ?? d.keyOverrides
    selectionStyle = try c.decodeIfPresent(SelectionStyle.self, forKey: .selectionStyle) ?? d.selectionStyle
    theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? d.theme
    appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? d.appearance
    zoom = try c.decodeIfPresent(Double.self, forKey: .zoom) ?? d.zoom
    welcomeShown = try c.decodeIfPresent(Bool.self, forKey: .welcomeShown) ?? d.welcomeShown
    tutorialMode = try c.decodeIfPresent(TutorialMode.self, forKey: .tutorialMode) ?? d.tutorialMode
    tutorialSpeed = try c.decodeIfPresent(Double.self, forKey: .tutorialSpeed) ?? d.tutorialSpeed
    watchedExplainers = try c.decodeIfPresent([String].self, forKey: .watchedExplainers) ?? d.watchedExplainers
    tutorialPosition = try c.decodeIfPresent(Int.self, forKey: .tutorialPosition) ?? d.tutorialPosition
    paneSplit = try c.decodeIfPresent(Double.self, forKey: .paneSplit) ?? d.paneSplit
    scrollMargin = min(10, max(0, try c.decodeIfPresent(Int.self, forKey: .scrollMargin) ?? d.scrollMargin))
    optionAsAlt = try c.decodeIfPresent(Bool.self, forKey: .optionAsAlt) ?? d.optionAsAlt
    terminalEditor = try c.decodeIfPresent(Bool.self, forKey: .terminalEditor) ?? d.terminalEditor
    editorWasOpen = try c.decodeIfPresent(Bool.self, forKey: .editorWasOpen) ?? d.editorWasOpen
  }

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
