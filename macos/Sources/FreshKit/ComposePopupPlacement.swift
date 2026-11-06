import Foundation
import CoreGraphics

/// One translation shared by popup painting and pointer routing. Popup cells
/// retain their size; only the source-relative anchor is measured in pixels.
public struct ComposePopupPlacement: Equatable, Sendable {
  public let original: CGRect
  public let frame: CGRect
  public let clip: CGRect
  public let cell: CGSize
  public var translation: CGPoint { CGPoint(x: frame.minX - original.minX, y: frame.minY - original.minY) }

  public init?(rect: WireRect, cell: CGSize, within bounds: CGRect,
               anchor: CGRect? = nil, horizontal: CGRect? = nil, placement: UInt32 = 0) {
    guard cell.width.isFinite, cell.height.isFinite, cell.width > 0, cell.height > 0,
          bounds.minX.isFinite, bounds.minY.isFinite, bounds.width.isFinite, bounds.height.isFinite,
          bounds.width > 0, bounds.height > 0, rect.w > 0, rect.h > 0 else { return nil }
    let original = CGRect(x: CGFloat(rect.x) * cell.width, y: CGFloat(rect.y) * cell.height,
                          width: CGFloat(rect.w) * cell.width, height: CGFloat(rect.h) * cell.height)
    guard original.minX.isFinite, original.minY.isFinite, original.width.isFinite, original.height.isFinite else { return nil }
    var origin = original.origin
    if let anchor {
      guard anchor.minX.isFinite, anchor.minY.isFinite, anchor.width.isFinite, anchor.height.isFinite,
            anchor.width > 0, anchor.height > 0 else { return nil }
      // A completion word can wrap before the caret. Its x belongs to this
      // visual row only when the two measured fragments share that row.
      let sameRow = horizontal.map { abs($0.minY - anchor.minY) < 0.5 } ?? false
      origin.x = sameRow ? horizontal!.minX : anchor.minX
      switch placement {
      case 1: origin.y = anchor.minY
      case 2:
        origin.y = anchor.maxY
        if origin.y + original.height > bounds.maxY, anchor.minY - original.height >= bounds.minY {
          origin.y = anchor.minY - original.height
        }
      case 3: origin.y = anchor.minY - original.height
      default: return nil
      }
    }
    origin.x = min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX - original.width))
    origin.y = min(max(origin.y, bounds.minY), max(bounds.minY, bounds.maxY - original.height))
    self.original = original
    frame = CGRect(origin: origin, size: original.size)
    clip = frame.intersection(bounds)
    self.cell = cell
    guard !clip.isEmpty else { return nil }
  }

  public func contains(_ point: CGPoint) -> Bool { clip.contains(point) }

  /// Signed positions preserve drag selection outside the popup. Cropping a
  /// small window does not rescale its cells or change the retained row index.
  public func localCell(at point: CGPoint) -> (column: Int32, row: Int32)? {
    guard point.x.isFinite, point.y.isFinite else { return nil }
    let x = floor((point.x - frame.minX) / cell.width)
    let y = floor((point.y - frame.minY) / cell.height)
    return (Int32(clamping: Int64(min(max(x, CGFloat(Int32.min)), CGFloat(Int32.max)))),
            Int32(clamping: Int64(min(max(y, CGFloat(Int32.min)), CGFloat(Int32.max)))))
  }
}
