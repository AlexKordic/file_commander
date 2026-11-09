import AppKit
import SwiftUI

/// A color value in a theme: "#RRGGBB", "#RRGGBBAA" or "system:<NSColor name>".
struct ThemeColor: Codable, Hashable {
  var light: String
  var dark: String

  init(_ light: String, _ dark: String? = nil) {
    self.light = light
    self.dark = dark ?? light
  }

  func nsColor(dark isDark: Bool) -> NSColor { ThemeColor.resolve(isDark ? dark : light) }

  /// A dynamic color that follows the window's appearance.
  var nsColor: NSColor {
    NSColor(name: nil) { appearance in
      let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      return self.nsColor(dark: isDark)
    }
  }
  var color: Color { Color(nsColor: nsColor) }

  static func resolve(_ value: String) -> NSColor {
    if value.hasPrefix("system:") {
      let name = String(value.dropFirst(7))
      let known: [String: NSColor] = [
        "label": .labelColor, "secondaryLabel": .secondaryLabelColor, "tertiaryLabel": .tertiaryLabelColor,
        "quaternaryLabel": .quaternaryLabelColor, "accent": .controlAccentColor, "text": .textColor,
        "textBackground": .textBackgroundColor, "windowBackground": .windowBackgroundColor,
        "controlBackground": .controlBackgroundColor, "selectedContentBackground": .selectedContentBackgroundColor,
        "unemphasizedSelectedContentBackground": .unemphasizedSelectedContentBackgroundColor,
        "selectedText": .selectedTextColor, "separator": .separatorColor, "grid": .gridColor,
        "red": .systemRed, "orange": .systemOrange, "yellow": .systemYellow, "green": .systemGreen, "mint": .systemMint,
        "teal": .systemTeal, "cyan": .systemCyan, "blue": .systemBlue, "indigo": .systemIndigo, "purple": .systemPurple,
        "pink": .systemPink, "brown": .systemBrown, "gray": .systemGray, "clear": .clear,
        "alternatingRow": NSColor.alternatingContentBackgroundColors.last ?? .controlBackgroundColor,
      ]
      return known[name] ?? .labelColor
    }
    return NSColor(hex: value) ?? .labelColor
  }
}

/// A font in a theme. Family is "system", "system-mono", "system-rounded" or an installed family.
struct ThemeFont: Codable, Hashable {
  var family = "system"
  var size: Double = 13
  var weight = "regular"
  var monospacedDigits = false

  func nsFont(zoom: Double) -> NSFont {
    let points = CGFloat(size * zoom)
    let w = ThemeFont.weights[weight] ?? .regular
    var font: NSFont
    switch family {
    case "system": font = .systemFont(ofSize: points, weight: w)
    case "system-mono": font = .monospacedSystemFont(ofSize: points, weight: w)
    case "system-rounded":
      let base = NSFont.systemFont(ofSize: points, weight: w)
      font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: points) } ?? base
    default:
      font = NSFontManager.shared.font(withFamily: family, traits: [], weight: ThemeFont.managerWeight(w), size: points)
        ?? .systemFont(ofSize: points, weight: w)
    }
    if monospacedDigits {
      let descriptor = font.fontDescriptor.addingAttributes([
        .featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]],
      ])
      font = NSFont(descriptor: descriptor, size: points) ?? font
    }
    return font
  }

  func font(zoom: Double) -> Font { Font(nsFont(zoom: zoom)) }

  static let weights: [String: NSFont.Weight] = [
    "ultralight": .ultraLight, "thin": .thin, "light": .light, "regular": .regular, "medium": .medium,
    "semibold": .semibold, "bold": .bold, "heavy": .heavy, "black": .black,
  ]
  static let weightNames = ["ultralight", "thin", "light", "regular", "medium", "semibold", "bold", "heavy", "black"]
  private static func managerWeight(_ w: NSFont.Weight) -> Int {
    switch w {
    case .ultraLight: return 2
    case .thin: return 3
    case .light: return 4
    case .medium: return 6
    case .semibold: return 8
    case .bold: return 9
    case .heavy: return 10
    case .black: return 11
    default: return 5
    }
  }
}

/// One themable element, for the editor's list.
struct ThemeElement: Identifiable, Hashable {
  enum Kind { case color, font }
  var key: String  // The theme's color or font key; a color and a font can share it.
  var title: String
  var group: String
  var kind: Kind
  var id: String { kind == .font ? key + "#font" : key }
}

