import Foundation
import CoreText
import CoreGraphics

/// A pane's native typography and source map. The Markdown decisions arrive
/// from Fresh; this object resolves semantic roles to measured font runs.
public final class ComposePaneLayout {
  public let pane: WireComposePane
  public let text: ComposeTextLayout
  public let links: [ComposeLink]
  private let linkRanges: ComposeIntervalIndex
  private let body, monospace: CTFont
  /// The wrapping measure; complete glyphs and cells can expose a wider extent.
  public let width: CGFloat
  private let typography: ComposeTypography
  private let images: [UInt64: ComposeImageState]
  private let imageSizes: [Int: CGSize]
  private let tableModel: ComposeTableModel
  private struct CodeBlock { var source, display: Range<Int>; var indent: CGFloat }
  private var codeBlocks: [CodeBlock] = []
  private static let codePadding: CGFloat = 8
  public let preedit: ComposeMarkedText?
  public let draftDisplayRange: NSRange?
  public let composition: ComposeComposition?
  public let draftDisplayRanges: [UInt64: NSRange]
  public let virtualInsertion: ComposeVirtualInsertion?
  private let contextDisplayRanges: [UInt64: NSRange]
  let maximumAuxiliaryContextUnits: Int

  public init?(pane: WireComposePane, body: CTFont, monospace: CTFont, width: CGFloat,
               typography: ComposeTypography = .init(),
               images: [UInt64: ComposeImageState] = [:], reuse: ComposePaneLayout? = nil,
               sharingMeasurementsWith peers: [ComposePaneLayout] = [],
               measuredBase: ComposePaneLayout? = nil,
               preedit: ComposeMarkedText? = nil, composition: ComposeComposition? = nil, virtualInsertion: ComposeVirtualInsertion? = nil,
               measurement: ComposeTextLayout.MeasurementOptions? = nil, record: ((ComposeTextLayout.Fragment)->Bool)? = nil) {
    guard typography.isValid, width.isFinite, width > 0,
          let sourceStart = Int(exactly: pane.sourceStart), let sourceEnd = Int(exactly: pane.sourceEnd), sourceStart <= sourceEnd else { return nil }
    guard pane.images.allSatisfy({ !($0.rendered && $0.sourcePreview) }) else { return nil }
    // Complete table samples and offscreen list markers are shaped before the
    // main text layout. Admit them before either a cache miss or a cache hit;
    // a previously measured sample cannot bypass this generation's budget.
    var auxiliaryUnits = 0
    if let measurement {
      guard measurement.maximumContextUnits > 0, measurement.maximumCoordinates > 0,
            measurement.maximumFragments > 0 else { return nil }
      for context in pane.hangingContexts {
        let units = context.text.utf16.count
        guard units <= measurement.maximumContextUnits else { return nil }
        auxiliaryUnits = max(auxiliaryUnits, units)
      }
      for table in pane.tables where table.hasMeasurement {
        for column in table.measurement.columns {
          for sample in column.samples {
            let units = sample.text.utf16.count
            guard units <= measurement.maximumContextUnits else { return nil }
            auxiliaryUnits = max(auxiliaryUnits, units)
          }
        }
      }
    }
    maximumAuxiliaryContextUnits = auxiliaryUnits
    let composition = composition ?? preedit.flatMap { ComposeComposition(primary: 0, values: [0: $0]) }
    let preedit = composition?.primary
    self.composition = composition; self.preedit = preedit; self.virtualInsertion = virtualInsertion
    let sourceComposition = virtualInsertion?.regions ?? composition
    let linkEdits = sourceComposition?.values.values.filter { !$0.source.isEmpty || $0.draft.length > 0 }.map(\.source) ?? []
    let visible = pane.images.filter { image in
      guard image.rendered || image.sourcePreview else { return false }
      guard let sourceComposition else { return true }
      return !sourceComposition.values.values.contains { value in
        guard !value.source.isEmpty || value.draft.length > 0 else { return false }
        return value.source.overlaps(Int(image.start)..<Int(image.end))
          || (value.source.isEmpty && Int(image.start) < value.source.lowerBound && value.source.lowerBound < Int(image.end))
      }
    }
    var sourceRanges: [Range<Int>] = [], sizes: [Int: CGSize] = [:]
    for image in visible {
      guard let start = Int(exactly: image.start), let end = Int(exactly: image.end), start < end,
            start >= sourceStart, end <= sourceEnd else { return nil }
      if image.rendered { sourceRanges.append(start..<end) }
      let containers = pane.spans.filter { ($0.role == 9 || $0.role == 10) && $0.start <= image.start && image.start < $0.end }.count
      let available = width - min(CGFloat(containers) * typography.indent, width * 0.6)
      var size = (images[image.start] ?? .loading).size(body: CTFontGetSize(body),
        width: image.sourcePreview ? min(360, available) : available, block: image.block || image.sourcePreview)
      if image.sourcePreview, size.height > 240 {
        size.width *= 240 / size.height; size.height = 240
      }
      sizes[start] = size
    }
    self.pane = pane; self.body = body; self.monospace = monospace
    self.width = width; self.typography = typography; self.images = images; self.imageSizes = sizes
    // Geometry depends on literal content and measured inputs, not scene
    // revisions or caret/marked-clause selection. A queued event can retain
    // its measured base while the visible pane already shows a draft. Check
    // that explicit base with the same complete validation. Split peers share
    // table measurements, but retain their own complete text layouts.
    // Virtual insertion has additional placement maps and uses the full path.
    for reuse in (reuse.map { [$0] } ?? []) + (measuredBase.map { [$0] } ?? []) {
      guard measurement == nil,reuse.text.measurementUsage.retainedGlyphs else {continue}
      let sameComposition: Bool
      switch (composition, reuse.composition) {
      case (nil, nil): sameComposition = true
      case (.some(let a), .some(let b)): sameComposition = a.hasSameLayout(as: b)
      default: sameComposition = false
      }
      guard sameComposition, virtualInsertion == nil, reuse.virtualInsertion == nil,
       pane.sourceStart == reuse.pane.sourceStart, pane.sourceEnd == reuse.pane.sourceEnd,
       pane.documentLen == reuse.pane.documentLen,
       pane.assetAuthority == reuse.pane.assetAuthority, pane.assetDocument == reuse.pane.assetDocument,
       pane.text.utf8.elementsEqual(reuse.pane.text.utf8), pane.segments == reuse.pane.segments,
       Self.sameTypography(pane.spans, reuse.pane.spans), pane.images == reuse.pane.images, pane.tables == reuse.pane.tables,
       pane.hangingContexts == reuse.pane.hangingContexts, sizes == reuse.imageSizes,
       width == reuse.width, typography == reuse.typography,
       CFEqual(body, reuse.body), CFEqual(monospace, reuse.monospace) else { continue }
      tableModel = reuse.tableModel; text = reuse.text
      links = ComposeLink.resolving(pane, text: reuse.text, excluding: linkEdits)
      linkRanges = ComposeIntervalIndex(links.map { $0.range.location..<NSMaxRange($0.range) })
      contextDisplayRanges = reuse.contextDisplayRanges; draftDisplayRanges = reuse.draftDisplayRanges
      draftDisplayRange = reuse.draftDisplayRange
      quoteRails = reuse.quoteRails; thematicRules = reuse.thematicRules
      codeBlocks = reuse.codeBlocks; codeFrames = reuse.codeFrames
      return
    }
    guard let baseProjection = ComposeProjection(pane) else { return nil }
    let items = Dictionary(grouping: pane.spans.filter { $0.role == 13 }, by: \.start)
    var hangingContexts: [UInt64: ComposeHangingContext] = [:]
    for wire in pane.hangingContexts {
      guard hangingContexts[wire.itemStart] == nil, let owners = items[wire.itemStart], owners.count == 1,
            let context = ComposeHangingContext(wire, item: owners[0]) else { return nil }
      hangingContexts[wire.itemStart] = context
    }
    let objects = baseProjection.replacingObjects(sourceRanges)
    let base = objects?.projection ?? baseProjection
    guard let tableModel = ComposeTableModel(pane: pane, projection: base, reuse: reuse?.tableModel,
      sharingMeasurementsWith: peers.map(\.tableModel)) else { return nil }
    self.tableModel = tableModel
    let layered = virtualInsertion?.projected(over: base)
    let replacement: (projection: ComposeProjection, displays: [UInt64: Range<Int>])? = layered.map { ($0.projection, $0.drafts) }
      ?? (virtualInsertion == nil ? composition?.project(over: base) : nil)
    let sourceDisplays = layered?.contexts ?? replacement?.displays ?? [:]
    guard preedit == nil || replacement != nil else { return nil }
    let projection = replacement?.projection ?? base
    let drafts = sourceDisplays.compactMap { id, display -> (source: Range<Int>, display: Range<Int>)? in
      sourceComposition?.values[id].flatMap { value in
        value.source.isEmpty && value.draft.length == 0 ? nil : (value.source, display)
      }
    }
    guard let tables = tableModel.remapping(to: projection, drafts: drafts) else { return nil }
    let displayBytes = Array(projection.text.utf8)
    let displayRanges = (replacement?.displays ?? [:]).mapValues {
      NSRange(location: String(decoding: displayBytes[..<$0.lowerBound], as: UTF8.self).utf16.count,
        length: String(decoding: displayBytes[$0], as: UTF8.self).utf16.count)
    }
    contextDisplayRanges = sourceDisplays.mapValues {
      NSRange(location: String(decoding: displayBytes[..<$0.lowerBound], as: UTF8.self).utf16.count,
        length: String(decoding: displayBytes[$0], as: UTF8.self).utf16.count)
    }
    draftDisplayRanges = displayRanges
    draftDisplayRange = composition.flatMap { displayRanges[$0.primaryID] }
    var attachments = (objects?.objects ?? []).compactMap { object -> ComposeTextLayout.Attachment? in
      guard let size = sizes[object.source.lowerBound],
            let a = projection.displayPosition(for: object.source.lowerBound),
            let b = projection.displayPosition(for: object.source.upperBound, affinity: .upstream), a < b else { return nil }
      return .init(source: object.source, display: a..<b, size: size)
    }
    for image in visible where image.sourcePreview {
      let source = Int(image.start)..<Int(image.end)
      guard projection.segments.allSatisfy({ segment in
        let inside = segment.source.overlaps(source) || (segment.source.isEmpty
          && source.lowerBound < segment.source.lowerBound && segment.source.lowerBound < source.upperBound)
        return !inside || segment.kind == .copy
      }) else { return nil }
      guard let start = projection.displayPosition(for: source.lowerBound, affinity: .downstream),
            let end = projection.displayPosition(for: source.upperBound, affinity: .upstream), start < end,
            let size = sizes[source.lowerBound] else { return nil }
      attachments.append(.init(source: source, display: start..<end, size: size, preview: true))
    }
    struct Span { var source, range: Range<Int>; var role, flags: UInt32 }
    var spans: [Span] = []
    for span in pane.spans {
      guard let a = Int(exactly: span.start), let b = Int(exactly: span.end), a <= b else { return nil }
      let from = max(a, projection.source.lowerBound), to = min(b, projection.source.upperBound)
      guard from < to,
            let start = projection.displayPosition(for: from, affinity: .downstream),
            let end = projection.displayPosition(for: to, affinity: .upstream), start < end else { continue }
      spans.append(Span(source: a..<b, range: start..<end, role: span.role, flags: span.flags))
    }
    // Image markup remains ordinary source, styled as code while it is edited.
    for attachment in attachments where attachment.preview {
      spans.append(.init(source: attachment.source, range: attachment.display, role: 7, flags: 0))
    }
    for table in tables {
      for row in table.rows where !row.display.isEmpty {
        if row.raw { spans.append(.init(source: row.source, range: row.display, role: 7, flags: 0)) }
        else if row.header { spans.append(.init(source: row.source, range: row.display, role: 0, flags: 1)) }
      }
    }
    let boundaries = Set([0, projection.text.utf8.count] + spans.flatMap { [$0.range.lowerBound, $0.range.upperBound] }).sorted()
    let styleIndex = ComposeIntervalIndex(spans.map(\.range))
    var fonts: [ComposeTextLayout.FontRun] = []
    struct FontKey: Hashable { let mono: Bool; let size: CGFloat; let traits: UInt32 }
    var fontCache: [FontKey: CTFont] = [:]
    func fontRun(_ active: [Span], _ range: Range<Int>) -> ComposeTextLayout.FontRun {
      let heading = active.map(\.role).filter { (1...6).contains($0) }.min()
      let flags = active.reduce(UInt32(0)) { $0 | $1.flags }
      let mono = active.contains { span in
        span.role == 7 || span.role == 12 || (span.role == 8 && !tables.contains { $0.source.overlaps(span.source) })
      }
      let pointSize = CTFontGetSize(body) * (heading.map { typography.headingScales[Int($0) - 1] } ?? 1)
      var traits: CTFontSymbolicTraits = []
      if heading != nil || flags & 1 != 0 { traits.insert(.traitBold) }
      if flags & 2 != 0 { traits.insert(.traitItalic) }
      let key = FontKey(mono: mono, size: pointSize, traits: traits.rawValue)
      let font: CTFont
      if let cached = fontCache[key] { font = cached }
      else {
        let base = CTFontCreateCopyWithAttributes(mono ? monospace : body, pointSize, nil, nil)
        font = CTFontCreateCopyWithSymbolicTraits(base, pointSize, nil, traits, [.traitBold, .traitItalic]) ?? base
        fontCache[key] = font
      }
      let role: UInt32 = heading ?? (active.contains { $0.role == 12 } ? 12 : mono ? 7 : active.contains { $0.role == 9 } ? 9 : 0)
      return .init(display: range, font: font, role: role, flags: flags)
    }
    func prefixWidth(_ context: ComposeHangingContext) -> CGFloat? {
      let wire = context.wire, bytes = Array(context.wire.text.utf8)
      let value = NSMutableAttributedString(string: wire.text,
        attributes: [NSAttributedString.Key(kCTFontAttributeName as String): body])
      let styles = wire.spans.map { Span(source: 0..<0, range: Int($0.start)..<Int($0.end), role: $0.role, flags: $0.flags) }
      let edges = Set([0, bytes.count] + styles.flatMap { [$0.range.lowerBound, $0.range.upperBound] }).sorted()
      for (a, b) in zip(edges, edges.dropFirst()) where a < b {
        let font = fontRun(styles.filter { $0.range.contains(a) }, a..<b).font
        let from = String(decoding: bytes[..<a], as: UTF8.self).utf16.count
        let count = String(decoding: bytes[a..<b], as: UTF8.self).utf16.count
        value.addAttribute(NSAttributedString.Key(kCTFontAttributeName as String), value: font,
          range: NSRange(location: from, length: count))
      }
      guard let line = ComposeShaping.line(value) else { return nil }
      return ComposeTextLayout.hangingPrefixWidth(line, start: 0, content: context.prefixUTF16)
    }
    for (start, end) in zip(boundaries, boundaries.dropFirst()) where start < end {
      fonts.append(fontRun(styleIndex.matches(at: start).map { spans[$0] }, start..<end))
    }
    if let sourceComposition {
      for (id, display) in sourceDisplays where !display.isEmpty {
        let value = sourceComposition.values[id]!
        fonts.append(fontRun(spans.filter { $0.source.lowerBound <= value.source.lowerBound && value.source.lowerBound <= $0.source.upperBound }, display))
      }
    }
    // Quote geometry is a fallback for empty/code-only lines; an equally
    // sized actual paragraph keeps its own spacing and layout precedence.
    let blocks = spans.filter { (1...6).contains($0.role) || [8, 11, 12, 13].contains($0.role) }
      + spans.filter { $0.role == 9 }
    var codeGeometry: [CodeBlock] = []
    let paragraphs = blocks.compactMap { block -> ComposeTextLayout.ParagraphRun? in
      let containers = styleIndex.matches(at: block.range.lowerBound).filter { spans[$0].role == 9 || spans[$0].role == 10 }.count
      let heading = (1...6).contains(block.role)
      let code = block.role == 12, padding = code ? Self.codePadding : 0
      let indent = code ? min(CGFloat(containers) * typography.indent, max(0, width * 0.6 - padding)) : CGFloat(containers) * typography.indent
      var range = block.range
      if code {
        // A semantic block can begin after a list marker on its first line.
        // Keep that preceding text outside the block's frame and paragraph.
        let start = displayBytes[..<range.lowerBound].lastIndex(where: { $0 == 10 || $0 == 13 }).map { $0 + 1 } ?? 0
        if !String(decoding: displayBytes[start..<range.lowerBound], as: UTF8.self).trimmingCharacters(in: .whitespaces).isEmpty,
           let newline = displayBytes[range].firstIndex(where: { $0 == 10 || $0 == 13 }) {
          let next = newline + (displayBytes[newline] == 13 && displayBytes.indices.contains(newline + 1) && displayBytes[newline + 1] == 10 ? 2 : 1)
          if next < range.upperBound { range = next..<range.upperBound }
        }
        codeGeometry.append(.init(source: block.source, display: range, indent: indent))
      }
      let before = heading ? CTFontGetSize(body) * 0.45 : code ? typography.paragraphSpacing + padding : 0
      let after = [9, 13].contains(block.role) ? 0 : typography.paragraphSpacing + padding
      return ComposeTextLayout.ParagraphRun(display: range, indent: indent + padding, trailing: padding,
        before: block.source.lowerBound >= projection.source.lowerBound ? before : 0,
        after: block.source.upperBound <= projection.source.upperBound ? after : 0, verbatim: code)
    }
    codeBlocks = codeGeometry
    let bytes = Array(projection.text.utf8)
    var hanging: [ComposeTextLayout.HangingRun] = []
    for item in pane.spans where item.role == 13 && item.hasContentStart {
      guard item.start <= item.contentStart, item.contentStart < item.end else { return nil }
      if item.contentStart <= pane.sourceStart, item.start < pane.sourceStart,
         let context = hangingContexts[item.start],
         let end = projection.displayPosition(for: min(Int(item.end), projection.source.upperBound), affinity: .upstream), end > 0 {
        let containers = pane.spans.filter { ($0.role == 9 || $0.role == 10) && $0.start <= item.contentStart && item.contentStart < $0.end }.count
        guard let measuredPrefix = prefixWidth(context) else { return nil }
        hanging.append(.init(display: 0..<end, contentStart: 0, indent: CGFloat(containers) * typography.indent,
          measuredPrefix: measuredPrefix, physicalStart: context.wire.sourceLineStart))
        continue
      }
      // Older producers omit offscreen marker samples. Preserve that behavior
      // rather than measuring a partial prefix as a complete list marker.
      guard item.start >= pane.sourceStart, item.contentStart >= pane.sourceStart,
            item.contentStart < pane.sourceEnd,
            let source = Int(exactly: item.start), let content = Int(exactly: item.contentStart),
            let start = projection.displayPosition(for: source, affinity: .downstream),
            let bodyStart = projection.displayPosition(for: content, affinity: .downstream),
            let end = projection.displayPosition(for: min(Int(item.end), projection.source.upperBound), affinity: .upstream),
            bodyStart < end else { continue }
      let lineStart = bytes[..<start].lastIndex(where: { $0 == 10 || $0 == 13 }).map { $0 + 1 } ?? 0
      guard !bytes[lineStart..<bodyStart].contains(where: { $0 == 10 || $0 == 13 }) else { continue }
      let containers = pane.spans.filter { ($0.role == 9 || $0.role == 10) && $0.start <= item.contentStart && item.contentStart < $0.end }.count
      hanging.append(.init(display: lineStart..<end, contentStart: bodyStart, indent: CGFloat(containers) * typography.indent))
    }
    let tableRuns = tables.map { table in
      let containers = pane.spans.filter { ($0.role == 9 || $0.role == 10) && $0.start <= table.source.lowerBound && table.source.lowerBound < $0.end }.count
      let indent = min(CGFloat(containers) * typography.indent, width * 0.6)
      var columns: [CGFloat]? = nil
      if let measurement = table.measurement {
        // The validated object owns its intrinsic font cache. An ID alone
        // cannot certify old columns when the supplied content has changed.
        columns = measurement.widths(body: body, monospace: monospace, available: max(1, width - indent))
      }
      return ComposeTextLayout.TableRun(table: table, indent: CGFloat(containers) * typography.indent,
        before: table.source.lowerBound >= projection.source.lowerBound ? typography.paragraphSpacing : 0,
        after: table.source.upperBound <= projection.source.upperBound ? typography.paragraphSpacing : 0,
        columns: columns, adaptiveMinimum: composition != nil)
    }
    guard let layout = ComposeTextLayout(projection: projection, font: body, width: width,
      lineSpacing: typography.lineSpacing, fonts: fonts, attachments: attachments, paragraphs: paragraphs, hanging: hanging, tables: tableRuns,
      measurement:measurement,record:record) else { return nil }
    text = layout
    links = ComposeLink.resolving(pane, text: layout, excluding: linkEdits)
    linkRanges = ComposeIntervalIndex(links.map { $0.range.location..<NSMaxRange($0.range) })
  }

