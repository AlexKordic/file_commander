import AppKit
import CoreText
import FreshKit

/// Drawing and hit testing for one rich pane. Fresh retains the buffer,
/// selections and undo history; this is an immutable scene presentation.
@MainActor
final class ComposePresentation: ComposeInputBasis {
  struct Identity: Equatable {
    var window, leaf, buffer: UInt64
  }
  let identity: Identity
  let pane: WirePane
  let layout: ComposePaneLayout
  let bounds: CGRect
  let origin: CGPoint
  let body: CTFont
  let viewport: WireComposeViewport
  let scrolling: ComposeViewport
  let textContext: ComposeTextContext?
  var measuredInputBase: ComposePresentation? { self }
  /// Selection feedback only; input measurements must use the backend snapshot.
  let pendingSelection: Bool
  let virtualSelections: ComposeVirtualSelections?
  private let caretStates: [UInt64: WireComposeCaret]
  private struct ImageSource: Hashable { let start, end: UInt64 }
  private let imageStarts: [UInt64: Int]
  private let imageSources: [ImageSource: Int]
  private let attachmentSources: [ImageSource: Int]
  private(set) var navigation: WireComposeLayout?
  private let monospace: CTFont
  private let styleRevision: UInt64
  private let environmentRevision, geometryRevision: UInt64
  private let typography: ComposeTypography

