import ExplainerKit
import FCKit
import SwiftUI

/// One pane: its tabs, path bar with filter, the listing and a status line.
struct PaneView: View {
  let side: Int
  @Environment(AppController.self) private var app

  private var name: String { side == 0 ? "left" : "right" }

  var body: some View {
    let pane = app.engine.pane(side)
    let focused = app.engine.focusedSide == side
    VStack(spacing: 0) {
      TabStrip(side: side, pane: pane, focused: focused)
      if app.engine.singlePane && focused {
        TargetBar(side: side)
      }
      PathBar(side: side, pane: pane, focused: focused)
      ListingView(side: side)
        .explainerAnchor("pane.\(name).listing")
      StatusFooter(side: side, pane: pane)
    }
    .overlay(alignment: .top) {
      Rectangle().fill(focused ? app.theme.color("pane.focus") : .clear).frame(height: 2)
    }
    .explainerAnchor("pane.\(name)")
  }
}

/// In single-pane mode: where copies and moves go (the hidden pane), and how to get there.
struct TargetBar: View {
  let side: Int
  @Environment(AppController.self) private var app

  var body: some View {
    let other = app.engine.pane(1 - side)
    HStack(spacing: 6) {
      Image(systemName: side == 0 ? "rectangle.righthalf.inset.filled.arrow.right" : "rectangle.lefthalf.inset.filled.arrow.left")
        .foregroundStyle(.secondary)
      Text(side == 0 ? "Right pane:" : "Left pane:").foregroundStyle(.secondary)
      Text(other.path).lineLimit(1).truncationMode(.head)
      Spacer(minLength: 8)
      Text("Copies and moves go here").foregroundStyle(.tertiary)
      Button {
        app.run("switch_panel")
      } label: {
        Text("Show \(app.keymap.chord(for: "switch_panel").map { "(\($0.symbols))" } ?? "")")
      }
      .buttonStyle(.link)
      .explainerAnchor("pane.target.show") { app.run("switch_panel") }
    }
    .font(app.theme.font("pane.status"))
    .padding(.horizontal, 10).padding(.vertical, 4)
    .background(app.theme.color("pane.focus").opacity(0.08))
    .overlay(alignment: .bottom) { Divider() }
    .help("Single-pane mode hides the other pane; operations still use it as their destination")
    .explainerAnchor("pane.target")
  }
}

struct TabStrip: View {
  let side: Int
  let pane: PaneSnapshot
  let focused: Bool
  @Environment(AppController.self) private var app

  var body: some View {
    let name = side == 0 ? "left" : "right"
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 4) {
        ForEach(Array(pane.tabs.enumerated()), id: \.offset) { index, tab in
          TabChip(tab: tab, active: index == pane.activeTab, focused: focused, closable: pane.tabs.count > 1) {
            app.engine.switchTab(side, to: index)
            app.focusPane(side)
          } close: {
            app.engine.closeTab(side, index: index)
          }
          .explainerAnchor("pane.\(name).tab[\(index + 1)]") { app.engine.switchTab(side, to: index) }
          .draggable("\(side):\(index)")
          .dropDestination(for: String.self) { items, _ in
            guard let item = items.first, let from = Int(item.split(separator: ":").last ?? ""),
                  item.hasPrefix("\(side):") else { return false }
            app.engine.moveTab(side, from: from, to: index)
            return true
          }
        }
        Button {
          app.focusPane(side)
          app.run("tab_new")
        } label: {
          Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.borderless)
        .help("New tab")
        .explainerAnchor("pane.\(name).new_tab") { app.focusPane(side); app.run("tab_new") }
      }
      .padding(.horizontal, 8).padding(.vertical, 5)
    }
    .font(app.theme.font("pane.tabs"))
    .background(.bar)
    .explainerAnchor("pane.\(name).tabs")
  }
}