  public func link(atUTF16 position: Int) -> ComposeLink? {
    let matches = linkRanges.matches(at: position)
    // Ambiguous overlapping metadata cannot choose a different destination.
    return matches.count == 1 ? links[matches[0]] : nil
  }

  private static func sameTypography(_ lhs: [WireComposeSpan], _ rhs: [WireComposeSpan]) -> Bool {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { a, b in
      a.start == b.start && a.end == b.end && a.role == b.role && a.flags == b.flags
        && a.hasContentStart == b.hasContentStart && a.contentStart == b.contentStart
    }
  }

  func matchesMeasurement(body:CTFont,monospace:CTFont,width:CGFloat,typography:ComposeTypography,imageSizes:[UInt64:CGSize]) -> Bool {
    guard self.width==width,self.typography==typography,CFEqual(self.body,body),CFEqual(self.monospace,monospace) else {return false}
    for image in pane.images where image.rendered || image.sourcePreview {
      let state=images[image.start] ?? .loading
      let actual:CGSize?
      if case .deferred(let size)=state {actual=size} else {actual=state.asset?.originalSize}
      guard actual==imageSizes[image.start] else {return false}
    }
    return true
  }

  public func measurementEnvironment(images:[UInt64:ComposeImageState]?=nil) -> ComposeFlowMeasurement.Environment {
    .init(body:body,monospace:monospace,width:width,typography:typography,images:images ?? self.images)
  }

