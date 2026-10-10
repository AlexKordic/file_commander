import ExplainerKit
import FCKit
import SwiftUI

/// The command palette: a floating search panel. In help mode it lists the
/// feature explainers and the entire tutorial instead of commands.
struct PaletteOverlay: View {
  @Environment(AppController.self) private var app

  var body: some View {
    if let mode = app.paletteMode {
      ZStack(alignment: .top) {
        Color.black.opacity(0.08)
          .contentShape(Rectangle())
          .onTapGesture { app.paletteMode = nil }
        Group {
          switch mode {
          case .commands: CommandList()
          case .help: HelpList()
          }
        }
        .frame(width: 620)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        .padding(.top, 40)
        .explainerAnchor("palette")
      }
      .transition(.opacity)
    }
  }
}

struct CommandList: View {
  @Environment(AppController.self) private var app
  @State private var query = ""
  @State private var selection = 0
  @FocusState private var focused: Bool

  var body: some View {
    let ids = app.engine.palette(query)
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "command").font(.title2).foregroundStyle(.secondary)
        TextField("Search commands", text: $query)
          .textFieldStyle(.plain)
          .font(app.theme.font("palette.input"))
          .focused($focused)
          .onSubmit { run(ids) }
          .onKeyPress(.downArrow) { selection = min(selection + 1, max(ids.count - 1, 0)); return .handled }
          .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
          .onKeyPress(.escape) { app.paletteMode = nil; return .handled }
          .explainerAnchor("palette.field")
      }
      .padding(16)
      Divider()
      if let id = app.rebinding {
        Label("Press the new key for “\(app.engine.command(id)?.title ?? id)”. Esc cancels.", systemImage: "keyboard")
          .padding(10)
          .frame(maxWidth: .infinity)
          .background(Color.accentColor.opacity(0.15))
      }
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
              CommandRow(id: id, selected: index == selection)
                .id(id)
                .onTapGesture { selection = index; run(ids) }
                .explainerAnchor("palette.row[command=\(id)]") { selection = index; run(ids) }
            }
          }
          .padding(6)
        }
        .frame(maxHeight: 380)
        .onChange(of: selection) { _, new in if ids.indices.contains(new) { proxy.scrollTo(ids[new]) } }
      }
      Divider()
      HStack {
        Text("↩ run   ⌃K change key   ⎋ close").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Text("Most used commands come first among equal matches").font(.caption).foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 14).padding(.vertical, 7)
    }
    .onAppear {
      selection = 0
      app.paletteSelection = ids.first
      DispatchQueue.main.async { focused = true }
    }
    .onChange(of: query) { selection = 0; app.paletteSelection = app.engine.palette(query).first }
    .onChange(of: selection) { _, new in app.paletteSelection = ids.indices.contains(new) ? ids[new] : nil }
  }

  private func run(_ ids: [String]) {
    guard ids.indices.contains(selection) else { return }
    let id = ids[selection]
    app.paletteMode = nil
    DispatchQueue.main.async { app.run(id) }
  }
}

struct CommandRow: View {
  let id: String
  let selected: Bool
  @Environment(AppController.self) private var app

  var body: some View {
    let command = app.engine.command(id)
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(command?.title ?? id).font(app.theme.font("palette.row"))
        Text(command?.help ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer()
      Text(command?.menu ?? "").font(.caption).foregroundStyle(.tertiary)
      if let chord = app.keymap.chord(for: id) {
        Text(chord.symbols)
          .font(.system(size: 12, weight: .medium, design: .rounded))
          .padding(.horizontal, 6).padding(.vertical, 2)
          .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
      }
    }
    .padding(.horizontal, 10).padding(.vertical, 6)
    .background(selected ? app.theme.color("palette.selection").opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 7))
    .contentShape(Rectangle())
  }
}

/// Help: choose a feature explainer, or run the entire tutorial.
struct HelpList: View {
  @Environment(AppController.self) private var app
  @State private var query = ""
  @State private var selection = 0
  @FocusState private var focused: Bool

