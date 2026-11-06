import Foundation

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
  public func matches(_ original: WireComposeScope, epoch: UInt64) -> Bool {
    hasPane && pane.hasViewport && pane.viewport.epoch == self.epoch && self.epoch != 0 && self.epoch == epoch && window == original.windowID
      && leaf == original.leaf && buffer == original.buffer && pane.bufferRevision >= original.bufferRevision
      && pane.sourceStart <= pane.sourceEnd && pane.sourceEnd <= pane.documentLen
  }
}