  public struct Palette {
    public var link, quote, code, codeBackground: CGColor
    public init(link: CGColor, quote: CGColor, code: CGColor, codeBackground: CGColor) {
      self.link = link; self.quote = quote; self.code = code; self.codeBackground = codeBackground
    }
  }

  public func imageDescription(_ image: WireComposeImage) -> String {
    let label = image.alt.isEmpty ? "Image" : image.alt
    let state = images[image.start] ?? .loading
    let message: String
    switch state {
    case .loading: message = "\(label): loading"
    case .deferred: message = "\(label): preview memory limit reached"
    case .failed(let error): message = "\(label): \(error)"
    case .stale(_, let error): message = "\(label): showing the last preview; \(error)"
    case .ready: message = image.title.isEmpty ? label : "\(label): \(image.title)"
    }
    return String(message.prefix(512))
  }

  /// Native block ornaments are measured rectangles, never repeated glyphs.
  /// Their source ranges still belong to Fresh for selection and editing.
  public private(set) lazy var quoteRails: [CGRect] = {
    pane.spans.filter { $0.role == 9 }.compactMap { quote in
      guard let start = Int(exactly: quote.start), let end = Int(exactly: quote.end), start < end else { return nil }
      let source = start..<end
      let rows = text.selectionRects(for: source)
      let assets = text.attachments.filter { $0.attachment.source.overlaps(source) }.map(\.rect)
      let code = codeFrames.filter { $0.source.overlaps(source) }.map(\.rect)
      let tables = text.tables.filter { $0.source.overlaps(source) }.map(\.rect)
      guard let top = (rows + assets + code + tables).map(\.minY).min(), let bottom = (rows + assets + code + tables).map(\.maxY).max() else { return nil }
      let containers = pane.spans.filter { ($0.role == 9 || $0.role == 10) && $0.start <= quote.start && quote.start < $0.end }.count
      return CGRect(x: min(CGFloat(containers) * typography.indent, width * 0.6) - 10,
        y: top, width: 2, height: bottom - top)
    }
  }()

