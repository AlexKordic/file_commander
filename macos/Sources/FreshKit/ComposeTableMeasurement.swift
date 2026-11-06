import Foundation
import CoreText
import CoreGraphics

/// Complete parser-owned font inputs, independent of the displayed row subset.
/// Relative UTF-8 styles are validated before native font measurement.
public final class ComposeTableMeasurement {
  public let id: UInt64
  let wire: WireComposeTableMeasurement
  private struct FontMetrics {
    let body, monospace: CTFont
    let minimum, glyphMinimum, natural: [CGFloat]
    let emptyWidth: CGFloat
    let images: [Bool]
  }
  private let metricsLock = NSLock()
  /// One immutable aggregate per measurement, with no shaped strings/lines
  /// retained. A new font environment replaces this bounded cache entry.
  private var cachedMetrics: FontMetrics?

  init?(id: UInt64, wire: WireComposeTableMeasurement, columns: Int) {
    guard id != 0, wire.columns.count == columns else { return nil }
    for column in wire.columns {
      for sample in column.samples {
        let bytes = Array(sample.text.utf8)
        var end = 0
        guard !(sample.minimumOnly && sample.image) else { return nil }
        for span in sample.spans {
          guard let a = Int(exactly: span.start), let b = Int(exactly: span.end),
                a >= end, a < b, b <= bytes.count, span.flags <= 3,
                [a, b].allSatisfy({ $0 == bytes.count || bytes[$0] & 0xc0 != 0x80 }) else { return nil }
          end = b
        }
      }
    }
    self.id = id; self.wire = wire
  }

  func widths(body: CTFont, monospace: CTFont, available: CGFloat) -> [CGFloat] {
    let metrics = fontMetrics(body: body, monospace: monospace)
    guard !metrics.minimum.isEmpty else { return [] }
    var constraints = ComposeColumnConstraints(count: metrics.minimum.count, emptyWidth: metrics.emptyWidth, available: available)
    let share = max(metrics.emptyWidth, available / CGFloat(metrics.minimum.count) - ComposeMeasuredTable.padding * 2)
    for column in metrics.minimum.indices {
      constraints.minimum[column] = max(metrics.glyphMinimum[column], min(share, metrics.minimum[column]))
      constraints.natural[column] = max(metrics.emptyWidth, max(min(available, metrics.natural[column]),
        metrics.images[column] ? available * 0.35 : 0))
    }
    return constraints.widths
  }

  private func fontMetrics(body: CTFont, monospace: CTFont) -> FontMetrics {
    metricsLock.lock()
    if let cachedMetrics, CFEqual(cachedMetrics.body, body), CFEqual(cachedMetrics.monospace, monospace) {
      metricsLock.unlock()
      return cachedMetrics
    }
    metricsLock.unlock()
    // Collect uncapped native preferences once. Resolving a narrower pane
    // caps only the wrapping preference, never a complete shaped grapheme.
    var constraints = ComposeColumnConstraints(count: wire.columns.count, font: body, available: .greatestFiniteMagnitude)
    var images = Array(repeating: false, count: wire.columns.count)
    // Complete table inputs can contain thousands of distinct samples with
    // the same style. Fonts depend on this call's body/code faces and size,
    // not on the sample text or column; retain each variant for this pass.
    struct FontKey: Hashable { let code: Bool; let flags: UInt32 }
    var fonts: [FontKey: CTFont] = [:]
    for (column, value) in wire.columns.enumerated() {
      for sample in value.samples {
        let text = NSMutableAttributedString(string: sample.text,
          attributes: [NSAttributedString.Key(kCTFontAttributeName as String): body])
        let needed = Set(sample.spans.flatMap { [Int($0.start), Int($0.end)] })
        var offsets: [Int: Int] = [0: 0], byte = 0, unit = 0
        if !needed.isEmpty {
          for scalar in sample.text.unicodeScalars {
            byte += scalar.utf8.count; unit += scalar.utf16.count
            if needed.contains(byte) { offsets[byte] = unit }
          }
        }
        for span in sample.spans {
          let start = offsets[Int(span.start)]!, length = offsets[Int(span.end)]! - start
          let key = FontKey(code: span.code, flags: span.flags)
          let font: CTFont
          if let cached = fonts[key] { font = cached }
          else {
            var traits: CTFontSymbolicTraits = []
            if span.flags & 1 != 0 { traits.insert(.traitBold) }
            if span.flags & 2 != 0 { traits.insert(.traitItalic) }
            let size = CTFontGetSize(body)
            let base = CTFontCreateCopyWithAttributes(span.code ? monospace : body, size, nil, nil)
            font = CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, [.traitBold, .traitItalic]) ?? base
            fonts[key] = font
          }
          text.addAttribute(NSAttributedString.Key(kCTFontAttributeName as String), value: font,
            range: NSRange(location: start, length: length))
        }
        constraints.include(text, range: NSRange(location: 0, length: text.length), column: column,
          preferred: !sample.minimumOnly)
        images[column] = images[column] || sample.image
      }
    }
    let measured = FontMetrics(body: body, monospace: monospace, minimum: constraints.minimum,
      glyphMinimum: constraints.glyphMinimum, natural: constraints.natural, emptyWidth: constraints.emptyWidth, images: images)
    metricsLock.lock()
    cachedMetrics = measured
    metricsLock.unlock()
    return measured
  }
}