  private struct Entry: Hashable {
    var id: String
    var title: String
    var summary: String
    var duration: Int
    var chapter: String
  }

  var body: some View {
    @Bindable var app = app
    let entries = filtered
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "graduationcap").font(.title2).foregroundStyle(.secondary)
        TextField("Explain a feature", text: $query)
          .textFieldStyle(.plain)
          .font(app.theme.font("palette.input"))
          .focused($focused)
          .onSubmit { start(entries) }
          .onKeyPress(.downArrow) { selection = min(selection + 1, max(entries.count - 1, 0)); return .handled }
          .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
          .onKeyPress(.escape) { app.paletteMode = nil; return .handled }
          .explainerAnchor("help.field")
      }
      .padding(16)
      Divider()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(Array(entries.enumerated()), id: \.element) { index, entry in
            if index == 0 || entries[index - 1].chapter != entry.chapter {
              Text(entry.chapter.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 3)
            }
            HStack(spacing: 10) {
              Image(systemName: entry.id == TutorialCoordinator.entireID ? "play.rectangle.on.rectangle" :
                      app.preferences.watchedExplainers.contains(entry.id) ? "checkmark.circle.fill" : "play.circle")
                .foregroundStyle(app.preferences.watchedExplainers.contains(entry.id) ? .green : .accentColor)
              VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(app.theme.font("palette.row")).fontWeight(entry.id == TutorialCoordinator.entireID ? .semibold : .regular)
                Text(entry.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              }
              Spacer()
              Text(duration(entry.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(index == selection ? app.theme.color("palette.selection").opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
            .onTapGesture { selection = index; start(entries) }
            .explainerAnchor("help.row[id=\(entry.id)]") { selection = index; start(entries) }
          }
        }
        .padding(6)
      }
      .frame(maxHeight: 420)
      Divider()
      HStack(spacing: 14) {
        Picker("Mode", selection: $app.preferences.tutorialMode) {
          ForEach(AppPreferences.TutorialMode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented).frame(width: 150).labelsHidden()
        .help("Watch plays every step. Guided lets you do the steps yourself.")
        Picker("Speed", selection: $app.preferences.tutorialSpeed) {
          Text("0.5×").tag(0.5); Text("1×").tag(1.0); Text("1.5×").tag(1.5); Text("2×").tag(2.0); Text("3×").tag(3.0)
        }
        .frame(width: 120)
        Spacer()
        Text("Explainers run real operations on demo files in their own tabs").font(.caption).foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 14).padding(.vertical, 8)
    }
    .onAppear {
      selection = 0
      DispatchQueue.main.async { focused = true }
    }
    .onChange(of: query) { selection = 0 }
  }

  private var filtered: [Entry] {
    var entries: [Entry] = []
    let catalog = app.tutorial.catalog
    let remaining = catalog.scripts.count - min(app.preferences.tutorialPosition, catalog.scripts.count)
    let entireSummary = app.preferences.tutorialPosition > 0 && remaining > 0
      ? "Continue: \(remaining) explainers left" : "Every explainer in order"
    entries.append(Entry(id: TutorialCoordinator.entireID, title: "Entire tutorial", summary: entireSummary,
                         duration: catalog.totalDuration, chapter: "Tutorial"))
    for chapter in catalog.chapters {
      for script in catalog.scripts(in: chapter.id) {
        entries.append(Entry(id: script.id, title: script.title, summary: script.summary, duration: script.duration, chapter: chapter.title))
      }
    }
    let q = query.lowercased()
    guard !q.isEmpty else { return entries }
    return entries.filter { $0.title.lowercased().contains(q) || $0.summary.lowercased().contains(q) || $0.id.contains(q) }
  }

  private func duration(_ seconds: Int) -> String {
    seconds >= 90 ? "\(Int((Double(seconds) / 60).rounded())) min" : "\(seconds) s"
  }

  private func start(_ entries: [Entry]) {
    guard entries.indices.contains(selection) else { return }
    let id = entries[selection].id
    app.paletteMode = nil
    DispatchQueue.main.async { app.tutorial.start(id) }
  }
}