  public struct Rule {
    public let source: Range<Int>
    public let rect: CGRect
  }
  public private(set) lazy var thematicRules: [Rule] = {
    pane.spans.filter { $0.role == 14 }.compactMap { rule in
      guard let start = Int(exactly: rule.start), let end = Int(exactly: rule.end), start < end,
            start >= text.projection.source.lowerBound, end <= text.projection.source.upperBound else { return nil }
      let segments = text.projection.segments.filter { $0.source.overlaps(start..<end) }
      guard !segments.isEmpty, segments.allSatisfy({ $0.kind == .hidden }), let caret = text.caret(for: start) else { return nil }
      let containers = pane.spans.filter { ($0.role == 9 || $0.role == 10) && $0.start <= rule.start && rule.start < $0.end }.count
      let left = min(width, max(caret.minX, min(CGFloat(containers) * typography.indent, width * 0.6)))
      return Rule(source: start..<end, rect: CGRect(x: left, y: caret.midY, width: width - left, height: 1))
    }
  }()

  public struct CodeFrame {
    public let source: Range<Int>
    public let rect: CGRect
    public let hasStart, hasEnd: Bool
  }

  public private(set) lazy var codeFrames: [CodeFrame] = {
    let bytes = Array(text.projection.text.utf8)
    return codeBlocks.compactMap { block in
      let start = String(decoding: bytes[..<block.display.lowerBound], as: UTF8.self).utf16.count
      let end = start + String(decoding: bytes[block.display], as: UTF8.self).utf16.count
      let rows = text.fragments.filter { $0.range.location < end && NSMaxRange($0.range) > start }
      guard let first = rows.first, let last = rows.last else { return nil }
      let hasStart = block.source.lowerBound >= text.projection.source.lowerBound
      let hasEnd = block.source.upperBound <= text.projection.source.upperBound
      let left = min(block.indent, width * 0.6)
      let top = first.rect.minY - (hasStart ? Self.codePadding : 0)
      let bottom = last.rect.maxY + (hasEnd ? Self.codePadding : 0)
      return CodeFrame(source: block.source, rect: CGRect(x: left, y: top, width: width - left, height: bottom - top), hasStart: hasStart, hasEnd: hasEnd)
    }
  }()

