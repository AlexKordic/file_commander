import Foundation
import CoreText
import CoreGraphics

extension WireComposePane {
  /// Older fixtures and grid-era scenes omit the readiness extension.
  public var formattingReady: Bool { !hasReady || ready }
}

/// Fresh's source-preserving Compose projection. Coordinates in this contract
/// are UTF-8 bytes. Core Text's UTF-16 indices stay inside ComposeTextLayout.
public struct ComposeProjection {
  public enum Affinity { case upstream, downstream }
  public enum Kind { case copy, hidden, replacement, insertion }

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
      guard segment.source.lowerBound == sourceEnd,
            segment.source.upperBound <= source.upperBound,
            segment.display.lowerBound == displayEnd,
            boundaries.contains(segment.display.lowerBound),
            boundaries.contains(segment.display.upperBound) else { return nil }
      switch segment.kind {
      case .copy:
        guard !segment.source.isEmpty, segment.source.count == segment.display.count else { return nil }
      case .hidden:
        guard !segment.source.isEmpty, segment.display.isEmpty else { return nil }
      case .replacement:
        guard !segment.source.isEmpty, !segment.display.isEmpty else { return nil }
      case .insertion:
        guard segment.source.isEmpty, !segment.display.isEmpty else { return nil }
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

  /// Validate the server's map before using it for graphical input. Unknown
  /// segment kinds and integers that cannot be represented locally are refused.
  public init?(_ wire: WireComposePane) {
    guard let start = Int(exactly: wire.sourceStart), let end = Int(exactly: wire.sourceEnd), start <= end else { return nil }
    var segments: [Segment] = []
    for segment in wire.segments {
      guard let a = Int(exactly: segment.sourceStart), let b = Int(exactly: segment.sourceEnd), a <= b,
            let c = Int(exactly: segment.displayStart), let d = Int(exactly: segment.displayEnd), c <= d else { return nil }
      let kind: Kind
      switch segment.kind {
      case 0: kind = .copy
      case 1: kind = .hidden
      case 2: kind = .replacement
      case 3: kind = .insertion
      default: return nil
      }
      segments.append(.init(source: a..<b, display: c..<d, kind: kind))
    }
    self.init(source: start..<end, text: wire.text, segments: segments)
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
      case .insertion: display = affinity == .upstream ? segment.display.lowerBound : segment.display.upperBound
      default:
        if source == segment.source.lowerBound { display = segment.display.lowerBound }
        else if source == segment.source.upperBound { display = segment.display.upperBound }
        else { display = affinity == .upstream ? segment.display.lowerBound : segment.display.upperBound }
      }
      return boundaries.contains(display) ? display : nil
    }
    return affinity == .upstream ? positions.min() : positions.max()
  }

  public struct Object {
    public let source: Range<Int>
    public let display: Range<Int>
  }

  /// Substitute presentation objects without changing the source map. An
  /// existing atomic replacement cannot be split at an invented boundary.
  public func replacingObjects(_ ranges: [Range<Int>]) -> (projection: Self, objects: [Object])? {
    let ordered = ranges.sorted { $0.lowerBound < $1.lowerBound }
    guard !ordered.isEmpty else { return (self, []) }
    let bytes = Array(text.utf8)
    var result = "", mapped: [Segment] = [], objects: [Object] = []
    func append(_ source: Range<Int>, _ display: Range<Int>, _ kind: Kind) -> Bool {
      guard boundaries.contains(display.lowerBound), boundaries.contains(display.upperBound) else { return false }
      let start = result.utf8.count
      result += String(decoding: bytes[display], as: UTF8.self)
      mapped.append(.init(source: source, display: start..<result.utf8.count, kind: kind))
      return true
    }
    func gap(_ range: Range<Int>) -> Bool {
      for segment in segments {
        if segment.kind == .insertion {
          let at = segment.source.lowerBound
          if (range.contains(at) || at == source.upperBound && range.upperBound == at),
             !ordered.contains(where: { at >= $0.lowerBound && at <= $0.upperBound }),
             !append(segment.source, segment.display, .insertion) { return false }
          continue
        }
        let from = max(range.lowerBound, segment.source.lowerBound), to = min(range.upperBound, segment.source.upperBound)
        guard from < to else { continue }
        switch segment.kind {
        case .copy:
          let a = segment.display.lowerBound + from - segment.source.lowerBound
          if !append(from..<to, a..<(a + to - from), .copy) { return false }
        case .hidden:
          if !append(from..<to, segment.display, .hidden) { return false }
        case .replacement:
          guard from == segment.source.lowerBound, to == segment.source.upperBound,
                append(from..<to, segment.display, .replacement) else { return false }
        case .insertion: break
        }
      }
      return true
    }
    var from = source.lowerBound
    for range in ordered {
      guard !range.isEmpty, range.lowerBound >= from, range.upperBound <= source.upperBound,
            gap(from..<range.lowerBound) else { return nil }
      let start = result.utf8.count
      result += "\u{fffc}"
      let display = start..<result.utf8.count
      mapped.append(.init(source: range, display: display, kind: .replacement))
      objects.append(.init(source: range, display: display))
      from = range.upperBound
    }
    guard gap(from..<source.upperBound), let projection = Self(source: source, text: result, segments: mapped) else { return nil }
    return (projection, objects)
  }
}

