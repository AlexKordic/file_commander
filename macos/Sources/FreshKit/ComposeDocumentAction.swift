import Foundation

/// A complete-value action waiting behind captured native input. Every point
/// retains its origin until a correlated receipt binds it to real source.
/// The owner of this value must also enforce its connection and queue tokens.
public struct ComposeDocumentAction {
  public enum Cursor {
    case known(UInt64)
    case selectedGroup(UUID, ordinal: Int)
  }
  public enum Position {
    case source(Int, affinity: ComposeProjection.Affinity)
    case inserted(UUID, cursor: Cursor, position: ComposeAcceptedEdits.InsertedPosition, affinity: ComposeProjection.Affinity)
  }
  public struct Bounds {
    public let start, end: Position
    public init(start: Position, end: Position) { self.start = start; self.end = end }
  }
  public enum Kind {
    case selection
    case replacement(String, cursor: Cursor)
  }
  public enum Ready {
    case selection(ComposeSelectionChange)
    case replacement(ComposeReplacement)
  }
  public private(set) var owner: WireComposeIndexOwner
  public private(set) var scope: WireComposeScope
  public private(set) var bounds: [Bounds]
  public private(set) var kind: Kind
  public var isSelection: Bool { if case .selection = kind { return true }; return false }
  public var recoveryTexts: [String] {
    if case .replacement(let text,_) = kind, !text.isEmpty { return [text] }
    return []
  }

  public init?(owner: WireComposeIndexOwner, scope: WireComposeScope, bounds: [Bounds], kind: Kind) {
    guard owner.epoch != 0, owner.window == scope.windowID, owner.leaf == scope.leaf, owner.buffer == scope.buffer,
          owner.revision == scope.bufferRevision, !bounds.isEmpty, bounds.count <= 1024 else { return nil }
    if case .replacement = kind, bounds.count != 1 { return nil }
    for range in bounds {
      for point in [range.start,range.end] {
        if case .source(let byte,_) = point, byte < 0 || UInt64(byte) > owner.length { return nil }
      }
    }
    self.owner = owner; self.scope = scope; self.bounds = bounds; self.kind = kind
  }

  /// Consume every preceding result, including text not owning an endpoint:
  /// its accepted batch can shift existing source points between insertions.
  /// `selectedIDs` comes from the acknowledged selector's actual cursor group,
  /// in its target order. Proposed secondary identities never go on the wire.
  public func resolving(_ receipt: WireComposeEditReceipt, token: UUID, selectedIDs: [UInt64]? = nil) -> Self? {
    guard receipt.matches(scope,epoch: owner.epoch), receipt.pane.assetAuthority == owner.authority,
          receipt.pane.assetDocument == owner.document else { return nil }
    let supplied = receipt.hasSourceRevision || receipt.hasSourceLength || !receipt.anchors.isEmpty
    let proof = supplied ? ComposeAcceptedEdits(receipt,original: scope,epoch: owner.epoch) : nil
    guard !supplied || proof != nil else { return nil }
    let sameSource = receipt.pane.bufferRevision == owner.revision && receipt.pane.documentLen == owner.length
    let rebase = proof.map { $0.sourceRevision == owner.revision && UInt64($0.sourceLength) == owner.length } ?? false
    let selected = selectedIDs.flatMap { Set($0).count == $0.count ? $0 : nil }
    func cursor(_ captured: Cursor) -> Cursor? {
      if case .selectedGroup(let selector,let index) = captured, selector == token {
        guard let selected, selected.indices.contains(index) else { return nil }
        return .known(selected[index])
      }
      return captured
    }
    func point(_ captured: Position) -> Position? {
      switch captured {
      case .source(let byte,let affinity):
        if rebase, let next = proof?.rebased(byte,from: owner.revision,affinity: affinity) { return .source(next,affinity: affinity) }
        return sameSource ? captured : nil
      case .inserted(let predecessor,let original,let position,let affinity):
        guard let bound = cursor(original) else { return nil }
        if predecessor == token {
          guard case .known(let id) = bound, let byte = proof?.position(position,cursor: id) else { return nil }
          return .source(byte,affinity: affinity)
        }
        return .inserted(predecessor,cursor: bound,position: position,affinity: affinity)
      }
    }
    var next = self, resolved: [Bounds] = []
    for range in bounds {
      guard let a = point(range.start), let b = point(range.end) else { return nil }
      resolved.append(.init(start: a,end: b))
    }
    if case .replacement(let text,let original) = kind {
      guard let bound = cursor(original) else { return nil }; next.kind = .replacement(text,cursor: bound)
    }
    next.bounds = resolved; next.scope = receipt.scope
    next.owner.revision = receipt.pane.bufferRevision; next.owner.length = receipt.pane.documentLen
    return next
  }

  public func ready() -> Ready? {
    var ranges: [Range<Int>] = []
    for range in bounds {
      guard case .source(let a,_) = range.start, case .source(let b,_) = range.end,
            a <= b, a >= 0, UInt64(b) <= owner.length else { return nil }
      ranges.append(a..<b)
    }
    switch kind {
    case .selection:
      return ComposeSelectionChange(scope: scope,epoch: owner.epoch,ranges: ranges).map(Ready.selection)
    case .replacement(let text,let cursor):
      guard case .known(let id) = cursor else { return nil }
      return ComposeReplacement(scope: scope,epoch: owner.epoch,source: ranges[0],cursor: id,text: text).map(Ready.replacement)
    }
  }
}
