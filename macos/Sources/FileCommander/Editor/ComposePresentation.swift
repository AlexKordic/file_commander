import AppKit
import CoreText
import FreshKit

/// Drawing and hit testing for one rich pane. Fresh retains the buffer,
/// selections and undo history; this is an immutable scene presentation.
@MainActor
final class ComposePresentation {
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
  private let caretStates: [UInt64: WireComposeCaret]
  private(set) var navigation: WireComposeLayout?
  private let monospace: CTFont
  private let styleRevision: UInt64
  private let typography: ComposeTypography

  init?(pane: WirePane, window: UInt64, cell: CGSize, body: NSFont, monospace: NSFont,
        typography: ComposeTypography = .init(), pageWidth: CGFloat = 0, reuse: ComposePresentation? = nil,
        caretStates: [UInt64: WireComposeCaret] = [:], images: [UInt64: ComposeImageState] = [:], viewport: WireComposeViewport? = nil,
        preedit: ComposeMarkedText? = nil, composition: ComposeComposition? = nil) {
    guard pane.hasCompose, pane.hasBuffer else { return nil }
    if pane.compose.hasTextContext {
      if let reuse, reuse.pane.compose.documentLen == pane.compose.documentLen,
         reuse.pane.compose.textContext == pane.compose.textContext { textContext = reuse.textContext }
      else { textContext = ComposeTextContext(pane.compose.textContext, documentLength: pane.compose.documentLen) }
      guard textContext != nil else { return nil }
    } else { textContext = nil }
    let rect = pane.content
    let bounds = CGRect(x: CGFloat(rect.x) * cell.width, y: CGFloat(rect.y) * cell.height,
                        width: CGFloat(rect.w) * cell.width, height: CGFloat(rect.h) * cell.height)
    let available = bounds.width - 32
    let width = pageWidth > 0 ? min(pageWidth, available) : available
    guard width > 0, let layout = ComposePaneLayout(pane: pane.compose, body: body as CTFont,
      monospace: monospace as CTFont, width: width, typography: typography, images: images, reuse: reuse?.layout, preedit: preedit, composition: composition) else { return nil }
    self.pane = pane
    self.layout = layout
    self.bounds = bounds
    self.body = body as CTFont
    self.monospace = monospace as CTFont
    self.typography = typography
    let sameColumns = reuse.map { previous in
      previous.layout.text.tables.count == layout.text.tables.count && zip(previous.layout.text.tables, layout.text.tables).allSatisfy {
        $0.source == $1.source && $0.columns == $1.columns && $0.rect.minX == $1.rect.minX
      }
    } ?? false
    if let reuse, reuse.layout.text.size.width == layout.text.size.width, reuse.bounds.height == bounds.height,
       CFEqual(reuse.body, body as CTFont), CFEqual(reuse.monospace, monospace as CTFont), reuse.typography == typography, sameColumns {
      styleRevision = reuse.styleRevision
    } else { styleRevision = UInt64.random(in: 1...UInt64.max) }
    self.caretStates = caretStates
    if let reuse, reuse.layout.text === layout.text, reuse.bounds.height == bounds.height { navigation = reuse.navigation }
    identity = .init(window: window, leaf: pane.leaf, buffer: pane.buffer)
    self.viewport = viewport ?? .with { $0.position = pane.compose.topByte }
    scrolling = ComposeViewport(text: layout.text, documentLength: pane.compose.documentLen, height: max(1, bounds.height - 24))
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
    origin = CGPoint(x: bounds.midX - width / 2, y: y)
  }

  var scope: WireComposeScope {
    WireComposeScope.with {
      $0.windowID = identity.window
      $0.leaf = identity.leaf
      $0.buffer = identity.buffer
      $0.bufferRevision = pane.compose.bufferRevision
      $0.projectionRevision = pane.compose.projectionRevision
      $0.selectionRevision = pane.compose.selectionRevision
    }
  }

  var caret: CGRect? {
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
    if let composition = layout.composition {
      return layout.draftDisplayRanges.compactMap { id, display in
        guard let value = composition.values[id] else { return nil }
        return layout.text.caret(atUTF16: display.location + NSMaxRange(value.selected))?.offsetBy(dx: origin.x, dy: origin.y)
      }
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
    guard layout.preedit == nil else { return nil }
    if let navigation, aroundY == nil { return navigation }
    let positions = pane.compose.cursors.flatMap { $0.hasAnchor ? [$0.position, $0.anchor] : [$0.position] }
    navigation = layout.text.navigation(id: UInt64.random(in: 1...UInt64.max), pageHeight: max(1, bounds.height - 40),
      documentLength: pane.compose.documentLen, positions: positions, aroundY: aroundY, styleRevision: styleRevision)
    return navigation
  }

  func position(at point: CGPoint) -> Int? {
    layout.text.sourcePosition(at: CGPoint(x: point.x - origin.x, y: point.y - origin.y))
  }

  func hit(at point: CGPoint) -> ComposeTextLayout.Hit? {
    layout.text.hit(at: CGPoint(x: point.x - origin.x, y: point.y - origin.y))
  }

  var selectedRange: NSRange {
    if let preedit = layout.preedit, let display = layout.draftDisplayRange {
      return NSRange(location: display.location + preedit.selected.location, length: preedit.selected.length)
    }
    guard let cursor,
          let position = Int(exactly: cursor.position),
          let anchor = Int(exactly: cursor.hasAnchor ? cursor.anchor : cursor.position),
          let a = layout.text.projection.displayPosition(for: min(position, anchor)),
          let b = layout.text.projection.displayPosition(for: max(position, anchor)) else { return NSRange(location: 0, length: 0) }
    let bytes = Array(layout.text.projection.text.utf8)
    let start = String(decoding: bytes[..<a], as: UTF8.self).utf16.count
    let end = String(decoding: bytes[..<b], as: UTF8.self).utf16.count
    return NSRange(location: start, length: max(0, end - start))
  }

  var textServiceSelectedRange: NSRange { textContext?.selection ?? selectedRange }

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

  private func preeditDisplayPosition(_ position: Int) -> Int? {
    guard let composition = layout.composition else { return nil }
    if let draft = composition.draftPosition(at: position) {
      return layout.draftDisplayRanges[draft.id].map { $0.location + draft.offset }
    }
    guard let source = composition.sourcePosition(at: position) else { return nil }
    return layout.text.utf16Position(for: source)
  }

  func preeditDocumentPosition(_ displayPosition: Int) -> Int? {
    guard let composition = layout.composition else { return nil }
    for id in [composition.primaryID] + composition.ordered.filter({ $0 != composition.primaryID }) {
      if let display = layout.draftDisplayRanges[id], displayPosition >= display.location && displayPosition <= NSMaxRange(display) {
        return composition.virtualStart(for: id) + displayPosition - display.location
      }
    }
    guard let sourceRange = layout.text.sourceRange(forUTF16: NSRange(location: displayPosition, length: 0)) else { return nil }
    return composition.virtualPosition(for: sourceRange.lowerBound)
  }

  func draw(in context: CGContext, dirty: CGRect, foreground: NSColor, background: NSColor, selection: NSColor,
            palette: ComposePaneLayout.Palette? = nil) {
    layout.draw(in: context, origin: origin, clip: bounds, dirty: dirty, foreground: foreground.cgColor,
                background: background.cgColor, selection: selection.withAlphaComponent(0.4).cgColor, palette: palette)
  }
}
