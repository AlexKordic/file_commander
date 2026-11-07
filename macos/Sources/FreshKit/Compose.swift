import Foundation
import CoreText
import CoreGraphics

extension WireComposePane {
  /// Older fixtures and grid-era scenes omit the readiness extension.
  public var formattingReady: Bool { !hasReady || ready }
  /// A current-source projection can retain certified completed formatting
  /// while another range's formatter is pending. It is safe for measured input.
  public var projectionUsable: Bool { formattingReady || currentProjection }
}

/// Fresh's source-preserving Compose projection. Coordinates in this contract
/// are UTF-8 bytes. Text APIs translate displayed UTF-16 through this same map.
public struct ComposeProjection: Sendable {
  public enum Affinity: Sendable { case upstream, downstream }
  public enum Kind: Sendable { case copy, hidden, replacement, insertion }

  public struct Segment: Sendable {
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
  let textIndex: ComposeTextIndex

  /// Refuse incomplete or ambiguous maps before they can address the buffer.
  /// The server supplies the original source; this object never serializes it.
  public init?(source: Range<Int>, text: String, segments: [Segment]) {
    guard source.lowerBound >= 0 else { return nil }
    let index = ComposeTextIndex(text)
    var sourceEnd = source.lowerBound
    var displayEnd = 0
    for segment in segments {
      guard segment.source.lowerBound == sourceEnd,
            segment.source.upperBound <= source.upperBound,
            segment.display.lowerBound == displayEnd,
            index.contains(byte: segment.display.lowerBound),
            index.contains(byte: segment.display.upperBound) else { return nil }
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
    guard sourceEnd == source.upperBound, displayEnd == index.byteCount else { return nil }
    self.source = source
    self.text = text
    self.segments = segments
    textIndex = index
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
    guard textIndex.contains(byte: display) else { return nil }
    if segments.isEmpty { return display == 0 ? source.lowerBound : nil }
    let index = affinity == .upstream ? firstSegment { $0.display.upperBound >= display }
      : firstSegment { $0.display.lowerBound > display } - 1
    guard segments.indices.contains(index) else { return nil }
    let segment = segments[index]
    switch segment.kind {
    case .copy: return segment.source.lowerBound + (display - segment.display.lowerBound)
    default:
      if !segment.display.isEmpty {
        if display == segment.display.lowerBound { return segment.source.lowerBound }
        if display == segment.display.upperBound { return segment.source.upperBound }
      }
      return affinity == .upstream ? segment.source.lowerBound : segment.source.upperBound
    }
  }

  public func displayPosition(for source: Int, affinity: Affinity = .downstream) -> Int? {
    guard source >= self.source.lowerBound, source <= self.source.upperBound else { return nil }
    if segments.isEmpty { return 0 }
    let index = affinity == .upstream ? firstSegment { $0.source.upperBound >= source }
      : firstSegment { $0.source.lowerBound > source } - 1
    guard segments.indices.contains(index) else { return nil }
    let segment = segments[index], display: Int
    switch segment.kind {
    case .copy: display = segment.display.lowerBound + (source - segment.source.lowerBound)
    case .insertion: display = affinity == .upstream ? segment.display.lowerBound : segment.display.upperBound
    default:
      if source == segment.source.lowerBound { display = segment.display.lowerBound }
      else if source == segment.source.upperBound { display = segment.display.upperBound }
      else { display = affinity == .upstream ? segment.display.lowerBound : segment.display.upperBound }
    }
    return textIndex.contains(byte: display) ? display : nil
  }

  /// Validation guarantees both coordinate spaces are monotonic. Inclusive
  /// edges can have several hidden/inserted segments: the first match owns
  /// upstream affinity and the last owns downstream, without an array scan.
  private func firstSegment(where predicate: (Segment) -> Bool) -> Int {
    var low = 0, high = segments.count
    while low < high {
      let middle = low + (high - low) / 2
      if predicate(segments[middle]) { high = middle } else { low = middle + 1 }
    }
    return low
  }

  public struct Object: Sendable {
    public let source: Range<Int>
    public let display: Range<Int>
  }

  /// Substitute presentation objects without changing the source map. An
  /// existing atomic replacement cannot be split at an invented boundary.
  public func replacingObjects(_ ranges: [Range<Int>]) -> (projection: Self, objects: [Object])? {
    let ordered = ranges.sorted { $0.lowerBound < $1.lowerBound }
    guard !ordered.isEmpty else { return (self, []) }
    var previous = source.lowerBound
    for range in ordered {
      guard !range.isEmpty, range.lowerBound >= previous, range.upperBound <= source.upperBound else { return nil }
      previous = range.upperBound
    }
    let bytes = Array(text.utf8)
    var result = "", mapped: [Segment] = [], objects: [Object] = []
    func append(_ source: Range<Int>, _ display: Range<Int>, _ kind: Kind) -> Bool {
      guard textIndex.contains(byte: display.lowerBound), textIndex.contains(byte: display.upperBound) else { return false }
      let start = result.utf8.count
      result += String(decoding: bytes[display], as: UTF8.self)
      mapped.append(.init(source: source, display: start..<result.utf8.count, kind: kind))
      return true
    }
    func gap(_ range: Range<Int>) -> Bool {
      let first = firstSegment { $0.source.upperBound >= range.lowerBound }
      for segment in segments[first...] {
        if segment.source.lowerBound > range.upperBound { break }
        if segment.kind == .insertion {
          let at = segment.source.lowerBound
          var low = 0, high = ordered.count
          while low < high {
            let middle = low + (high - low) / 2
            if ordered[middle].upperBound >= at { high = middle } else { low = middle + 1 }
          }
          let inObject = low < ordered.count && ordered[low].lowerBound <= at
          if (range.contains(at) || at == source.upperBound && range.upperBound == at),
             !inObject,
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

  /// Displayed UTF-16 and authoritative UTF-8 share this implementation for
  /// both drawing windows and complete accessible document snapshots.
  public func utf16Position(for source: Int, affinity: Affinity = .downstream) -> Int? {
    displayPosition(for: source, affinity: affinity).flatMap { textIndex.unit(forByte: $0) }
  }

  public func sourceRange(forUTF16 range: NSRange, insertion: Int? = nil) -> Range<Int>? {
    guard let bytes = textIndex.bytes(for: range) else { return nil }
    return sourceRange(forDisplayBytes: bytes, insertion: insertion)
  }

  func sourceRange(forDisplayBytes bytes: Range<Int>, insertion: Int? = nil) -> Range<Int>? {
    if bytes.isEmpty, let insertion, displayPosition(for: insertion) == bytes.lowerBound { return insertion..<insertion }
    guard let start = sourcePosition(at: bytes.lowerBound, affinity: .downstream) else { return nil }
    if bytes.isEmpty { return start..<start }
    guard let end = sourcePosition(at: bytes.upperBound, affinity: .upstream), start <= end else { return nil }
    return start..<end
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

  public struct Attachment: Sendable {
    public let source: Range<Int>
    public let display: Range<Int>
    public let size: CGSize
    /// A source-edit preview occupies flow space after its text line, without
    /// replacing text, adding caret stops, or introducing clipboard characters.
    public let preview: Bool
    public init(source: Range<Int>, display: Range<Int>, size: CGSize, preview: Bool = false) {
      self.source = source; self.display = display; self.size = size
      self.preview = preview
    }
  }
  public struct PlacedAttachment: Sendable {
    public let attachment: Attachment
    public let rect: CGRect
  }
  private final class Metrics {
    let size: CGSize
    init(_ size: CGSize) { self.size = size }
  }
  static let attachmentKey = NSAttributedString.Key("fc.compose.attachment")

  static func hangingPrefixWidth(_ line: CTLine, start: Int, content: Int, origin: Int = 0) -> CGFloat {
    guard start < content else { return 0 }
    let runs = (CTLineGetGlyphRuns(line) as! [CTRun]).filter { run in
      let range = CTRunGetStringRange(run)
      return range.location+origin < content && range.location+origin+range.length > start
    }
    // The body caret is a visual coordinate. In a reordered prefix it can
    // include most of the RTL body, so measure the marker's logical glyphs.
    // Keep the contextual caret for LTR markers, including body-side kerning.
    guard runs.contains(where: { CTRunGetStatus($0).contains(.rightToLeft) }) else {
      return CTLineGetOffsetForStringIndex(line, content-origin, nil)
    }
    var width: CGFloat = 0
    for run in runs {
      let count = CTRunGetGlyphCount(run)
      guard count > 0 else { continue }
      var indices = Array(repeating: CFIndex(0), count: count)
      var advances = Array(repeating: CGSize.zero, count: count)
      CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
      CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
      for glyph in 0..<count where indices[glyph]+origin >= start && indices[glyph]+origin < content {
        width += advances[glyph].width
      }
    }
    return width
  }
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
    public var indent, trailing, before, after: CGFloat
    public var verbatim: Bool

    public init(display: Range<Int>, indent: CGFloat = 0, trailing: CGFloat = 0,
                before: CGFloat = 0, after: CGFloat = 0, verbatim: Bool = false) {
      self.display = display; self.indent = indent; self.trailing = trailing
      self.before = before; self.after = after; self.verbatim = verbatim
    }
  }

  /// Fresh identifies the body after a list/task marker. Core Text measures
  /// the displayed prefix; no Markdown recognition or column estimate occurs
  /// in the native client. Nested items override their containing item.
  public struct HangingRun {
    public var display: Range<Int>
    public var contentStart: Int
    public var indent: CGFloat
    /// An offscreen marker measured in this client's current fonts. Such a
    /// continuation starts at contentStart; its prefix is never inserted text.
    public var measuredPrefix: CGFloat?
    /// The clipped run begins at a source-owned physical line boundary.
    public var physicalStart: Bool

    public init(display: Range<Int>, contentStart: Int, indent: CGFloat,
                measuredPrefix: CGFloat? = nil, physicalStart: Bool = false) {
      self.display = display; self.contentStart = contentStart; self.indent = indent
      self.measuredPrefix = measuredPrefix; self.physicalStart = physicalStart
    }
  }

  public struct Fragment {
    public let shaped: ComposeShapedLine
    public var line: CTLine { shaped.line }
    public var indexOrigin: Int { shaped.origin }
    /// Global projection UTF-16 range, including a consumed line ending.
    /// An empty cell retains its global index even though its CTLine is empty.
    public let range: NSRange
    public let rect: CGRect
    /// Baseline measured down from the block's top.
    public let baseline: CGFloat
    /// A caret may reach this index, but not enter a line ending's interior.
    public let contentEnd: Int
    public let table: TablePosition?
    init(line: CTLine, range: NSRange, rect: CGRect, baseline: CGFloat, contentEnd: Int, table: TablePosition?, indexOrigin: Int = 0,context:NSString?=nil) {
      shaped = .init(line:line,origin:indexOrigin,context:context);self.range=range;self.rect=rect
      self.baseline=baseline;self.contentEnd=contentEnd;self.table=table
    }
  }

  public let projection: ComposeProjection
  public let fragments: [Fragment]
  public let size: CGSize
  public let attachments: [PlacedAttachment]
  public let tables: [Table]
  public struct MeasurementOptions: Sendable, Equatable {
    public var maximumContextUnits: Int
    public var maximumCoordinates: Int
    public var maximumFragments: Int
    public init(maximumContextUnits:Int=65_536,maximumCoordinates:Int=262_144,maximumFragments:Int=262_144) {
      self.maximumContextUnits=maximumContextUnits;self.maximumCoordinates=maximumCoordinates;self.maximumFragments=maximumFragments
    }
  }
  public struct MeasurementUsage: Sendable {
    public let maximumContextUnits,contexts,coordinateEntries,fragments: Int
    public let retainedGlyphs: Bool
  }
  public let measurementUsage: MeasurementUsage
  let measurementPlan: ComposeShapingContexts.Plan?
  let utf16ToByte: [Int: Int]
  let byteToUTF16: [Int: Int]
  let string: NSString

  /// Width and vertical geometry are in points. No rounding to terminal cells
  /// takes place. Invalid font ranges fail instead of quietly mis-styling text.
  public init?(projection: ComposeProjection, font: CTFont, width: CGFloat,
               lineSpacing: CGFloat = 3, fonts: [FontRun] = [], attachments: [Attachment] = [],
               paragraphs: [ParagraphRun] = [], hanging: [HangingRun] = [], tables: [TableRun] = [],
               measurement: MeasurementOptions? = nil, record: ((Fragment)->Bool)? = nil) {
    guard width.isFinite, width > 0, lineSpacing.isFinite, lineSpacing >= 0 else { return nil }
    if let measurement {guard measurement.maximumContextUnits>0,measurement.maximumCoordinates>0,measurement.maximumFragments>0 else {return nil}}
    let string = NSString(string:projection.text)
    var utf16ToByte = [0: 0]
    var byteToUTF16 = [0: 0]
    var byte = 0, unit = 0, paragraphStart = 0
    var hasLongParagraph = false
    for scalar in projection.text.unicodeScalars {
      byte += scalar.utf8.count
      unit += scalar.utf16.count
      if measurement == nil {utf16ToByte[unit] = byte;byteToUTF16[byte] = unit}
      if !hasLongParagraph {
        // LF-delimited runs overestimate the length for other newline kinds.
        // This cheap rejection avoids another scan on ordinary short prose;
        // the wrapping index still validates its actual paragraph ranges.
        if unit - paragraphStart >= ComposeWrappingBreaks.minimumLength { hasLongParagraph = true }
        if scalar.value == 0x0a { paragraphStart = unit }
      }
    }
    if let measurement {
      var required:Set<Int>=[0,byte]
      guard required.count<=measurement.maximumCoordinates else {return nil}
      var overflow=false
      func includePoint(_ point:Int) {
        guard !overflow else {return}
        guard required.count<measurement.maximumCoordinates || required.contains(point) else {overflow=true;return}
        required.insert(point)
      }
      func include(_ range:Range<Int>) {includePoint(range.lowerBound);includePoint(range.upperBound)}
      for font in fonts {include(font.display)}
      for attachment in attachments {include(attachment.display)}
      for paragraph in paragraphs {include(paragraph.display)}
      for item in hanging {include(item.display);includePoint(item.contentStart)}
      for table in tables {for row in table.table.rows {include(row.display);for cell in row.cells {if let range=cell.display {include(range)}}}}
      guard !overflow else {return nil}
      for point in required {
        guard let unit=projection.textIndex.unit(forByte:point) else {return nil}
        byteToUTF16[point]=unit;utf16ToByte[unit]=point
      }
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
            start < end, [paragraph.indent, paragraph.trailing, paragraph.before, paragraph.after].allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
      blocks.append((NSRange(location: start, length: end - start), paragraph))
    }
    // Markers and cells share the same fonts and complete projection before
    // image delegates are installed. Fixed column inputs need no extra shaper.
    let measuresText = hanging.contains { $0.measuredPrefix == nil }
      || tables.contains { $0.columns == nil || $0.adaptiveMinimum }
    let measurementTypesetter = measuresText ? ComposeShapingContexts(attributed,wrapping:hasLongParagraph,
      maximumUnits:measurement?.maximumContextUnits) : nil
    var hangs: [(range: NSRange, content: Int, prefix: CGFloat, indent: CGFloat, physicalStart: Bool)] = []
    for item in hanging {
      guard let start = byteToUTF16[item.display.lowerBound], let end = byteToUTF16[item.display.upperBound],
            let content = byteToUTF16[item.contentStart], start <= content, content < end,
            item.indent.isFinite, item.indent >= 0,
            string.rangeOfCharacter(from: .newlines, range: NSRange(location: start, length: content - start)).location == NSNotFound else { return nil }
      if let measured = item.measuredPrefix {
        guard measured.isFinite, measured >= 0, start == content else { return nil }
        hangs.append((NSRange(location: start, length: end - start), content, measured, item.indent, item.physicalStart))
        continue
      }
      guard let measurementTypesetter else { return nil }
      // Shape the first visual line, not a copy of the whole joined paragraph.
      // Include at least the first complete body grapheme: cutting at the
      // marker changes kerning ("1) An"), even when a narrow pane wraps there.
      let measure = max(1, width - min(item.indent, width * 0.6))
      guard let count = measurementTypesetter.suggest(from:start,width:Double(measure)) else {return nil}
      let bodyEnd = NSMaxRange(string.rangeOfComposedCharacterSequence(at: content))
      var contextEnd = min(end, max(start + max(0, count), bodyEnd))
      if contextEnd < end {
        let cluster = string.rangeOfComposedCharacterSequence(at: contextEnd)
        if cluster.location < contextEnd { contextEnd = min(end, NSMaxRange(cluster)) }
      }
      guard let prefix = measurementTypesetter.line(NSRange(location:start,length:contextEnd-start)) else {return nil}
      let measured = Self.hangingPrefixWidth(prefix.line, start: start, content: content,origin:prefix.origin)
      guard measured.isFinite, measured >= 0 else { return nil }
      hangs.append((NSRange(location: start, length: end - start), content, measured, item.indent, false))
    }
    let hangingIndex = ComposeIntervalIndex(hangs.map { $0.range.location..<NSMaxRange($0.range) })
    func hangingItem(at position: Int) -> (range: NSRange, content: Int, prefix: CGFloat, indent: CGFloat, physicalStart: Bool)? {
      hangingIndex.matches(at: position).min { a, b in
        if hangs[a].range.length != hangs[b].range.length { return hangs[a].range.length < hangs[b].range.length }
        if hangs[a].content != hangs[b].content { return hangs[a].content > hangs[b].content }
        return a < b
      }.map { hangs[$0] }
    }
    guard attachments.allSatisfy({ $0.size.width.isFinite && $0.size.height.isFinite && $0.size.width > 0 && $0.size.height > 0 }) else { return nil }
    var measuredTables: [ComposeMeasuredTable] = []
    var tableRows: [(table: Int, row: Int, range: NSRange)] = []
    var previousRowEnd = 0
    for run in tables {
      guard let measured = ComposeMeasuredTable(run: run, attributed: attributed, typesetter: measurementTypesetter, font: font, width: width,
        indices: byteToUTF16, attachments: attachments), !measured.rows.isEmpty else { return nil }
      for (row, value) in measured.rows.enumerated() {
        guard value.range.location >= previousRowEnd else { return nil }
        tableRows.append((measuredTables.count, row, value.range)); previousRowEnd = NSMaxRange(value.range)
      }
      measuredTables.append(measured)
    }
    // Reserve the same content measure for attachments as for continuation
    // text, including on a first line that also contains the marker.
    let attachments = attachments.map { attachment in
      var available = width
      if let start = byteToUTF16[attachment.display.lowerBound], let item = hangingItem(at: start) {
        available = width - min(item.indent + item.prefix, width * 0.6)
      }
      for table in measuredTables {
        for row in table.rows where row.model.source.overlaps(attachment.source) {
          if row.model.raw { available = min(available, table.width - ComposeMeasuredTable.padding * 2) }
          else if let column = row.model.cells.firstIndex(where: { $0.source.overlaps(attachment.source) }) {
            available = min(available, table.columns[column] - ComposeMeasuredTable.padding * 2)
          }
        }
      }
      available = max(1, available)
      guard attachment.size.width > available else { return attachment }
      return Attachment(source: attachment.source, display: attachment.display,
        size: CGSize(width: available, height: attachment.size.height * available / attachment.size.width), preview: attachment.preview)
    }
    var previews: [(index: Int, end: Int)] = []
    for (index, attachment) in attachments.enumerated() {
      guard attachment.size.width.isFinite, attachment.size.height.isFinite,
            attachment.size.width > 0, attachment.size.height > 0,
            let start = byteToUTF16[attachment.display.lowerBound], let end = byteToUTF16[attachment.display.upperBound],
            start < end, !attachment.source.isEmpty,
            attachment.source.lowerBound >= projection.source.lowerBound,
            attachment.source.upperBound <= projection.source.upperBound else { return nil }
      if attachment.preview {
        previews.append((index, end))
        continue
      }
      guard end - start == 1, string.character(at: start) == 0xfffc else { return nil }
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
    // Non-preview images added run delegates after marker/cell measurement. Their
    // final typesetter must see those new attributes instead of reusing it.
    let typesetter = attachments.contains(where: { !$0.preview })
      ? ComposeShapingContexts(attributed,wrapping:hasLongParagraph,maximumUnits:measurement?.maximumContextUnits)
      : (measurementTypesetter ?? ComposeShapingContexts(attributed,wrapping:hasLongParagraph,maximumUnits:measurement?.maximumContextUnits))
    var lines: [Fragment] = []
    var from = 0
    var top: CGFloat = 0
    var placed: [PlacedAttachment] = []
    var placedRows = Array(repeating: [TableRow](), count: measuredTables.count)
    previews.sort { $0.end == $1.end ? $0.index < $1.index : $0.end < $1.end }
    var nextPreview = 0, shapingFailed = false,fragmentCount=0
    var rightExtent:CGFloat?
    let baseHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
    let blockIndex = ComposeIntervalIndex(blocks.map { $0.range.location..<NSMaxRange($0.range) })
    func block(at position: Int) -> (range: NSRange, style: ParagraphRun)? {
      blockIndex.matches(at: position).min { a, b in
        blocks[a].range.length == blocks[b].range.length ? a < b : blocks[a].range.length < blocks[b].range.length
      }.map { blocks[$0] }
    }
    func append(_ range: NSRange, block: (range: NSRange, style: ParagraphRun)?, indent: CGFloat,
                measure: CGFloat? = nil, table: TablePosition? = nil, alignment: ComposeTableModel.Alignment = .left) {
      guard measurement.map({fragmentCount<$0.maximumFragments}) ?? true else {shapingFailed=true;return}
      if let block, range.location == block.range.location { top += block.style.before }
      // Core Text interprets length zero as "to the end", not an empty cell.
      guard let shaped = typesetter.line(range) else {shapingFailed=true;return}
      let line=shaped.line
      var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
      let natural = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
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
      let measure = measure ?? max(1, width - indent - (block?.style.trailing ?? 0))
      let shift = max(0, measure - natural) * (alignment == .center ? 0.5 : alignment == .right ? 1 : 0)
      let left = indent + shift
      let fragment=Fragment(line: line, range: range,
        rect: CGRect(x: left, y: top, width: max(1, measure - shift), height: height),
        baseline: top + ascent, contentEnd: contentEnd, table: table,indexOrigin:shaped.origin,context:shaped.context)
      fragmentCount+=1
      let right=left+max(natural,CTLineGetBoundsWithOptions(line,.useGlyphPathBounds).maxX)
      rightExtent=rightExtent.map {max($0,right)} ?? right
      if measurement == nil {lines.append(fragment)}
      if record?(fragment) == false {shapingFailed=true;return}
      for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let index = attributes[Self.attachmentKey] as? Int, attachments.indices.contains(index) else { continue }
        var position = CGPoint.zero
        CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
        let attachment = attachments[index]
        placed.append(.init(attachment: attachment,
          rect: CGRect(x: left + position.x, y: top + ascent - attachment.size.height, width: attachment.size.width, height: attachment.size.height)))
      }
      top += height
      while nextPreview < previews.count, previews[nextPreview].end <= NSMaxRange(range) {
        let attachment = attachments[previews[nextPreview].index]
        top += 18 // Caption; presentation only, with no source/caret position.
        let item = table == nil ? byteToUTF16[attachment.display.lowerBound].flatMap { hangingItem(at: $0) } : nil
        let previewIndent = item.map { min($0.indent + $0.prefix, width * 0.6) } ?? indent
        placed.append(.init(attachment: attachment, rect: CGRect(x: previewIndent, y: top,
          width: attachment.size.width, height: attachment.size.height)))
        top += attachment.size.height + 8
        nextPreview += 1
      }
      if let block, NSMaxRange(range) >= NSMaxRange(block.range) { top += block.style.after }
    }
    func wrapped(_ range: NSRange, indent: CGFloat, measure: CGFloat, table: TablePosition, alignment: ComposeTableModel.Alignment) -> Bool {
      var at = range.location
      if range.length == 0 { append(range, block: nil, indent: indent, measure: measure, table: table, alignment: alignment) }
      guard !shapingFailed else {return false}
      while at < NSMaxRange(range) {
        guard let suggestion = typesetter.suggest(from:at,width:Double(measure)) else {return false}
        var count = min(suggestion > 0 ? suggestion : string.rangeOfComposedCharacterSequence(at: at).length, NSMaxRange(range) - at)
        if at + count < NSMaxRange(range) {
          let cluster = string.rangeOfComposedCharacterSequence(at: at + count)
          if cluster.location < at + count { count = NSMaxRange(cluster) - at }
        }
        // A suggested word break can consume trailing whitespace whose
        // advance extends beyond the measure. Carry it onto the next line;
        // every source character and its caret still belongs to this cell.
        while count > 0 {
          guard let shaped = typesetter.line(NSRange(location:at,length:count)) else {return false}
          guard CGFloat(CTLineGetTypographicBounds(shaped.line, nil, nil, nil)) > measure + 0.001 else { break }
          let last = string.rangeOfComposedCharacterSequence(at: at + count - 1)
          guard last.location > at else { break }
          count = last.location - at
        }
        guard count > 0, count <= NSMaxRange(range) - at else { return false }
        append(NSRange(location: at, length: count), block: nil, indent: indent, measure: measure, table: table, alignment: alignment)
        guard !shapingFailed else {return false}
        at += count
      }
      return true
    }
    var nextRow = 0, emptyTableEOF = false
    while from < string.length || nextRow < tableRows.count {
      if nextRow < tableRows.count, tableRows[nextRow].range.location == from {
        let next = tableRows[nextRow], table = measuredTables[next.table], row = table.rows[next.row]
        if next.row == 0 { top += table.run.before }
        let rowTop = top, padding = ComposeMeasuredTable.padding
        var bottom = rowTop + padding + baseHeight + lineSpacing
        var cells: [TableCell] = []
        if row.model.raw {
          top = rowTop + padding
          let position = TablePosition(table: table.run.table.source.lowerBound, row: row.model.source, column: nil, source: row.model.source)
          guard wrapped(row.range, indent: table.indent + padding, measure: max(1, table.width - padding * 2), table: position, alignment: .left) else { return nil }
          bottom = max(bottom, top)
        } else {
          var left = table.indent
          for (column, cell) in row.model.cells.enumerated() {
            let measure = max(1, table.columns[column] - padding * 2)
            if let range = row.cells[column] {
              top = rowTop + padding
              let position = TablePosition(table: table.run.table.source.lowerBound, row: row.model.source, column: column, source: cell.source)
              let alignment: ComposeTableModel.Alignment = cell.revealed ? .left : table.run.table.alignments[column]
              guard wrapped(range, indent: left + padding, measure: measure, table: position, alignment: alignment) else { return nil }
              bottom = max(bottom, top)
            }
            cells.append(TableCell(source: cell.missing ? nil : cell.source, display: row.cells[column],
              rect: CGRect(x: left, y: rowTop, width: table.columns[column], height: 0),
              content: CGRect(x: left + padding, y: rowTop + padding, width: measure, height: 0), column: column))
            left += table.columns[column]
          }
        }
        top = bottom + padding
        cells = cells.map { cell in
          TableCell(source: cell.source, display: cell.display,
            rect: CGRect(x: cell.rect.minX, y: rowTop, width: cell.rect.width, height: top - rowTop),
            content: CGRect(x: cell.content.minX, y: cell.content.minY, width: cell.content.width, height: bottom - cell.content.minY), column: cell.column)
        }
        placedRows[next.table].append(TableRow(source: row.model.source, contentEnd: row.model.contentEnd,
          rect: CGRect(x: table.indent, y: rowTop, width: table.width, height: top - rowTop), header: row.model.header, raw: row.model.raw, cells: cells))
        if next.row + 1 == table.rows.count { top += table.run.after }
        from = NSMaxRange(row.range); nextRow += 1
        emptyTableEOF = from == string.length && row.range.length == 0
        continue
      }
      guard from < string.length else { return nil }
      let paragraph = block(at: from)
      var desired = paragraph?.style.indent ?? 0
      if paragraph?.style.verbatim != true, let item = hangingItem(at: from) {
        desired = item.indent
        if from >= item.content {
          // Source indentation on a physical continuation line is already
          // drawn. Charge only the missing part of the measured prefix.
          var whitespace = from
          if from > 0 && [10, 13].contains(string.character(at: from - 1))
              || from == item.range.location && item.physicalStart {
            while whitespace < string.length && [9, 32].contains(string.character(at: whitespace)) { whitespace += 1 }
          }
          var existing: CGFloat = 0
          if whitespace > from {
            guard let prefix = typesetter.line(NSRange(location:from,length:whitespace-from)) else {return nil}
            existing = CGFloat(CTLineGetTypographicBounds(prefix.line, nil, nil, nil))
          }
          desired += max(0, item.prefix - existing)
        }
      }
      let indent = min(desired, width * 0.6)
      guard let suggested = typesetter.suggest(from:from,width:Double(max(1,width-indent-(paragraph?.style.trailing ?? 0)))) else {return nil}
      var count = suggested > 0 ? suggested : string.rangeOfComposedCharacterSequence(at: from).length
      if nextRow < tableRows.count { count = min(count, tableRows[nextRow].range.location - from) }
      guard count > 0, count <= string.length - from else { return nil }
      // A viewport narrower than a single composed character must overflow
      // that character intact instead of splitting an emoji/combining cluster.
      if from + count < string.length {
        let cluster = string.rangeOfComposedCharacterSequence(at: from + count)
        if cluster.location < from + count { count = NSMaxRange(cluster) - from }
      }
      append(NSRange(location: from, length: count), block: paragraph, indent: indent)
      guard !shapingFailed else {return nil}
      from += count
    }
    if !emptyTableEOF && (string.length == 0 || string.character(at: string.length - 1) == 10 || string.character(at: string.length - 1) == 13) {
      append(NSRange(location: string.length, length: 0), block: nil, indent: 0)
    }
    guard !shapingFailed else {return nil}
    self.projection = projection
    self.fragments = lines
    self.tables = measuredTables.enumerated().compactMap { index, table in
      guard let first = placedRows[index].first, let last = placedRows[index].last else { return nil }
      return Table(source: table.run.table.source, rect: CGRect(x: table.indent, y: first.rect.minY,
        width: table.width, height: last.rect.maxY - first.rect.minY), columns: table.columns, rows: placedRows[index])
    }
    // A complete grapheme can exceed a narrow measure. Its real shaped
    // advance/ink and caret must remain reachable by horizontal scrolling.
    let right = rightExtent ?? width
    self.size = CGSize(width: max(width, right + 1, self.tables.map(\.rect.maxX).max() ?? width,
      placed.map(\.rect.maxX).max() ?? width), height: top)
    self.utf16ToByte = utf16ToByte
    self.byteToUTF16 = byteToUTF16
    self.string = string
    self.attachments = placed
    measurementUsage = .init(maximumContextUnits:max(typesetter.usage.maximumUnits,measurementTypesetter?.usage.maximumUnits ?? 0),
      contexts:typesetter.usage.contexts+(measurementTypesetter === typesetter ? 0 : measurementTypesetter?.usage.contexts ?? 0),
      coordinateEntries:utf16ToByte.count+byteToUTF16.count,fragments:fragmentCount,retainedGlyphs:measurement == nil)
    measurementPlan=measurement == nil ? nil : typesetter.plan()
  }

  func byte(forUnit unit:Int) -> Int? {utf16ToByte[unit] ?? projection.textIndex.byte(forUnit:unit)}
  func unit(forByte byte:Int) -> Int? {byteToUTF16[byte] ?? projection.textIndex.unit(forByte:byte)}

  /// A hit returns a source-byte caret, snapping to a complete grapheme. It
  /// never returns the middle of a surrogate pair, CRLF, or composed character.
  public func sourcePosition(at point: CGPoint, affinity: ComposeProjection.Affinity = .downstream) -> Int? {
    if let object = attachmentHit(at: point) { return object.source }
    if let anchor = tableAnchor(at: point) { return anchor }
    guard let (_, boundary) = hitIndex(at: point), let byte = byte(forUnit:boundary) else { return nil }
    return projection.sourcePosition(at: byte, affinity: affinity)
  }

  /// Preserve which side of a wrapped line was clicked. Source bytes alone
  /// cannot distinguish a line's end from the following line's beginning.
  public func hit(at point: CGPoint) -> Hit? {
    if let object = attachmentHit(at: point) { return object }
    if let anchor = tableAnchor(at: point) { return Hit(source: anchor, affinity: .downstream) }
    guard let (fragment, boundary) = hitIndex(at: point), let byte = byte(forUnit:boundary) else { return nil }
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

  private func tableRegion(at point: CGPoint) -> (Table, TableRow, TableCell?)? {
    guard point.x.isFinite, point.y.isFinite,
          let table = tables.first(where: { point.y >= $0.rect.minY && point.y < $0.rect.maxY }),
          let row = table.rows.first(where: { point.y >= $0.rect.minY && point.y < $0.rect.maxY }) else { return nil }
    let cell = row.cells.first(where: { point.x >= $0.rect.minX && point.x < $0.rect.maxX })
      ?? row.cells.min(by: { abs($0.rect.midX - point.x) < abs($1.rect.midX - point.x) })
    return (table, row, cell)
  }

  private func tableAnchor(at point: CGPoint) -> Int? {
    guard let (_, row, cell) = tableRegion(at: point), let cell else { return nil }
    if cell.missing { return row.contentEnd }
    return cell.display?.length == 0 ? cell.source?.lowerBound : nil
  }

  private func hitIndex(at point: CGPoint) -> (Fragment, Int)? {
    guard point.x.isFinite, point.y.isFinite else { return nil }
    let candidates: [Fragment]
    if let (table, row, cell) = tableRegion(at: point) {
      candidates = fragments.filter { $0.table?.table == table.source.lowerBound && $0.table?.row == row.source && $0.table?.column == cell?.column }
    } else { candidates = fragments }
    func distance(_ rect: CGRect) -> CGFloat { max(0, rect.minY - point.y, point.y - rect.maxY) }
    guard let fragment = candidates.min(by: { distance($0.rect) < distance($1.rect) }) else { return nil }
    let x = point.x - fragment.rect.minX
    let raw = fragment.shaped.index(at:CGPoint(x:x,y:0))
    let index = min(fragment.contentEnd, max(fragment.range.location, raw == kCFNotFound ? fragment.contentEnd : raw))
    var boundary = index
    if index < string.length {
      let grapheme = string.rangeOfComposedCharacterSequence(at: index)
      if index != grapheme.location {
        let left = fragment.shaped.offset(for:grapheme.location)
        let right = fragment.shaped.offset(for:NSMaxRange(grapheme))
        boundary = abs(x - left) <= abs(x - right) ? grapheme.location : NSMaxRange(grapheme)
      }
    }
    return (fragment, boundary)
  }

  public func hitUTF16(at point: CGPoint) -> Int? {
    if let anchor = tableAnchor(at: point) { return utf16Position(for: anchor) }
    return hitIndex(at: point)?.1
  }

  /// Caret geometry from the same shaped lines that supply hit testing. The
  /// affinity selects the visible side of a soft-wrap boundary.
  public func caret(for source: Int, affinity: ComposeProjection.Affinity = .downstream) -> CGRect? {
    guard let index = utf16Position(for: source, affinity: affinity) else { return nil }
    return caret(atUTF16: index, affinity: affinity)
  }

  public func utf16Position(for source: Int, affinity: ComposeProjection.Affinity = .downstream) -> Int? {
    projection.displayPosition(for: source, affinity: affinity).flatMap { unit(forByte:$0) }
  }

  /// AppKit ranges address this projection's UTF-16 context. A replacement
  /// stays inside adjacent hidden markup; a collapsed current caret retains
  /// its real source position instead of guessing a side of that markup.
  public func sourceRange(forUTF16 range: NSRange, insertion: Int? = nil) -> Range<Int>? {
    guard range.location >= 0, range.location <= string.length, range.length >= 0,
          range.length <= string.length - range.location,
          let a = byte(forUnit:range.location), let b = byte(forUnit:NSMaxRange(range)) else { return nil }
    return projection.sourceRange(forDisplayBytes: a..<b, insertion: insertion)
  }

  public func caret(atUTF16 position: Int, affinity: ComposeProjection.Affinity = .downstream) -> CGRect? {
    guard let (fragment, index) = caretFragment(atUTF16: position, affinity: affinity) else { return nil }
    let x = fragment.rect.minX + fragment.shaped.offset(for:index)
    return CGRect(x: x, y: fragment.rect.minY, width: 1, height: fragment.rect.height)
  }

  private func caretFragment(atUTF16 position: Int, affinity: ComposeProjection.Affinity = .downstream) -> (Fragment, Int)? {
    guard byte(forUnit:position) != nil else { return nil }
    var index = position
    var matches = fragments.filter { index >= $0.range.location && index <= $0.contentEnd }
    if matches.isEmpty, let ending = fragments.first(where: { index > $0.contentEnd && index < NSMaxRange($0.range) }) {
      index = ending.contentEnd
      matches = [ending]
    }
    guard let fragment = affinity == .upstream ? matches.first : matches.last else { return nil }
    return (fragment, index)
  }

  public func firstRect(forUTF16 range: NSRange) -> (rect: CGRect, range: NSRange)? {
    guard range.location >= 0, range.length >= 0, range.location <= string.length,
          range.length <= string.length - range.location, byte(forUnit:NSMaxRange(range)) != nil,
          let (fragment, _) = caretFragment(atUTF16: range.location) else { return nil }
    let start = min(range.location, fragment.contentEnd), end = max(start, min(NSMaxRange(range), fragment.contentEnd))
    let a = fragment.shaped.offset(for:start), b = fragment.shaped.offset(for:end)
    return (CGRect(x: fragment.rect.minX + min(a, b), y: fragment.rect.minY, width: max(1, abs(b-a)), height: fragment.rect.height),
      NSRange(location: start, length: end-start))
  }

  /// Selection geometry in layout coordinates. Concealed syntax stays in the
  /// source selection while the visible part uses the very same shaped lines
  /// as the caret and text. A selected line ending extends to the line edge.
  public func selectionRects(for source: Range<Int>) -> [CGRect] {
    guard !source.isEmpty,
          let start = projection.displayPosition(for: max(source.lowerBound, projection.source.lowerBound), affinity: .downstream),
          let end = projection.displayPosition(for: min(source.upperBound, projection.source.upperBound), affinity: .upstream),
          let a = unit(forByte:start), let b = unit(forByte:end), a <= b else { return [] }
    return selectionRects(forUTF16: NSRange(location: a, length: b - a))
  }

  public func selectionRects(forUTF16 range: NSRange) -> [CGRect] {
    guard range.location >= 0, range.length >= 0, range.location <= string.length,
          range.length <= string.length - range.location,
          byte(forUnit:range.location) != nil, byte(forUnit:NSMaxRange(range)) != nil else { return [] }
    let a = range.location, b = NSMaxRange(range)
    return fragments.compactMap { fragment in
      let from = max(a, fragment.range.location)
      let to = min(b, fragment.contentEnd)
      let newline = b > fragment.contentEnd && b >= NSMaxRange(fragment.range)
      guard from < to || (newline && from <= fragment.contentEnd) else { return nil }
      let x0 = fragment.rect.minX + fragment.shaped.offset(for:from)
      let x1 = newline ? fragment.rect.maxX : fragment.rect.minX + fragment.shaped.offset(for:to)
      return CGRect(x: min(x0, x1), y: fragment.rect.minY, width: max(1, abs(x1 - x0)), height: fragment.rect.height)
    }
  }
}
