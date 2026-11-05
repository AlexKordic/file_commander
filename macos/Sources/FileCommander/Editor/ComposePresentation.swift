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
  private let caretStates: [UInt64: WireComposeCaret]
  private(set) var navigation: WireComposeLayout?
  private let monospace: CTFont
  private let styleRevision: UInt64

  init?(pane: WirePane, window: UInt64, cell: CGSize, body: NSFont, monospace: NSFont, reuse: ComposePresentation? = nil,
        caretStates: [UInt64: WireComposeCaret] = [:], images: [UInt64: ComposeImageState] = [:]) {
    guard pane.hasCompose, pane.hasBuffer else { return nil }
    let rect = pane.content
    let bounds = CGRect(x: CGFloat(rect.x) * cell.width, y: CGFloat(rect.y) * cell.height,
                        width: CGFloat(rect.w) * cell.width, height: CGFloat(rect.h) * cell.height)
    let width = min(760, bounds.width - 32)
    guard width > 0, let layout = ComposePaneLayout(pane: pane.compose, body: body as CTFont,
      monospace: monospace as CTFont, width: width, images: images, reuse: reuse?.layout) else { return nil }
    self.pane = pane
    self.layout = layout
    self.bounds = bounds
    self.body = body as CTFont
    self.monospace = monospace as CTFont
    if let reuse, reuse.layout.text.size.width == layout.text.size.width, reuse.bounds.height == bounds.height,
       CFEqual(reuse.body, body as CTFont), CFEqual(reuse.monospace, monospace as CTFont) {
      styleRevision = reuse.styleRevision
    } else { styleRevision = UInt64.random(in: 1...UInt64.max) }
    self.caretStates = caretStates
    if let reuse, reuse.layout.text === layout.text, reuse.bounds.height == bounds.height { navigation = reuse.navigation }
    identity = .init(window: window, leaf: pane.leaf, buffer: pane.buffer)
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
    guard let cursor, let position = Int(exactly: cursor.position),
          let rect = layout.text.caret(for: position, affinity: affinity(for: cursor)) else { return nil }
    return rect.offsetBy(dx: origin.x, dy: origin.y)
  }

  var cursor: WireComposeSelection? {
    pane.compose.cursors.first(where: \.primary) ?? pane.compose.cursors.first
  }

  var carets: [CGRect] {
    pane.compose.cursors.compactMap { cursor in
      Int(exactly: cursor.position).flatMap { layout.text.caret(for: $0, affinity: affinity(for: cursor)) }?.offsetBy(dx: origin.x, dy: origin.y)
    }
  }

  private func affinity(for cursor: WireComposeSelection) -> ComposeProjection.Affinity {
    guard let state = caretStates[cursor.id], state.position == cursor.position else { return .downstream }
    return state.affinity == 1 ? .upstream : .downstream
  }

  func measuredNavigation(aroundY: CGFloat? = nil) -> WireComposeLayout? {
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

  func draw(in context: CGContext, dirty: CGRect, foreground: NSColor, background: NSColor, selection: NSColor) {
    layout.draw(in: context, origin: origin, clip: bounds, dirty: dirty, foreground: foreground.cgColor,
                background: background.cgColor, selection: selection.withAlphaComponent(0.4).cgColor)
  }
}
