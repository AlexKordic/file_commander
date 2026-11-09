import AppKit
import FreshKit

/// The drawn thumb and pointer routing share one geometry. Complete layouts
/// use measured pixels; cropped layouts show source progress through the file.
struct ComposeScrollbar {
  let track: CGRect
  let proportion: CGFloat
  let value: CGFloat

  @MainActor
  init(pane: ComposePresentation, cell: CGSize, seeking: UInt64? = nil) {
    let wire = pane.pane.vscroll
    track = CGRect(x: CGFloat(wire.x) * cell.width, y: CGFloat(wire.y) * cell.height,
      width: CGFloat(wire.w) * cell.width, height: CGFloat(wire.h) * cell.height)
    let view = pane.scrolling, text = view.text, top = view.displayedTop(pane.viewport)
    if text.projection.source.lowerBound == 0, UInt64(text.projection.source.upperBound) == view.documentLength {
      proportion = min(1, view.height / max(1, text.size.height))
      value = top / max(1, text.size.height - view.height)
    } else {
      let start = text.hit(at: CGPoint(x: 0, y: top))?.source ?? text.projection.source.lowerBound
      let end = text.hit(at: CGPoint(x: 0, y: min(text.size.height, top + view.height)))?.source
        ?? text.projection.source.upperBound
      let visible = CGFloat(max(0, end - start)), length = CGFloat(max(1, view.documentLength))
      proportion = min(1, visible / length)
      let intent = seeking ?? (view.requestedTop(pane.viewport) == nil ? pane.viewport.position : nil)
      value = intent.map { CGFloat($0) / length } ?? min(1, CGFloat(start) / max(1, length - visible))
    }
  }

  var thumb: CGRect { thumb(value: value) }

  func thumb(value: CGFloat, height: CGFloat? = nil) -> CGRect {
    let height = min(track.height, height ?? max(18, track.height * proportion))
    return CGRect(x: track.minX, y: track.minY + max(0, track.height - height) * min(1, max(0, value)),
      width: track.width, height: height)
  }

  func fraction(at y: CGFloat, grabOffset: CGFloat, height: CGFloat) -> CGFloat {
    min(1, max(0, (y - track.minY - grabOffset) / max(1, track.height - height)))
  }
}
