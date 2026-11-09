import Foundation

/// A local presentation over one verified Fresh source generation. Capture is
/// text-only: mutable attributed values and AppKit objects stay on the UI side.
/// This is never a replacement source snapshot or permission to send its
/// synthetic region coordinates to Fresh.
public struct ComposeDocumentOverlay: Sendable {
  public let id = UUID()
  public let owner: WireComposeIndexOwner
  let selection: UInt64
  let decoration: UInt64?
  let cursors: [WireComposeSelection]
  let composition: ComposePlainComposition?
  let insertion: ComposeVirtualInsertion.Plain?
  let selectionPrefix: ComposePlainComposition?
  let virtualCursors: [UInt64: ComposeVirtualSelections.Cursor]?
  let primary: UInt64
  var sourceComposition: ComposePlainComposition? { insertion?.regions ?? composition }

  public init?(window: UInt64, pane: WirePane, composition: ComposeComposition? = nil,
               virtualInsertion: ComposeVirtualInsertion? = nil, virtualSelections: ComposeVirtualSelections? = nil) {
    guard pane.hasBuffer, pane.hasCompose, pane.compose.projectionUsable,
          pane.compose.hasViewport, pane.compose.viewport.epoch != 0,
          pane.compose.cursors.count <= 1024, pane.compose.cursors.filter(\.primary).count == 1 else { return nil }
    let ids = Set(pane.compose.cursors.map(\.id)), primary = pane.compose.cursors.first(where: \.primary)!.id
    guard ids.count == pane.compose.cursors.count,
          composition == nil || virtualInsertion != nil || Set(composition!.values.keys).isSubset(of: ids),
          virtualInsertion == nil || virtualInsertion!.cursors.count <= 1024 && virtualInsertion!.primaryID == primary,
          virtualSelections == nil || virtualSelections!.cursors.count <= 1024 && virtualSelections!.primaryID == primary else { return nil }
    owner = .with {
      $0.window = window; $0.leaf = pane.leaf; $0.buffer = pane.buffer; $0.epoch = pane.compose.viewport.epoch
      $0.revision = pane.compose.bufferRevision; $0.authority = pane.compose.assetAuthority
      $0.document = pane.compose.assetDocument; $0.length = pane.compose.documentLen
    }
    selection = pane.compose.selectionRevision
    decoration = pane.compose.hasDecorationRevision ? pane.compose.decorationRevision : nil
    cursors = pane.compose.cursors; self.primary = primary
    self.composition = composition.map(ComposePlainComposition.init)
    insertion = virtualInsertion.map(ComposeVirtualInsertion.Plain.init)
    selectionPrefix = virtualSelections.map { ComposePlainComposition($0.prefix) }
    virtualCursors = virtualSelections?.cursors
    // A layered insertion's inner composition can address a derived raw
    // document. Only its folded-back regions own the actual Fresh source.
    for prefix in [sourceComposition, selectionPrefix].compactMap({ $0 }) {
      guard prefix.values.values.allSatisfy({ value in
        value.context.documentLength == Int(exactly: owner.length)
          && value.source.lowerBound >= 0 && UInt64(value.source.upperBound) <= owner.length
      }) else { return nil }
    }
  }

  func owns(_ document: ComposeAccessibleDocument) -> Bool {
    owner == document.owner && selection == document.selectionRevision && decoration == document.decorationRevision
  }

  public func isEquivalent(to other: Self) -> Bool {
    func same(_ a: ComposePlainComposition?, _ b: ComposePlainComposition?) -> Bool {
      switch (a,b) { case (nil,nil): return true; case (let a?,let b?): return a.isEquivalent(to:b); default: return false }
    }
    let sameInsertion: Bool
    switch (insertion,other.insertion) {
    case (nil,nil): sameInsertion = true
    case (let a?,let b?): sameInsertion = a.isEquivalent(to:b)
    default: sameInsertion = false
    }
    return owner == other.owner && selection == other.selection && decoration == other.decoration
      && cursors == other.cursors && primary == other.primary && virtualCursors == other.virtualCursors
      && same(composition,other.composition) && sameInsertion && same(selectionPrefix,other.selectionPrefix)
  }

  func hasSameLayout(as other: Self) -> Bool {
    switch (sourceComposition,other.sourceComposition) {
    case (nil,nil): return true
    case (let a?,let b?): return a.isEquivalent(to:b,includingSelection:false)
    default: return false
    }
  }
}