struct Theme: Codable, Equatable {
  var version = 1
  var name: String
  var base: String?  // A custom theme stores only what differs from its base.
  var colors: [String: ThemeColor] = [:]
  var fonts: [String: ThemeFont] = [:]

  func color(_ id: String) -> ThemeColor { colors[id] ?? Theme.standard.colors[id] ?? ThemeColor("system:label") }
  func font(_ id: String) -> ThemeFont { fonts[id] ?? Theme.standard.fonts[id] ?? ThemeFont() }

  /// The base's values with this theme's on top.
  func resolved(using themes: [String: Theme]) -> Theme {
    guard let baseName = base, let parent = themes[baseName], baseName != name else { return self }
    var merged = parent.resolved(using: themes)
    merged.name = name
    merged.base = base
    merged.colors.merge(colors) { _, new in new }
    merged.fonts.merge(fonts) { _, new in new }
    return merged
  }

  /// Only the values that differ from `base`, for saving a custom theme.
  func differences(from base: Theme) -> Theme {
    var out = Theme(name: name, base: base.name)
    for (id, value) in colors where base.colors[id] != value { out.colors[id] = value }
    for (id, value) in fonts where base.fonts[id] != value { out.fonts[id] = value }
    return out
  }

  static let elements: [ThemeElement] = {
    var out: [ThemeElement] = []
    func c(_ id: String, _ title: String, _ group: String) { out.append(ThemeElement(key: id, title: title, group: group, kind: .color)) }
    func f(_ id: String, _ title: String, _ group: String) { out.append(ThemeElement(key: id, title: title, group: group, kind: .font)) }
    f("listing.name", "Names", "Listing"); f("listing.size", "Sizes", "Listing"); f("listing.date", "Dates", "Listing")
    f("listing.meta", "Permissions and owner", "Listing")
    c("listing.background", "Background", "Listing"); c("listing.text", "Regular files", "Listing")
    c("listing.directory", "Folders", "Listing"); c("listing.executable", "Executables", "Listing")
    c("listing.symlink", "Symbolic links", "Listing"); c("listing.special", "Devices, pipes and sockets", "Listing")
    c("listing.error", "Unreadable items", "Listing"); c("listing.warning", "Warnings", "Listing")
    c("listing.size", "Size text", "Listing"); c("listing.size.large", "Sizes over 1 MB (bold over 50 MB)", "Listing")
    c("listing.size.huge", "Sizes over 1 GB (bold over 10 GB)", "Listing"); c("listing.date", "Date text", "Listing")
    c("listing.marked.text", "Selected text", "Listing"); c("listing.marked.background", "Selected rows", "Listing")
    c("listing.cursor", "Cursor (focused pane)", "Listing"); c("listing.cursor.inactive", "Cursor (other pane)", "Listing")
    c("listing.gauge", "Size bar", "Listing"); c("listing.gauge.cursor", "Size bar on the cursor", "Listing")
    c("listing.gauge.cursor.inactive", "Size bar on the cursor (other pane)", "Listing")
    f("pane.tabs", "Tabs", "Pane"); f("pane.path", "Path bar", "Pane"); f("pane.status", "Status line", "Pane")
    c("pane.tab.active", "Active tab", "Pane"); c("pane.tab.text", "Tab text", "Pane"); c("pane.tab.tutorial", "Tutorial tab", "Pane")
    c("pane.path", "Path text", "Pane"); c("pane.filter", "Filter text", "Pane"); c("pane.focus", "Focus ring", "Pane")
    c("pane.status", "Status text", "Pane")
    f("bottom.jobs", "Job bar", "Bottom"); f("bottom.errors", "Error lines", "Bottom")
    c("bottom.background", "Background", "Bottom"); c("bottom.progress", "Progress", "Bottom")
    c("bottom.pause", "Pause/Resume button", "Bottom"); c("bottom.cancel", "Cancel and Stop buttons", "Bottom")
    c("bottom.error", "Error text", "Bottom")
    f("sheet.body", "Dialog text", "Dialogs"); f("sheet.field", "Dialog fields", "Dialogs")
    f("palette.input", "Palette search", "Dialogs"); f("palette.row", "Palette rows", "Dialogs")
    c("palette.selection", "Palette selection", "Dialogs"); c("hud.background", "Confirmation background", "Dialogs")
    c("hud.text", "Confirmation text", "Dialogs")
    f("editor.terminal", "Font", "Editor"); c("editor.background", "Background", "Editor"); c("editor.text", "Text", "Editor")
    f("caption.title", "Caption title", "Explainers"); f("caption.subtitle", "Caption subtitle", "Explainers")
    f("badge", "Key badges", "Explainers")
    c("caption.background", "Caption card", "Explainers"); c("caption.title", "Caption title", "Explainers")
    c("caption.subtitle", "Caption subtitle", "Explainers"); c("explainer.highlight", "Highlight", "Explainers")
    c("explainer.pointer", "Pointer", "Explainers"); c("explainer.badge", "Key badge", "Explainers")
    c("explainer.badge.text", "Key badge text", "Explainers"); c("explainer.crash", "Crash stamp", "Explainers")
    c("explainer.spotlight", "Spotlight dim", "Explainers")
    return out
  }()

