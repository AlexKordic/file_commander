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

  /// Ephemeral selection feedback for an absolute source placement. The
  /// captured input and backend snapshot remain unchanged. Word/line policy
  /// and source outside the supplied raw context still require Fresh's reply.
  public struct Preview {
    public let pane: WireComposePane
    public let caret: WireComposeCaret
  }

  public func preview(in selections: ComposeVirtualSelections) -> ComposeVirtualSelections? {
    guard captured.clickCount <= 1, let source = Int(exactly: captured.position),
          let point = selections.prefix.virtualPosition(for: source) else { return nil }
    if captured.hasAttachmentStart, !captured.extend {
      guard let source = Int(exactly: captured.attachmentStart), let anchor = selections.prefix.virtualPosition(for: source) else { return nil }
      return selections.movingPrimary(to: anchor, extend: false)?.movingPrimary(to: point, extend: true, affinity: captured.affinity == 1 ? .upstream : .downstream)
    }
    return selections.movingPrimary(to: point, extend: captured.extend, affinity: captured.affinity == 1 ? .upstream : .downstream)
  }

  public func preview(in pane: WireComposePane) -> Preview? {
    guard pane.bufferRevision == captured.sourceRevision, pane.hasViewport, pane.viewport.epoch == captured.bufferEpoch,
          captured.clickCount <= 1,
          pane.hasTextContext, let original = pane.cursors.first(where: \.primary) ?? pane.cursors.first,
          pane.cursors.filter({ $0.id == original.id }).count == 1,
          let position = Int(exactly: captured.position), position <= pane.documentLen,
          let context = ComposeTextContext(pane.textContext, documentLength: pane.documentLen),
          let unit = context.utf16Position(for: position) else { return nil }
    let anchor: UInt64? = captured.hasAttachmentStart ? captured.attachmentStart
      : captured.extend ? (original.hasAnchor ? original.anchor : original.position) : nil
    let anchorUnit: Int?
    if let anchor {
      guard let source = Int(exactly: anchor), let index = context.utf16Position(for: source) else { return nil }
      anchorUnit = index
    } else { anchorUnit = nil }
    var preview = pane, cursor = original
    cursor.position = captured.position; cursor.utf16Position = UInt64(unit)
    if let anchor, let anchorUnit { cursor.anchor = anchor; cursor.utf16Anchor = UInt64(anchorUnit) }
    else { cursor.clearAnchor(); cursor.clearUtf16Anchor() }
    guard let index = preview.cursors.firstIndex(where: { $0.id == original.id }) else { return nil }
    preview.cursors[index] = cursor
    preview.textContext.selectionStart = UInt64(min(unit, anchorUnit ?? unit))
    preview.textContext.selectionEnd = UInt64(max(unit, anchorUnit ?? unit))
    let caret = WireComposeCaret.with {
      $0.id = original.id; $0.position = captured.position; $0.affinity = captured.affinity
    }
    return Preview(pane: preview, caret: caret)
  }

  public func input(id: UInt64) -> WireComposeInput {
    var input = captured; input.id = id; return input
  }
}
