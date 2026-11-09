import AppKit
import FreshKit
import SwiftUI

/// Fresh's Settings and key binding editor as native panels over the editor
/// window. Fresh owns their state; the panels draw it from the scene. Keys keep
/// going to Fresh (the panels never take the keyboard), and clicks become the
/// same `settings` and `kbedit` messages a click on Fresh's own cells resolves
/// to. While one of Fresh's own small dialogs is up (an unsaved-changes
/// confirmation, the binding edit dialog), the panel steps aside so Fresh shows
/// it as it draws it.
struct FreshModals: View {
  let store: SceneStore
  let send: (SceneInput) -> Void

  var body: some View {
    let _ = store.regionRevisions["settings"]
    let _ = store.regionRevisions["keybindingEditor"]
    let _ = store.revision
    ZStack {
      if let settings = FreshModals.settings(store) {
        Color.black.opacity(0.55)
        SettingsPanel(model: settings, send: send)
          .padding(28)
      } else if let editor = FreshModals.keybindings(store) {
        Color.black.opacity(0.55)
        KeybindingPanel(model: editor, send: send)
          .padding(28)
      }
    }
  }

  /// The Settings model, when the panel should show it.
  static func settings(_ store: SceneStore) -> WireSettingsView? {
    guard let settings = store.settings, !settings.showingConfirm, !settings.showingReset else { return nil }
    return settings
  }

  /// The key binding editor model, when the panel should show it.
  static func keybindings(_ store: SceneStore) -> WireKeybindingEditorView? {
    guard let editor = store.keybindingEditor, !editor.hasEditDialog, !editor.hasConfirm, !editor.showingHelp else { return nil }
    return editor
  }

  static func showing(_ store: SceneStore) -> Bool { settings(store) != nil || keybindings(store) != nil }
}

/// A host for the panels that never takes the keyboard, and lets clicks through
/// to the editor while no panel shows.
final class ModalHost: NSHostingView<FreshModals> {
  var isShowing: () -> Bool = { false }
  override var acceptsFirstResponder: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { isShowing() ? super.hitTest(point) : nil }
}

// MARK: Settings

private struct SettingsPanel: View {
  let model: WireSettingsView
  let send: (SceneInput) -> Void

  private var categories: [WireSettingsCategoryView] { model.categories }
  private var items: [WireSettingItemView] { model.items }
  private var focus: String { model.focus }