  init?(pane: WirePane, window: UInt64, cell: CGSize, body: NSFont, monospace: NSFont,
        typography: ComposeTypography = .init(), pageWidth: CGFloat = 0, reuse: ComposePresentation? = nil,
        sharingMeasurementsWith peers: [ComposePresentation] = [],
        measuredBase: ComposePresentation? = nil,
        caretStates: [UInt64: WireComposeCaret] = [:], images: [UInt64: ComposeImageState] = [:], viewport: WireComposeViewport? = nil,
        preedit: ComposeMarkedText? = nil, composition: ComposeComposition? = nil, pendingSelection: Bool = false,
        virtualInsertion: ComposeVirtualInsertion? = nil, virtualSelections: ComposeVirtualSelections? = nil,
        environmentLike: ComposePresentation? = nil, geometryRevision: UInt64 = 0,
        previewResult: ComposePreviewResult? = nil, reusingOnly: Bool = false) {
    guard pane.hasCompose, pane.hasBuffer else { return nil }
    if pane.compose.hasTextContext {
      textContext = ComposeTextContext(pane.compose.textContext, documentLength: pane.compose.documentLen, reuse: reuse?.textContext)
      guard textContext != nil else { return nil }
    } else { textContext = nil }
    let rect = pane.content
    let bounds = CGRect(x: CGFloat(rect.x) * cell.width, y: CGFloat(rect.y) * cell.height,
                        width: CGFloat(rect.w) * cell.width, height: CGFloat(rect.h) * cell.height)
    let available = bounds.width - 32
    let width = pageWidth > 0 ? min(pageWidth, available) : available
    guard width > 0 else { return nil }
    let prepared: ComposePaneLayout?
    if let previewResult {
      let draft = composition ?? preedit.flatMap { ComposeComposition(primary: 0, values: [0: $0]) }
      guard let request = ComposePreviewRequest(pane: pane.compose, body: body as CTFont,
        monospace: monospace as CTFont, width: width, typography: typography, images: images,
        composition: draft, virtualInsertion: virtualInsertion) else { return nil }
      prepared = previewResult.layout(matching: request)
    } else {
      prepared = ComposePaneLayout(pane: pane.compose, body: body as CTFont,
        monospace: monospace as CTFont, width: width, typography: typography, images: images, reuse: reuse?.layout,
        sharingMeasurementsWith: peers.map(\.layout), measuredBase: measuredBase?.layout,
        preedit: preedit, composition: composition, virtualInsertion: virtualInsertion, reusingOnly: reusingOnly)
    }
    guard let layout = prepared else { return nil }
    self.pane = pane; self.pendingSelection = pendingSelection; self.virtualSelections = virtualSelections
    self.layout = layout
    // Each snapshot owns its indices. Keep the first match, as the prior
    // linear searches did, without rescanning all images for every AX child.
    var starts: [UInt64: Int] = [:], sources: [ImageSource: Int] = [:], attachments: [ImageSource: Int] = [:]
    starts.reserveCapacity(pane.compose.images.count); sources.reserveCapacity(pane.compose.images.count)
    attachments.reserveCapacity(layout.text.attachments.count)
    for (index, image) in pane.compose.images.enumerated() {
      let source = ImageSource(start: image.start, end: image.end)
      if starts[image.start] == nil { starts[image.start] = index }
      if sources[source] == nil { sources[source] = index }
    }
    for (index, placed) in layout.text.attachments.enumerated() {
      let source = ImageSource(start: UInt64(placed.attachment.source.lowerBound), end: UInt64(placed.attachment.source.upperBound))
      if attachments[source] == nil { attachments[source] = index }
    }
    imageStarts = starts; imageSources = sources; attachmentSources = attachments
    self.bounds = bounds
    self.body = body as CTFont
    self.monospace = monospace as CTFont
    self.typography = typography
    self.geometryRevision = geometryRevision
    if let previous = environmentLike ?? reuse, previous.layout.width == width, previous.bounds.height == bounds.height,
       CFEqual(previous.body, body as CTFont), CFEqual(previous.monospace, monospace as CTFont),
       previous.typography == typography, previous.geometryRevision == geometryRevision {
      environmentRevision = previous.environmentRevision
    } else { environmentRevision = UInt64.random(in: 1...UInt64.max) }
    let sameColumns = reuse.map { previous in
      previous.layout.text.tables.count == layout.text.tables.count && zip(previous.layout.text.tables, layout.text.tables).allSatisfy {
        $0.source == $1.source && $0.columns == $1.columns && $0.rect.minX == $1.rect.minX
      }
    } ?? false
    if let reuse, reuse.layout.width == layout.width, reuse.bounds.height == bounds.height,
       CFEqual(reuse.body, body as CTFont), CFEqual(reuse.monospace, monospace as CTFont), reuse.typography == typography, sameColumns {
      styleRevision = reuse.styleRevision
    } else { styleRevision = UInt64.random(in: 1...UInt64.max) }
    self.caretStates = caretStates
    // Keep a valid nearby sample across ordinary caret moves. A distant caret
    // needs new stops; sharing immutable text cannot certify missing geometry.
    if let reuse, let sample = reuse.navigation, reuse.layout.text === layout.text, reuse.bounds.height == bounds.height,
       reuse.identity == .init(window: window, leaf: pane.leaf, buffer: pane.buffer),
       reuse.pane.compose.bufferRevision == pane.compose.bufferRevision,
       reuse.pane.compose.projectionRevision == pane.compose.projectionRevision,
       reuse.styleRevision == styleRevision, reuse.environmentRevision == environmentRevision,
       pane.compose.cursors.flatMap({ $0.hasAnchor ? [$0.position, $0.anchor] : [$0.position] }).allSatisfy({ position in
         sample.lines.contains { $0.stops.contains { $0.source == position } }
       }) {
      navigation = sample
    }
    identity = .init(window: window, leaf: pane.leaf, buffer: pane.buffer)
    self.viewport = viewport ?? .with { $0.position = pane.compose.topByte }
    scrolling = ComposeViewport(text: layout.text, documentLength: pane.compose.documentLen, height: max(1, bounds.height - 24),
      width: available, leading: max(0, (available - width) / 2))
    let top = Int(exactly: pane.compose.topByte).flatMap { layout.text.caret(for: $0)?.minY } ?? 0
    var y = bounds.minY + 12 - top
    if let reuse, reuse.identity == identity,
       reuse.pane.compose.bufferRevision == pane.compose.bufferRevision,
       reuse.pane.compose.topByte == pane.compose.topByte,
       reuse.pane.compose.assetDocument == pane.compose.assetDocument,
       let anchor = reuse.layout.text.hit(at: CGPoint(x: 0, y: max(0, reuse.bounds.minY + 12 - reuse.origin.y))),
       let before = reuse.layout.text.caret(for: anchor.source, affinity: anchor.affinity),
       let after = layout.text.caret(for: anchor.source, affinity: anchor.affinity) {
      y = bounds.minY + before.minY + reuse.origin.y - reuse.bounds.minY - after.minY
    }
    if pane.compose.hasViewport {
      let fallback = max(0, bounds.minY + 12 - (reuse?.origin.y ?? bounds.minY + 12))
      y = bounds.minY + 12 - scrolling.displayedTop(self.viewport, fallback: fallback)
    }
    origin = CGPoint(x: bounds.midX - width / 2 - scrolling.displayedLeft(self.viewport), y: y)
  }

