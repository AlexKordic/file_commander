import AppKit
import Observation
import SwiftUI

/// The themes available, the active one and the zoom. Custom themes live in
/// the profile's themes/ folder and store only what differs from their base.
@MainActor @Observable
final class ThemeStore {
  private(set) var themes: [String: Theme] = [:]
  private(set) var active: Theme = .standard
  var zoom: Double = 1.0 { didSet { revision &+= 1 } }
  /// Bumped on every visible change, so AppKit views know to redraw.
  private(set) var revision = 0
  @ObservationIgnored private var folder: URL?

  init() {
    for theme in Theme.builtIns { themes[theme.name] = theme }
  }

  var names: [String] {
    let builtIn = Theme.builtIns.map(\.name)
    return builtIn + themes.keys.filter { !builtIn.contains($0) }.sorted()
  }
  func isBuiltIn(_ name: String) -> Bool { Theme.builtIns.contains { $0.name == name } }

  func load(profile: URL, activeName: String) {
    folder = profile.appendingPathComponent("themes", isDirectory: true)
    if let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
      for file in files where file.pathExtension == "json" {
        if let data = try? Data(contentsOf: file), let theme = try? JSONDecoder().decode(Theme.self, from: data), !isBuiltIn(theme.name) {
          themes[theme.name] = theme
        }
      }
    }
    activate(activeName)
  }

  func activate(_ name: String) {
    let theme = themes[name] ?? .standard
    active = theme.resolved(using: themes)
    revision &+= 1
  }

  /// An isolated recording uses the exact resolved theme, including live edits.
  func registerRecordingTheme(_ theme: Theme) {
    themes[theme.name] = theme
  }

  /// Applies a live edit without saving it.
  func preview(_ theme: Theme) {
    active = theme.resolved(using: themes)
    revision &+= 1
  }

  /// Saves a custom theme; a built-in name is saved under "<name> (Custom)".
  @discardableResult
  func save(_ theme: Theme) -> String {
    var theme = theme
    if isBuiltIn(theme.name) { theme.name += " (Custom)" }
    let baseName = theme.base.flatMap { themes[$0] != nil ? $0 : nil } ?? "Default"
    let base = (themes[baseName] ?? .standard).resolved(using: themes)
    var stored = theme.resolved(using: themes).differences(from: base)
    stored.base = baseName
    themes[stored.name] = stored
    write(stored)
    activate(stored.name)
    return stored.name
  }

  func delete(_ name: String) {
    guard !isBuiltIn(name) else { return }
    themes[name] = nil
    if let folder { try? FileManager.default.removeItem(at: folder.appendingPathComponent(ThemeStore.fileName(name))) }
    if active.name == name { activate("Default") }
  }

  func importTheme(from url: URL) throws -> String {
    let theme = try JSONDecoder().decode(Theme.self, from: Data(contentsOf: url))
    return save(theme)
  }

  func export(_ name: String, to url: URL) throws {
    let theme = (themes[name] ?? active).resolved(using: themes)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(theme).write(to: url, options: .atomic)
  }

  private func write(_ theme: Theme) {
    guard let folder else { return }
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? encoder.encode(theme).write(to: folder.appendingPathComponent(ThemeStore.fileName(theme.name)), options: .atomic)
  }

  private static func fileName(_ name: String) -> String {
    name.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined().lowercased() + ".json"
  }

  // MARK: Lookup

  func color(_ id: String) -> Color { active.color(id).color }
  func nsColor(_ id: String) -> NSColor { active.color(id).nsColor }
  func font(_ id: String) -> Font { active.font(id).font(zoom: zoom) }
  func nsFont(_ id: String) -> NSFont { active.font(id).nsFont(zoom: zoom) }

  // MARK: Import from the terminal interface

  /// Converts the TUI's theme_colors.json (named colors and 256-color indices) into a theme.
  func importTerminalColors(from url: URL) -> String? {
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let colors = json["colors"] as? [String: String], !colors.isEmpty else { return nil }
    let mapping = [
      "default_fg": "listing.text", "default_bg": "listing.background", "files_path_fg": "pane.path",
      "files_filter_fg": "pane.filter", "files_selected_fg": "listing.marked.text", "files_warning_fg": "listing.warning",
      "files_focused_full": "listing.cursor", "files_unfocused_full": "listing.cursor.inactive",
      "file_directory_file": "listing.directory", "file_symlink_file": "listing.symlink", "file_perm_exe": "listing.executable",
      "file_status_error": "listing.error", "size_gauge_full": "listing.gauge", "progress_total_fg": "bottom.progress",
      "pause_button_bg": "bottom.pause", "stop_button_bg": "bottom.cancel", "recent_error_fg": "bottom.error",
    ]
    var theme = Theme(name: "Imported from TUI", base: "Commander Classic")
    for (tuiID, token) in colors {
      guard let element = mapping[tuiID], let hex = ThemeStore.terminalHex(token) else { continue }
      theme.colors[element] = ThemeColor(hex)
    }
    return save(theme)
  }

  static func terminalHex(_ token: String) -> String? {
    let named: [String: Int] = ["black": 0, "red": 1, "green": 2, "yellow": 3, "blue": 4, "magenta": 5, "cyan": 6, "gray_light": 7,
                                "gray_dark": 8, "white": 15, "grey0": 16, "grey19": 236, "grey27": 238, "gold1": 220, "plum2": 183,
                                "plum3": 176, "dark_green": 22, "dark_sea_green4": 65, "dark_olive_green3_ter": 149,
                                "light_goldenrod2_ter": 222, "orange_red1": 202, "spring_green1": 48, "pale_turquoise1": 159,
                                "pale_green1": 156, "wheat4": 101, "salmon1": 209, "light_pink3": 174, "turquoise2": 45,
                                "misty_rose3": 181, "dark_khaki": 143, "medium_purple4": 60, "dark_goldenrod": 136, "dark_red": 88]
    let index: Int
    if token.hasPrefix("p"), let n = Int(token.dropFirst()), (0...255).contains(n) { index = n }
    else if let n = named[token] { index = n }
    else { return nil }
    return xterm(index)
  }

  static func xterm(_ index: Int) -> String {
    let base: [(Int, Int, Int)] = [(0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0), (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
                                   (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0), (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255)]
    let rgb: (Int, Int, Int)
    if index < 16 {
      rgb = base[index]
    } else if index < 232 {
      let n = index - 16
      let levels = [0, 95, 135, 175, 215, 255]
      rgb = (levels[n / 36], levels[(n / 6) % 6], levels[n % 6])
    } else {
      let v = 8 + (index - 232) * 10
      rgb = (v, v, v)
    }
    return String(format: "#%02X%02X%02X", rgb.0, rgb.1, rgb.2)
  }
}
