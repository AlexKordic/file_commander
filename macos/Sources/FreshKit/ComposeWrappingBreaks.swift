import Foundation
import CoreText

/// Reuse native Unicode break opportunities in long physical paragraphs.
/// Core Text still supplies every width, glyph cluster and shaped line. The
/// threshold selects an optimization; it never limits content or pane width.
struct ComposeWrappingBreaks {
  private struct Unit {
    let end, trimmed: Int
    let complex: Bool
  }
  private struct Paragraph {
    let range: NSRange
    let units: [Unit]
  }
  private let string: NSString
  private let paragraphs: [Paragraph]
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
      let eligible = !string.substring(with: range).unicodeScalars.contains { scalar in
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
      paragraphs.append(Paragraph(range: range, units: units))
    }
    guard !paragraphs.isEmpty else { return nil }
    self.string = string; self.paragraphs = paragraphs
  }

  func suggest(_ typesetter: CTTypesetter, from: Int, width: Double) -> Int {
    func native() -> Int { CTTypesetterSuggestLineBreak(typesetter, from, width) }
    let index = first(paragraphs) { NSMaxRange($0.range) > from }
    guard index < paragraphs.count, paragraphs[index].range.location <= from else { return native() }
    let paragraph = paragraphs[index]
    let count = CTTypesetterSuggestClusterBreak(typesetter, from, width)
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