  private func hit(_ kind: String, _ a: Int = 0, _ b: Int = 0) -> () -> Void {
    { send(.settingsClick(.click(kind, a, b))) }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(model.title.isEmpty ? "Settings" : model.title).font(.headline)
        Spacer()
        Text("Layer: \(model.targetLayer)").foregroundStyle(.secondary)
          .onTapGesture(perform: hit("layer"))
      }
      .padding(.horizontal, 16).padding(.vertical, 10)
      Divider()
      HStack(spacing: 0) {
        categoryList.frame(width: 210)
        Divider()
        if model.searchActive { searchResults } else { itemList }
      }
      Divider()
      footer
    }
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .overlay { if model.hasEntryDialog { EntryDialog(model: model.entryDialog, send: send) } }
    .overlay {
      if model.showingHelp {
        Text("↑↓ move · Tab switches panel · Space or Return changes · ⌃S saves · Esc closes")
          .padding(14).background(.thickMaterial, in: RoundedRectangle(cornerRadius: 8))
      }
    }
    .shadow(radius: 20)
  }

  private var categoryList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 1) {
        ForEach(Array(categories.enumerated()), id: \.offset) { _, category in
          let index = Int(category.index)
          let selected = category.selected
          HStack(spacing: 4) {
            if category.expandable {
              Image(systemName: category.expanded ? "chevron.down" : "chevron.right")
                .font(.caption2).frame(width: 12)
                .onTapGesture(perform: hit("categoryDisclosure", index))
            } else {
              Spacer().frame(width: 12)
            }
            Text(category.name).lineLimit(1)
            Spacer()
          }
          .padding(.leading, category.nested ? 22 : 8).padding(.vertical, 4).padding(.trailing, 6)
          .background(selected ? (focus == "categories" ? Color.accentColor : Color.secondary.opacity(0.3)) : .clear,
                      in: RoundedRectangle(cornerRadius: 5))
          .foregroundStyle(selected && focus == "categories" ? Color.white : Color.primary)
          .contentShape(Rectangle())
          .onTapGesture(perform: hit("category", index))
          if category.expanded {
            ForEach(Array(category.sections.enumerated()), id: \.offset) { section, name in
              Text(name).font(.callout).foregroundStyle(.secondary).padding(.leading, 30).padding(.vertical, 2)
                .contentShape(Rectangle()).onTapGesture(perform: hit("categorySection", index, section))
            }
          }
        }
      }
      .padding(8)
    }
  }

  private var itemList: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(Array(items.enumerated()), id: \.offset) { position, item in
            if item.sectionStart, item.hasSection {
              Text(item.section).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 10).padding(.leading, 4)
            }
            SettingRow(item: item, live: true, focused: focus == "settings", send: send).id(position)
          }
        }
        .padding(10)
      }
      .onAppear { scrollToSelection(proxy) }
      .onChange(of: items.firstIndex(where: \.selected)) { _, _ in scrollToSelection(proxy) }
    }
  }

  private func scrollToSelection(_ proxy: ScrollViewProxy) {
    if let selected = items.firstIndex(where: \.selected) { proxy.scrollTo(selected) }
  }

  private var searchResults: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        Text(model.searchQuery + "▏")
        Spacer()
      }
      .padding(8).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
      ScrollView {
        VStack(alignment: .leading, spacing: 1) {
          let selected = Int(model.searchSelected)
          ForEach(Array(model.searchResults.enumerated()), id: \.offset) { index, result in
            HStack {
              Text(result.name)
              Text(result.category).foregroundStyle(index == selected ? Color.white.opacity(0.8) : .secondary)
              Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(index == selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(index == selected ? Color.white : Color.primary)
            .contentShape(Rectangle()).onTapGesture(perform: hit("searchResult", index))
          }
        }
      }
    }
    .padding(10)
  }

  private var footer: some View {
    HStack(spacing: 8) {
      Text("⌃S saves · Esc closes · Tab moves between the lists").font(.callout).foregroundStyle(.secondary)
      Spacer()
      let kinds = ["layer", "reset", "save", "cancel"]
      let selected = Int(model.footerSelected)
      ForEach(Array(model.footerButtons.enumerated()), id: \.offset) { index, title in
        let primary = title == "Save"
        Text(title).padding(.horizontal, 12).padding(.vertical, 4)
          .background(primary ? Color.accentColor : Color.secondary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
          .foregroundStyle(primary ? Color.white : Color.primary)
          .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: focus == "footer" && index == selected ? 2 : 0))
          .onTapGesture(perform: hit(index < kinds.count ? kinds[index] : "cancel"))
      }
    }
    .padding(.horizontal, 16).padding(.vertical, 10)
  }
}

/// One setting: name and control on a line, the description under it, and a
/// list block for composite values.
private struct SettingRow: View {
  let item: WireSettingItemView
  let live: Bool
  let focused: Bool
  let send: (SceneInput) -> Void
  var entry = false

  private var index: Int { Int(item.index) }
  private var control: WireSettingControl.OneOf_Control? { item.control.control }
  private var isList: Bool {
    switch control {
    case .textList?, .map?, .objectArray?, .dualList?: return true
    default: return false
    }
  }

  private func hit(_ kind: String, _ b: Int = 0) -> () -> Void {
    let index = self.index
    let entry = self.entry
    return {
      if entry { send(.settingsClick(.click("entryItem", index))) } else if live {
        send(.settingsClick(.click(kind, index, b)))
      }
    }
  }

