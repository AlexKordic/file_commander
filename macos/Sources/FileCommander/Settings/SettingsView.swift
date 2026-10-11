import AppKit
import ExplainerKit
import FCKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  @Environment(AppController.self) private var app

  var body: some View {
    @Bindable var app = app
    TabView(selection: $app.settingsTab) {
      GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
      KeySettings().tabItem { Label("Keys", systemImage: "keyboard") }.tag(SettingsTab.keys)
      ThemeEditor().tabItem { Label("Appearance", systemImage: "paintpalette") }.tag(SettingsTab.appearance)
      TransferSettings().tabItem { Label("Transfers", systemImage: "speedometer") }.tag(SettingsTab.transfers)
      EditorSettings().tabItem { Label("Editor", systemImage: "chevron.left.forwardslash.chevron.right") }.tag(SettingsTab.editor)
      TutorialSettings().tabItem { Label("Tutorial", systemImage: "graduationcap") }.tag(SettingsTab.tutorial)
    }
    .frame(width: 860, height: 600)
    .explainerAnchor("settings")
  }
}

struct GeneralSettings: View {
  @Environment(AppController.self) private var app
  var body: some View {
    @Bindable var app = app
    Form {
      Picker("Selection style", selection: $app.preferences.selectionStyle) {
        ForEach(AppPreferences.SelectionStyle.allCases) { Text($0.title).tag($0) }
      }
      Text("Commander: arrow keys move a cursor, Space marks items, commands act on the marked items or the cursor. Finder: arrow keys select, ⌘-click adds to the selection.")
        .font(.callout).foregroundStyle(.secondary)
      LabeledContent("Cursor margin") {
        HStack {
          Text("Edge").font(.caption).foregroundStyle(.secondary)
          Slider(value: Binding(get: { Double(app.preferences.scrollMargin) }, set: { app.preferences.scrollMargin = Int($0.rounded()) }),
                 in: 0...10, step: 1)
            .frame(width: 220)
          Text("Center").font(.caption).foregroundStyle(.secondary)
          Text("\(app.preferences.scrollMargin)").monospacedDigit().frame(width: 24)
        }
      }
      Text("How far from the edge of a pane the arrow keys and Page Up/Down keep the cursor: 0 lets it reach the edge, 10 keeps it in the middle. Near the start and end of a list it moves closer to the edge.")
        .font(.callout).foregroundStyle(.secondary)
      Picker("Appearance", selection: $app.preferences.appearance) {
        ForEach(AppPreferences.Appearance.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      LabeledContent("Text size") {
        Stepper(value: $app.preferences.zoom, in: 0.7...2.0, step: 0.1) { Text("\(Int(app.preferences.zoom * 100))%") }
          .onChange(of: app.preferences.zoom) { _, new in app.theme.zoom = new }
      }
      LabeledContent("Profile") {
        Text(app.engine.profileDirectory).textSelection(.enabled).foregroundStyle(.secondary)
      }
      Text("The profile is shared with the terminal interface: workspace, bookmarks and paused transfers move between the two. Only one of them can use a profile at a time.")
        .font(.callout).foregroundStyle(.secondary)
    }
    .formStyle(.grouped)
  }
}

struct KeySettings: View {
  @Environment(AppController.self) private var app
  @State private var query = ""
  @State private var problem = ""

  var body: some View {
    @Bindable var app = app
    VStack(spacing: 10) {
      HStack {
        Picker("Preset", selection: $app.preferences.keyPreset) {
          ForEach(AppPreferences.KeyPreset.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented).frame(width: 240)
        Spacer()
        TextField("Search", text: $query).textFieldStyle(.roundedBorder).frame(width: 200)
        Button("Reset Preset") { app.resetKeys() }
      }
      if let id = app.rebinding {
        Label("Press the new key for “\(app.engine.command(id)?.title ?? id)”. Esc cancels.", systemImage: "keyboard")
          .frame(maxWidth: .infinity).padding(8).background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
      }
      if !problem.isEmpty { Text(problem).foregroundStyle(.red) }
      Table(commands) {
        TableColumn("Command") { command in
          VStack(alignment: .leading) {
            Text(command.title)
            Text(command.help).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        TableColumn("Menu") { Text($0.menu).foregroundStyle(.secondary) }.width(80)
        TableColumn("Key") { command in
          HStack {
            Text(app.keymap.chord(for: command.id)?.symbols ?? "—").monospaced()
            Spacer()
            Button("Change") { app.rebinding = command.id }.controlSize(.small)
            Button("Remove") { problem = app.rebind(command.id, to: nil) ?? "" }.controlSize(.small)
          }
        }
        .width(200)
      }
      Text("Keys without ⌘ or ⌃ (such as Space, + and ?) act while a file list has the focus; the others also appear in the menus. macOS keeps some keys, such as F11 and ⌃← ⌃→, unless you turn them off in System Settings › Keyboard › Keyboard Shortcuts.")
        .font(.callout).foregroundStyle(.secondary)
    }
    .padding()
  }

  private var commands: [CommandInfo] {
    let q = query.lowercased()
    return app.engine.commands.filter { !$0.hidden && (q.isEmpty || $0.title.lowercased().contains(q) || $0.id.contains(q)) }
  }
}

struct TransferSettings: View {
  var body: some View {
    Form { TransferSpeedView(inPopover: true) }.formStyle(.grouped)
  }
}

struct EditorSettings: View {
  @Environment(AppController.self) private var app
  var body: some View {
    @Bindable var app = app
    Form {
      Section {
        Text("Files open in Fresh, which keeps running as its own program. The main window shows it in place of the panes and draws it natively: while it is shown, Fresh's menus fill the menu bar, and its tabs, sidebar, palette and status bar are Mac controls. Its tabs and unsaved text survive switching back, quitting File Commander and crashes.")
        LabeledContent("Switch key") { Text(app.keymap.chord(for: "switch_to_file_commander")?.symbols ?? "F10") }
        LabeledContent("Text font") { Text("Appearance › Editor › Font") }
      }
      Section("Keyboard") {
        Toggle("Use Option as Alt", isOn: $app.preferences.optionAsAlt)
          .explainerAnchor("settings.editor.option")
        Text("Option types its character (é, ü, ∑) by default. With this on, Option sends Alt instead, for Fresh's Alt shortcuts. ⌘ shortcuts work either way.")
          .font(.callout).foregroundStyle(.secondary)
      }
      Section("Display") {
        Toggle("Show the editor as a terminal", isOn: $app.preferences.terminalEditor)
          .explainerAnchor("settings.editor.terminal")
        Text("Runs Fresh's terminal interface in a terminal view instead. File Commander uses it anyway for a Fresh without the native editor's channel, such as an older version set in fresh_binary_path.")
          .font(.callout).foregroundStyle(.secondary)
      }
      Section("Diagnostics") {
        Toggle("Record editor timing", isOn: $app.preferences.editorTelemetry)
        Text("Writes scroll input, Fresh's frames and redraws, with their times, to a file in the profile's telemetry folder, for finding where the editor's latency comes from.")
          .font(.callout).foregroundStyle(.secondary)
        Button("Show Recordings in Finder") {
          try? FileManager.default.createDirectory(at: app.telemetryDirectory, withIntermediateDirectories: true)
          NSWorkspace.shared.open(app.telemetryDirectory)
        }
      }
      Section {
        Button("Restart Editor Backend…") { app.sheet = .restartEditor }
      }
    }
    .formStyle(.grouped)
  }
}

struct TutorialSettings: View {
  @Environment(AppController.self) private var app
  var body: some View {
    @Bindable var app = app
    Form {
      Picker("Mode", selection: $app.preferences.tutorialMode) {
        ForEach(AppPreferences.TutorialMode.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      Text("Watch plays every step. Guided stops where you can do the step yourself, and shows you how when you ask.")
        .font(.callout).foregroundStyle(.secondary)
      Picker("Speed", selection: $app.preferences.tutorialSpeed) {
        Text("0.5×").tag(0.5); Text("1×").tag(1.0); Text("1.5×").tag(1.5); Text("2×").tag(2.0); Text("3×").tag(3.0)
      }
      LabeledContent("Watched") { Text("\(app.preferences.watchedExplainers.count) of \(app.tutorial.catalog.scripts.count) explainers") }
      Button("Forget Tutorial Progress") {
        app.preferences.watchedExplainers = []
        app.preferences.tutorialPosition = 0
      }
      Button("Show Welcome Again") { app.preferences.welcomeShown = false; app.sheet = .welcome }
    }
    .formStyle(.grouped)
  }
}

/// Colors for light and dark, and a font for every element, with a live preview.
struct ThemeEditor: View {
  @Environment(AppController.self) private var app
  @State private var draft = Theme.standard
  @State private var selected = "listing.directory"
  @State private var query = ""
  @State private var dirty = false
  @State private var message = ""

  var body: some View {
    @Bindable var app = app
    HSplitView {
      VStack(spacing: 6) {
        Picker("Theme", selection: Binding(get: { app.preferences.theme }, set: { name in
          app.preferences.theme = name
          app.theme.activate(name)
          load()
        })) {
          ForEach(app.theme.names, id: \.self) { Text($0).tag($0) }
        }
        TextField("Search elements", text: $query).textFieldStyle(.roundedBorder)
        List(selection: $selected) {
          ForEach(groups, id: \.self) { group in
            Section(group) {
              ForEach(elements(in: group)) { element in
                HStack {
                  Image(systemName: element.kind == .color ? "paintbrush" : "textformat")
                    .foregroundStyle(element.kind == .color ? draft.color(element.key).color : .secondary)
                  Text(element.title)
                }
                .tag(element.id)
                .explainerAnchor("settings.appearance.element[\(element.id)]") { selected = element.id }
              }
            }
          }
        }
      }
      .frame(minWidth: 230, maxWidth: 280)
      .padding(8)
      VStack(alignment: .leading, spacing: 14) {
        inspector
        Divider()
        ThemePreview(theme: draft.resolved(using: app.theme.themes), zoom: app.theme.zoom)
        Spacer()
        HStack {
          Menu("More") {
            Button("Duplicate") {
              draft.name = draft.name.replacingOccurrences(of: " (Custom)", with: "") + " Copy"
              save()
            }
            Button("Import…", action: importTheme)
            Button("Export…", action: exportTheme)
            Button("Import Terminal Colors") {
              let url = URL(fileURLWithPath: app.engine.profileDirectory).appendingPathComponent("theme_colors.json")
              if let name = app.theme.importTerminalColors(from: url) { app.preferences.theme = name; load() } else { message = "No theme_colors.json in the profile" }
            }
            Divider()
            Button("Delete Theme", role: .destructive) {
              app.theme.delete(app.preferences.theme)
              app.preferences.theme = app.theme.active.name
              load()
            }
            .disabled(app.theme.isBuiltIn(app.preferences.theme))
          }
          .fixedSize()
          Text(message).foregroundStyle(.secondary).font(.callout)
          Spacer()
          Button("Reset to Defaults") {
            let base = draft.base.flatMap { app.theme.themes[$0] } ?? Theme.standard
            let name = draft.name
            draft = base.resolved(using: app.theme.themes)
            draft.name = name
            changed()
          }
          Button("Revert") { app.theme.activate(app.preferences.theme); load() }.disabled(!dirty)
            .explainerAnchor("settings.appearance.revert") { app.theme.activate(app.preferences.theme); load() }
          Button("Save", action: save).keyboardShortcut("s").disabled(!dirty)
            .explainerAnchor("settings.appearance.save", action: save)
        }
      }
      .padding(16)
      .frame(minWidth: 480)
    }
    .onAppear(perform: load)
    .onDisappear { if dirty { app.theme.activate(app.preferences.theme) } }
  }

  @ViewBuilder private var inspector: some View {
    let isFont = selected.hasSuffix("#font")
    let id = isFont ? String(selected.dropLast(5)) : selected
    let element = Theme.elements.first { $0.key == id && ($0.kind == .font) == isFont }
    Text(element?.title ?? id).font(.title3.weight(.semibold))
    Text(element?.group ?? "").foregroundStyle(.secondary)
    if isFont {
      let font = draft.font(id)
      Grid(alignment: .leading, verticalSpacing: 10) {
        GridRow {
          Text("Family")
          Picker("", selection: Binding(get: { font.family }, set: { var f = font; f.family = $0; setFont(id, f) })) {
            Text("System").tag("system"); Text("System Monospaced").tag("system-mono"); Text("System Rounded").tag("system-rounded")
            Divider()
            ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { Text($0).tag($0) }
          }
          .labelsHidden().frame(width: 260)
          .explainerAnchor("settings.appearance.font.family")
        }
        GridRow {
          Text("Size")
          HStack {
            Stepper(value: Binding(get: { font.size }, set: { var f = font; f.size = $0; setFont(id, f) }), in: 8...72, step: 1) {
              Text("\(Int(font.size)) pt").monospacedDigit()
            }
            .explainerAnchor("settings.appearance.font.size")
            Button { var f = font; f.size = max(8, f.size - 1); setFont(id, f) } label: { Image(systemName: "textformat.size.smaller") }
              .help("Smaller")
              .explainerAnchor("settings.appearance.font.smaller") { var f = draft.font(id); f.size = max(8, f.size - 1); setFont(id, f) }
            Button { var f = font; f.size = min(72, f.size + 1); setFont(id, f) } label: { Image(systemName: "textformat.size.larger") }
              .help("Bigger")
              .explainerAnchor("settings.appearance.font.bigger") { var f = draft.font(id); f.size = min(72, f.size + 1); setFont(id, f) }
          }
        }
        GridRow {
          Text("Weight")
          Picker("", selection: Binding(get: { font.weight }, set: { var f = font; f.weight = $0; setFont(id, f) })) {
            ForEach(ThemeFont.weightNames, id: \.self) { Text($0.capitalized).tag($0) }
          }
          .labelsHidden().frame(width: 160)
        }
        GridRow {
          Text("Digits")
          Toggle("Monospaced digits", isOn: Binding(get: { font.monospacedDigits }, set: { var f = font; f.monospacedDigits = $0; setFont(id, f) }))
        }
      }
    } else {
      let color = draft.color(id)
      HStack(spacing: 24) {
        ColorWell(title: "Light", value: color.light) { var c = color; c.light = $0; setColor(id, c) }
          .explainerAnchor("settings.appearance.color.light")
        ColorWell(title: "Dark", value: color.dark) { var c = color; c.dark = $0; setColor(id, c) }
          .explainerAnchor("settings.appearance.color.dark")
        Menu("Use System Color") {
          ForEach(["label", "secondaryLabel", "accent", "red", "orange", "yellow", "green", "mint", "teal", "blue", "indigo", "purple", "pink", "brown", "gray",
                   "selectedContentBackground", "controlBackground", "windowBackground"], id: \.self) { name in
            Button(name) { setColor(id, ThemeColor("system:\(name)")) }
          }
        }
        .fixedSize()
      }
      if color.light.hasPrefix("system:") || color.dark.hasPrefix("system:") {
        Text("System colors follow the accent color and Increase Contrast.").font(.callout).foregroundStyle(.secondary)
      }
    }
  }

  private var groups: [String] {
    var seen: [String] = []
    for e in filtered where !seen.contains(e.group) { seen.append(e.group) }
    return seen
  }
  private var filtered: [ThemeElement] {
    let q = query.lowercased()
    return Theme.elements.filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.key.contains(q) || $0.group.lowercased().contains(q) }
  }
  private func elements(in group: String) -> [ThemeElement] { filtered.filter { $0.group == group } }

  private func load() {
    draft = app.theme.active
    dirty = false
    message = ""
  }
  private func changed() {
    dirty = true
    app.theme.preview(draft)
  }
  private func setColor(_ id: String, _ color: ThemeColor) { draft.colors[id] = color; changed() }
  private func setFont(_ id: String, _ font: ThemeFont) { draft.fonts[id] = font; changed() }

  private func save() {
    let name = app.theme.save(draft)
    app.preferences.theme = name
    load()
    message = "Saved as “\(name)”"
  }

  private func importTheme() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      app.preferences.theme = try app.theme.importTheme(from: url)
      load()
    } catch { message = "Not a theme file: \(error.localizedDescription)" }
  }

  private func exportTheme() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = app.preferences.theme + ".json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    try? app.theme.export(app.preferences.theme, to: url)
  }
}

/// A color picker bound to a hex or system color string.
struct ColorWell: View {
  let title: String
  let value: String
  let set: (String) -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ColorPicker(title, selection: Binding(get: { Color(nsColor: ThemeColor.resolve(value)) },
                                            set: { set(NSColor($0).hexString) }), supportsOpacity: true)
      Text(value).font(.caption.monospaced()).foregroundStyle(.secondary)
    }
  }
}

/// A small mock of the window in light and dark, drawn with the draft theme.
struct ThemePreview: View {
  let theme: Theme
  let zoom: Double