  func image(start: UInt64, end: UInt64? = nil) -> WireComposeImage? {
    let index: Int?
    if let end { index = imageSources[ImageSource(start: start, end: end)] }
    else { index = imageStarts[start] }
    return index.map { pane.compose.images[$0] }
  }

  func attachment(start: UInt64, end: UInt64) -> ComposeTextLayout.PlacedAttachment? {
    attachmentSources[ImageSource(start: start, end: end)].map { layout.text.attachments[$0] }
  }

  var caret: CGRect? {
    if let selections = virtualSelections, let unit = layout.provisionalDisplayPosition(selections.cursors[selections.primaryID]!.position) {
      return layout.text.caret(atUTF16: unit, affinity: selections.cursors[selections.primaryID]!.affinity)?.offsetBy(dx: origin.x, dy: origin.y)
    }
    if let preedit = layout.preedit, let display = layout.draftDisplayRange {
      return layout.text.caret(atUTF16: display.location + NSMaxRange(preedit.selected))?.offsetBy(dx: origin.x, dy: origin.y)
    }
    guard let cursor, let position = Int(exactly: cursor.position),
          let rect = layout.text.caret(for: position, affinity: affinity(for: cursor)) else { return nil }
    return rect.offsetBy(dx: origin.x, dy: origin.y)
  }

  var cursor: WireComposeSelection? {
    pane.compose.cursors.first(where: \.primary) ?? pane.compose.cursors.first
  }

  var cursorAffinity: UInt32 { cursor.map { affinity(for: $0) == .upstream ? 1 : 0 } ?? 0 }

  var carets: [CGRect] {
    if let selections = virtualSelections {
      return selections.cursors.values.compactMap { cursor in
        layout.provisionalDisplayPosition(cursor.position).flatMap { layout.text.caret(atUTF16: $0, affinity: cursor.affinity) }?.offsetBy(dx: origin.x, dy: origin.y)
      }
    }
    if let insertion = layout.virtualInsertion {
      return insertion.cursors.values.compactMap { cursor in
        layout.provisionalDisplayPosition(cursor.position).flatMap { layout.text.caret(atUTF16: $0, affinity: cursor.affinity) }?.offsetBy(dx: origin.x, dy: origin.y)
      }
    }
    if let composition = layout.composition {
      var result = layout.draftDisplayRanges.compactMap { id, display -> CGRect? in
        guard let value = composition.values[id] else { return nil }
        return layout.text.caret(atUTF16: display.location + NSMaxRange(value.selected))?.offsetBy(dx: origin.x, dy: origin.y)
      }
      for cursor in pane.compose.cursors where composition.values[cursor.id] == nil {
        guard let source = Int(exactly: cursor.position), let unit = composition.virtualPosition(for: source),
              composition.sourcePosition(at: unit) == source, let display = layout.provisionalDisplayPosition(unit),
              let caret = layout.text.caret(atUTF16: display, affinity: affinity(for: cursor)) else { continue }
        result.append(caret.offsetBy(dx: origin.x, dy: origin.y))
      }
      return result
    }
    return pane.compose.cursors.compactMap { cursor in
      Int(exactly: cursor.position).flatMap { layout.text.caret(for: $0, affinity: affinity(for: cursor)) }?.offsetBy(dx: origin.x, dy: origin.y)
    }
  }