struct ComposeColumnConstraints {
  var minimum, glyphMinimum, natural: [CGFloat]
  let available, emptyWidth: CGFloat
  private lazy var breaks = ComposeLineBreaks()
  init(count: Int, font: CTFont, available: CGFloat) {
    let blank = CTLineCreateWithAttributedString(NSAttributedString(string: " ",
      attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
    self.init(count: count, emptyWidth: max(1, CGFloat(CTLineGetTypographicBounds(blank, nil, nil, nil))), available: available)
  }
  init(count: Int, emptyWidth: CGFloat, available: CGFloat) {
    self.available = available; self.emptyWidth = emptyWidth
    minimum = Array(repeating: emptyWidth, count: count); natural = minimum; glyphMinimum = minimum
  }
  mutating func include(_ text: NSAttributedString, range: NSRange, column: Int, preferred: Bool, imageWidth: CGFloat = 0, typesetter: CTTypesetter? = nil) {
    if preferred { natural[column] = max(natural[column], min(available, imageWidth)) }
    guard range.length > 0 else { return }
    let typesetter = typesetter ?? CTTypesetterCreateWithAttributedString(text)
    let line = CTTypesetterCreateLine(typesetter, CFRange(location: range.location, length: range.length))
    let string = text.string as NSString
    // A point query enumerates the shaped line internally. Asking at every
    // cluster boundary is quadratic for long source/URI samples. Collect both
    // logical edges once, then measure the extent of each complete cluster.
    // Primary insertion positions at bidi boundaries can span an entire RTL
    // run; those jumps are not the width of the adjacent source character.
    var edges = Array(repeating: SIMD2<Double>(.infinity, -.infinity), count: range.length)
    CTLineEnumerateCaretOffsets(line) { offset, index, _, _ in
      let at = index - range.location
      guard at >= 0, at < edges.count else { return }
      edges[at].x = min(edges[at].x, offset); edges[at].y = max(edges[at].y, offset)
    }
    var at = range.location, glyph = glyphMinimum[column]
    while at < NSMaxRange(range) {
      let next = min(NSMaxRange(range), NSMaxRange(string.rangeOfComposedCharacterSequence(at: at)))
      var low = Double.infinity, high = -Double.infinity
      for index in (at - range.location)..<(next - range.location) {
        low = min(low, edges[index].x); high = max(high, edges[index].y)
      }
      if low.isFinite, high.isFinite { glyph = max(glyph, CGFloat(high - low)) }
      at = next
    }
    glyphMinimum[column] = glyph
    minimum[column] = max(minimum[column], glyph)
    guard preferred else { return }
    natural[column] = max(natural[column], min(available, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))))
    let share = max(emptyWidth, available / CGFloat(natural.count) - ComposeMeasuredTable.padding * 2)
    var wordMinimum = minimum[column]
    if wordMinimum < share { breaks.forEach(in: string, range: range) { word in
      let line = CTTypesetterCreateLine(typesetter, CFRange(location: word.location, length: word.length))
      wordMinimum = max(wordMinimum, min(share, ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))) + 0.5))
      return wordMinimum < share
    } }
    minimum[column] = wordMinimum
  }
  var widths: [CGFloat] {
    let minimum = minimum.map { $0 + ComposeMeasuredTable.padding * 2 }
    let natural = zip(natural, minimum).map { max($0 + ComposeMeasuredTable.padding * 2, $1) }
    let floor = minimum.reduce(0, +), desired = natural.reduce(0, +)
    if available >= desired { return natural.map { $0 + (available - desired) / CGFloat(natural.count) } }
    if available > floor { return zip(minimum, natural).map { $0 + ($1 - $0) * (available - floor) / (desired - floor) } }
    return minimum
  }
}

extension WireComposePane {
  /// A delivered pane retains its complete measurements when a later source
  /// window refers to their ID. No unrelated document or table supplies data.
  public func retainingTableMeasurements(from previous: WireComposePane?) -> WireComposePane {
    guard let previous, previous.assetDocument == assetDocument, previous.assetAuthority == assetAuthority else { return self }
    var result = self
    for index in result.tables.indices where result.tables[index].measurementID != 0 && !result.tables[index].hasMeasurement {
      let table = result.tables[index]
      if let old = previous.tables.first(where: { $0.start == table.start && $0.end == table.end
        && $0.measurementID == table.measurementID && $0.hasMeasurement }) {
        result.tables[index].measurement = old.measurement
      }
    }
    return result
  }
}
