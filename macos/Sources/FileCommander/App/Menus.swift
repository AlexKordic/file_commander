import AppKit
import FCKit
import SwiftUI

/// Every command in the menu bar, generated from the catalog so the menus
/// always show the current keys and only enable what can run.
struct AppCommands: Commands {
  let app: AppController

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      item("tab_new")
      item("tab_close")
      Divider()
      item("mkdir")
      item("rename")
      item("copy")
      item("move")
      item("delete")
      Divider()
      item("open_in_editor")
      item("connect_ssh")
      item("run_script")
    }
    CommandGroup(after: .pasteboard) {
      Divider()
      item("names_to_clipboard")
      item("paths_to_clipboard")
      Divider()
      item("select_toggle")
      item("glob_select")
      item("glob_deselect")
      item("clear_selection")
      Divider()
      item("find")
    }
    CommandGroup(replacing: .textEditing) {}
    CommandGroup(after: .toolbar) {
      item("command_palette")
      Divider()
      item("toggle_single_panel_mode")
      item("refresh_dir")
      Divider()
      Menu("Sort By") {
        item("sort_by_name")
        item("sort_by_size")
        item("sort_by_date")
      }
      Menu("Columns") {
        item("toggle_permissions_column")
        item("toggle_owner_group_column")
      }
      Divider()
      Button("Bigger Text") { zoom(0.1) }.keyboardShortcut("+", modifiers: .command)
      Button("Smaller Text") { zoom(-0.1) }.keyboardShortcut("-", modifiers: .command)
      Button("Actual Size") { app.preferences.zoom = 1; app.theme.zoom = 1 }.keyboardShortcut("0", modifiers: .command)
      Divider()
      item("edit_theme_colors")
    }
    CommandMenu("Go") {
      item("enter_dir")
      item("leave_dir")
      Divider()
      item("switch_panel")
      item("target_left")
      item("target_right")
      Divider()
      item("open_bookmarks")
      item("add_bookmark")
      Button("Home") { app.engine.navigate(app.engine.focusedSide, to: NSHomeDirectory()) }.keyboardShortcut("h", modifiers: [.command, .shift])
    }
    CommandMenu("Transfers") {
      item("transfer_speed")
      item("toggle_job_list")
      Divider()
      if let job = app.menuJob {
        Button(job.isPaused ? "Resume \(job.title)" : "Pause \(job.title)") {
          if job.isPaused { app.engine.resumeJob(job.id) } else { app.engine.pauseJob(job.id) }
        }
        Button("Cancel \(job.title)") { app.engine.cancelJob(job.id) }
      }
    }
    CommandGroup(before: .windowList) {
      item("tab_next")
      item("tab_prev")
      Divider()
      item("toggle_errors")
      item("clear_errors")
      Divider()
      item("switch_to_file_commander")
      item("restart_editor_backend")
      Divider()
    }
    CommandGroup(replacing: .help) {
      Button("File Commander Tutorial") { app.tutorial.start(TutorialCoordinator.entireID) }
      item("help")
      Divider()
      ForEach(app.tutorial.catalog.chapters) { chapter in
        Menu(chapter.title) {
          ForEach(app.tutorial.catalog.scripts(in: chapter.id)) { script in
            Button(script.title) { app.tutorial.start(script.id) }
          }
        }
      }
    }
  }

  @ViewBuilder
  private func item(_ id: String) -> some View {
    let title = app.engine.command(id)?.title ?? id
    let shortcut = app.keymap.chord(for: id).flatMap { MenuShortcuts.allowed($0) ? $0.shortcut : nil }
    // While the palette is open or a new key is being captured, keys belong to them.
    Button(title) { app.run(id) }
      .keyboardShortcut(shortcut)
      .disabled(!app.engine.isStarted || app.paletteMode != nil || app.rebinding != nil)
  }

  private func zoom(_ delta: Double) {
    app.preferences.zoom = min(2, max(0.7, app.preferences.zoom + delta))
    app.theme.zoom = app.preferences.zoom
  }
}

enum MenuShortcuts {
  /// Commands with a menu item: their shortcuts belong to the menu, so the
  /// key router leaves those chords alone and each key runs once.
  static let inMenus: Set<String> = [
    "tab_new", "tab_close", "mkdir", "rename", "copy", "move", "delete", "open_in_editor", "connect_ssh", "run_script",
    "names_to_clipboard", "paths_to_clipboard", "select_toggle", "glob_select", "glob_deselect", "clear_selection", "find",
    "command_palette", "toggle_single_panel_mode", "refresh_dir", "sort_by_name", "sort_by_size", "sort_by_date",
    "toggle_permissions_column", "toggle_owner_group_column", "edit_theme_colors", "enter_dir", "leave_dir", "switch_panel",
    "target_left", "target_right", "open_bookmarks", "add_bookmark", "transfer_speed", "toggle_job_list", "tab_next", "tab_prev",
    "toggle_errors", "clear_errors", "switch_to_file_commander", "restart_editor_backend", "help",
  ]
  /// Whether a menu item owns this chord for this command.
  static func menuOwns(_ chord: KeyChord, command: String) -> Bool { inMenus.contains(command) && allowed(chord) }

  /// Standard text-editing chords stay with text fields; the key router
  /// still runs them as commands in a file list.
  static func allowed(_ chord: KeyChord) -> Bool {
    let editing: Set<String> = ["Cmd+C", "Cmd+V", "Cmd+X", "Cmd+A", "Cmd+Z", "Shift+Cmd+Z"]
    return chord.isMenuSafe && !editing.contains(chord.description)
  }
}

/// The context menu of a file row.
enum ContextMenu {
  @MainActor
  static func make(app: AppController) -> NSMenu {
    let menu = NSMenu()
    for id in ["enter_dir", "open_in_editor", "-", "copy", "move", "rename", "delete", "-", "names_to_clipboard", "paths_to_clipboard", "-",
               "mkdir", "add_bookmark", "target_left", "target_right"] {
      if id == "-" { menu.addItem(.separator()); continue }
      let item = ClosureMenuItem(title: app.engine.command(id)?.title ?? id) { app.run(id) }
      if let chord = app.keymap.chord(for: id) { item.toolTip = chord.symbols }
      item.isEnabled = app.engine.isAvailable(id)
      menu.addItem(item)
    }
    menu.addItem(.separator())
    menu.addItem(ClosureMenuItem(title: "Explain File Operations…") { app.tutorial.start("copy") })
    return menu
  }
}

final class ClosureMenuItem: NSMenuItem {
  private let handler: () -> Void
  init(title: String, handler: @escaping () -> Void) {
    self.handler = handler
    super.init(title: title, action: #selector(fire), keyEquivalent: "")
    target = self
  }
  required init(coder: NSCoder) { fatalError() }
  @objc private func fire() { handler() }
}