/// Measured Compose text with one geometry shared by painting and hit testing.
/// Fresh owns editing and undo; this is an immutable presentation of one block.
public final class ComposeTextLayout {
  public struct Hit {
    public var source: Int
    public var affinity: ComposeProjection.Affinity
    public var attachment: Range<Int>? = nil
  }

  public struct Attachment {
    public let source: Range<Int>
    public let display: Range<Int>
    public let size: CGSize
    public init(source: Range<Int>, display: Range<Int>, size: CGSize) {
      self.source = source; self.display = display; self.size = size
    }
  }
  public struct PlacedAttachment {
    public let attachment: Attachment
    public let rect: CGRect
  }
  private final class Metrics {
    let size: CGSize
    init(_ size: CGSize) { self.size = size }
  }
  static let attachmentKey = NSAttributedString.Key("fc.compose.attachment")
  static let roleKey = NSAttributedString.Key("fc.compose.role")
  static let flagsKey = NSAttributedString.Key("fc.compose.flags")
  public struct FontRun {
    public var display: Range<Int>
    public var font: CTFont
    public var role: UInt32
    public var flags: UInt32

    public init(display: Range<Int>, font: CTFont, role: UInt32 = 0, flags: UInt32 = 0) {
      self.display = display
      self.font = font
      self.role = role
      self.flags = flags
    }
  }

  /// A source-mapped block, before any measured wrapping. Nested blocks use
  /// their innermost paragraph geometry; spacing belongs to the block edges.
  public struct ParagraphRun {
    public var display: Range<Int>
    public var indent, before, after: CGFloat

