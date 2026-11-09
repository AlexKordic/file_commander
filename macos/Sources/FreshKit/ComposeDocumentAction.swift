import Foundation

/// A complete-value action waiting behind captured native input. Every point
/// retains its origin until a correlated receipt binds it to real source.
/// The owner of this value must also enforce its connection and queue tokens.
public struct ComposeDocumentAction {
  /// Compact accepted history: no pane text, source map, image data or UI
  /// layout is retained after the queue has consumed the original receipt.
  public struct Transition: Sendable {
    public let owner: WireComposeIndexOwner
    public let scope: WireComposeScope
    let proof: ComposeAcceptedEdits?
    let selectedIDs: [UInt64]?

    public init?(_ receipt: WireComposeEditReceipt, original: WireComposeScope, epoch: UInt64,
                 selectedIDs: [UInt64]? = nil) {
      guard receipt.matches(original, epoch: epoch) else { return nil }
      let supplied = receipt.hasSourceRevision || receipt.hasSourceLength || !receipt.anchors.isEmpty
      proof = supplied ? ComposeAcceptedEdits(receipt, original: original, epoch: epoch) : nil
      guard !supplied || proof != nil else { return nil }
      if let selectedIDs {
        guard selectedIDs.count <= 1024, Set(selectedIDs).count == selectedIDs.count,
              selectedIDs.count == receipt.pane.cursors.count,
              Set(selectedIDs) == Set(receipt.pane.cursors.map(\.id)) else { return nil }
      }
      self.selectedIDs = selectedIDs; scope = receipt.scope
      owner = .with {
        $0.window = receipt.window; $0.leaf = receipt.leaf; $0.buffer = receipt.buffer; $0.epoch = receipt.epoch
        $0.revision = receipt.pane.bufferRevision; $0.length = receipt.pane.documentLen
        $0.authority = receipt.pane.assetAuthority; $0.document = receipt.pane.assetDocument
      }
    }
  }
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
    guard let transition = Transition(receipt, original: scope, epoch: owner.epoch, selectedIDs: selectedIDs) else { return nil }
    return resolving(transition, token: token)
  }

  public func resolving(_ transition: Transition, token: UUID) -> Self? {
    guard transition.owner.isSameDocument(as: owner), transition.owner.revision >= owner.revision else { return nil }
    let proof = transition.proof
    let sameSource = transition.owner.revision == owner.revision && transition.owner.length == owner.length
    let rebase = proof.map { $0.sourceRevision == owner.revision && UInt64($0.sourceLength) == owner.length } ?? false
    let selected = transition.selectedIDs
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
    next.bounds = resolved; next.scope = transition.scope; next.owner = transition.owner
    return next
  }

  public func depends(on token: UUID) -> Bool {
    func cursor(_ cursor: Cursor) -> Bool {
      if case .selectedGroup(let predecessor, _) = cursor { return predecessor == token }; return false
    }
    if case .replacement(_, let id) = kind, cursor(id) { return true }
    return bounds.contains { range in [range.start, range.end].contains { point in
      if case .inserted(let predecessor, let id, _, _) = point { return predecessor == token || cursor(id) }
      return false
    } }
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