  private func affinity(for cursor: WireComposeSelection) -> ComposeProjection.Affinity {
    guard let state = caretStates[cursor.id], state.position == cursor.position else { return .downstream }
    return state.affinity == 1 ? .upstream : .downstream
  }

  func measuredNavigation(aroundY: CGFloat? = nil) -> WireComposeLayout? {
    guard layout.composition == nil, layout.virtualInsertion == nil else { return nil }
    if let navigation, aroundY == nil { return navigation }
    let positions = pane.compose.cursors.flatMap { $0.hasAnchor ? [$0.position, $0.anchor] : [$0.position] }
    navigation = layout.text.navigation(id: UInt64.random(in: 1...UInt64.max), pageHeight: max(1, bounds.height - 40),
      documentLength: pane.compose.documentLen, positions: positions, aroundY: aroundY, styleRevision: styleRevision, environmentRevision: environmentRevision)
    return navigation
  }

  func position(at point: CGPoint) -> Int? {
    layout.text.sourcePosition(at: CGPoint(x: point.x - origin.x, y: point.y - origin.y))
  }

  func hit(at point: CGPoint) -> ComposeTextLayout.Hit? {
    layout.text.hit(at: CGPoint(x: point.x - origin.x, y: point.y - origin.y))
  }

  private var primarySelectionID: UInt64? { virtualSelections?.primaryID ?? layout.virtualInsertion?.primaryID ?? cursor?.id }
  var selectedRange: NSRange {
    primarySelectionID.flatMap { displaySelections[$0] } ?? NSRange(location: NSNotFound, length: 0)
  }

  /// Accessibility ranges address the displayed value, not raw source context.
  /// Keep primary first; an offscreen primary must not promote a secondary.
  var selectedRanges: [NSRange] {
    let selections = displaySelections
    let primary = primarySelectionID
    return selections.keys.sorted { a, b in a == primary && b != primary ? true : b == primary ? false : a < b }.compactMap { selections[$0] }
  }

  private var displaySelections: [UInt64: NSRange] {
    let virtual = virtualSelections?.cursors ?? layout.virtualInsertion?.cursors
    if let virtual {
      return virtual.reduce(into: [:]) { result, value in
        let range = value.value.selection
        guard let a = layout.provisionalDisplayPosition(range.location),
              let b = layout.provisionalDisplayPosition(NSMaxRange(range)), a <= b else { return }
        result[value.key] = NSRange(location: a, length: b - a)
      }
    }
    return pane.compose.cursors.reduce(into: [:]) { result, cursor in
      if let draft = layout.composition?.values[cursor.id], let display = layout.draftDisplayRanges[cursor.id] {
        result[cursor.id] = NSRange(location: display.location + draft.selected.location, length: draft.selected.length)
        return
      }
      guard let a = Int(exactly: cursor.hasAnchor ? min(cursor.position, cursor.anchor) : cursor.position),
            let b = Int(exactly: cursor.hasAnchor ? max(cursor.position, cursor.anchor) : cursor.position) else { return }
      if let composition = layout.composition {
        guard let start = composition.virtualPosition(for: a), composition.sourcePosition(at: start) == a,
              let end = composition.virtualPosition(for: b), composition.sourcePosition(at: end) == b,
              let x = layout.provisionalDisplayPosition(start), let y = layout.provisionalDisplayPosition(end), x <= y else { return }
        result[cursor.id] = NSRange(location: x, length: y - x)
        return
      }
      guard let start = layout.text.utf16Position(for: max(a, layout.text.projection.source.lowerBound)),
            let end = layout.text.utf16Position(for: min(b, layout.text.projection.source.upperBound), affinity: .upstream), start <= end else { return }
      result[cursor.id] = NSRange(location: start, length: end - start)
    }
  }

