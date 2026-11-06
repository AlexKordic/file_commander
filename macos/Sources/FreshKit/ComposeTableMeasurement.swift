import Foundation
import CoreText
import CoreGraphics

/// Complete parser-owned font inputs, independent of the displayed row subset.
/// Relative UTF-8 styles are validated before native font measurement.
public final class ComposeTableMeasurement {
  public let id: UInt64
  let wire: WireComposeTableMeasurement

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
    var constraints = ComposeColumnConstraints(count: wire.columns.count, font: body, available: available)
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
          var traits: CTFontSymbolicTraits = []
          if span.flags & 1 != 0 { traits.insert(.traitBold) }
          if span.flags & 2 != 0 { traits.insert(.traitItalic) }
          let size = CTFontGetSize(body)
          let base = CTFontCreateCopyWithAttributes(span.code ? monospace : body, size, nil, nil)
          let font = CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, [.traitBold, .traitItalic]) ?? base
          text.addAttribute(NSAttributedString.Key(kCTFontAttributeName as String), value: font,
            range: NSRange(location: start, length: length))
        }
        constraints.include(text, range: NSRange(location: 0, length: text.length), column: column,
          preferred: !sample.minimumOnly, imageWidth: sample.image ? available * 0.35 : 0)
      }
    }
    return constraints.widths
  }
}

struct ComposeColumnConstraints {
  var minimum, natural: [CGFloat]
  let available, emptyWidth: CGFloat
  init(count: Int, font: CTFont, available: CGFloat) {
    self.available = available
    let blank = CTLineCreateWithAttributedString(NSAttributedString(string: " ",
      attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
    emptyWidth = max(1, CGFloat(CTLineGetTypographicBounds(blank, nil, nil, nil)))
    minimum = Array(repeating: emptyWidth, count: count); natural = minimum
  }
  mutating func include(_ text: NSAttributedString, range: NSRange, column: Int, preferred: Bool, imageWidth: CGFloat = 0, typesetter: CTTypesetter? = nil) {
    if preferred { natural[column] = max(natural[column], min(available, imageWidth)) }
    guard range.length > 0 else { return }
    let typesetter = typesetter ?? CTTypesetterCreateWithAttributedString(text)
    let line = CTTypesetterCreateLine(typesetter, CFRange(location: range.location, length: range.length))
    let string = text.string as NSString
    var at = range.location
    while at < NSMaxRange(range) {
      let next = min(NSMaxRange(range), NSMaxRange(string.rangeOfComposedCharacterSequence(at: at)))
      let a = CTLineGetOffsetForStringIndex(line, at, nil), b = CTLineGetOffsetForStringIndex(line, next, nil)
      minimum[column] = max(minimum[column], abs(b - a)); at = next
    }
    guard preferred else { return }
    natural[column] = max(natural[column], min(available, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))))
    let share = max(emptyWidth, available / CGFloat(natural.count) - ComposeMeasuredTable.padding * 2)
    var wordMinimum = minimum[column]
    if wordMinimum < share { string.enumerateSubstrings(in: range, options: [.byWords, .substringNotRequired]) { _, word, _, stop in
      let line = CTTypesetterCreateLine(typesetter, CFRange(location: word.location, length: word.length))
      wordMinimum = max(wordMinimum, min(share, ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))) + 0.5))
      if wordMinimum >= share { stop.pointee = true }
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
