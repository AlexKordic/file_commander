import AppKit
import FreshKit

/// Native popup geometry and input share this presentation. Fresh's retained
/// picture supplies wrapped rows, selection, scrollbar and close affordances.
@MainActor
struct ComposePopupPresentation {
  let popup: WireScenePopup
  let placement: ComposePopupPlacement
  let relocated: Bool
}

extension CellGridView {
  func popupPresentation(_ popup: WireScenePopup) -> ComposePopupPresentation? {
    let cell = CGSize(width: cellWidth, height: cellHeight)
    let area = bounds.intersection(CGRect(x: 0, y: 0, width: CGFloat(store.width) * cellWidth,
                                          height: CGFloat(store.height) * cellHeight))
    if richPopupProjection, popup.hasSourceAnchor {
      let anchor = popup.sourceAnchor
      guard store.nativePopupProjection, composeInputAllowed, popup.hasGrid,
            let pane = composePanes[anchor.leaf], pane.identity.window == anchor.windowID,
            pane.identity.buffer == anchor.buffer, pane.pane.compose.focused,
            pane.pane.compose.viewport.epoch == anchor.bufferEpoch,
            pane.pane.compose.bufferRevision == anchor.bufferRevision,
            pane.cursor?.position == anchor.caret, !pane.pendingSelection,
            pane.layout.draftDisplayRange == nil, pane.layout.virtualInsertion == nil,
            let caret = pane.caret, pane.bounds.intersects(caret) else { return nil }
      let horizontal = Int(exactly: anchor.horizontal).flatMap { pane.layout.text.caret(for: $0) }
        .map { $0.offsetBy(dx: pane.origin.x, dy: pane.origin.y) }
      guard let placement = ComposePopupPlacement(rect: popup.rect, cell: cell, within: area,
        anchor: caret, horizontal: horizontal, placement: anchor.placement) else { return nil }
      return ComposePopupPresentation(popup: popup, placement: placement, relocated: true)
    }
    guard let placement = ComposePopupPlacement(rect: popup.rect, cell: cell, within: area) else { return nil }
    return ComposePopupPresentation(popup: popup, placement: placement, relocated: false)
  }

  func popup(at point: CGPoint) -> ComposePopupPresentation? {
    store.popups.reversed().compactMap(popupPresentation).first { $0.placement.contains(point) }
  }

  /// A captured popup owns its release even if the press accepted a completion
  /// and removed it. That trailing event must never land in the document.
  func sendPopupMouse(_ kind: WireMouseKind, point: CGPoint, flags: NSEvent.ModifierFlags,
                      button: WireMouseButton = .left, count: Int = 1, steps: Int = 1) -> Bool {
    let presentation: ComposePopupPresentation?
    if (kind == .drag || kind == .up), let captured = popupCapture {
      presentation = store.popups.first { $0.instance == captured }.flatMap(popupPresentation)
      if kind == .up { popupCapture = nil }
      guard presentation != nil else { return true }
    } else if kind == .moved, popup(at: point) == nil, let hovered = popupHover {
      presentation = store.popups.first { $0.instance == hovered }.flatMap(popupPresentation)
      popupHover = nil
    } else {
      presentation = popup(at: point)
    }
    guard let presentation, presentation.relocated,
          let cell = presentation.placement.localCell(at: point) else { return false }
    if kind == .down { popupCapture = presentation.popup.instance }
    if presentation.placement.contains(point) { popupHover = presentation.popup.instance }
    delegate?.grid(self, send: .popupPointer(.with {
      $0.instance = presentation.popup.instance; $0.version = presentation.popup.version
      $0.column = cell.column; $0.row = cell.row
      $0.mouse = .with {
        $0.kind = kind; $0.button = button
        $0.count = UInt64(clamping: count); $0.n = UInt32(clamping: steps)
        $0.ctrl = flags.contains(.control); $0.alt = flags.contains(.option); $0.shift = flags.contains(.shift)
      }
    }))
    return true
  }
}
