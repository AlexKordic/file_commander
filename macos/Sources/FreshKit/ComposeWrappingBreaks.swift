import Foundation
import CoreText

/// Reuse native Unicode break opportunities in long physical paragraphs.
/// Core Text still supplies every width, glyph cluster and shaped line. The
/// threshold selects an optimization; it never limits content or pane width.
final class ComposeWrappingBreaks {
  private struct Unit {
    let end, trimmed: Int
    let complex: Bool
  }
  private struct Paragraph {
    let range: NSRange
    let units: [Unit]
    let manyObjects: Bool
  }
  private struct Advances {
    let indices: [Int], offsets: [CGFloat]

    init?(_ typesetter: CTTypesetter, range: NSRange) {
      let line = CTTypesetterCreateLine(typesetter, CFRange(location: range.location, length: range.length))
      var indices: [Int] = [], offsets: [CGFloat] = []
      for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let status = CTRunGetStatus(run)
        guard !status.contains(.rightToLeft), !status.contains(.nonMonotonic), !status.contains(.hasNonIdentityMatrix) else { return nil }
        let count = CTRunGetGlyphCount(run)
        var positions = [CGPoint](repeating: .zero, count: count)
        var sources = [CFIndex](repeating: 0, count: count)
        CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
        CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &sources)
        for i in 0..<count {
          let source = sources[i], x = positions[i].x
          guard range.location <= source, source < NSMaxRange(range), x.isFinite else { return nil }
          if source == indices.last { continue }
          guard source > (indices.last ?? -1), x >= (offsets.last ?? -CGFloat.infinity) else { return nil }
          indices.append(source); offsets.append(x)
        }
      }
      let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
      guard indices.first == range.location, width.isFinite, width >= (offsets.last ?? 0) else { return nil }
      indices.append(NSMaxRange(range)); offsets.append(width)
      self.indices = indices; self.offsets = offsets
    }

    func clusterBreak(from: Int, width: Double) -> Int? {
      var low = 0, high = indices.count
      while low < high {
        let mid = low + (high - low) / 2
        if indices[mid] < from { low = mid + 1 } else { high = mid }
      }
      guard low < indices.count, indices[low] == from else { return nil }
      let origin = low, limit = offsets[low] + CGFloat(width)
      high = offsets.count
      while low < high {
        let mid = low + (high - low) / 2
        if offsets[mid] <= limit { low = mid + 1 } else { high = mid }
      }
      return indices[max(origin, low - 1)] - from
    }
  }
  private let string: NSString
  private let paragraphs: [Paragraph]
  private var measuredTypesetter: CTTypesetter?
  private var measuredParagraph: Int?
  // Only the most recently queried paragraph is retained. These advances are
  // temporary construction data, not another document-wide layout cache.
  private var advances: Advances?
  private(set) var measuredBreakCount = 0
  static let minimumLength = 4096

  init?(_ string: NSString) {
    guard string.length >= Self.minimumLength else { return nil }
    var paragraphs: [Paragraph] = [], from = 0
    var tokenizer: CFStringTokenizer?
    let whitespace = CharacterSet.whitespacesAndNewlines
    while from < string.length {
      let newline = string.rangeOfCharacter(from: .newlines,
        range: NSRange(location: from, length: string.length - from))
      var end = newline.location == NSNotFound ? string.length : NSMaxRange(newline)
      if newline.location != NSNotFound, string.character(at: newline.location) == 13,
         end < string.length, string.character(at: end) == 10 { end += 1 }
      let range = NSRange(location: from, length: end - from)
      defer { from = end }
      guard range.length >= Self.minimumLength else { continue }
      // Preserve Core Text's handling of tabs, nonbreaking whitespace and
      // explicit formatting controls. ZWJ remains available for emoji; a
      // forced break inside an unbroken word also uses Core Text below.
      var objects = 0
      let eligible = !string.substring(with: range).unicodeScalars.contains { scalar in
        if scalar.value == 0xfffc { objects += 1 }
        if [0x20, 0x0a, 0x0d, 0x200d].contains(scalar.value) { return false }
        return [.control, .format, .spaceSeparator, .lineSeparator, .paragraphSeparator]
          .contains(scalar.properties.generalCategory)
      }
      guard eligible else { continue }
      if tokenizer == nil {
        tokenizer = CFStringTokenizerCreate(nil, "" as CFString,
          CFRange(location: 0, length: 0), kCFStringTokenizerUnitLineBreak, nil)
      }
      guard let tokenizer else { return nil }
      CFStringTokenizerSetString(tokenizer, string as CFString,
        CFRange(location: range.location, length: range.length))
      var units: [Unit] = []
      while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
        let token = CFStringTokenizerGetCurrentTokenRange(tokenizer)
        let unit = NSRange(location: token.location, length: token.length)
        let first = string.rangeOfCharacter(from: whitespace.inverted, range: unit)
        let last = string.rangeOfCharacter(from: whitespace.inverted, options: .backwards, range: unit)
        let complex = first.location != NSNotFound && string.rangeOfCharacter(from: whitespace,
          range: NSRange(location: first.location, length: NSMaxRange(last) - first.location)).location != NSNotFound
        units.append(Unit(end: NSMaxRange(unit),
          trimmed: last.location == NSNotFound ? unit.location : NSMaxRange(last), complex: complex))
      }
      guard units.last?.end == end else { continue }
      paragraphs.append(Paragraph(range: range, units: units, manyObjects: objects >= 32))
    }
    guard !paragraphs.isEmpty else { return nil }
    self.string = string; self.paragraphs = paragraphs
  }

  func suggest(_ typesetter: CTTypesetter, from: Int, width: Double) -> Int {
    func native() -> Int { CTTypesetterSuggestLineBreak(typesetter, from, width) }
    let index = first(paragraphs) { NSMaxRange($0.range) > from }
    guard index < paragraphs.count, paragraphs[index].range.location <= from else { return native() }
    let paragraph = paragraphs[index]
    // Core Text's cluster suggestion clones the remaining delegate runs on
    // each line of a dense image paragraph. Measure that complete paragraph
    // once, preserving shaping context, and reuse its monotonic LTR advances.
    // Bidi, reordered glyphs and transformed runs keep the native path.
    if paragraph.manyObjects && (measuredParagraph != index || measuredTypesetter !== typesetter) {
      measuredTypesetter = typesetter; measuredParagraph = index
      advances = Advances(typesetter, range: paragraph.range)
    }
    let measured = paragraph.manyObjects ? advances?.clusterBreak(from: from, width: width) : nil
    if measured != nil { measuredBreakCount += 1 }
    let count = measured ?? CTTypesetterSuggestClusterBreak(typesetter, from, width)
    guard count > string.rangeOfComposedCharacterSequence(at: from).length else { return native() }
    let fit = from + count
    if NSMaxRange(paragraph.range) <= fit { return NSMaxRange(paragraph.range) - from }
    let next = first(paragraph.units) { $0.end > fit }
    if next < paragraph.units.count {
      let unit = paragraph.units[next]
      // Some native units contain an interior space before punctuation.
      // Core Text can select a contextual break inside them. Do not invent
      // a new punctuation policy or split an unbreakable word ourselves.
      guard !unit.complex else { return native() }
      if unit.trimmed <= fit { return unit.end - from }
    }
    if next > 0, paragraph.units[next - 1].end > from {
      return paragraph.units[next - 1].end - from
    }
    return native()
  }

  private func first<T>(_ values: [T], matching predicate: (T) -> Bool) -> Int {
    var low = 0, high = values.count
    while low < high {
      let mid = low + (high - low) / 2
      if predicate(values[mid]) { high = mid } else { low = mid + 1 }
    }
    return low
  }
}