  /// Draw in a context whose y axis points down, using the same line objects
  /// as hit testing and navigation. The native view and rendering tests share
  /// this path; no cell approximation or second text layout is involved.
  public func containsProvisionalRegion(displayPosition: Int) -> Bool {
    let regions = virtualInsertion?.regions ?? composition
    return contextDisplayRanges.contains { id, range in
      guard let value = regions?.values[id], !value.source.isEmpty || value.draft.length > 0 else { return false }
      return range.location <= displayPosition && displayPosition <= NSMaxRange(range)
    }
  }

  public func provisionalDisplayPosition(_ position: Int) -> Int? {
    guard let regions = virtualInsertion?.regions ?? composition else { return nil }
    if let point = regions.draftPosition(at: position) {
      return contextDisplayRanges[point.id].map { $0.location + point.offset }
    }
    guard let source = regions.sourcePosition(at: position) else { return nil }
    return text.utf16Position(for: source)
  }

  public func provisionalDocumentPosition(_ display: Int) -> Int? {
    guard let regions = virtualInsertion?.regions ?? composition else { return nil }
    for id in [regions.primaryID] + regions.ordered.filter({ $0 != regions.primaryID }) {
      if let range = contextDisplayRanges[id], range.location <= display && display <= NSMaxRange(range) {
        return regions.virtualStart(for: id) + display - range.location
      }
    }
    guard let source = text.sourceRange(forUTF16: NSRange(location: display, length: 0)) else { return nil }
    return regions.virtualPosition(for: source.lowerBound)
  }