  var textServiceSelectedRange: NSRange { virtualSelections?.selection ?? layout.composition?.selectedRange ?? textContext?.selection ?? selectedRange }

  func sourceRange(forTextServiceRange range: NSRange) -> Range<Int>? {
    guard let context = textContext else {
      return layout.text.sourceRange(forUTF16: range, insertion: cursor.flatMap { Int(exactly: $0.position) })
    }
    if let source = context.sourceRange(forUTF16: range) { return source }
    // A large selection can extend past the bounded context. Its byte ends
    // already belong to the captured Fresh cursor and do not need guessing.
    if range == context.selection, let cursor,
       let a = Int(exactly: cursor.position), let b = Int(exactly: cursor.hasAnchor ? cursor.anchor : cursor.position) {
      return min(a, b)..<max(a, b)
    }
    return nil
  }

  func textServiceIndex(for source: Int, affinity: ComposeProjection.Affinity = .downstream) -> Int? {
    if let context = textContext { return context.utf16Position(for: source) }
    return layout.text.utf16Position(for: source, affinity: affinity)
  }

  func textServiceRect(for range: NSRange) -> (rect: CGRect, range: NSRange)? {
    if range.length == 0, range == textServiceSelectedRange, let caret {
      return (caret.offsetBy(dx: -origin.x, dy: -origin.y), range)
    }
    if layout.preedit != nil, layout.draftDisplayRange != nil {
      guard range.location >= 0, range.location != NSNotFound,
            let a = preeditDisplayPosition(range.location), range.length >= 0,
            range.length <= Int.max - range.location,
            let b = preeditDisplayPosition(NSMaxRange(range)), a <= b,
            let rect = layout.text.firstRect(forUTF16: NSRange(location: a, length: b - a)) else { return nil }
      let start = preeditDocumentPosition(rect.range.location), end = preeditDocumentPosition(NSMaxRange(rect.range))
      guard let start, let end, start <= end else { return nil }
      return (rect.rect, NSRange(location: start, length: end - start))
    }
    guard let context = textContext else { return layout.text.firstRect(forUTF16: range) }
    guard let source = sourceRange(forTextServiceRange: range),
          let a = layout.text.utf16Position(for: source.lowerBound),
          let b = layout.text.utf16Position(for: source.upperBound, affinity: .upstream), b >= a,
          let area = layout.text.firstRect(forUTF16: NSRange(location: a, length: b - a)) else { return nil }
    if range.length == 0 { return (area.rect, range) }
    guard let actual = layout.text.sourceRange(forUTF16: area.range),
          let start = context.utf16Position(for: actual.lowerBound), let end = context.utf16Position(for: actual.upperBound) else { return nil }
    return (area.rect, NSRange(location: start, length: end - start))
  }

  private func preeditDisplayPosition(_ position: Int) -> Int? { layout.provisionalDisplayPosition(position) }

  func preeditDocumentPosition(_ displayPosition: Int) -> Int? { layout.provisionalDocumentPosition(displayPosition) }

  func draw(in context: CGContext, dirty: CGRect, foreground: NSColor, background: NSColor, selection: NSColor,
            palette: ComposePaneLayout.Palette? = nil) {
    layout.draw(in: context, origin: origin, clip: bounds, dirty: dirty, foreground: foreground.cgColor,
                background: background.cgColor, selection: selection.withAlphaComponent(0.4).cgColor, palette: palette,
                provisionalSelections: virtualSelections.map { $0.cursors.values.map(\.selection) }
                  ?? layout.virtualInsertion.map { $0.cursors.values.map(\.selection) })
  }
}
