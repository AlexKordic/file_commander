import AppKit
import ExplainerKit
import FCKit

/// Routes keys while a listing has the keyboard focus: bound commands first,
/// then typing into the pane's filter, as in the terminal interface. Text
/// fields, sheets and menus get their keys as usual.
@MainActor
final class KeyRouter {
  private weak var app: AppController?
  private var monitor: Any?
  private var escapes: [Date] = []

  init(app: AppController) {
    self.app = app
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      MainActor.assumeIsolated { self?.handle(event) ?? event }
    }
  }

  private func handle(_ event: NSEvent) -> NSEvent? {
    guard let app else { return event }
    if Trace.enabled {
      Trace.write("key \(KeyChord(event: event)?.description ?? "?") window \(event.window?.identifier?.rawValue ?? "-") responder \(event.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") sheet \(event.window?.attachedSheet != nil) palette \(String(describing: app.paletteMode))")
    }
    if let id = app.rebinding {
      if let chord = KeyChord(event: event) {
        if chord.key == "Esc" && chord.modifiers.isEmpty {
          app.rebinding = nil
        } else if let problem = app.rebind(id, to: chord) {
          app.flash(problem)
        } else {
          app.rebinding = nil
          app.flash("\(app.engine.command(id)?.title ?? id): \(chord.symbols)")
        }
      }
      return nil
    }
    if app.tutorial.handleKey(event) { return nil }
    // The editor in the main window takes its own keys.
    if let window = app.editor.window, event.window === window { return event }
    // In the palette, ⌃K rebinds the highlighted command, as in the terminal interface.
    // It must win over a menu shortcut on the same key.
    if app.paletteMode == .commands, let chord = KeyChord(event: event), chord == KeyChord("Ctrl+K"), let id = app.paletteSelection {
      app.rebinding = id
      return nil
    }
    guard let window = event.window, window.attachedSheet == nil, app.paletteMode == nil, let chord = KeyChord(event: event) else { return event }
    if let table = window.firstResponder as? ListingTableView {
      return dispatch(chord, characters: event.characters, side: table.side) ? nil : event
    }
    // Nothing is being typed into in the main window (the focus is on a button,
    // the toolbar or nowhere): keys belong to the focused pane's list.
    guard window.identifier?.rawValue.hasPrefix("main") == true, !(window.firstResponder is NSText),
          let table = app.listing(app.engine.focusedSide) else { return event }
    window.makeFirstResponder(table)
    return dispatch(chord, characters: event.characters, side: table.side) ? nil : event
  }

  /// Runs what a chord does in a focused listing; false when the table should handle it.
  @discardableResult
  func dispatch(_ chord: KeyChord, characters: String?, side: Int) -> Bool {
    guard let app else { return false }
    let engine = app.engine
    if chord.key == "Esc" && chord.modifiers.isEmpty {
      let now = Date()
      escapes = escapes.filter { now.timeIntervalSince($0) < 1 } + [now]
      if escapes.count >= 3 {
        escapes = []
        engine.clearErrors()
        return true
      }
      if engine.pane(side).loading {
        engine.stopLoading(side)
        return true
      }
    } else {
      escapes = []
    }
    if let id = app.keymap.command(for: chord) {
      // Bindings change at once here, before menus catch up; run() ignores the
      // menu's second delivery of the same key press.
      app.run(id)
      return true
    }
    let typing = chord.modifiers.subtracting([.shift]).isEmpty
    guard typing else { return false }
    let filter = engine.pane(side).filter
    if chord.key == "Backspace" {
      guard !filter.isEmpty else { return false }
      engine.setFilter(side, String(filter.dropLast()))
      return true
    }
    guard chord.key.count == 1, let text = characters, !text.isEmpty,
          text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return false }
    engine.setFilter(side, filter + text)
    return true
  }
}