struct TabChip: View {
  let tab: TabInfo
  let active: Bool
  let focused: Bool
  let closable: Bool
  let select: () -> Void
  let close: () -> Void
  @Environment(AppController.self) private var app
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: icon).font(.system(size: 10))
      Text(tab.title).lineLimit(1)
      if tab.tutorial {
        Image(systemName: "graduationcap.fill").font(.system(size: 9)).foregroundStyle(app.theme.color("pane.tab.tutorial"))
      }
      if !tab.remoteError.isEmpty {
        Image(systemName: "bolt.horizontal.circle").foregroundStyle(.orange).help(tab.remoteError)
      }
      if closable && (hovering || active) {
        Button(action: close) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
          .buttonStyle(.borderless)
          .help("Close tab")
      }
    }
    .padding(.horizontal, 9).padding(.vertical, 3)
    .foregroundStyle(active ? Color.white : app.theme.color("pane.tab.text"))
    .background {
      RoundedRectangle(cornerRadius: 6)
        .fill(active ? (tab.tutorial ? app.theme.color("pane.tab.tutorial") : app.theme.color("pane.tab.active")).opacity(focused ? 1 : 0.55)
                     : Color.primary.opacity(hovering ? 0.08 : 0.04))
    }
    .contentShape(Rectangle())
    .onTapGesture(perform: select)
    .onHover { hovering = $0 }
    .help(tab.path)
  }

  private var icon: String {
    switch tab.kind {
    case .remote: return "server.rack"
    case .archive: return "archivebox"
    case .local: return "folder"
    }
  }
}

/// Breadcrumbs of the location and the filter field.
struct PathBar: View {
  let side: Int
  let pane: PaneSnapshot
  let focused: Bool
  @Environment(AppController.self) private var app

  var body: some View {
    let name = side == 0 ? "left" : "right"
    HStack(spacing: 6) {
      Image(systemName: pane.kind == .remote ? "server.rack" : pane.kind == .archive ? "archivebox" : "folder")
        .foregroundStyle(.secondary)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 2) {
          ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
            if index > 0 { Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary) }
            Button(crumb.title) {
              app.engine.navigate(side, to: crumb.location)
              app.focusPane(side)
            }
            .buttonStyle(.plain)
            .foregroundStyle(index == crumbs.count - 1 ? app.theme.color("pane.path") : .secondary)
          }
          if pane.readOnly {
            Text("read-only").font(.caption).padding(.horizontal, 5).background(.orange.opacity(0.2), in: Capsule())
          }
        }
      }
      .defaultScrollAnchor(.trailing)
      .explainerAnchor("pane.\(name).path")
      Spacer(minLength: 4)
      // The filter is typed into the list, as in the terminal interface; this shows it.
      HStack(spacing: 4) {
        Image(systemName: "line.3.horizontal.decrease").foregroundStyle(pane.filter.isEmpty ? Color.secondary : app.theme.color("pane.filter"))
        Text(pane.filter.isEmpty ? "Type to filter" : pane.filter)
          .foregroundStyle(pane.filter.isEmpty ? Color.secondary.opacity(0.7) : app.theme.color("pane.filter"))
          .lineLimit(1)
          .frame(minWidth: 70, maxWidth: 130, alignment: .leading)
        if !pane.filter.isEmpty {
          Button { app.engine.setFilter(side, "") } label: { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .help("Clear the filter")
        }
      }
      .contentShape(Rectangle())
      .onTapGesture { app.focusPane(side) }
      .help("Type in the list to filter it; Backspace edits the filter")
      .padding(.horizontal, 7).padding(.vertical, 3)
      .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(pane.filter.isEmpty ? 0.04 : 0.09)))
      .explainerAnchor("pane.\(name).filter")
      .popover(isPresented: Binding(get: { app.glob?.side == side }, set: { if !$0 { app.glob = nil } }), arrowEdge: .bottom) {
        GlobPopover(side: side, select: app.glob?.select ?? true)
      }
    }
    .font(app.theme.font("pane.path"))
    .padding(.horizontal, 10).padding(.vertical, 5)
  }

  private struct Crumb { var title: String; var location: String }

  private var crumbs: [Crumb] {
    let path = pane.path
    if pane.kind == .local {
      var out: [Crumb] = []
      var current = ""
      let parts = path.split(separator: "/", omittingEmptySubsequences: true)
      out.append(Crumb(title: "/", location: "/"))
      for part in parts {
        current += "/" + part
        out.append(Crumb(title: String(part), location: current))
      }
      if path.hasPrefix(NSHomeDirectory()) {
        let home = NSHomeDirectory().split(separator: "/").count
        out.removeFirst(home)
        out.insert(Crumb(title: "~", location: NSHomeDirectory()), at: 0)
      }
      return out
    }
    // Remote and archive paths: one crumb, the whole display path.
    return [Crumb(title: path, location: pane.encoded)]
  }
}

