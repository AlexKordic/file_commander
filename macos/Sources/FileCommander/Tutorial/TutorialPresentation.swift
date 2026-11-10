import ExplainerKit
import Foundation

/// Only presentation settings enter an export. Sessions, history, credentials,
/// executable plugin settings and the user's files stay in their own profile.
struct TutorialAppPresentation: Codable {
  var theme: Theme
  var zoom: Double
  var paneSplit: Double
  var optionAsAlt: Bool
  var compose: ComposePreferences
}

enum TutorialPresentation {
  static func retakes(root: URL, scripts: [ExplainerScript], options: [String: JSONValue],
                      geometry: TutorialFrameRecorder.Geometry, presentationChanged: Bool) -> [String] {
    scripts.filter { script in
      if presentationChanged { return true }
      let take = root.appendingPathComponent("capture").appendingPathComponent(script.id)
      guard let data = try? Data(contentsOf: take.appendingPathComponent("manifest.json")),
            let manifest = try? JSONDecoder().decode([String: JSONValue].self, from: data),
            manifest["status"]?.string == "complete" else { return false }
      guard let previous = try? TutorialCaptureConfiguration.read(take.appendingPathComponent("config.json")),
            let data = try? Data(contentsOf: take.appendingPathComponent("lesson.json")),
            let lesson = try? JSONDecoder().decode(ExplainerScript.self, from: data) else { return true }
      return previous.hostOptions != options || previous.geometry != geometry || lesson != script
    }.map(\.id)
  }

  static func value<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
  }

  static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
    try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
  }

  @MainActor static func capture(app: AppController, home: URL = URL(fileURLWithPath: NSHomeDirectory())) throws -> [String: JSONValue] {
    let presentation = TutorialAppPresentation(theme: app.theme.active, zoom: app.preferences.zoom,
      paneSplit: app.preferences.paneSplit, optionAsAlt: app.preferences.optionAsAlt, compose: app.preferences.compose)
    var options: [String: JSONValue] = [
      "sidebarShown": .bool(app.preferences.sidebarShown),
      "collapsedSidebarSections": .array(app.preferences.collapsedSidebarSections.map(JSONValue.string)),
      "appPresentation": try value(presentation),
    ]
    let candidates = [home.appendingPathComponent(".config/fresh"), home.appendingPathComponent("Library/Application Support/fresh")]
    let folder = candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("config.json").path) }
    let fresh = try freshSettings(folder: folder)
    options["freshConfig"] = .object(fresh.configuration)
    options["freshThemes"] = .object(fresh.themes)
    return options
  }

  static func freshSettings(folder: URL?) throws -> (configuration: [String: JSONValue], themes: [String: JSONValue]) {
    guard let folder else { return ([:], [:]) }
    let decoder = JSONDecoder()
    decoder.allowsJSON5 = true
    var source = try decoder.decode([String: JSONValue].self, from: Data(contentsOf: folder.appendingPathComponent("config.json")))
    let platform = folder.appendingPathComponent("config_macos.json")
    if FileManager.default.fileExists(atPath: platform.path) {
      source = merge(source, try decoder.decode([String: JSONValue].self, from: Data(contentsOf: platform)))
    }
    var configuration: [String: JSONValue] = [:]
    for key in ["theme", "editor"] { configuration[key] = source[key] }
    if let plugins = source["plugins"]?.object {
      configuration["plugins"] = .object(plugins.compactMapValues { settings in
        settings["enabled"]?.bool.map { .object(["enabled": .bool($0)]) }
      })
    }
    var themes: [String: JSONValue] = [:]
    let directory = folder.appendingPathComponent("themes")
    if FileManager.default.fileExists(atPath: directory.path) {
      for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        where file.pathExtension == "json" {
        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
        themes[file.lastPathComponent] = try decoder.decode(JSONValue.self, from: Data(contentsOf: file))
      }
    }
    return (configuration, themes)
  }

  private static func merge(_ base: [String: JSONValue], _ overrides: [String: JSONValue]) -> [String: JSONValue] {
    var result = base
    for (key, value) in overrides {
      if let old = result[key]?.object, let new = value.object { result[key] = .object(merge(old, new)) }
      else { result[key] = value }
    }
    return result
  }
}
