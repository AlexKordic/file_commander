import Foundation
import CoreText
import CoreGraphics

/// A pane's native typography and source map. The Markdown decisions arrive
/// from Fresh; this object resolves semantic roles to measured font runs.
public final class ComposePaneLayout {
  public let pane: WireComposePane
  public let text: ComposeTextLayout
  private let body, monospace: CTFont
  private let width: CGFloat
  private let headingScales: [CGFloat]

  public init?(pane: WireComposePane, body: CTFont, monospace: CTFont, width: CGFloat,
               headingScales: [CGFloat] = [1.8, 1.5, 1.25, 1.15, 1.05, 1], reuse: ComposePaneLayout? = nil) {
    guard let projection = ComposeProjection(pane), headingScales.count == 6,
          headingScales.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
    self.pane = pane
    self.body = body
    self.monospace = monospace
    self.width = width
    self.headingScales = headingScales
    if let reuse, pane.projectionRevision == reuse.pane.projectionRevision,
       pane.text == reuse.pane.text, pane.segments == reuse.pane.segments,
       pane.spans == reuse.pane.spans, width == reuse.width, headingScales == reuse.headingScales,
       CFEqual(body, reuse.body), CFEqual(monospace, reuse.monospace) {
      text = reuse.text
      return
    }
    struct Span { var range: Range<Int>; var role, flags: UInt32 }
    var spans: [Span] = []
    for span in pane.spans {
      guard let a = Int(exactly: span.start), let b = Int(exactly: span.end), a <= b else { return nil }
      let from = max(a, projection.source.lowerBound), to = min(b, projection.source.upperBound)
      guard from < to,
            let start = projection.displayPosition(for: from, affinity: .downstream),
            let end = projection.displayPosition(for: to, affinity: .upstream), start < end else { continue }
      spans.append(Span(range: start..<end, role: span.role, flags: span.flags))
    }
    let boundaries = Set([0, pane.text.utf8.count] + spans.flatMap { [$0.range.lowerBound, $0.range.upperBound] }).sorted()
    var fonts: [ComposeTextLayout.FontRun] = []
    for (start, end) in zip(boundaries, boundaries.dropFirst()) where start < end {
      let active = spans.filter { $0.range.contains(start) }
      let heading = active.map(\.role).filter { (1...6).contains($0) }.min()
      let flags = active.reduce(UInt32(0)) { $0 | $1.flags }
      let mono = active.contains { $0.role == 7 || $0.role == 8 }
      let pointSize = CTFontGetSize(body) * (heading.map { headingScales[Int($0) - 1] } ?? 1)
      let base = CTFontCreateCopyWithAttributes(mono ? monospace : body, pointSize, nil, nil)
      var traits: CTFontSymbolicTraits = []
      if heading != nil || flags & 1 != 0 { traits.insert(.traitBold) }
      if flags & 2 != 0 { traits.insert(.traitItalic) }
      let font = CTFontCreateCopyWithSymbolicTraits(base, pointSize, nil, traits, [.traitBold, .traitItalic]) ?? base
      fonts.append(.init(display: start..<end, font: font))
    }
    guard let layout = ComposeTextLayout(projection: projection, font: body, width: width, fonts: fonts) else { return nil }
    text = layout
  }

  /// Draw in a context whose y axis points down, using the same line objects
  /// as hit testing and navigation. The native view and rendering tests share
  /// this path; no cell approximation or second text layout is involved.
  public func draw(in context: CGContext, origin: CGPoint, clip: CGRect, dirty: CGRect,
                   foreground: CGColor, background: CGColor, selection: CGColor) {
    guard clip.intersects(dirty) else { return }
    context.saveGState()
    defer { context.restoreGState() }
    context.clip(to: clip)
    context.setFillColor(background)
    context.fill(clip)
    context.setFillColor(selection)
    for cursor in pane.cursors where cursor.hasAnchor {
      guard let a = Int(exactly: cursor.position), let b = Int(exactly: cursor.anchor) else { continue }
      for rect in text.selectionRects(for: min(a, b)..<max(a, b)) {
        context.fill(rect.offsetBy(dx: origin.x, dy: origin.y))
      }
    }
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    context.setFillColor(foreground)
    for fragment in text.fragments {
      let rect = fragment.rect.offsetBy(dx: origin.x, dy: origin.y)
      guard rect.intersects(clip), rect.intersects(dirty) else { continue }
      context.textPosition = CGPoint(x: origin.x, y: origin.y + fragment.baseline)
      CTLineDraw(fragment.line, context)
    }
    context.textPosition = .zero
  }
}
