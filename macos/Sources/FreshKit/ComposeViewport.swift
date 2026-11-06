import Foundation
import CoreGraphics

/// Pixel scrolling over the same shaped text used for drawing and editing.
/// A source position and its caret-fragment offset survive reflow; cell rows
/// and proportional estimates of the document's height do not participate.
public struct ComposeViewport {
  public let text: ComposeTextLayout
  public let documentLength: UInt64
  public let height: CGFloat
  public let width: CGFloat
  /// Centering space before a user-selected reading measure, in points.
  public let leading: CGFloat

  public init(text: ComposeTextLayout, documentLength: UInt64, height: CGFloat, width: CGFloat? = nil, leading: CGFloat = 0) {
    self.text = text; self.documentLength = documentLength
    self.height = height.isFinite ? max(1, height) : 1
    self.width = width.map { $0.isFinite ? max(1, $0) : 1 } ?? text.size.width
    self.leading = leading.isFinite ? max(0, leading) : 0
  }

  public func requestedTop(_ anchor: WireComposeViewport) -> CGFloat? {
    guard anchor.offset.isFinite, let source = Int(exactly: anchor.position),
          let caret = text.caret(for: source, affinity: anchor.affinity == 1 ? .upstream : .downstream) else { return nil }
    return caret.minY - CGFloat(anchor.offset)
  }

  /// Do not draw an empty pane while the next source window is in flight.
  /// The unclamped intent remains in the anchor and is resumed on arrival.
  public func displayedTop(_ anchor: WireComposeViewport, fallback: CGFloat = 0) -> CGFloat {
    min(max(0, text.size.height - height), max(0, requestedTop(anchor) ?? fallback))
  }

  public func displayedLeft(_ anchor: WireComposeViewport) -> CGFloat {
    limitedHorizontal(CGFloat(anchor.horizontalOffset))
  }

  public func moved(_ anchor: WireComposeViewport, by delta: CGFloat, horizontally horizontal: CGFloat = 0, fallback: CGFloat = 0) -> WireComposeViewport? {
    guard delta.isFinite, horizontal.isFinite, delta != 0 || horizontal != 0 else { return nil }
    var result = anchor
    if delta != 0 {
      let top = requestedTop(anchor) ?? displayedTop(anchor, fallback: fallback)
      guard let moved = anchored(at: top + delta, from: anchor) else { return nil }
      result = moved
    }
    if horizontal != 0 { result.horizontalOffset = Double(limitedHorizontal(displayedLeft(anchor) + horizontal)) }
    return result
  }

  /// Fetch an adjacent source region without replacing the visible anchor.
  /// The backend retains the anchor's shaping context while loading the probe.
  public func continuation(_ anchor: WireComposeViewport) -> WireComposeViewport? {
    guard let top = requestedTop(anchor) else { return nil }
    var result = anchor
    if top < 0, text.projection.source.lowerBound > 0 {
      result.region = UInt64(text.projection.source.lowerBound - 1)
    } else if top + height > text.size.height, UInt64(text.projection.source.upperBound) < documentLength {
      result.region = UInt64(text.projection.source.upperBound)
    } else { return nil }
    return result
  }

  public func revealing(_ position: UInt64, affinity: UInt32, from anchor: WireComposeViewport) -> WireComposeViewport? {
    guard let source = Int(exactly: position),
          let caret = text.caret(for: source, affinity: affinity == 1 ? .upstream : .downstream) else {
      guard position <= documentLength else { return nil }
      var result = anchor; result.position = position; result.affinity = affinity; result.offset = 0; result.clearRegion()
      return result
    }
    return revealing(caret: caret, from: anchor)
  }

  /// The provisional IME caret is measured in the same layout coordinates as
  /// committed text. Revealing it does not invent a source edit or move Fresh's cursor.
  public func revealing(caret: CGRect, from anchor: WireComposeViewport) -> WireComposeViewport? {
    guard !caret.isNull, [caret.minX, caret.maxX, caret.minY, caret.maxY].allSatisfy(\.isFinite) else { return nil }
    let top = displayedTop(anchor)
    var result = anchor, changed = false
    if caret.minY < top {
      guard let next = anchored(at: caret.minY, from: anchor) else { return nil }
      result = next; changed = true
    }
    if caret.maxY > top + height {
      guard let next = anchored(at: min(caret.minY, caret.maxY - height), from: anchor) else { return nil }
      result = next; changed = true
    }
    let left = displayedLeft(anchor)
    if caret.minX + leading < left {
      result.horizontalOffset = Double(limitedHorizontal(caret.minX + leading)); changed = true
    } else if caret.maxX + leading > left + width {
      result.horizontalOffset = Double(limitedHorizontal(caret.maxX + leading - width)); changed = true
    }
    return changed ? result : nil
  }

  private func limitedHorizontal(_ requested: CGFloat) -> CGFloat {
    min(100_000_000, max(0, text.size.width + leading - width), max(0, requested.isFinite ? requested : 0))
  }

  private func anchored(at requested: CGFloat, from anchor: WireComposeViewport) -> WireComposeViewport? {
    var top = requested
    if text.projection.source.lowerBound == 0 { top = max(0, top) }
    if UInt64(text.projection.source.upperBound) == documentLength { top = min(top, max(0, text.size.height - height)) }
    if top < 0 { return edge(text.projection.source.lowerBound, top: top, from: anchor, affinity: 0) }
    if top >= text.size.height { return edge(text.projection.source.upperBound, top: top, from: anchor, affinity: 1) }
    guard let hit = text.hit(at: CGPoint(x: 0, y: top)),
          let caret = text.caret(for: hit.source, affinity: hit.affinity) else { return nil }
    return .with {
      $0.position = UInt64(hit.source); $0.affinity = hit.affinity == .upstream ? 1 : 0
      $0.offset = Double(caret.minY - top); $0.epoch = anchor.epoch; $0.horizontalOffset = anchor.horizontalOffset
    }
  }

  private func edge(_ position: Int, top: CGFloat, from anchor: WireComposeViewport, affinity: UInt32) -> WireComposeViewport? {
    var result = anchor
    let original = Int(exactly: anchor.position).flatMap { text.caret(for: $0, affinity: anchor.affinity == 1 ? .upstream : .downstream) }
    guard let caret = original ?? text.caret(for: position, affinity: affinity == 1 ? .upstream : .downstream) else { return nil }
    if original == nil { result.position = UInt64(position); result.affinity = affinity }
    let offset = Double(caret.minY - top)
    guard offset.isFinite, abs(offset) <= 100_000 else { return nil }
    result.offset = offset
    result.region = UInt64(affinity == 0 && position > 0 ? position - 1 : position)
    return result
  }
}
