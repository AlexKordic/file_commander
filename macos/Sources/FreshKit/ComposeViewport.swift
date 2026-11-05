import Foundation
import CoreGraphics

/// Pixel scrolling over the same shaped text used for drawing and editing.
/// A source position and its caret-fragment offset survive reflow; cell rows
/// and proportional estimates of the document's height do not participate.
public struct ComposeViewport {
  public let text: ComposeTextLayout
  public let documentLength: UInt64
  public let height: CGFloat

  public init(text: ComposeTextLayout, documentLength: UInt64, height: CGFloat) {
    self.text = text; self.documentLength = documentLength
    self.height = height.isFinite ? max(1, height) : 1
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

  public func moved(_ anchor: WireComposeViewport, by delta: CGFloat, fallback: CGFloat = 0) -> WireComposeViewport? {
    guard delta.isFinite, delta != 0 else { return nil }
    let top = requestedTop(anchor) ?? displayedTop(anchor, fallback: fallback)
    return anchored(at: top + delta, epoch: anchor.epoch)
  }

  /// Request the source beyond a loaded edge while retaining the same pixel
  /// top. Measuring an edge caret is enough; no document-height guess is used.
  public func continuation(_ anchor: WireComposeViewport) -> WireComposeViewport? {
    guard let top = requestedTop(anchor) else { return nil }
    if top < 0, text.projection.source.lowerBound > 0 {
      return edge(text.projection.source.lowerBound, top: top, epoch: anchor.epoch, affinity: 0)
    }
    if top + height > text.size.height, UInt64(text.projection.source.upperBound) < documentLength {
      return edge(text.projection.source.upperBound, top: top, epoch: anchor.epoch, affinity: 1)
    }
    return nil
  }

  public func revealing(_ position: UInt64, affinity: UInt32, from anchor: WireComposeViewport) -> WireComposeViewport? {
    guard let source = Int(exactly: position),
          let caret = text.caret(for: source, affinity: affinity == 1 ? .upstream : .downstream) else {
      guard position <= documentLength else { return nil }
      return .with { $0.position = position; $0.affinity = affinity; $0.epoch = anchor.epoch }
    }
    let top = displayedTop(anchor)
    if caret.minY < top { return anchored(at: caret.minY, epoch: anchor.epoch) }
    if caret.maxY > top + height {
      return anchored(at: min(caret.minY, caret.maxY - height), epoch: anchor.epoch)
    }
    return nil
  }

  private func anchored(at requested: CGFloat, epoch: UInt64) -> WireComposeViewport? {
    var top = requested
    if text.projection.source.lowerBound == 0 { top = max(0, top) }
    if UInt64(text.projection.source.upperBound) == documentLength { top = min(top, max(0, text.size.height - height)) }
    if top < 0 { return edge(text.projection.source.lowerBound, top: top, epoch: epoch, affinity: 0) }
    if top >= text.size.height { return edge(text.projection.source.upperBound, top: top, epoch: epoch, affinity: 1) }
    guard let hit = text.hit(at: CGPoint(x: 0, y: top)),
          let caret = text.caret(for: hit.source, affinity: hit.affinity) else { return nil }
    return .with {
      $0.position = UInt64(hit.source); $0.affinity = hit.affinity == .upstream ? 1 : 0
      $0.offset = Double(caret.minY - top); $0.epoch = epoch
    }
  }

  private func edge(_ position: Int, top: CGFloat, epoch: UInt64, affinity: UInt32) -> WireComposeViewport? {
    guard let caret = text.caret(for: position, affinity: affinity == 1 ? .upstream : .downstream) else { return nil }
    let offset = Double(caret.minY - top)
    guard offset.isFinite, abs(offset) <= 100_000 else { return nil }
    return .with { $0.position = UInt64(position); $0.affinity = affinity; $0.offset = offset; $0.epoch = epoch }
  }
}