  public func draw(in context: CGContext, origin: CGPoint, clip: CGRect, dirty: CGRect,
                   foreground: CGColor, background: CGColor, selection: CGColor, palette: Palette? = nil, provisionalSelections: [NSRange]? = nil) {
    guard clip.intersects(dirty) else { return }
    context.saveGState()
    defer { context.restoreGState() }
    context.clip(to: clip)
    context.setFillColor(background)
    context.fill(clip)
    let palette = palette ?? Palette(link: foreground, quote: foreground, code: foreground,
      codeBackground: foreground.copy(alpha: 0.07) ?? foreground)
    for table in text.tables {
      let rect = table.rect.offsetBy(dx: origin.x, dy: origin.y)
      guard rect.intersects(clip.intersection(dirty)) else { continue }
      context.setLineWidth(1)
      context.setStrokeColor(foreground.copy(alpha: 0.25) ?? foreground)
      context.move(to: CGPoint(x: rect.minX, y: rect.minY)); context.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
      context.move(to: CGPoint(x: rect.maxX, y: rect.minY)); context.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
      if table.source.lowerBound >= text.projection.source.lowerBound {
        context.move(to: CGPoint(x: rect.minX, y: rect.minY)); context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
      }
      for (index, row) in table.rows.enumerated() {
        let bounds = row.rect.offsetBy(dx: origin.x, dy: origin.y)
        if row.header || row.raw {
          context.setFillColor(row.raw ? palette.codeBackground : foreground.copy(alpha: 0.05) ?? foreground)
          context.fill(bounds)
        }
        for cell in row.cells.dropFirst() {
          let x = origin.x + cell.rect.minX
          context.move(to: CGPoint(x: x, y: bounds.minY)); context.addLine(to: CGPoint(x: x, y: bounds.maxY))
        }
        if index + 1 < table.rows.count || table.source.upperBound <= text.projection.source.upperBound {
          context.move(to: CGPoint(x: bounds.minX, y: bounds.maxY)); context.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY))
        }
      }
      context.strokePath()
    }
    for frame in codeFrames {
      let rect = frame.rect.offsetBy(dx: origin.x, dy: origin.y)
      guard rect.intersects(clip.intersection(dirty)) else { continue }
      context.setFillColor(palette.codeBackground)
      context.setStrokeColor(palette.code.copy(alpha: 0.25) ?? palette.code)
      context.setLineWidth(1)
      if frame.hasStart && frame.hasEnd {
        let path = CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 5, cornerHeight: 5, transform: nil)
        context.addPath(path); context.drawPath(using: .fillStroke)
      } else {
        context.fill(rect)
        context.move(to: CGPoint(x: rect.minX + 0.5, y: rect.minY)); context.addLine(to: CGPoint(x: rect.minX + 0.5, y: rect.maxY))
        context.move(to: CGPoint(x: rect.maxX - 0.5, y: rect.minY)); context.addLine(to: CGPoint(x: rect.maxX - 0.5, y: rect.maxY))
        if frame.hasStart { context.move(to: CGPoint(x: rect.minX, y: rect.minY + 0.5)); context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 0.5)) }
        if frame.hasEnd { context.move(to: CGPoint(x: rect.minX, y: rect.maxY - 0.5)); context.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 0.5)) }
        context.strokePath()
      }
    }
    context.setFillColor(palette.quote.copy(alpha: 0.4) ?? palette.quote)
    for rect in quoteRails {
      context.fill(rect.offsetBy(dx: origin.x, dy: origin.y))
    }
    for rule in thematicRules {
      let selected = pane.cursors.contains { cursor in cursor.hasAnchor
        && min(cursor.position, cursor.anchor) < UInt64(rule.source.upperBound)
        && max(cursor.position, cursor.anchor) > UInt64(rule.source.lowerBound) }
      context.setFillColor(selected ? selection : palette.quote.copy(alpha: 0.4) ?? palette.quote)
      context.fill(rule.rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: 0, dy: selected ? -1 : 0))
    }
    func runRect(_ run: CTRun, _ fragment: ComposeTextLayout.Fragment) -> CGRect {
      let range = CTRunGetStringRange(run)
      let a = CTLineGetOffsetForStringIndex(fragment.line, range.location, nil)
      let b = CTLineGetOffsetForStringIndex(fragment.line, range.location + range.length, nil)
      return CGRect(x: origin.x + fragment.rect.minX + min(a, b), y: origin.y + fragment.rect.minY,
        width: max(1, abs(b - a)), height: fragment.rect.height)
    }
    // Code backgrounds precede selection, so selected source stays visible.
    for fragment in text.fragments where fragment.rect.offsetBy(dx: origin.x, dy: origin.y).intersects(clip.intersection(dirty)) {
      let runs = CTLineGetGlyphRuns(fragment.line) as! [CTRun]
      context.setFillColor(palette.codeBackground)
      for run in runs where (CTRunGetAttributes(run) as NSDictionary)[ComposeTextLayout.roleKey] as? UInt32 == 7 {
        context.fill(runRect(run, fragment))
      }
    }
    context.setFillColor(selection)
    for cursor in pane.cursors where provisionalSelections == nil && cursor.hasAnchor && composition?.values[cursor.id] == nil {
      guard let a = Int(exactly: cursor.position), let b = Int(exactly: cursor.anchor) else { continue }
      for rect in text.selectionRects(for: min(a, b)..<max(a, b)) {
        context.fill(rect.offsetBy(dx: origin.x, dy: origin.y))
      }
    }
    for (id, display) in draftDisplayRanges where provisionalSelections == nil {
      guard let value = composition?.values[id] else { continue }
      for rect in text.selectionRects(forUTF16: NSRange(location: display.location + value.selected.location, length: value.selected.length)) {
        context.fill(rect.offsetBy(dx: origin.x, dy: origin.y))
      }
    }
    for range in provisionalSelections ?? [] {
      guard let start = provisionalDisplayPosition(range.location), let end = provisionalDisplayPosition(NSMaxRange(range)), start <= end else { continue }
      for rect in text.selectionRects(forUTF16: NSRange(location: start, length: end - start)) { context.fill(rect.offsetBy(dx: origin.x, dy: origin.y)) }
    }
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    context.setFillColor(foreground)
    for fragment in text.fragments {
      let rect = fragment.rect.offsetBy(dx: origin.x, dy: origin.y)
      guard rect.intersects(clip), rect.intersects(dirty) else { continue }
      // Core Text can change the context's fill color while drawing a run.
      // Skip the replacement glyph and restore the run color before every
      // text run, including text following an attachment on the same line.
      for run in CTLineGetGlyphRuns(fragment.line) as! [CTRun] {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard attributes[ComposeTextLayout.attachmentKey] == nil else { continue }
        let role = attributes[ComposeTextLayout.roleKey] as? UInt32 ?? 0
        let flags = attributes[ComposeTextLayout.flagsKey] as? UInt32 ?? 0
        let color = flags & 16 != 0 ? palette.link : [7, 12].contains(role) ? palette.code : role == 9 ? palette.quote : foreground
        context.setFillColor(color)
        context.textPosition = CGPoint(x: origin.x + fragment.rect.minX, y: origin.y + fragment.baseline)
        CTRunDraw(run, context, CFRange(location: 0, length: 0))
        if flags & 12 != 0 {
          let font = attributes[kCTFontAttributeName] as! CTFont
          let rect = runRect(run, fragment)
          context.setFillColor(color)
          let thickness = max(1, CTFontGetUnderlineThickness(font))
          if flags & 4 != 0 {
            context.fill(CGRect(x: rect.minX, y: origin.y + fragment.baseline - CTFontGetUnderlinePosition(font), width: rect.width, height: thickness))
          }
          if flags & 8 != 0 {
            context.fill(CGRect(x: rect.minX, y: origin.y + fragment.baseline - CTFontGetXHeight(font) * 0.5, width: rect.width, height: thickness))
          }
        }
      }
    }
    for (id, display) in draftDisplayRanges {
      guard let value = composition?.values[id] else { continue }
      context.setFillColor(foreground)
      let marked = NSRange(location: display.location + value.marked.location, length: value.marked.length)
      for rect in text.selectionRects(forUTF16: marked) {
        context.fill(CGRect(x: origin.x + rect.minX, y: origin.y + rect.maxY - 1, width: rect.width, height: 1))
      }
    }
    for placed in text.attachments {
      let rect = placed.rect.offsetBy(dx: origin.x, dy: origin.y)
      let caption = CGRect(x: rect.minX, y: rect.minY - 18, width: rect.width, height: 18)
      let bounds = placed.attachment.preview ? rect.union(caption) : rect
      guard bounds.intersects(clip), bounds.intersects(dirty),
            let image = pane.images.first(where: { $0.start == UInt64(placed.attachment.source.lowerBound) }) else { continue }
      let state = images[image.start] ?? .loading
      context.saveGState()
      if placed.attachment.preview {
        context.setFillColor(foreground.copy(alpha: 0.65) ?? foreground)
        let font = CTFontCreateCopyWithAttributes(body, min(12, CTFontGetSize(body)), nil, nil)
        let label = ComposeShaping.line(NSAttributedString(string: "Preview", attributes: [
          NSAttributedString.Key(kCTFontAttributeName as String): font,
          NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]))
        context.saveGState(); context.clip(to: caption)
        context.textPosition = CGPoint(x: caption.minX, y: caption.minY + CTFontGetAscent(font) + 1)
        if let label { CTLineDraw(label, context) }; context.restoreGState()
      }
      context.clip(to: rect)
      if let asset = state.asset {
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(asset.image, in: CGRect(origin: .zero, size: rect.size))
      } else {
        context.setFillColor(foreground.copy(alpha: 0.08) ?? foreground)
        context.fill(rect)
        context.clip(to: rect.insetBy(dx: 4, dy: 2))
        context.setFillColor(foreground)
        let label: String
        if case .failed(let error) = state { label = "\(image.alt.isEmpty ? "Image" : image.alt): \(error)" }
        else if case .deferred = state { label = "\(image.alt.isEmpty ? "Image" : image.alt): preview memory limit reached" }
        else { label = "Loading \(image.alt.isEmpty ? "image" : image.alt)…" }
        let line = ComposeShaping.line(NSAttributedString(string: label, attributes: [
          NSAttributedString.Key(kCTFontAttributeName as String): body,
          NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]))
        context.textPosition = CGPoint(x: rect.minX + 6, y: rect.minY + 4 + CTFontGetAscent(body))
        if let line { CTLineDraw(line, context) }
      }
      context.restoreGState()
      if case .stale(_, let warning) = state {
        context.saveGState()
        context.clip(to: rect)
        if rect.width < 140 || rect.height < 48 {
          // A footer would obscure a small inline image. Keep its pixels and
          // show a compact warning; the tooltip carries the explanation.
          let badge = CGRect(x: rect.maxX - min(10, rect.width), y: rect.maxY - min(10, rect.height),
            width: min(10, rect.width), height: min(10, rect.height))
          context.setFillColor(background.copy(alpha: 0.95) ?? background); context.fillEllipse(in: badge)
          context.setStrokeColor(foreground); context.setLineWidth(1); context.strokeEllipse(in: badge.insetBy(dx: 0.5, dy: 0.5))
          context.setFillColor(foreground)
          context.fill(CGRect(x: badge.midX - 0.5, y: badge.minY + 2, width: 1, height: max(1, badge.height - 5)))
          context.fill(CGRect(x: badge.midX - 0.5, y: badge.maxY - 2, width: 1, height: 1))
        } else {
          let strip = CGRect(x: rect.minX, y: rect.maxY - 24, width: rect.width, height: 24)
          context.clip(to: strip)
          context.setFillColor(background.copy(alpha: 0.92) ?? background); context.fill(strip)
          context.setFillColor(foreground)
          let font = CTFontCreateCopyWithAttributes(body, min(12, CTFontGetSize(body)), nil, nil)
          let label = "Last preview: \(String(warning.prefix(160)))"
          let line = ComposeShaping.line(NSAttributedString(string: label, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
          ]))
          context.textPosition = CGPoint(x: strip.minX + 4, y: strip.minY + CTFontGetAscent(font) + 2)
          if let line { CTLineDraw(line, context) }
        }
        context.restoreGState()
      }
      if pane.cursors.contains(where: { cursor in
        cursor.hasAnchor && (placed.attachment.preview
          ? min(cursor.position, cursor.anchor) <= image.start && max(cursor.position, cursor.anchor) >= image.end
          : min(cursor.position, cursor.anchor) < image.end && max(cursor.position, cursor.anchor) > image.start)
      }) {
        context.setStrokeColor(selection)
        context.setLineWidth(2)
        context.stroke(rect.insetBy(dx: 1, dy: 1))
      }
    }
    context.textPosition = .zero
  }
}
