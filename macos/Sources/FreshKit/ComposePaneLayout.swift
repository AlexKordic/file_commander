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
  private let images: [UInt64: ComposeImageState]
  private let imageSizes: [Int: CGSize]

  public init?(pane: WireComposePane, body: CTFont, monospace: CTFont, width: CGFloat,
               headingScales: [CGFloat] = [1.8, 1.5, 1.25, 1.15, 1.05, 1],
               images: [UInt64: ComposeImageState] = [:], reuse: ComposePaneLayout? = nil) {
    guard let baseProjection = ComposeProjection(pane), headingScales.count == 6,
          headingScales.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
    let rendered = pane.images.filter(\.rendered)
    var sourceRanges: [Range<Int>] = [], sizes: [Int: CGSize] = [:]
    for image in rendered {
      guard let start = Int(exactly: image.start), let end = Int(exactly: image.end), start < end else { return nil }
      sourceRanges.append(start..<end)
      sizes[start] = (images[image.start] ?? .loading).size(body: CTFontGetSize(body), width: width, block: image.block)
    }
    let objects = baseProjection.replacingObjects(sourceRanges)
    let projection = objects?.projection ?? baseProjection
    let attachments = (objects?.objects ?? []).compactMap { object -> ComposeTextLayout.Attachment? in
      guard let size = sizes[object.source.lowerBound] else { return nil }
      return .init(source: object.source, display: object.display, size: size)
    }
    self.pane = pane
    self.body = body
    self.monospace = monospace
    self.width = width
    self.headingScales = headingScales
    self.images = images
    self.imageSizes = sizes
    if let reuse, pane.projectionRevision == reuse.pane.projectionRevision,
       pane.text == reuse.pane.text, pane.segments == reuse.pane.segments,
       pane.spans == reuse.pane.spans, pane.images == reuse.pane.images, sizes == reuse.imageSizes,
       width == reuse.width, headingScales == reuse.headingScales,
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
    let boundaries = Set([0, projection.text.utf8.count] + spans.flatMap { [$0.range.lowerBound, $0.range.upperBound] }).sorted()
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
    guard let layout = ComposeTextLayout(projection: projection, font: body, width: width, fonts: fonts, attachments: attachments) else { return nil }
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
      // Core Text can change the context's fill color while drawing a run.
      // Skip the replacement glyph and restore the foreground before every
      // text run, including text following an attachment on the same line.
      for run in CTLineGetGlyphRuns(fragment.line) as! [CTRun] {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard attributes[ComposeTextLayout.attachmentKey] == nil else { continue }
        context.setFillColor(foreground)
        context.textPosition = CGPoint(x: origin.x, y: origin.y + fragment.baseline)
        CTRunDraw(run, context, CFRange(location: 0, length: 0))
      }
    }
    for placed in text.attachments {
      let rect = placed.rect.offsetBy(dx: origin.x, dy: origin.y)
      guard rect.intersects(clip), rect.intersects(dirty),
            let image = pane.images.first(where: { $0.start == UInt64(placed.attachment.source.lowerBound) }) else { continue }
      let state = images[image.start] ?? .loading
      context.saveGState()
      if case .ready(let asset) = state {
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
        else { label = "Loading \(image.alt.isEmpty ? "image" : image.alt)…" }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [
          NSAttributedString.Key(kCTFontAttributeName as String): body,
          NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]))
        context.textPosition = CGPoint(x: rect.minX + 6, y: rect.minY + 4 + CTFontGetAscent(body))
        CTLineDraw(line, context)
      }
      context.restoreGState()
      if pane.cursors.contains(where: { cursor in
        cursor.hasAnchor && min(cursor.position, cursor.anchor) < image.end && max(cursor.position, cursor.anchor) > image.start
      }) {
        context.setStrokeColor(selection)
        context.setLineWidth(2)
        context.stroke(rect.insetBy(dx: 1, dy: 1))
      }
    }
    context.textPosition = .zero
  }
}