  /// The native theme: semantic system colors that follow the accent color and contrast settings.
  static let standard: Theme = {
    var t = Theme(name: "Default")
    t.colors = [
      "listing.background": ThemeColor("system:controlBackground"),
      "listing.text": ThemeColor("system:label"),
      "listing.directory": ThemeColor("#1F5FBF", "#7CB7FF"),
      "listing.executable": ThemeColor("#2E7D32", "#7FD68A"),
      "listing.symlink": ThemeColor("#7A3E9D", "#C792EA"),
      "listing.special": ThemeColor("#A0522D", "#E3A27A"),
      "listing.error": ThemeColor("system:red"),
      "listing.warning": ThemeColor("system:orange"),
      "listing.size": ThemeColor("system:secondaryLabel"),
      "listing.date": ThemeColor("system:secondaryLabel"),
      "listing.marked.text": ThemeColor("#9A5B00", "#FFD15C"),
      "listing.marked.background": ThemeColor("#FFE9A833", "#FFD15C29"),
      "listing.cursor": ThemeColor("system:selectedContentBackground"),
      "listing.cursor.inactive": ThemeColor("system:unemphasizedSelectedContentBackground"),
      "listing.gauge": ThemeColor("#0A84FF59", "#409CFF73"),
      "listing.gauge.cursor": ThemeColor("#FFFFFFB3", "#FFFFFFB3"),
      "listing.gauge.cursor.inactive": ThemeColor("#0A84FFB3", "#409CFFCC"),
      "listing.size.large": ThemeColor("#A66F00", "#FFD60A"),
      "listing.size.huge": ThemeColor("#D12F2F", "#FF6961"),
      "pane.tab.active": ThemeColor("system:accent"),
      "pane.tab.text": ThemeColor("system:label"),
      "pane.tab.tutorial": ThemeColor("system:purple"),
      "pane.path": ThemeColor("system:label"),
      "pane.filter": ThemeColor("system:orange"),
      "pane.focus": ThemeColor("system:accent"),
      "pane.status": ThemeColor("system:secondaryLabel"),
      "bottom.background": ThemeColor("system:windowBackground"),
      "bottom.progress": ThemeColor("system:accent"),
      "bottom.pause": ThemeColor("#B8860B"),
      "bottom.cancel": ThemeColor("#8B0000", "#B22222"),
      "bottom.error": ThemeColor("system:red"),
      "palette.selection": ThemeColor("system:selectedContentBackground"),
      "hud.background": ThemeColor("#1C1C1EE6", "#2C2C2EF2"),
      "hud.text": ThemeColor("#FFFFFF"),
      "editor.background": ThemeColor("#FFFFFF", "#1E1E1E"),
      "editor.text": ThemeColor("#1E1E1E", "#E6E6E6"),
      "caption.background": ThemeColor("#0E1116F2"),
      "caption.title": ThemeColor("#FFFFFF"),
      "caption.subtitle": ThemeColor("#C9D1D9"),
      "explainer.highlight": ThemeColor("#4C9AFF"),
      "explainer.pointer": ThemeColor("#FFFFFF"),
      "explainer.badge": ThemeColor("#1B2230E6"),
      "explainer.badge.text": ThemeColor("#FFFFFF"),
      "explainer.crash": ThemeColor("#FF3B30"),
      "explainer.spotlight": ThemeColor("#00000073"),
    ]
    t.fonts = [
      "listing.name": ThemeFont(family: "system", size: 13),
      "listing.size": ThemeFont(family: "system", size: 12, monospacedDigits: true),
      "listing.date": ThemeFont(family: "system", size: 12, monospacedDigits: true),
      "listing.meta": ThemeFont(family: "system-mono", size: 11),
      "pane.tabs": ThemeFont(family: "system", size: 12, weight: "medium"),
      "pane.path": ThemeFont(family: "system", size: 12, weight: "medium"),
      "pane.status": ThemeFont(family: "system", size: 11, monospacedDigits: true),
      "bottom.jobs": ThemeFont(family: "system", size: 12, monospacedDigits: true),
      "bottom.errors": ThemeFont(family: "system", size: 12),
      "sheet.body": ThemeFont(family: "system", size: 13),
      "sheet.field": ThemeFont(family: "system", size: 13),
      "palette.input": ThemeFont(family: "system", size: 20, weight: "light"),
      "palette.row": ThemeFont(family: "system", size: 13),
      "editor.terminal": ThemeFont(family: "system-mono", size: 13),
      "caption.title": ThemeFont(family: "system", size: 26, weight: "semibold"),
      "caption.subtitle": ThemeFont(family: "system", size: 16),
      "badge": ThemeFont(family: "system", size: 17, weight: "semibold"),
    ]
    return t
  }()

