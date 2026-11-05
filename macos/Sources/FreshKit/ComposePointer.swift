import Foundation

/// An immutable source intent captured at event time. Its screen point and
/// layout are deliberately absent: subsequent scrolling, reflow or source
/// edits cannot turn the same queued click into a click on a different word.
public struct ComposePointer {
  private let captured: WireComposeInput
  public var scope: WireComposeScope { captured.scope }

  public init?(scope: WireComposeScope, epoch: UInt64, hit: ComposeTextLayout.Hit, extend: Bool, count: Int) {
    guard epoch != 0, hit.source >= 0 else { return nil }
    captured = .with {
      $0.scope = scope; $0.bufferEpoch = epoch; $0.sourceRevision = scope.bufferRevision
      $0.position = UInt64(hit.source); $0.affinity = hit.affinity == .upstream ? 1 : 0
      $0.extend = extend; $0.clickCount = UInt32(clamping: count)
      if let attachment = hit.attachment, !extend {
        $0.attachmentStart = UInt64(attachment.lowerBound)
        $0.position = UInt64(attachment.upperBound)
      }
    }
  }

  public func input(id: UInt64) -> WireComposeInput {
    var input = captured; input.id = id; return input
  }
}