    public init(display: Range<Int>, indent: CGFloat = 0, before: CGFloat = 0, after: CGFloat = 0) {
      self.display = display; self.indent = indent; self.before = before; self.after = after
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
  public let attachments: [PlacedAttachment]
  private let utf16ToByte: [Int: Int]
  private let byteToUTF16: [Int: Int]
  private let string: NSString

  /// Width and vertical geometry are in points. No rounding to terminal cells
  /// takes place. Invalid font ranges fail instead of quietly mis-styling text.
  public init?(projection: ComposeProjection, font: CTFont, width: CGFloat,
               lineSpacing: CGFloat = 3, fonts: [FontRun] = [], attachments: [Attachment] = [],
               paragraphs: [ParagraphRun] = []) {
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
      attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true])
    for run in fonts {
      guard let start = byteToUTF16[run.display.lowerBound], let end = byteToUTF16[run.display.upperBound] else { return nil }
      attributed.addAttributes([NSAttributedString.Key(kCTFontAttributeName as String): run.font,
        Self.roleKey: run.role, Self.flagsKey: run.flags], range: NSRange(location: start, length: end - start))
    }
    var blocks: [(range: NSRange, style: ParagraphRun)] = []
    for paragraph in paragraphs {
      guard let start = byteToUTF16[paragraph.display.lowerBound], let end = byteToUTF16[paragraph.display.upperBound],
            start < end, [paragraph.indent, paragraph.before, paragraph.after].allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
      blocks.append((NSRange(location: start, length: end - start), paragraph))
    }
    for (index, attachment) in attachments.enumerated() {
      guard attachment.size.width.isFinite, attachment.size.height.isFinite,
            attachment.size.width > 0, attachment.size.height > 0,
            let start = byteToUTF16[attachment.display.lowerBound], let end = byteToUTF16[attachment.display.upperBound],
            end - start == 1, string.character(at: start) == 0xfffc else { return nil }
      let metrics = Unmanaged.passRetained(Metrics(attachment.size)).toOpaque()
      var callbacks = CTRunDelegateCallbacks(version: kCTRunDelegateCurrentVersion,
        dealloc: { Unmanaged<Metrics>.fromOpaque($0).release() },
        getAscent: { Unmanaged<Metrics>.fromOpaque($0).takeUnretainedValue().size.height },
        getDescent: { _ in 0 },
        getWidth: { Unmanaged<Metrics>.fromOpaque($0).takeUnretainedValue().size.width })
      guard let delegate = CTRunDelegateCreate(&callbacks, metrics) else {
        Unmanaged<Metrics>.fromOpaque(metrics).release(); return nil
      }
      attributed.addAttributes([
        NSAttributedString.Key(kCTRunDelegateAttributeName as String): delegate,
        Self.attachmentKey: index,
        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): false,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 0),
      ], range: NSRange(location: start, length: 1))
    }
    let typesetter = CTTypesetterCreateWithAttributedString(attributed)
    var lines: [Fragment] = []
    var from = 0
    var top: CGFloat = 0
    var placed: [PlacedAttachment] = []
    let baseHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
    func block(at position: Int) -> (range: NSRange, style: ParagraphRun)? {
      blocks.filter { NSLocationInRange(position, $0.range) }.min { $0.range.length < $1.range.length }
    }
    func append(_ range: NSRange, block: (range: NSRange, style: ParagraphRun)?, indent: CGFloat) {
      if let block, range.location == block.range.location { top += block.style.before }
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
        rect: CGRect(x: indent, y: top, width: width - indent, height: height),
        baseline: top + ascent, contentEnd: contentEnd))
      for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let index = attributes[Self.attachmentKey] as? Int, attachments.indices.contains(index) else { continue }
        var position = CGPoint.zero
        CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
        let attachment = attachments[index]
        placed.append(.init(attachment: attachment,
          rect: CGRect(x: indent + position.x, y: top + ascent - attachment.size.height, width: attachment.size.width, height: attachment.size.height)))
      }
      top += height
      if let block, NSMaxRange(range) >= NSMaxRange(block.range) { top += block.style.after }
    }
    while from < string.length {
      let paragraph = block(at: from)
      let indent = min(paragraph?.style.indent ?? 0, width * 0.6)
      let suggested = CTTypesetterSuggestLineBreak(typesetter, from, Double(width - indent))
      var count = suggested > 0 ? suggested : string.rangeOfComposedCharacterSequence(at: from).length
      guard count > 0, count <= string.length - from else { return nil }
      // A viewport narrower than a single composed character must overflow
      // that character intact instead of splitting an emoji/combining cluster.
      if from + count < string.length {
        let cluster = string.rangeOfComposedCharacterSequence(at: from + count)
        if cluster.location < from + count { count = NSMaxRange(cluster) - from }
      }
      append(NSRange(location: from, length: count), block: paragraph, indent: indent)
      from += count
    }
    if string.length == 0 || string.character(at: string.length - 1) == 10 || string.character(at: string.length - 1) == 13 {
      append(NSRange(location: string.length, length: 0), block: nil, indent: 0)
    }
    self.projection = projection
    self.fragments = lines
    self.size = CGSize(width: width, height: top)
    self.utf16ToByte = utf16ToByte
    self.byteToUTF16 = byteToUTF16
    self.string = string
    self.attachments = placed
  }

  /// A hit returns a source-byte caret, snapping to a complete grapheme. It
  /// never returns the middle of a surrogate pair, CRLF, or composed character.
  public func sourcePosition(at point: CGPoint, affinity: ComposeProjection.Affinity = .downstream) -> Int? {
    if let object = attachmentHit(at: point) { return object.source }
    guard let (_, boundary) = hitIndex(at: point), let byte = utf16ToByte[boundary] else { return nil }
    return projection.sourcePosition(at: byte, affinity: affinity)
  }

  /// Preserve which side of a wrapped line was clicked. Source bytes alone
  /// cannot distinguish a line's end from the following line's beginning.
  public func hit(at point: CGPoint) -> Hit? {
    if let object = attachmentHit(at: point) { return object }
    guard let (fragment, boundary) = hitIndex(at: point), let byte = utf16ToByte[boundary] else { return nil }
    let affinity: ComposeProjection.Affinity = boundary == fragment.contentEnd && boundary > fragment.range.location ? .upstream : .downstream
    guard let source = projection.sourcePosition(at: byte, affinity: affinity) else { return nil }
    return Hit(source: source, affinity: affinity)
  }

  private func attachmentHit(at point: CGPoint) -> Hit? {
    guard let placed = attachments.first(where: { $0.rect.contains(point) }) else { return nil }
    let range = placed.attachment.source
    let before = point.x < placed.rect.midX
    return Hit(source: before ? range.lowerBound : range.upperBound, affinity: before ? .downstream : .upstream, attachment: range)
  }

  private func hitIndex(at point: CGPoint) -> (Fragment, Int)? {
    guard point.x.isFinite, point.y.isFinite, let first = fragments.first else { return nil }
    let fragment = fragments.first(where: { point.y < $0.rect.maxY }) ?? fragments.last ?? first
    let x = point.x - fragment.rect.minX
    let raw = CTLineGetStringIndexForPosition(fragment.line, CGPoint(x: x, y: 0))
    let index = min(fragment.contentEnd, max(fragment.range.location, raw == kCFNotFound ? fragment.contentEnd : raw))
    var boundary = index
    if index < string.length {
      let grapheme = string.rangeOfComposedCharacterSequence(at: index)
      if index != grapheme.location {
        let left = CTLineGetOffsetForStringIndex(fragment.line, grapheme.location, nil)
        let right = CTLineGetOffsetForStringIndex(fragment.line, NSMaxRange(grapheme), nil)
        boundary = abs(x - left) <= abs(x - right) ? grapheme.location : NSMaxRange(grapheme)
      }
    }
    return (fragment, boundary)
  }

  /// Caret geometry from the same shaped lines that supply hit testing. The
  /// affinity selects the visible side of a soft-wrap boundary.
  public func caret(for source: Int, affinity: ComposeProjection.Affinity = .downstream) -> CGRect? {
    guard let byte = projection.displayPosition(for: source, affinity: affinity), var index = byteToUTF16[byte] else { return nil }
    var matches = fragments.filter { index >= $0.range.location && index <= $0.contentEnd }
    if matches.isEmpty, let ending = fragments.first(where: { index > $0.contentEnd && index < NSMaxRange($0.range) }) {
      index = ending.contentEnd
      matches = [ending]
    }
    guard let fragment = affinity == .upstream ? matches.first : matches.last else { return nil }
    let x = fragment.rect.minX + CTLineGetOffsetForStringIndex(fragment.line, index, nil)
    return CGRect(x: x, y: fragment.rect.minY, width: 1, height: fragment.rect.height)
  }

  /// Feedback is sparse: include measured lines around the cursors and an
  /// optional requested y coordinate. Line ordinals prevent the backend from
  /// treating a gap between exported regions as adjacent visual lines.
  public func navigation(id: UInt64, pageHeight: CGFloat, documentLength: UInt64,
                         positions: [UInt64], aroundY: CGFloat? = nil, styleRevision: UInt64 = 0) -> WireComposeLayout? {
    guard id != 0, pageHeight.isFinite, pageHeight > 0 else { return nil }
    var centers = positions.compactMap { Int(exactly: $0).flatMap { caret(for: $0)?.midY } }
    if let aroundY, aroundY.isFinite { centers.append(aroundY) }
    if centers.isEmpty { centers = [0] }
    let radius = max(120, pageHeight * 2)
    var totalStops = 0
    var lines: [WireComposeLine] = []
    for (number, fragment) in fragments.enumerated() where centers.contains(where: { $0 + radius >= fragment.rect.minY && $0 - radius <= fragment.rect.maxY }) {
      func stop(_ index: Int, _ affinity: ComposeProjection.Affinity) -> WireComposeStop? {
        guard let display = utf16ToByte[index], let source = projection.sourcePosition(at: display, affinity: affinity),
              projection.displayPosition(for: source, affinity: affinity) == display else { return nil }
        if affinity == .upstream, number > 0, index == fragment.range.location,
           fragments[number - 1].contentEnd == index { return nil }
        if affinity == .downstream, number + 1 < fragments.count, index == fragment.contentEnd,
           fragments[number + 1].range.location == index { return nil }
        return WireComposeStop.with {
          $0.source = UInt64(source)
          $0.x = Double(fragment.rect.minX + CTLineGetOffsetForStringIndex(fragment.line, index, nil))
          $0.affinity = affinity == .upstream ? 1 : 0
        }
      }
      var stops: [WireComposeStop] = []
      var index = fragment.range.location
      while index <= fragment.contentEnd {
        for affinity: ComposeProjection.Affinity in [.downstream, .upstream] {
          if let point = stop(index, affinity), !stops.suffix(2).contains(where: { $0.source == point.source && $0.x == point.x }) {
            stops.append(point)
          }
        }
        guard index < fragment.contentEnd else { break }
        let next = NSMaxRange(string.rangeOfComposedCharacterSequence(at: index))
        guard next > index else { return nil }
        index = min(next, fragment.contentEnd)
      }
      guard let first = stop(fragment.range.location, .downstream) ?? stop(fragment.range.location, .upstream) ?? stops.first,
            let last = stop(fragment.contentEnd, .upstream) ?? stop(fragment.contentEnd, .downstream) ?? stops.last,
            let a = utf16ToByte[fragment.range.location], let b = utf16ToByte[NSMaxRange(fragment.range)],
            let sourceStart = projection.sourcePosition(at: a, affinity: .upstream),
            let sourceEnd = projection.sourcePosition(at: b, affinity: .downstream) else { return nil }
      // Explicit edge stops also preserve the desired affinity for Home/End.
      if !stops.contains(first) { stops.append(first) }
      if !stops.contains(last) { stops.append(last) }
      totalStops += stops.count
      guard totalStops <= 100_000, lines.count < 16_384 else { return nil }
      lines.append(WireComposeLine.with {
        $0.number = UInt64(number)
        $0.y = Double(fragment.rect.minY)
        $0.height = Double(fragment.rect.height)
        $0.sourceStart = UInt64(sourceStart)
        $0.sourceEnd = UInt64(sourceEnd)
        $0.start = first
        $0.end = last
        $0.stops = stops
      })
    }
    return WireComposeLayout.with {
      $0.id = id
      $0.pageHeight = Double(pageHeight)
      $0.sourceStart = UInt64(projection.source.lowerBound)
      $0.sourceEnd = UInt64(projection.source.upperBound)
      $0.documentLen = documentLength
      $0.lines = lines
      $0.totalLines = UInt64(fragments.count)
      $0.height = Double(size.height)
      $0.styleRevision = styleRevision
    }
  }

  /// Selection geometry in layout coordinates. Concealed syntax stays in the
  /// source selection while the visible part uses the very same shaped lines
  /// as the caret and text. A selected line ending extends to the line edge.
  public func selectionRects(for source: Range<Int>) -> [CGRect] {
    guard !source.isEmpty,
          let start = projection.displayPosition(for: max(source.lowerBound, projection.source.lowerBound), affinity: .downstream),
          let end = projection.displayPosition(for: min(source.upperBound, projection.source.upperBound), affinity: .upstream),
          let a = byteToUTF16[start], let b = byteToUTF16[end], a <= b else { return [] }
    return fragments.compactMap { fragment in
      let from = max(a, fragment.range.location)
      let to = min(b, fragment.contentEnd)
      let newline = b > fragment.contentEnd && b >= NSMaxRange(fragment.range)
      guard from < to || (newline && from <= fragment.contentEnd) else { return nil }
      let x0 = fragment.rect.minX + CTLineGetOffsetForStringIndex(fragment.line, from, nil)
      let x1 = newline ? fragment.rect.maxX : fragment.rect.minX + CTLineGetOffsetForStringIndex(fragment.line, to, nil)
      return CGRect(x: min(x0, x1), y: fragment.rect.minY, width: max(1, abs(x1 - x0)), height: fragment.rect.height)
    }
  }
}