  var body: some View {
    let selected = item.selected
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text(item.name + (item.modified ? "  •" : ""))
          .fontWeight(selected ? .semibold : .regular)
          .onTapGesture(perform: hit("item"))
        Spacer(minLength: 12)
        if !isList { inlineControl }
      }
      if !item.description_p.isEmpty {
        Text(item.description_p).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      if isList { listControl }
    }
    .padding(.horizontal, 10).padding(.vertical, 7)
    .background(selected ? Color.accentColor.opacity(focused ? 0.18 : 0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor.opacity(selected && focused ? 0.8 : 0), lineWidth: 1))
    .opacity(item.readOnly ? 0.55 : 1)
    .contentShape(Rectangle())
    .onTapGesture(perform: hit("item"))
  }

  @ViewBuilder private var inlineControl: some View {
    switch control {
    case .toggle(let toggle)?:
      let on = toggle.checked
      Capsule().fill(on ? Color.accentColor : Color.secondary.opacity(0.35)).frame(width: 34, height: 20)
        .overlay(Circle().fill(.white).padding(2).offset(x: on ? 7 : -7))
        .onTapGesture(perform: hit("controlToggle"))
    case .number(let number)?:
      let value = number.value
      let shown = number.percent ? "\(Int((value * 100).rounded()))%"
        : number.integer ? "\(Int(value.rounded()))" : String(format: "%g", value)
      HStack(spacing: 0) {
        Image(systemName: "minus").frame(width: 24, height: 20).contentShape(Rectangle()).onTapGesture(perform: hit("controlDecrement"))
        Text(shown).monospacedDigit().frame(minWidth: 44)
        Image(systemName: "plus").frame(width: 24, height: 20).contentShape(Rectangle()).onTapGesture(perform: hit("controlIncrement"))
      }
      .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
    case .dropdown(let dropdown)?:
      let options = dropdown.options
      let selected = Int(dropdown.selected)
      VStack(alignment: .trailing, spacing: 2) {
        HStack(spacing: 4) {
          Text(selected < options.count ? options[selected] : "—")
          Image(systemName: "chevron.up.chevron.down").font(.caption2)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
        .onTapGesture(perform: hit("controlDropdown"))
        if dropdown.open {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { option, name in
              Text(name).padding(.horizontal, 8).padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading)
                .background(option == selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(option == selected ? Color.white : Color.primary)
                .contentShape(Rectangle()).onTapGesture(perform: hit("controlDropdownOption", option))
            }
          }
          .padding(4).frame(maxWidth: 260).background(.thickMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
      }
    case .text(let text)?:
      textField(text.value, editing: text.editing, placeholder: text.placeholder, monospaced: false)
    case .json(let json)?:
      textField(json.value, editing: false, placeholder: "", monospaced: true)
    case .complex(let complex)?:
      Text("‹\(complex.typeName.isEmpty ? "value" : complex.typeName)›").foregroundStyle(.secondary)
    default:
      EmptyView()
    }
  }

  private func textField(_ value: String, editing: Bool, placeholder: String, monospaced: Bool) -> some View {
    Text(value.isEmpty ? placeholder : value + (editing ? "▏" : ""))
      .font(monospaced ? .system(.body, design: .monospaced) : .body)
      .foregroundStyle(value.isEmpty ? .secondary : .primary)
      .lineLimit(1).truncationMode(.tail)
      .padding(.horizontal, 6).padding(.vertical, 3).frame(minWidth: 140, maxWidth: 320, alignment: .leading)
      .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
      .overlay(RoundedRectangle(cornerRadius: 5).stroke(editing ? Color.accentColor : Color.secondary.opacity(0.3)))
      .onTapGesture(perform: hit("controlText"))
  }

  @ViewBuilder private var listControl: some View {
    switch control {
    case .dualList(let list)?:
      HStack(alignment: .top, spacing: 8) {
        dualColumn("Available", list.available, active: list.activeColumn == "available",
                   cursor: Int(list.availableCursor), kind: "controlDualListAvailable")
        VStack(spacing: 4) {
          ForEach([("arrow.right", "controlDualListAdd"), ("arrow.left", "controlDualListRemove"),
                   ("arrow.up", "controlDualListMoveUp"), ("arrow.down", "controlDualListMoveDown")], id: \.1) { symbol, kind in
            Image(systemName: symbol).frame(width: 26, height: 22).background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
              .onTapGesture(perform: hit(kind))
          }
        }
        dualColumn("Included", list.included, active: list.activeColumn == "included",
                   cursor: Int(list.includedCursor), kind: "controlDualListIncluded")
      }
    case .textList(let list)?:
      rowList(list.items.map { ($0, nil) }, focused: list.hasFocused ? Int(list.focused) : nil, addFocused: false,
              add: hit("controlTextListRow", list.items.count), row: "controlTextListRow")
    case .map(let map)?:
      rowList(map.entries.map { ($0.key, $0.display.isEmpty ? nil : $0.display) }, focused: map.hasFocused ? Int(map.focused) : nil,
              addFocused: map.addFocused, add: map.noAdd ? nil : hit("controlMapAddNew"), row: "controlMapRow")
    case .objectArray(let array)?:
      rowList(array.entries.map { ($0, nil) }, focused: array.hasFocused ? Int(array.focused) : nil, addFocused: array.addFocused,
              add: hit("controlTextListRow", array.entries.count), row: "controlMapRow")
    default:
      EmptyView()
    }
  }

  /// A list setting's rows and its Add… row (unless `add` is nil).
  private func rowList(_ rows: [(String, String?)], focused focusedRow: Int?, addFocused: Bool, add: (() -> Void)?, row kind: String) -> some View {
      VStack(alignment: .leading, spacing: 1) {
        if rows.isEmpty { Text("No entries").foregroundStyle(.secondary).padding(.vertical, 2) }
        ForEach(Array(rows.enumerated()), id: \.offset) { row, value in
          HStack {
            Text(value.0)
            if let sub = value.1 { Text(sub).foregroundStyle(.secondary) }
            Spacer()
          }
          .padding(.horizontal, 8).padding(.vertical, 3)
          .background(row == focusedRow ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
          .contentShape(Rectangle())
          .onTapGesture(perform: hit(kind, row))
        }
        if let add {
          Label("Add…", systemImage: "plus").font(.callout).padding(.horizontal, 8).padding(.vertical, 3)
            .background(addFocused ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .onTapGesture(perform: add)
        }
      }
      .padding(6).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
  }

  private func dualColumn(_ title: String, _ values: [String], active: Bool, cursor: Int, kind: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      ForEach(Array(values.enumerated()), id: \.offset) { row, value in
        Text(value).padding(.horizontal, 6).padding(.vertical, 2).frame(maxWidth: .infinity, alignment: .leading)
          .background(active && row == cursor ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
          .foregroundStyle(active && row == cursor ? Color.white : Color.primary)
          .contentShape(Rectangle()).onTapGesture(perform: hit(kind, row))
      }
    }
    .padding(6).frame(maxWidth: .infinity).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
  }
}

/// The add/edit dialog of a map or list setting: pick a field, then edit it from the keyboard.
private struct EntryDialog: View {
  let model: WireEntryDialogView
  let send: (SceneInput) -> Void

  var body: some View {
    ZStack {
      Color.black.opacity(0.25)
      VStack(alignment: .leading, spacing: 8) {
        Text(model.title).font(.headline)
        let selected = Int(model.selectedItem)
        let onButtons = model.focusOnButtons
        ScrollView {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(model.items.enumerated()), id: \.offset) { position, item in
              var marked = item
              let _ = marked.selected = position == selected && !onButtons
              SettingRow(item: marked, live: false, focused: true, send: send, entry: true)
            }
          }
        }
        .frame(maxHeight: 360)
        HStack {
          Spacer()
          let focused = Int(model.focusedButton)
          let names = model.noDelete ? ["Save", "Cancel"] : ["Save", "Delete", "Cancel"]
          let order = ["Save": 0, "Cancel": 1, "Delete": 2]
          ForEach(names, id: \.self) { name in
            Text(name).padding(.horizontal, 12).padding(.vertical, 4)
              .background(name == "Save" ? Color.accentColor : name == "Delete" ? Color.red.opacity(0.8) : Color.secondary.opacity(0.2),
                          in: RoundedRectangle(cornerRadius: 6))
              .foregroundStyle(name == "Cancel" ? Color.primary : Color.white)
              .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: onButtons && order[name] == focused ? 2 : 0))
              .onTapGesture { send(.settingsClick(WireSettingsClick.with { $0.kind = "entryButton"; $0.button = name.lowercased() })) }
          }
        }
      }
      .padding(18).frame(maxWidth: 560)
      .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12)).shadow(radius: 16)
    }
  }
}

