import AppKit
import CoreText
import FreshKit

/// Logical preview inputs exist before glyph geometry. Complete text/AX work
/// and queued input may use this owner while the visible frame is still old.
@MainActor
final class ComposeLogicalPreview: ComposeInputBasis {
  let basis: ComposeInputSnapshot
  var identity: ComposePresentation.Identity { basis.identity }
  var pane: WirePane { basis.pane }
  var textContext: ComposeTextContext? { basis.textContext }
  var measuredInputBase: ComposePresentation? { basis.measuredInputBase }
  let composition: ComposeComposition?
  let insertion: ComposeVirtualInsertion?
  let selections: ComposeVirtualSelections?
  let pendingSelection: Bool
  private let body, monospace: NSFont
  private let width: CGFloat
  private let typography: ComposeTypography

  init(basis: ComposeInputSnapshot, body: NSFont, monospace: NSFont, width: CGFloat, typography: ComposeTypography,
       composition: ComposeComposition?, insertion: ComposeVirtualInsertion?, selections: ComposeVirtualSelections?, pendingSelection: Bool) {
    self.basis = basis; self.body = body; self.monospace = monospace; self.width = width; self.typography = typography
    self.composition = composition; self.insertion = insertion; self.selections = selections; self.pendingSelection = pendingSelection
  }

  func environment(images: [UInt64: ComposeImageState]) -> ComposeFlowMeasurement.Environment {
    .init(body: body as CTFont, monospace: monospace as CTFont, width: width, typography: typography, images: images)
  }
}
