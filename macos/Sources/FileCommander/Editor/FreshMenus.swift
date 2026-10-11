import AppKit
import ExplainerKit
import FreshKit

/// Fresh's menus in the macOS menu bar while the editor is shown in the key
/// window. The menu bar becomes the app menu, Fresh's own menus (File, Edit,
/// View, ... and any a plugin adds) and Window; File Commander's menus come
/// back when the files are shown or another window becomes key. Items are built from the scene each time a menu opens,
/// so enabled and checked states are always current, and choosing one sends
/// the action to Fresh.
@MainActor
final class FreshMenus: NSObject, NSMenuDelegate {
  private let store: SceneStore
  private let run: (String, [String: Any]) -> Void
  /// Opens File Commander's Settings window.
  var openSettings: (() -> Void)?
  /// Hides the editor and shows the files.
  var showFiles: (() -> Void)?
  private var saved: NSMenu?
  private var installed: NSMenu?
  private var repairPending = false
  private var observers: [NSObjectProtocol] = []
  private var installedLabels: [String] = []

  /// Cmd shortcuts Fresh's macos-gui keymap gives these actions; shown on the
  /// items so the menus teach them. The editor view sends the keys to Fresh
  /// itself, so the menu only fires them when it is clicked.
  static let shortcuts: [String: (String, NSEvent.ModifierFlags)] = [
    "save": ("s", .command), "save_as": ("s", [.command, .shift]), "open": ("o", .command), "new": ("n", .command),
    "close_tab": ("w", .command), "undo": ("z", .command), "redo": ("z", [.command, .shift]), "copy": ("c", .command),
    "cut": ("x", .command), "paste": ("v", .command), "select_all": ("a", .command), "search": ("f", .command),
    "find_next": ("g", .command), "find_previous": ("g", [.command, .shift]), "quick_open": ("p", .command),
    "command_palette": ("p", [.command, .shift]), "add_cursor_next_match": ("d", .command), "goto_line": ("l", .command),
    "toggle_comment": ("/", .command), "toggle_file_explorer": ("b", .command), "delete_line": ("k", [.command, .shift]),
    "focus_file_explorer": ("e", .command), "navigate_back": ("-", .command), "navigate_forward": ("=", .command),
  ]