  var body: some View {
    HStack(spacing: 12) {
      sample(dark: false)
      sample(dark: true)
    }
    .explainerAnchor("settings.appearance.preview")
  }

  private func c(_ id: String, _ dark: Bool) -> Color { Color(nsColor: theme.color(id).nsColor(dark: dark)) }
  private func f(_ id: String) -> Font { theme.font(id).font(zoom: zoom) }

  private func sample(dark: Bool) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 4) {
        Text("demo").padding(.horizontal, 7).padding(.vertical, 2).background(c("pane.tab.active", dark), in: RoundedRectangle(cornerRadius: 5)).foregroundStyle(.white)
        Text("photos").padding(.horizontal, 7).foregroundStyle(c("pane.tab.text", dark))
      }
      .font(f("pane.tabs")).padding(6)
      Text("~ › demo › photos").font(f("pane.path")).foregroundStyle(c("pane.path", dark)).padding(.horizontal, 8).padding(.bottom, 4)
      VStack(spacing: 0) {
        row("2026", folder: true, dark: dark)
        row("lighthouse.jpg", size: "14.0 MB", marked: true, dark: dark)
        row("night-ferry.jpg", size: "15.0 MB", cursor: true, dark: dark)
        row("backup.sh", size: "2 KB", exe: true, dark: dark)
        row("latest", size: "→ 2026", link: true, dark: dark)
      }
      .background(c("listing.background", dark))
      HStack {
        Text("Copy").fontWeight(.semibold)
        ProgressView(value: 0.6).tint(c("bottom.progress", dark))
        Text("Pause").padding(.horizontal, 6).background(c("bottom.pause", dark), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white)
        Text("Cancel").padding(.horizontal, 6).background(c("bottom.cancel", dark), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white)
      }
      .font(f("bottom.jobs")).padding(6).background(c("bottom.background", dark))
      VStack(alignment: .leading, spacing: 2) {
        Text("Caption title").font(f("caption.title")).foregroundStyle(c("caption.title", dark))
        Text("Caption subtitle").font(f("caption.subtitle")).foregroundStyle(c("caption.subtitle", dark))
      }
      .padding(8).frame(maxWidth: .infinity, alignment: .leading)
      .background(c("caption.background", dark), in: RoundedRectangle(cornerRadius: 10)).padding(6)
    }
    .background(dark ? Color(white: 0.12) : Color(white: 0.97))
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.15)))
    .environment(\.colorScheme, dark ? .dark : .light)
  }

  private func row(_ name: String, size: String = "—", folder: Bool = false, marked: Bool = false, cursor: Bool = false,
                   exe: Bool = false, link: Bool = false, dark: Bool) -> some View {
    let color = marked ? c("listing.marked.text", dark) : folder ? c("listing.directory", dark) : exe ? c("listing.executable", dark)
      : link ? c("listing.symlink", dark) : c("listing.text", dark)
    return HStack {
      Image(systemName: folder ? "folder.fill" : link ? "arrow.up.right.square" : "photo").foregroundStyle(cursor ? .white : color)
      Text(name).font(f("listing.name")).fontWeight(marked ? .bold : .regular).foregroundStyle(cursor ? .white : color)
      Spacer()
      Text(size).font(f("listing.size")).foregroundStyle(cursor ? .white : c("listing.size", dark))
    }
    .padding(.horizontal, 8).padding(.vertical, 3)
    .background(cursor ? c("listing.cursor", dark) : marked ? c("listing.marked.background", dark) : .clear)
  }
}
