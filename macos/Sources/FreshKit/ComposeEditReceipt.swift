import Foundation

/// An acknowledged source basis against which retained formatted presentations
/// are checked. Selection revisions are opaque identities, not counters.
public struct ComposeAcceptance {
  public let window, leaf, buffer, epoch, revision, selection: UInt64

  public init(_ receipt: WireComposeEditReceipt) {
    window = receipt.window; leaf = receipt.leaf; buffer = receipt.buffer; epoch = receipt.epoch
    revision = receipt.pane.bufferRevision; selection = receipt.pane.selectionRevision
  }

  public func matches(_ pane: WirePane, window: UInt64) -> Bool {
    self.window == window && pane.leaf == leaf && pane.hasBuffer && pane.buffer == buffer
      && pane.hasCompose && pane.compose.hasViewport && pane.compose.viewport.epoch == epoch
  }

  public func permits(_ pane: WirePane, window: UInt64) -> Bool {
    matches(pane, window: window) && (pane.compose.bufferRevision > revision
      || pane.compose.bufferRevision == revision && pane.compose.selectionRevision == selection)
  }
}

extension WireComposeEditReceipt {
  public var scope: WireComposeScope {
    .with {
      $0.windowID = window; $0.leaf = leaf; $0.buffer = buffer
      $0.bufferRevision = pane.bufferRevision; $0.projectionRevision = pane.projectionRevision
      $0.selectionRevision = pane.selectionRevision
    }
  }

  /// Identity/lifetime and source order are checked before using an accepted
  /// edit as a dependent composition's new context. Its display may be pending.
  public func matches(_ original: WireComposeScope, epoch: UInt64, notBefore accepted: ComposeAcceptance? = nil) -> Bool {
    let ordered = accepted.map {
      $0.window != window || $0.leaf != leaf || $0.buffer != buffer || $0.epoch != self.epoch
        || pane.bufferRevision >= $0.revision
    } ?? true
    return ordered && hasPane && pane.hasViewport && pane.viewport.epoch == self.epoch && self.epoch != 0 && self.epoch == epoch && window == original.windowID
      && leaf == original.leaf && buffer == original.buffer && pane.bufferRevision >= original.bufferRevision
      && pane.sourceStart <= pane.sourceEnd && pane.sourceEnd <= pane.documentLen
  }
}
