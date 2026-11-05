import AppKit
import CoreText
import FreshKit

/// Native presentation preferences, saved beside the other app settings.
struct ComposePreferences: Codable, Equatable {
  var bodyFamily = "system"
  var monospaceFamily = "system-mono"
  var bodySize = 16.0
  var headingScales = [1.8, 1.5, 1.25, 1.15, 1.05, 1.0]
  var lineSpacing = 3.0
  var paragraphSpacing = 6.0
  var indent = 24.0
  var pageWidth = 760.0

  init() {}

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = Self()
    bodyFamily = try c.decodeIfPresent(String.self, forKey: .bodyFamily) ?? d.bodyFamily
    monospaceFamily = try c.decodeIfPresent(String.self, forKey: .monospaceFamily) ?? d.monospaceFamily
    bodySize = try c.decodeIfPresent(Double.self, forKey: .bodySize) ?? d.bodySize
    headingScales = try c.decodeIfPresent([Double].self, forKey: .headingScales) ?? d.headingScales
    lineSpacing = try c.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? d.lineSpacing
    paragraphSpacing = try c.decodeIfPresent(Double.self, forKey: .paragraphSpacing) ?? d.paragraphSpacing
    indent = try c.decodeIfPresent(Double.self, forKey: .indent) ?? d.indent
    pageWidth = try c.decodeIfPresent(Double.self, forKey: .pageWidth) ?? d.pageWidth
    self = normalized
  }

  var normalized: Self {
    var value = self
    let d = Self()
    func clamp(_ number: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
      number.isFinite ? min(range.upperBound, max(range.lowerBound, number)) : fallback
    }
    func family(_ name: String, _ fallback: String) -> String {
      let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
      return name.isEmpty || name.count > 200 ? fallback : name
    }
    value.bodyFamily = family(bodyFamily, d.bodyFamily)
    value.monospaceFamily = family(monospaceFamily, d.monospaceFamily)
    value.bodySize = clamp(bodySize, 8...72, d.bodySize)
    value.headingScales = headingScales.count == 6 ? zip(headingScales, d.headingScales).map { clamp($0, 0.75...3, $1) } : d.headingScales
    value.lineSpacing = clamp(lineSpacing, 0...24, d.lineSpacing)
    value.paragraphSpacing = clamp(paragraphSpacing, 0...48, d.paragraphSpacing)
    value.indent = clamp(indent, 8...64, d.indent)
    value.pageWidth = clamp(pageWidth, 320...1600, d.pageWidth)
    return value
  }

  func typography(zoom: Double) -> ComposeTypography {
    let value = normalized, scale = Self.scale(zoom)
    return .init(headingScales: value.headingScales.map { CGFloat($0) },
      lineSpacing: value.lineSpacing * scale, paragraphSpacing: value.paragraphSpacing * scale, indent: value.indent * scale)
  }

  @MainActor
  func fonts(zoom: Double) -> (body: NSFont, monospace: NSFont) {
    let value = normalized, scale = Self.scale(zoom)
    let body = ThemeFont(family: value.bodyFamily, size: value.bodySize).nsFont(zoom: scale)
    let mono = ThemeFont(family: value.monospaceFamily, size: value.bodySize).nsFont(zoom: scale)
    return (body, CTFontGetSymbolicTraits(mono as CTFont).contains(.traitMonoSpace) ? mono
      : .monospacedSystemFont(ofSize: value.bodySize * scale, weight: .regular))
  }

  static func scale(_ zoom: Double) -> Double { zoom.isFinite ? min(3, max(0.5, zoom)) : 1 }

  @MainActor
  static let monospacedFamilies = NSFontManager.shared.availableFontFamilies.filter { family in
    guard let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 16) else { return false }
    return CTFontGetSymbolicTraits(font as CTFont).contains(.traitMonoSpace)
  }
}