  /// The terminal interface's palette, for people who like the TUI look.
  static let commanderClassic: Theme = {
    var t = Theme(name: "Commander Classic", base: "Default")
    t.colors = [
      "listing.background": ThemeColor("#0A1A5C"),
      "listing.text": ThemeColor("#E8E8E8"),
      "listing.directory": ThemeColor("#FFFFFF"),
      "listing.executable": ThemeColor("#7CFC7C"),
      "listing.symlink": ThemeColor("#87D7FF"),
      "listing.special": ThemeColor("#FF87AF"),
      "listing.size": ThemeColor("#5FD7D7"),
      "listing.date": ThemeColor("#5FD7D7"),
      "listing.marked.text": ThemeColor("#FFFF00"),
      "listing.marked.background": ThemeColor("#FFFF0024"),
      "listing.cursor": ThemeColor("#00A0A0"),
      "listing.cursor.inactive": ThemeColor("#335577"),
      "listing.gauge": ThemeColor("#5FD7D780"),
      "listing.gauge.cursor": ThemeColor("#0A1A5CCC"),
      "listing.size.large": ThemeColor("#FFFF5F"),
      "listing.size.huge": ThemeColor("#FF5F5F"),
      "pane.filter": ThemeColor("#FFD700"),
      "bottom.pause": ThemeColor("#B8860B"),
      "bottom.cancel": ThemeColor("#8B0000"),
    ]
    t.fonts = [
      "listing.name": ThemeFont(family: "system-mono", size: 13),
      "listing.size": ThemeFont(family: "system-mono", size: 12),
      "listing.date": ThemeFont(family: "system-mono", size: 12),
    ]
    return t
  }()

  static let highContrast: Theme = {
    var t = Theme(name: "High Contrast", base: "Default")
    t.colors = [
      "listing.background": ThemeColor("#FFFFFF", "#000000"),
      "listing.text": ThemeColor("#000000", "#FFFFFF"),
      "listing.directory": ThemeColor("#0033AA", "#99CCFF"),
      "listing.size": ThemeColor("#000000", "#FFFFFF"),
      "listing.date": ThemeColor("#000000", "#FFFFFF"),
      "listing.marked.text": ThemeColor("#7A3D00", "#FFE066"),
      "listing.marked.background": ThemeColor("#FFD24D66", "#FFE06640"),
      "pane.status": ThemeColor("#000000", "#FFFFFF"),
    ]
    t.fonts = ["listing.name": ThemeFont(family: "system", size: 14, weight: "medium")]
    return t
  }()

  static let builtIns: [Theme] = [standard, commanderClassic, highContrast]
}

extension NSColor {
  convenience init?(hex: String) {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
    let r, g, b, a: CGFloat
    if s.count == 6 {
      r = CGFloat((value >> 16) & 0xFF) / 255; g = CGFloat((value >> 8) & 0xFF) / 255; b = CGFloat(value & 0xFF) / 255; a = 1
    } else {
      r = CGFloat((value >> 24) & 0xFF) / 255; g = CGFloat((value >> 16) & 0xFF) / 255
      b = CGFloat((value >> 8) & 0xFF) / 255; a = CGFloat(value & 0xFF) / 255
    }
    self.init(srgbRed: r, green: g, blue: b, alpha: a)
  }

  var hexString: String {
    guard let c = usingColorSpace(.sRGB) else { return "#000000" }
    let r = Int(round(c.redComponent * 255)), g = Int(round(c.greenComponent * 255)), b = Int(round(c.blueComponent * 255))
    let a = Int(round(c.alphaComponent * 255))
    return a == 255 ? String(format: "#%02X%02X%02X", r, g, b) : String(format: "#%02X%02X%02X%02X", r, g, b, a)
  }
}
