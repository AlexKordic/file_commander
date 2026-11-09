import FreshKit

/// Source ownership needed by queued text and native composition. Geometry is
/// optional: receiving a new raw context must not construct a preview to own it.
@MainActor
protocol ComposeInputBasis: AnyObject {
  var identity: ComposePresentation.Identity { get }
  var pane: WirePane { get }
  var scope: WireComposeScope { get }
  var textContext: ComposeTextContext? { get }
  /// A candidate only. Measurement must validate its complete layout inputs.
  var measuredInputBase: ComposePresentation? { get }
}

extension ComposeInputBasis {
  func ownsLifetime(window: UInt64, pane: WirePane) -> Bool {
    identity == .init(window: window, leaf: pane.leaf, buffer: pane.buffer)
      && self.pane.compose.viewport.epoch == pane.compose.viewport.epoch
      && self.pane.compose.assetAuthority == pane.compose.assetAuthority
      && self.pane.compose.assetDocument == pane.compose.assetDocument
  }

  var scope: WireComposeScope {
    .with {
      $0.windowID = identity.window; $0.leaf = identity.leaf; $0.buffer = identity.buffer
      $0.bufferRevision = pane.compose.bufferRevision
      $0.projectionRevision = pane.compose.projectionRevision
      $0.selectionRevision = pane.compose.selectionRevision
    }
  }
}

/// An exact Fresh header/raw-text snapshot, with no manufactured display map,
/// font, glyph lines, viewport geometry or authority borrowed from an old frame.
@MainActor
final class ComposeInputSnapshot: ComposeInputBasis {
  let identity: ComposePresentation.Identity
  let pane: WirePane
  let textContext: ComposeTextContext?
  let measuredInputBase: ComposePresentation?

  init?(pane: WirePane, window: UInt64, previous: (any ComposeInputBasis)? = nil) {
    guard pane.hasBuffer, pane.hasCompose, pane.compose.documentLen <= UInt64(Int.max) else { return nil }
    let identity = ComposePresentation.Identity(window: window, leaf: pane.leaf, buffer: pane.buffer)
    self.identity = identity
    self.pane = pane
    let sameLifetime = previous?.ownsLifetime(window: window, pane: pane) ?? false
    if pane.compose.hasTextContext {
      textContext = ComposeTextContext(pane.compose.textContext, documentLength: pane.compose.documentLen,
        reuse: sameLifetime ? previous?.textContext : nil)
      guard textContext != nil else { return nil }
    } else { textContext = nil }
    // A source receipt may advance without ready formatting. Keep that exact
    // source owner; never retain a pre-edit pane merely to obtain its geometry.
    if sameLifetime, let base = previous?.measuredInputBase,
       base.identity == identity, base.pane.compose.bufferRevision == pane.compose.bufferRevision {
      measuredInputBase = base
    } else { measuredInputBase = nil }
  }
}
