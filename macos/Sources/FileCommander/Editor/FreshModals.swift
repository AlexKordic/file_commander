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
  let send: ([String: Any]) -> Void

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
  static func settings(_ store: SceneStore) -> [String: Any]? {
    guard let settings = store.regions["settings"] as? [String: Any] else { return nil }
    if settings["showingConfirm"] as? Bool == true || settings["showingReset"] as? Bool == true { return nil }
    return settings
  }

  /// The key binding editor model, when the panel should show it.
  static func keybindings(_ store: SceneStore) -> [String: Any]? {
    guard let editor = store.regions["keybindingEditor"] as? [String: Any] else { return nil }
    if editor["editDialog"] is [String: Any] || editor["confirm"] is [String: Any] || editor["showingHelp"] as? Bool == true { return nil }
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
  let model: [String: Any]
  let send: ([String: Any]) -> Void

  private var categories: [[String: Any]] { model["categories"] as? [[String: Any]] ?? [] }
  private var items: [[String: Any]] { model["items"] as? [[String: Any]] ?? [] }
  private var focus: String { model["focus"] as? String ?? "" }

  private func hit(_ kind: String, _ a: Int = 0, _ b: Int = 0) -> () -> Void {
    { send(["type": "settings", "kind": kind, "a": a, "b": b]) }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(model["title"] as? String ?? "Settings").font(.headline)
        Spacer()
        Text("Layer: \(model["targetLayer"] as? String ?? "")").foregroundStyle(.secondary)
          .onTapGesture(perform: hit("layer"))
      }
      .padding(.horizontal, 16).padding(.vertical, 10)
      Divider()
      HStack(spacing: 0) {
        categoryList.frame(width: 210)
        Divider()
        if model["searchActive"] as? Bool == true { searchResults } else { itemList }
      }
      Divider()
      footer
    }
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .overlay { if let dialog = model["entryDialog"] as? [String: Any] { EntryDialog(model: dialog, send: send) } }
    .overlay {
      if model["showingHelp"] as? Bool == true {
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
          let index = category["index"] as? Int ?? 0
          let selected = category["selected"] as? Bool ?? false
          HStack(spacing: 4) {
            if category["expandable"] as? Bool == true {
              Image(systemName: category["expanded"] as? Bool == true ? "chevron.down" : "chevron.right")
                .font(.caption2).frame(width: 12)
                .onTapGesture(perform: hit("categoryDisclosure", index))
            } else {
              Spacer().frame(width: 12)
            }
            Text(category["name"] as? String ?? "").lineLimit(1)
            Spacer()
          }
          .padding(.leading, category["nested"] as? Bool == true ? 22 : 8).padding(.vertical, 4).padding(.trailing, 6)
          .background(selected ? (focus == "categories" ? Color.accentColor : Color.secondary.opacity(0.3)) : .clear,
                      in: RoundedRectangle(cornerRadius: 5))
          .foregroundStyle(selected && focus == "categories" ? Color.white : Color.primary)
          .contentShape(Rectangle())
          .onTapGesture(perform: hit("category", index))
          if category["expanded"] as? Bool == true {
            ForEach(Array((category["sections"] as? [String] ?? []).enumerated()), id: \.offset) { section, name in
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
            if item["sectionStart"] as? Bool == true, let section = item["section"] as? String {
              Text(section).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 10).padding(.leading, 4)
            }
            SettingRow(item: item, live: true, focused: focus == "settings", send: send).id(position)
          }
        }
        .padding(10)
      }
      .onAppear { scrollToSelection(proxy) }
      .onChange(of: items.firstIndex { $0["selected"] as? Bool == true }) { _, _ in scrollToSelection(proxy) }
    }
  }

  private func scrollToSelection(_ proxy: ScrollViewProxy) {
    if let selected = items.firstIndex(where: { $0["selected"] as? Bool == true }) { proxy.scrollTo(selected) }
  }

  private var searchResults: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        Text((model["searchQuery"] as? String ?? "") + "▏")
        Spacer()
      }
      .padding(8).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
      ScrollView {
        VStack(alignment: .leading, spacing: 1) {
          let selected = model["searchSelected"] as? Int ?? -1
          ForEach(Array((model["searchResults"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { index, result in
            HStack {
              Text(result["name"] as? String ?? "")
              Text(result["category"] as? String ?? "").foregroundStyle(index == selected ? Color.white.opacity(0.8) : .secondary)
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
      let selected = model["footerSelected"] as? Int ?? -1
      ForEach(Array((model["footerButtons"] as? [String] ?? []).enumerated()), id: \.offset) { index, title in
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
  let item: [String: Any]
  let live: Bool
  let focused: Bool
  let send: ([String: Any]) -> Void
  var entry = false

  private var index: Int { item["index"] as? Int ?? 0 }
  private var control: [String: Any] { item["control"] as? [String: Any] ?? [:] }
  private var kind: String { control["kind"] as? String ?? "" }
  private var isList: Bool { ["textList", "map", "objectArray", "dualList"].contains(kind) }

  private func hit(_ kind: String, _ b: Int = 0) -> () -> Void {
    let index = self.index
    let entry = self.entry
    return {
      if entry { send(["type": "settings", "kind": "entryItem", "a": index]) } else if live {
        send(["type": "settings", "kind": kind, "a": index, "b": b])
      }
    }
  }

  var body: some View {
    let selected = item["selected"] as? Bool ?? false
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text((item["name"] as? String ?? "") + (item["modified"] as? Bool == true ? "  •" : ""))
          .fontWeight(selected ? .semibold : .regular)
          .onTapGesture(perform: hit("item"))
        Spacer(minLength: 12)
        if !isList { inlineControl }
      }
      if let description = item["description"] as? String, !description.isEmpty {
        Text(description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      if isList { listControl }
    }
    .padding(.horizontal, 10).padding(.vertical, 7)
    .background(selected ? Color.accentColor.opacity(focused ? 0.18 : 0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor.opacity(selected && focused ? 0.8 : 0), lineWidth: 1))
    .opacity(item["readOnly"] as? Bool == true ? 0.55 : 1)
    .contentShape(Rectangle())
    .onTapGesture(perform: hit("item"))
  }

  @ViewBuilder private var inlineControl: some View {
    switch kind {
    case "toggle":
      let on = control["checked"] as? Bool ?? false
      Capsule().fill(on ? Color.accentColor : Color.secondary.opacity(0.35)).frame(width: 34, height: 20)
        .overlay(Circle().fill(.white).padding(2).offset(x: on ? 7 : -7))
        .onTapGesture(perform: hit("controlToggle"))
    case "number":
      let value = control["value"] as? Double ?? 0
      let shown = control["percent"] as? Bool == true ? "\(Int((value * 100).rounded()))%"
        : control["integer"] as? Bool == true ? "\(Int(value.rounded()))" : String(format: "%g", value)
      HStack(spacing: 0) {
        Image(systemName: "minus").frame(width: 24, height: 20).contentShape(Rectangle()).onTapGesture(perform: hit("controlDecrement"))
        Text(shown).monospacedDigit().frame(minWidth: 44)
        Image(systemName: "plus").frame(width: 24, height: 20).contentShape(Rectangle()).onTapGesture(perform: hit("controlIncrement"))
      }
      .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
    case "dropdown":
      let options = control["options"] as? [String] ?? []
      let selected = control["selected"] as? Int ?? 0
      VStack(alignment: .trailing, spacing: 2) {
        HStack(spacing: 4) {
          Text(selected < options.count ? options[selected] : "—")
          Image(systemName: "chevron.up.chevron.down").font(.caption2)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
        .onTapGesture(perform: hit("controlDropdown"))
        if control["open"] as? Bool == true {
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
    case "text", "json":
      let value = control["value"] as? String ?? ""
      let editing = control["editing"] as? Bool ?? false
      Text(value.isEmpty ? (control["placeholder"] as? String ?? "") : value + (editing ? "▏" : ""))
        .font(kind == "json" ? .system(.body, design: .monospaced) : .body)
        .foregroundStyle(value.isEmpty ? .secondary : .primary)
        .lineLimit(1).truncationMode(.tail)
        .padding(.horizontal, 6).padding(.vertical, 3).frame(minWidth: 140, maxWidth: 320, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(editing ? Color.accentColor : Color.secondary.opacity(0.3)))
        .onTapGesture(perform: hit("controlText"))
    case "complex":
      Text("‹\(control["typeName"] as? String ?? "value")›").foregroundStyle(.secondary)
    default:
      EmptyView()
    }
  }

  @ViewBuilder private var listControl: some View {
    switch kind {
    case "dualList":
      HStack(alignment: .top, spacing: 8) {
        dualColumn("Available", control["available"] as? [String] ?? [], active: control["activeColumn"] as? String == "available",
                   cursor: control["availableCursor"] as? Int ?? -1, kind: "controlDualListAvailable")
        VStack(spacing: 4) {
          ForEach([("arrow.right", "controlDualListAdd"), ("arrow.left", "controlDualListRemove"),
                   ("arrow.up", "controlDualListMoveUp"), ("arrow.down", "controlDualListMoveDown")], id: \.1) { symbol, kind in
            Image(systemName: symbol).frame(width: 26, height: 22).background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
              .onTapGesture(perform: hit(kind))
          }
        }
        dualColumn("Included", control["included"] as? [String] ?? [], active: control["activeColumn"] as? String == "included",
                   cursor: control["includedCursor"] as? Int ?? -1, kind: "controlDualListIncluded")
      }
    default:
      let rows: [(String, String?)] = {
        switch kind {
        case "textList": return (control["items"] as? [String] ?? []).map { ($0, nil) }
        case "map": return (control["entries"] as? [[String: Any]] ?? []).map { ($0["key"] as? String ?? "", $0["display"] as? String) }
        default: return (control["entries"] as? [String] ?? []).map { ($0, nil) }
        }
      }()
      let focusedRow = control["focused"] as? Int
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
          .onTapGesture(perform: hit(kind == "textList" ? "controlTextListRow" : "controlMapRow", row))
        }
        if !(kind == "map" && control["noAdd"] as? Bool == true) {
          Label("Add…", systemImage: "plus").font(.callout).padding(.horizontal, 8).padding(.vertical, 3)
            .background(control["addFocused"] as? Bool == true ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .onTapGesture(perform: kind == "map" ? hit("controlMapAddNew") : hit("controlTextListRow", rows.count))
        }
      }
      .padding(6).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
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
  let model: [String: Any]
  let send: ([String: Any]) -> Void

  var body: some View {
    ZStack {
      Color.black.opacity(0.25)
      VStack(alignment: .leading, spacing: 8) {
        Text(model["title"] as? String ?? "").font(.headline)
        let selected = model["selectedItem"] as? Int ?? -1
        let onButtons = model["focusOnButtons"] as? Bool ?? false
        ScrollView {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(Array((model["items"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { position, item in
              var marked = item
              let _ = marked["selected"] = position == selected && !onButtons
              SettingRow(item: marked, live: false, focused: true, send: send, entry: true)
            }
          }
        }
        .frame(maxHeight: 360)
        HStack {
          Spacer()
          let focused = model["focusedButton"] as? Int ?? -1
          let names = model["noDelete"] as? Bool == true ? ["Save", "Cancel"] : ["Save", "Delete", "Cancel"]
          let order = ["Save": 0, "Cancel": 1, "Delete": 2]
          ForEach(names, id: \.self) { name in
            Text(name).padding(.horizontal, 12).padding(.vertical, 4)
              .background(name == "Save" ? Color.accentColor : name == "Delete" ? Color.red.opacity(0.8) : Color.secondary.opacity(0.2),
                          in: RoundedRectangle(cornerRadius: 6))
              .foregroundStyle(name == "Cancel" ? Color.primary : Color.white)
              .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: onButtons && order[name] == focused ? 2 : 0))
              .onTapGesture { send(["type": "settings", "kind": "entryButton", "button": name.lowercased()]) }
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
  let model: [String: Any]
  let send: ([String: Any]) -> Void

  var body: some View {
    let search = model["search"] as? [String: Any] ?? [:]
    let rows = model["rows"] as? [[String: Any]] ?? []
    let start = model["scrollOffset"] as? Int ?? 0
    let count = model["viewport"] as? Int ?? rows.count
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Text(model["title"] as? String ?? "Keyboard Shortcuts").font(.headline)
        let maps = (model["keymaps"] as? [String] ?? []).joined(separator: ", ")
        Text((model["configPath"] as? String ?? "") + (maps.isEmpty ? "" : "   ·   \(maps)")).font(.caption).foregroundStyle(.secondary)
        HStack(spacing: 8) {
          if search["active"] as? Bool == true {
            HStack {
              Image(systemName: search["mode"] as? String == "recordKey" ? "keyboard" : "magnifyingglass").foregroundStyle(.secondary)
              Text(search["mode"] as? String == "recordKey" ? (search["keyDisplay"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Press a key…"
                   : (search["query"] as? String ?? "") + (search["focused"] as? Bool == true ? "▏" : ""))
              Spacer()
            }
            .padding(6).frame(maxWidth: 320).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
          }
          chip("Context: \(model["contextFilter"] as? String ?? "")", on: model["contextFiltered"] as? Bool ?? false)
          chip("Source: \(model["sourceFilter"] as? String ?? "")", on: model["sourceFiltered"] as? Bool ?? false)
          Spacer()
          Text("\(model["count"] as? String ?? "") bindings" + (model["hasChanges"] as? Bool == true ? " · changed" : ""))
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
          let row = rows[index]
          let selected = row["selected"] as? Bool ?? false
          Group {
            if row["type"] as? String == "section" {
              HStack {
                Image(systemName: row["collapsed"] as? Bool == true ? "chevron.right" : "chevron.down").font(.caption2)
                Text("\(row["name"] as? String ?? "") (\(row["count"] as? Int ?? 0))").fontWeight(.semibold)
                Spacer()
              }
            } else {
              HStack(spacing: 0) {
                Text(row["key"] as? String ?? "").font(.system(.body, design: .monospaced)).frame(width: 150, alignment: .leading)
                Text(row["action"] as? String ?? "").frame(width: 200, alignment: .leading)
                Text(row["description"] as? String ?? "").foregroundStyle(selected ? .white : .secondary).frame(maxWidth: .infinity, alignment: .leading)
                Text(row["context"] as? String ?? "").frame(width: 110, alignment: .leading)
                Text(row["source"] as? String ?? "").frame(width: 80, alignment: .leading)
              }
              .lineLimit(1)
            }
          }
          .padding(.horizontal, 10).padding(.vertical, 3)
          .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
          .foregroundStyle(selected ? Color.white : Color.primary)
          .contentShape(Rectangle())
          .onTapGesture { send(["type": "kbedit", "a": index]) }
          .id(index)
        }
      }
      .padding(.horizontal, 6)
      }
      .onChange(of: model["selected"] as? Int ?? 0) { _, selected in proxy.scrollTo(selected) }
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
