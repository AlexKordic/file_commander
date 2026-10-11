import AppKit
import FreshKit

/// The native editor as one view: Fresh's cells, the native surfaces drawn
/// over them, and the panels for Fresh's Settings and key bindings. It lives
/// as long as the app, wherever it is shown, so its connection and scene
/// survive being moved or hidden.
@MainActor
final class EditorHostView: NSView {
  let grid: CellGridView
  let chrome: ChromeView
  let modals: ModalHost

  init(store: SceneStore, send: @escaping ([String: Any]) -> Void) {
    grid = CellGridView(store: store)
    chrome = ChromeView(store: store, grid: grid)
    modals = ModalHost(rootView: FreshModals(store: store, send: send))
    super.init(frame: NSRect(x: 0, y: 0, width: 1040, height: 700))
    for view in [grid, chrome, modals] as [NSView] {
      view.frame = bounds
      view.autoresizingMask = [.width, .height]
      addSubview(view)
    }
    modals.isShowing = { FreshModals.showing(store) }
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  /// Fresh's light or dark look for this view only, so the native surfaces
  /// match Fresh's theme while the window around it keeps the app's.
  func applyLook(dark: Bool) {
    appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
  }
}
