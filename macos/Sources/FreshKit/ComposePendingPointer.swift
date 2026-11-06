import Foundation

/// A point within provisional text. No virtual source coordinate is sent to
/// Fresh: its owning edit must first supply an immutable matching receipt.
public struct ComposePendingPointer {
  private let scope: WireComposeScope
  private let epoch, cursor: UInt64
  private let text: String
  private let caretOffset, offset: Int
  private let affinity: ComposeProjection.Affinity
  private let extend: Bool
  private let count: Int

  init?(scope: WireComposeScope, epoch: UInt64, cursor: UInt64, text: String,
        caretOffset: Int, offset: Int, affinity: ComposeProjection.Affinity, extend: Bool, count: Int) {
    let local = WireComposeTextContext.with { $0.text = text }
    guard epoch != 0, let context = ComposeTextContext(local, documentLength: UInt64(text.utf8.count)),
          context.sourceRange(forUTF16: NSRange(location: caretOffset, length: 0)) != nil,
          context.sourceRange(forUTF16: NSRange(location: offset, length: 0)) != nil else { return nil }
    self.scope = scope; self.epoch = epoch; self.cursor = cursor; self.text = text
    self.caretOffset = caretOffset; self.offset = offset; self.affinity = affinity; self.extend = extend; self.count = count
  }

  /// Evaluate the same captured point in the current provisional document.
  /// An earlier prefix may already have become real source; relative owner
  /// placement and exact intervening text keep this independent of screen reflow.
  public func preview(in prefix: ComposeComposition, selections: ComposeVirtualSelections) -> ComposeVirtualSelections? {
    guard let owner = prefix.values[cursor] else { return nil }
    return preview(caret: prefix.virtualStart(for: cursor) + NSMaxRange(owner.selected), selections: selections)
  }

  public func preview(basis: ComposeVirtualSelections, updating selections: ComposeVirtualSelections) -> ComposeVirtualSelections? {
    guard let caret = basis.cursors[cursor]?.position else { return nil }
    return preview(caret: caret, selections: selections)
  }

  private func preview(caret: Int, selections: ComposeVirtualSelections) -> ComposeVirtualSelections? {
    let delta = offset - caretOffset
    let (point, overflow) = caret.addingReportingOverflow(delta)
    guard !overflow, point >= 0 else { return nil }
    let low = min(caret, point), length = abs(caret - point)
    let expectedStart = min(caretOffset, offset)
    let expected = (text as NSString).substring(with: NSRange(location: expectedStart, length: length))
    guard let actual = selections.substring(for: NSRange(location: low, length: length)),
          actual.string.utf16.elementsEqual(expected.utf16) else { return nil }
    return selections.movingPrimary(to: point, extend: extend, affinity: affinity)
  }

  public func resolved(_ receipt: WireComposeEditReceipt) -> ComposePointer? {
    guard receipt.matches(scope, epoch: epoch),
          receipt.cursors.contains(cursor) || receipt.preservedCursors.contains(cursor),
          receipt.pane.cursors.filter({ $0.id == cursor }).count == 1,
          let owner = receipt.pane.cursors.first(where: { $0.id == cursor }), owner.hasUtf16Position,
          !owner.hasAnchor || owner.anchor == owner.position,
          let unit = Int(exactly: owner.utf16Position),
          let byte = Int(exactly: owner.position) else { return nil }
    // Only the source between the clicked point and its proven caret owns
    // their relative position. Requiring the whole paste would reject nearby
    // clicks whenever its beginning lies outside the bounded receipt context.
    let low = min(caretOffset, offset), high = max(caretOffset, offset)
    let backward = caretOffset - low, length = high - low
    guard unit >= backward else { return nil }
    let start = unit - backward, pointOffset = offset - low
    guard length <= Int.max - start, pointOffset <= Int.max - start else { return nil }
    let expected = (text as NSString).substring(with: NSRange(location: low, length: length))
    let raw = [receipt.pane.textContext] + receipt.pane.textChunks.map { chunk in
      WireComposeTextContext.with { $0.text = chunk.text; $0.sourceStart = chunk.sourceStart; $0.utf16Start = chunk.utf16Start }
    }
    for wire in raw {
      guard let context = ComposeTextContext(wire, documentLength: receipt.pane.documentLen),
            context.utf16Position(for: byte) == unit,
            let actual = context.exactText(for: NSRange(location: start, length: length)),
            actual.utf16.elementsEqual(expected.utf16),
            let point = context.sourceRange(forUTF16: NSRange(location: start + pointOffset, length: 0)) else { continue }
      return ComposePointer(scope: receipt.scope, epoch: receipt.epoch,
        hit: .init(source: point.lowerBound, affinity: affinity), extend: extend, count: count)
    }
    return nil
  }
}
