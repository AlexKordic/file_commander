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

  init?(pane: WirePane, window: UInt64, cell: CGSize, body: NSFont, monospace: NSFont, reuse: ComposePresentation? = nil) {
    guard pane.hasCompose, pane.hasBuffer else { return nil }
    let rect = pane.content
    let bounds = CGRect(x: CGFloat(rect.x) * cell.width, y: CGFloat(rect.y) * cell.height,
                        width: CGFloat(rect.w) * cell.width, height: CGFloat(rect.h) * cell.height)
    let width = min(760, bounds.width - 32)
    guard width > 0, let layout = ComposePaneLayout(pane: pane.compose, body: body as CTFont,
      monospace: monospace as CTFont, width: width, reuse: reuse?.layout) else { return nil }
    self.pane = pane
    self.layout = layout
    self.bounds = bounds
    self.body = body as CTFont
    identity = .init(window: window, leaf: pane.leaf, buffer: pane.buffer)
    let top = Int(exactly: pane.compose.topByte).flatMap { layout.text.caret(for: $0)?.minY } ?? 0
    origin = CGPoint(x: bounds.midX - width / 2, y: bounds.minY + 12 - top)
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
          let rect = layout.text.caret(for: position) else { return nil }
    return rect.offsetBy(dx: origin.x, dy: origin.y)
  }

  var cursor: WireComposeSelection? {
    pane.compose.cursors.first(where: \.primary) ?? pane.compose.cursors.first
  }

  var carets: [CGRect] {
    pane.compose.cursors.compactMap { cursor in
      Int(exactly: cursor.position).flatMap { layout.text.caret(for: $0) }?.offsetBy(dx: origin.x, dy: origin.y)
    }
  }

  func position(at point: CGPoint) -> Int? {
    layout.text.sourcePosition(at: CGPoint(x: point.x - origin.x, y: point.y - origin.y))
  }

  var selectedRange: NSRange {
    guard let cursor,
          let position = Int(exactly: cursor.position),
          let anchor = Int(exactly: cursor.hasAnchor ? cursor.anchor : cursor.position),
          let a = layout.text.projection.displayPosition(for: min(position, anchor)),
          let b = layout.text.projection.displayPosition(for: max(position, anchor)) else { return NSRange(location: 0, length: 0) }
    let bytes = Array(pane.compose.text.utf8)
    let start = String(decoding: bytes[..<a], as: UTF8.self).utf16.count
    let end = String(decoding: bytes[..<b], as: UTF8.self).utf16.count
    return NSRange(location: start, length: max(0, end - start))
  }

  func draw(in context: CGContext, dirty: CGRect, foreground: NSColor, background: NSColor, selection: NSColor) {
    layout.draw(in: context, origin: origin, clip: bounds, dirty: dirty, foreground: foreground.cgColor,
                background: background.cgColor, selection: selection.withAlphaComponent(0.4).cgColor)
  }
}
