import Foundation

/// A complete cursor-selection group captured in Fresh source bytes. No
/// screen point, wrapped column or temporary cursor identity goes on the wire.
public struct ComposeSelectionChange {
  private let captured: WireComposeInput
  public var scope: WireComposeScope { captured.scope }

  public init?(scope: WireComposeScope, epoch: UInt64, ranges: [Range<Int>]) {
    guard epoch != 0, !ranges.isEmpty, ranges.count <= 1024,
          ranges.allSatisfy({ $0.lowerBound >= 0 }), Set(ranges.map(\.upperBound)).count == ranges.count else { return nil }
    let sorted = ranges.sorted { ($0.lowerBound, $0.upperBound) < ($1.lowerBound, $1.upperBound) }
    guard zip(sorted, sorted.dropFirst()).allSatisfy({ $0.upperBound <= $1.lowerBound && $0.lowerBound != $1.lowerBound }) else { return nil }
    captured = .with {
      $0.scope = scope; $0.bufferEpoch = epoch; $0.sourceRevision = scope.bufferRevision
      $0.selectionTargets = ranges.map { range in .with {
        $0.position = UInt64(range.upperBound)
        if !range.isEmpty { $0.anchor = UInt64(range.lowerBound) }
      } }
    }
  }

  public func input(id: UInt64) -> WireComposeInput {
    var input = captured; input.id = id; return input
  }

  /// Display feedback only. Fresh supplies real secondary IDs in its accepted
  /// action receipt before any dependent text can use them.
  public func preview(in pane: WireComposePane) -> WireComposePane? {
    guard pane.bufferRevision == captured.sourceRevision, pane.hasViewport,
          pane.viewport.epoch == captured.bufferEpoch,
          let primary = pane.cursors.first(where: \.primary) ?? pane.cursors.first else { return nil }
    let context = pane.hasTextContext ? ComposeTextContext(pane.textContext, documentLength: pane.documentLen) : nil
    let chunks = pane.textChunks.compactMap { chunk in ComposeTextContext(.with {
      $0.text = chunk.text; $0.sourceStart = chunk.sourceStart; $0.utf16Start = chunk.utf16Start
    }, documentLength: pane.documentLen) }
    let contexts = context.map { [$0] + chunks } ?? chunks
    func unit(_ source: UInt64) -> Int? {
      guard let source = Int(exactly: source) else { return nil }
      return contexts.lazy.compactMap { $0.utf16Position(for: source) }.first
    }
    var next = pane, maximum = pane.cursors.map(\.id).max() ?? 0
    var cursors: [WireComposeSelection] = []
    for (index, target) in captured.selectionTargets.enumerated() {
      guard target.position <= pane.documentLen, !target.hasAnchor || target.anchor <= pane.documentLen else { return nil }
      let id: UInt64
      if index == 0 { id = primary.id }
      else { guard maximum < UInt64.max else { return nil }; maximum += 1; id = maximum }
      cursors.append(.with {
        $0.id = id; $0.primary = index == 0; $0.position = target.position
        if target.hasAnchor { $0.anchor = target.anchor }
        if let position = unit(target.position) { $0.utf16Position = UInt64(position) }
        if target.hasAnchor, let anchor = unit(target.anchor) { $0.utf16Anchor = UInt64(anchor) }
      })
    }
    next.cursors = cursors
    if let primary = cursors.first, primary.hasUtf16Position,
       !primary.hasAnchor || primary.hasUtf16Anchor {
      let a = primary.utf16Position, b = primary.hasAnchor ? primary.utf16Anchor : a
      next.textContext.selectionStart = min(a, b); next.textContext.selectionEnd = max(a, b)
    }
    return next
  }
}
