import Foundation
import CoreText
import CoreGraphics

/// Fresh's source-preserving Compose projection. Coordinates in this contract
/// are UTF-8 bytes. Core Text's UTF-16 indices stay inside ComposeTextLayout.
public struct ComposeProjection {
  public enum Affinity { case upstream, downstream }
  public enum Kind { case copy, hidden, replacement }

  public struct Segment {
    public var source: Range<Int>
    public var display: Range<Int>
    public var kind: Kind

    public init(source: Range<Int>, display: Range<Int>, kind: Kind) {
      self.source = source
      self.display = display
      self.kind = kind
    }
  }

  public let source: Range<Int>
  public let text: String
  public let segments: [Segment]
  private let boundaries: Set<Int>

  /// Refuse incomplete or ambiguous maps before they can address the buffer.
  /// The server supplies the original source; this object never serializes it.
  public init?(source: Range<Int>, text: String, segments: [Segment]) {
    guard source.lowerBound >= 0 else { return nil }
    var boundaries: Set<Int> = [0]
    var byte = 0
    for scalar in text.unicodeScalars {
      byte += scalar.utf8.count
      boundaries.insert(byte)
    }
    var sourceEnd = source.lowerBound
    var displayEnd = 0
    for segment in segments {
      guard segment.source.lowerBound == sourceEnd, !segment.source.isEmpty,
            segment.source.upperBound <= source.upperBound,
            segment.display.lowerBound == displayEnd,
            boundaries.contains(segment.display.lowerBound),
            boundaries.contains(segment.display.upperBound) else { return nil }
      switch segment.kind {
      case .copy:
        guard segment.source.count == segment.display.count else { return nil }
      case .hidden:
        guard segment.display.isEmpty else { return nil }
      case .replacement:
        guard !segment.display.isEmpty else { return nil }
      }
      sourceEnd = segment.source.upperBound
      displayEnd = segment.display.upperBound
    }
    guard sourceEnd == source.upperBound, displayEnd == byte else { return nil }
    self.source = source
    self.text = text
    self.segments = segments
    self.boundaries = boundaries
  }

  public func sourcePosition(at display: Int, affinity: Affinity = .downstream) -> Int? {
    guard boundaries.contains(display) else { return nil }
    if segments.isEmpty { return display == 0 ? source.lowerBound : nil }
    let positions = segments.compactMap { segment -> Int? in
      guard display >= segment.display.lowerBound, display <= segment.display.upperBound else { return nil }
      switch segment.kind {
      case .copy: return segment.source.lowerBound + display - segment.display.lowerBound
      default:
        if !segment.display.isEmpty {
          if display == segment.display.lowerBound { return segment.source.lowerBound }
          if display == segment.display.upperBound { return segment.source.upperBound }
        }
        return affinity == .upstream ? segment.source.lowerBound : segment.source.upperBound
      }
    }
    return affinity == .upstream ? positions.min() : positions.max()
  }

  public func displayPosition(for source: Int, affinity: Affinity = .downstream) -> Int? {
    guard source >= self.source.lowerBound, source <= self.source.upperBound else { return nil }
    if segments.isEmpty { return 0 }
    let positions = segments.compactMap { segment -> Int? in
      guard source >= segment.source.lowerBound, source <= segment.source.upperBound else { return nil }
      let display: Int
      switch segment.kind {
      case .copy: display = segment.display.lowerBound + source - segment.source.lowerBound
      default:
        if source == segment.source.lowerBound { display = segment.display.lowerBound }
        else if source == segment.source.upperBound { display = segment.display.upperBound }
        else { display = affinity == .upstream ? segment.display.lowerBound : segment.display.upperBound }
      }
      return boundaries.contains(display) ? display : nil
    }
    return affinity == .upstream ? positions.min() : positions.max()
  }
}

/// Measured Compose text with one geometry shared by painting and hit testing.
/// Fresh owns editing and undo; this is an immutable presentation of one block.
public final class ComposeTextLayout {
  public struct FontRun {
    public var display: Range<Int>
    public var font: CTFont

    public init(display: Range<Int>, font: CTFont) {
      self.display = display
      self.font = font
    }
  }

  public struct Fragment {
    public let line: CTLine
    /// The exact Core Text range, in UTF-16, including a consumed line ending.
    public let range: NSRange
    public let rect: CGRect
    /// Baseline measured down from the block's top.
    public let baseline: CGFloat
    /// A caret may reach this index, but not enter a line ending's interior.
    public let contentEnd: Int
  }

  public let projection: ComposeProjection
  public let fragments: [Fragment]
  public let size: CGSize
  private let utf16ToByte: [Int: Int]
  private let byteToUTF16: [Int: Int]
  private let string: NSString