// MARK: Key binding editor

private struct KeybindingPanel: View {
  let model: WireKeybindingEditorView
  let send: (SceneInput) -> Void

  var body: some View {
    let search = model.search
    let rows = model.rows
    let start = Int(model.scrollOffset)
    let count = Int(model.viewport)
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Text(model.title.isEmpty ? "Keyboard Shortcuts" : model.title).font(.headline)
        let maps = model.keymaps.joined(separator: ", ")
        Text(model.configPath + (maps.isEmpty ? "" : "   ·   \(maps)")).font(.caption).foregroundStyle(.secondary)
        HStack(spacing: 8) {
          if search.active {
            HStack {
              Image(systemName: search.mode == "recordKey" ? "keyboard" : "magnifyingglass").foregroundStyle(.secondary)
              Text(search.mode == "recordKey" ? (search.keyDisplay.isEmpty ? "Press a key…" : search.keyDisplay)
                   : search.query + (search.focused ? "▏" : ""))
              Spacer()
            }
            .padding(6).frame(maxWidth: 320).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
          }
          chip("Context: \(model.contextFilter)", on: model.contextFiltered)
          chip("Source: \(model.sourceFilter)", on: model.sourceFiltered)
          Spacer()
          Text("\(model.count) bindings" + (model.hasChanges_p ? " · changed" : ""))
            .foregroundStyle(.secondary)
        }
      }
      .padding(16)
      Divider()
      HStack(spacing: 0) {
        ForEach([("Key", 150.0), ("Action", 200.0), ("Description", 0.0), ("Context", 110.0), ("Source", 80.0)], id: \.0) { title, width in
          Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .frame(width: width == 0 ? nil : width, alignment: .leading).frame(maxWidth: width == 0 ? .infinity : nil, alignment: .leading)
        }
      }
      .padding(.horizontal, 16).padding(.vertical, 6)
      ScrollViewReader { proxy in
      ScrollView {
      VStack(spacing: 0) {
        ForEach(start..<min(rows.count, start + max(0, count)), id: \.self) { index in
          let row = rows[index].row
          let selected: Bool = {
            switch row {
            case .section(let section)?: return section.selected
            case .binding(let binding)?: return binding.selected
            case nil: return false
            }
          }()
          Group {
            switch row {
            case .section(let section)?:
              HStack {
                Image(systemName: section.collapsed ? "chevron.right" : "chevron.down").font(.caption2)
                Text("\(section.name) (\(section.count))").fontWeight(.semibold)
                Spacer()
              }
            case .binding(let binding)?:
              HStack(spacing: 0) {
                Text(binding.key).font(.system(.body, design: .monospaced)).frame(width: 150, alignment: .leading)
                Text(binding.action).frame(width: 200, alignment: .leading)
                Text(binding.description_p).foregroundStyle(selected ? .white : .secondary).frame(maxWidth: .infinity, alignment: .leading)
                Text(binding.context).frame(width: 110, alignment: .leading)
                Text(binding.source).frame(width: 80, alignment: .leading)
              }
              .lineLimit(1)
            case nil:
              EmptyView()
            }
          }
          .padding(.horizontal, 10).padding(.vertical, 3)
          .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
          .foregroundStyle(selected ? Color.white : Color.primary)
          .contentShape(Rectangle())
          .onTapGesture { send(.kbEditClick(row: index)) }
          .id(index)
        }
      }
      .padding(.horizontal, 6)
      }
      .onChange(of: Int(model.selected)) { _, selected in proxy.scrollTo(selected) }
      }
      Divider()
      Text("Return edits · / searches · a adds · d deletes · ⌃S saves · Esc closes · ? help").font(.callout).foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .shadow(radius: 20)
  }

  private func chip(_ text: String, on: Bool) -> some View {
    Text(text).font(.callout).padding(.horizontal, 8).padding(.vertical, 3)
      .background(on ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12), in: Capsule())
  }
}

extension WireSettingsClick {
  /// A click on part `kind` of the panel, with its indices.
  static func click(_ kind: String, _ a: Int, _ b: Int = 0) -> WireSettingsClick {
    WireSettingsClick.with {
      $0.kind = kind
      $0.a = UInt64(clamping: a)
      $0.b = UInt64(clamping: b)
    }
  }
}