  init(store: SceneStore, run: @escaping (String, [String: Any]) -> Void) {
    self.store = store
    self.run = run
    super.init()
    for name in [NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
        MainActor.assumeIsolated { self?.barEdited(note.object as? NSMenu) }
      })
    }
  }

  private var entries: [[String: Any]] {
    (store.regions["menus"] as? [[String: Any]] ?? []).filter { $0["visible"] as? Bool ?? true }
  }

  // MARK: Installing

  func install() {
    guard saved == nil else { return }
    saved = NSApp.mainMenu
    let bar = buildMainMenu()
    installed = bar
    NSApp.mainMenu = bar
  }

  func uninstall() {
    guard let saved else { return }
    NSApp.mainMenu = saved
    self.saved = nil
    installed = nil
  }

  /// SwiftUI writes changes to the app's commands into whatever menu bar is
  /// installed, so a change while Fresh's bar is up lands in it. The app holds
  /// its commands still meanwhile (`AppController.menusHeld`); should one get
  /// through anyway, Fresh's bar is rebuilt.
  private func barEdited(_ menu: NSMenu?) {
    guard let menu, menu === installed, !repairPending else { return }
    repairPending = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.repairPending = false
      guard self.saved != nil else { return }
      Trace.write("menus: the app's commands changed in Fresh's menu bar; rebuilding it")
      let bar = self.buildMainMenu()
      self.installed = bar
      NSApp.mainMenu = bar
    }
  }

  /// Rebuilds the bar when Fresh's top-level menus change (a plugin added one).
  func menusChanged() {
    guard saved != nil else { return }
    let labels = entries.map { $0["label"] as? String ?? "" }
    guard labels != installedLabels else { return }
    let bar = buildMainMenu()
    installed = bar
    NSApp.mainMenu = bar
  }

  private func buildMainMenu() -> NSMenu {
    let bar = NSMenu(title: "Main")
    let appItem = NSMenuItem(title: "File Commander", action: nil, keyEquivalent: "")
    let appMenu = NSMenu(title: "File Commander")
    appMenu.addItem(withTitle: "About File Commander", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(item("Settings…", key: ",", action: #selector(settings)))
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Hide File Commander", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    let others = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
    others.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit File Commander", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    bar.addItem(appItem)

    installedLabels = []
    for (index, entry) in entries.enumerated() {
      let label = entry["label"] as? String ?? ""
      installedLabels.append(label)
      let top = NSMenuItem(title: label, action: nil, keyEquivalent: "")
      let menu = NSMenu(title: label)
      menu.autoenablesItems = false
      menu.delegate = self
      menu.identifier = NSUserInterfaceItemIdentifier("fresh.\(index)")
      top.submenu = menu
      bar.addItem(top)
    }

    let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    windowMenu.addItem(.separator())
    windowMenu.addItem(item("Show Files", key: "", action: #selector(files)))
    windowMenu.addItem(.separator())
    windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
    windowItem.submenu = windowMenu
    bar.addItem(windowItem)
    NSApp.windowsMenu = windowMenu
    return bar
  }

  private func item(_ title: String, key: String, action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.target = self
    return item
  }

  @objc private func settings() { openSettings?() }
  @objc private func files() { showFiles?() }

  // MARK: Fresh's items

  func menuNeedsUpdate(_ menu: NSMenu) {
    guard let id = menu.identifier?.rawValue, id.hasPrefix("fresh.") else { return }
    let path = id.dropFirst("fresh.".count).split(separator: ".").compactMap { Int($0) }
    guard let first = path.first, first < entries.count else { return }
    var items = entries[first]["items"] as? [[String: Any]] ?? []
    for index in path.dropFirst() {
      guard index < items.count else { return }
      items = items[index]["items"] as? [[String: Any]] ?? []
    }
    menu.removeAllItems()
    for (index, entry) in items.enumerated() {
      switch entry["kind"] as? String {
      case "sep":
        if menu.items.last.map({ !$0.isSeparatorItem }) ?? false { menu.addItem(.separator()) }
      case "submenu":
        let item = NSMenuItem(title: entry["label"] as? String ?? "", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: item.title)
        submenu.autoenablesItems = false
        submenu.delegate = self
        submenu.identifier = NSUserInterfaceItemIdentifier(id + ".\(index)")
        item.submenu = submenu
        menu.addItem(item)
      case "action":
        let action = entry["action"] as? String ?? ""
        let item = NSMenuItem(title: entry["label"] as? String ?? action, action: #selector(choose(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = MenuAction(name: action, args: entry["args"] as? [String: Any] ?? [:])
        item.isEnabled = entry["enabled"] as? Bool ?? true
        if let checked = entry["checked"] as? Bool { item.state = checked ? .on : .off }
        if let (key, modifiers) = FreshMenus.shortcuts[action] {
          item.keyEquivalent = key
          item.keyEquivalentModifierMask = modifiers
        } else if let accel = entry["accel"] as? String, !accel.isEmpty {
          item.attributedTitle = FreshMenus.title(item.title, accelerator: accel)
        }
        menu.addItem(item)
      default:
        if let label = entry["label"] as? String, !label.isEmpty {
          let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
          item.isEnabled = false
          menu.addItem(item)
        }
      }
    }
    while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
  }

  @objc private func choose(_ sender: NSMenuItem) {
    guard let action = sender.representedObject as? MenuAction else { return }
    run(action.name, action.args)
  }

  /// "Title" with Fresh's own shortcut right-aligned, for keys that aren't Cmd chords.
  static func title(_ title: String, accelerator: String) -> NSAttributedString {
    let style = NSMutableParagraphStyle()
    style.tabStops = [NSTextTab(textAlignment: .right, location: 260)]
    let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: style])
    text.append(NSAttributedString(string: "\t" + accelerator, attributes: [
      .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
    ]))
    return text
  }
}

private final class MenuAction: NSObject {
  let name: String
  let args: [String: Any]

  init(name: String, args: [String: Any]) {
    self.name = name
    self.args = args
  }
}