struct StatusFooter: View {
  let side: Int
  let pane: PaneSnapshot
  @Environment(AppController.self) private var app

  var body: some View {
    let name = side == 0 ? "left" : "right"
    HStack(spacing: 8) {
      if pane.itemsSelected > 0 {
        Text("\(pane.itemsSelected) of \(pane.itemsVisible) selected, \(Format.bytes(pane.bytesSelected)) of \(Format.bytes(pane.bytesTotal))")
          .foregroundStyle(app.theme.color("listing.marked.text"))
          .explainerAnchor("pane.\(name).status.selection")
      } else {
        Text(pane.itemsVisible == pane.itemsTotal ? "\(pane.itemsTotal) \(pane.itemsTotal == 1 ? "item" : "items"), \(Format.bytes(pane.bytesTotal))"
             : "\(pane.itemsVisible) of \(pane.itemsTotal) items match the filter")
      }
      Spacer()
      if !pane.remoteError.isEmpty {
        Label("Reconnecting", systemImage: "bolt.horizontal.circle").foregroundStyle(.orange).help(pane.remoteError)
      }
      if pane.loading && !pane.loadingUnattended {
        if pane.loadPercent >= 0 { Text("\(pane.loadPercent)%").monospacedDigit() }
        ProgressView().controlSize(.mini)
        Button("Stop") { app.engine.stopLoading(side) }
          .buttonStyle(TintedButtonStyle(color: app.theme.color("bottom.cancel")))
          .explainerAnchor("pane.\(name).status.stop") { app.engine.stopLoading(side) }
      } else if pane.loadMilliseconds > 0 {
        Text(String(format: "%.0f ms", pane.loadMilliseconds)).foregroundStyle(.tertiary).help("Time the last folder read took")
      }
    }
    .font(app.theme.font("pane.status"))
    .foregroundStyle(app.theme.color("pane.status"))
    .padding(.horizontal, 10).padding(.vertical, 4)
    .background(.bar)
    .explainerAnchor("pane.\(name).status")
  }
}

struct GlobPopover: View {
  let side: Int
  let select: Bool
  @Environment(AppController.self) private var app
  @State private var pattern = ""
  @State private var message = ""
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(select ? "Select by Pattern" : "Deselect by Pattern").font(.headline)
      TextField("Pattern, such as *.jpg", text: $pattern)
        .textFieldStyle(.roundedBorder)
        .frame(width: 240)
        .focused($focused)
        .onSubmit(apply)
        .explainerAnchor("glob.pattern")
      Text(message.isEmpty ? "* matches any characters, ? matches one. Case is ignored." : message)
        .font(.caption).foregroundStyle(message.isEmpty ? Color.secondary : .orange)
      HStack {
        Spacer()
        Button("Cancel") { app.glob = nil }.keyboardShortcut(.cancelAction)
        Button(select ? "Select" : "Deselect", action: apply).keyboardShortcut(.defaultAction)
          .explainerAnchor("glob.apply", action: apply)
      }
    }
    .padding(14)
    .background(KeyWindowMaker())
    .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true } }
  }

  private func apply() {
    guard !pattern.isEmpty else { message = "Enter a pattern"; return }
    let matches = app.engine.globSelect(side, pattern: pattern, select: select)
    if matches == 0 { message = "No items match \(pattern)"; return }
    app.glob = nil
    app.focusPane(side)
  }
}

/// Makes the window it lives in the key window, so a popover's field can take the keyboard.
struct KeyWindowMaker: NSViewRepresentable {
  final class Probe: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      DispatchQueue.main.async { [weak self] in self?.window?.makeKey() }
    }
  }
  func makeNSView(context: Context) -> Probe { Probe() }
  func updateNSView(_ view: Probe, context: Context) {}
}