  /// Width and vertical geometry are in points. No rounding to terminal cells
  /// takes place. Invalid font ranges fail instead of quietly mis-styling text.
  public init?(projection: ComposeProjection, font: CTFont, width: CGFloat,
               lineSpacing: CGFloat = 3, fonts: [FontRun] = []) {
    guard width.isFinite, width > 0, lineSpacing.isFinite, lineSpacing >= 0 else { return nil }
    let string = projection.text as NSString
    var utf16ToByte = [0: 0]
    var byteToUTF16 = [0: 0]
    var byte = 0, unit = 0
    for scalar in projection.text.unicodeScalars {
      byte += scalar.utf8.count
      unit += scalar.utf16.count
      utf16ToByte[unit] = byte
      byteToUTF16[byte] = unit
    }
    let attributed = NSMutableAttributedString(string: projection.text,
      attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
    for run in fonts {
      guard let start = byteToUTF16[run.display.lowerBound], let end = byteToUTF16[run.display.upperBound] else { return nil }
      attributed.addAttribute(NSAttributedString.Key(kCTFontAttributeName as String), value: run.font,
                              range: NSRange(location: start, length: end - start))
    }
    let typesetter = CTTypesetterCreateWithAttributedString(attributed)
    var lines: [Fragment] = []
    var from = 0
    var top: CGFloat = 0
    let baseHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
    func append(_ range: NSRange) {
      let line = CTTypesetterCreateLine(typesetter, CFRange(location: range.location, length: range.length))
      var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
      CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
      if range.length == 0 {
        ascent = CTFontGetAscent(font)
        descent = CTFontGetDescent(font)
        leading = CTFontGetLeading(font)
      }
      let height = max(baseHeight, ascent + descent + leading) + lineSpacing
      var contentEnd = range.location + range.length
      while contentEnd > range.location {
        let ch = string.character(at: contentEnd - 1)
        guard ch == 10 || ch == 13 else { break }
        contentEnd -= 1
      }
      lines.append(Fragment(line: line, range: range,
        rect: CGRect(x: 0, y: top, width: width, height: height),
        baseline: top + ascent, contentEnd: contentEnd))
      top += height
    }
    while from < string.length {
      let suggested = CTTypesetterSuggestLineBreak(typesetter, from, Double(width))
      var count = suggested > 0 ? suggested : string.rangeOfComposedCharacterSequence(at: from).length
      guard count > 0, count <= string.length - from else { return nil }
      // A viewport narrower than a single composed character must overflow
      // that character intact instead of splitting an emoji/combining cluster.
      if from + count < string.length {
        let cluster = string.rangeOfComposedCharacterSequence(at: from + count)
        if cluster.location < from + count { count = NSMaxRange(cluster) - from }
      }
      append(NSRange(location: from, length: count))
      from += count
    }
    if string.length == 0 || string.character(at: string.length - 1) == 10 || string.character(at: string.length - 1) == 13 {
      append(NSRange(location: string.length, length: 0))
    }
    self.projection = projection
    self.fragments = lines
    self.size = CGSize(width: width, height: top)
    self.utf16ToByte = utf16ToByte
    self.byteToUTF16 = byteToUTF16
    self.string = string
  }

  /// A hit returns a source-byte caret, snapping to a complete grapheme. It
  /// never returns the middle of a surrogate pair, CRLF, or composed character.
  public func sourcePosition(at point: CGPoint, affinity: ComposeProjection.Affinity = .downstream) -> Int? {
    guard point.x.isFinite, point.y.isFinite, let first = fragments.first else { return nil }
    let fragment = fragments.first(where: { point.y < $0.rect.maxY }) ?? fragments.last ?? first
    let raw = CTLineGetStringIndexForPosition(fragment.line, CGPoint(x: point.x, y: 0))
    let index = min(fragment.contentEnd, max(fragment.range.location, raw == kCFNotFound ? fragment.contentEnd : raw))
    var boundary = index
    if index < string.length {
      let grapheme = string.rangeOfComposedCharacterSequence(at: index)
      if index != grapheme.location {
        let left = CTLineGetOffsetForStringIndex(fragment.line, grapheme.location, nil)
        let right = CTLineGetOffsetForStringIndex(fragment.line, NSMaxRange(grapheme), nil)
        boundary = abs(point.x - left) <= abs(point.x - right) ? grapheme.location : NSMaxRange(grapheme)
      }
    }
    guard let byte = utf16ToByte[boundary] else { return nil }
    return projection.sourcePosition(at: byte, affinity: affinity)
  }

  /// Caret geometry from the same shaped lines that supply hit testing. The
  /// affinity selects the visible side of a soft-wrap boundary.
  public func caret(for source: Int, affinity: ComposeProjection.Affinity = .downstream) -> CGRect? {
    guard let byte = projection.displayPosition(for: source, affinity: affinity), let index = byteToUTF16[byte] else { return nil }
    let matches = fragments.filter { index >= $0.range.location && index <= $0.contentEnd }
    guard let fragment = affinity == .upstream ? matches.first : matches.last else { return nil }
    let x = CTLineGetOffsetForStringIndex(fragment.line, index, nil)
    return CGRect(x: x, y: fragment.rect.minY, width: 1, height: fragment.rect.height)
  }
}
