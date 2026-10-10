import AppKit
import ExplainerKit
import FCKit
import SwiftUI

/// A pane's file list. SwiftUI's Table can't keep a cursor apart from the
/// selection or route typing to the filter, so this is an NSTableView.
struct ListingView: NSViewRepresentable {
  let side: Int
  @Environment(AppController.self) private var app

  func makeCoordinator() -> Coordinator { Coordinator(side: side, app: app) }

  func makeNSView(context: Context) -> NSScrollView {
    let table = ListingTableView()
    table.side = side
    table.coordinator = context.coordinator
    table.headerView = ListingHeaderView()
    table.usesAlternatingRowBackgroundColors = false
    table.allowsColumnReordering = false
    table.allowsColumnResizing = true
    // Only the name column stretches; the others keep their width.
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    table.style = .fullWidth
    table.intercellSpacing = NSSize(width: 6, height: 0)
    table.gridStyleMask = []
    table.focusRingType = .none
    table.allowsTypeSelect = false
    table.target = context.coordinator
    table.doubleAction = #selector(Coordinator.doubleClicked(_:))
    table.registerForDraggedTypes([.fileURL, ListingTableView.rowType])
    table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
    table.setDraggingSourceOperationMask([.copy], forLocal: false)
    for (id, title, width) in [("name", "Name", 260.0), ("permissions", "Permissions", 96.0), ("owner", "Owner", 120.0),
                               ("size", "Size", 84.0), ("date", "Date Modified", 128.0)] {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
      column.title = title
      column.width = width
      column.minWidth = id == "name" ? 120 : 50
      if ["name", "size", "date"].contains(id) {
        column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
      }
      if id == "size" { column.headerCell.alignment = .right }
      column.resizingMask = id == "name" ? [.autoresizingMask, .userResizingMask] : [.userResizingMask]
      table.addTableColumn(column)
    }
    table.dataSource = context.coordinator
    table.delegate = context.coordinator
    let menu = NSMenu()
    menu.delegate = context.coordinator
    table.headerView?.menu = menu
    let scroll = ListingScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.drawsBackground = true
    context.coordinator.table = table
    app.register(listing: table, side: side)
    context.coordinator.apply(force: true)
    AnchorRegistry.shared.register(resolver: context.coordinator, prefix: "pane.\(side == 0 ? "left" : "right").row")
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    // Reading these registers the observation that triggers updates.
    _ = app.engine.listingRevision[side]
    _ = app.engine.focusedSide
    _ = app.theme.revision
    _ = app.preferences.selectionStyle
    _ = app.focusRequest
    context.coordinator.apply(force: false)
  }

  @MainActor
  final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, AnchorResolver {
    let side: Int
    let app: AppController
    weak var table: ListingTableView?
    private var cache: [Int: Row] = [:]
    private var syncing = false
    private var themeRevision = -1
    private var style: AppPreferences.SelectionStyle?
    private var focusRequest = -1
    private var contentRevision: UInt64 = .max
    private var marksRevision: UInt64 = .max

    init(side: Int, app: AppController) {
      self.side = side
      self.app = app
    }

    var engine: Engine { app.engine }
    var pane: PaneSnapshot { engine.pane(side) }

    func row(_ index: Int) -> Row {
      if let cached = cache[index] { return cached }
      let r = engine.row(side, index)
      cache[index] = r
      return r
    }

    /// Brings the table in line with the engine. Only a content change reloads
    /// everything; marks reload the visible rows; a cursor move reloads nothing,
    /// so held arrow keys and scrolling don't fight a reload.
    func apply(force: Bool) {
      guard let table else { return }
      let pane = self.pane
      let themeChanged = themeRevision != app.theme.revision
      let styleChanged = style != app.preferences.selectionStyle
      if force || pane.contentRevision != contentRevision || themeChanged || styleChanged {
        contentRevision = pane.contentRevision
        marksRevision = pane.marksRevision
        themeRevision = app.theme.revision
        style = app.preferences.selectionStyle
        cache.removeAll(keepingCapacity: true)
        syncing = true
        defer { syncing = false }
        table.allowsMultipleSelection = app.preferences.selectionStyle == .finder
        let rowFont = app.theme.nsFont("listing.name")
        table.rowHeight = ceil(rowFont.ascender - rowFont.descender + rowFont.leading) + 7
        table.backgroundColor = app.theme.nsColor("listing.background")
        table.enclosingScrollView?.backgroundColor = table.backgroundColor
        table.tableColumn(withIdentifier: .init("permissions"))?.isHidden = !pane.showPermissions
        table.tableColumn(withIdentifier: .init("owner"))?.isHidden = !pane.showOwnerGroup
        table.enclosingScrollView?.tile()
        let wanted = [NSSortDescriptor(key: ["name", "name", "size", "size", "date", "date"][pane.sort.rawValue], ascending: pane.sort.ascending)]
        if table.sortDescriptors != wanted { table.sortDescriptors = wanted }
        table.reloadData()
        syncSelection(pane)
        scroll(toKeep: Int(pane.cursorRow))
      } else if pane.marksRevision != marksRevision {
        marksRevision = pane.marksRevision
        cache.removeAll(keepingCapacity: true)
        let visible = table.rows(in: table.visibleRect)
        if visible.length > 0 {
          table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<visible.location + visible.length),
                           columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        }
        if app.preferences.selectionStyle == .finder { syncing = true; syncSelection(pane); syncing = false }
      }
      // The engine moved the cursor (Space, a command, a search result): follow it.
      if pane.cursorRow >= 0, pane.cursorRow < table.numberOfRows, !table.selectedRowIndexes.contains(Int(pane.cursorRow)) {
        syncing = true
        syncSelection(pane)
        syncing = false
        scroll(toKeep: Int(pane.cursorRow))
      }
      if focusRequest != app.focusRequest {
        focusRequest = app.focusRequest
        if engine.focusedSide == side, let window = table.window, window.firstResponder !== table {
          window.makeFirstResponder(table)
        }
      }
      // The keyboard follows the focused pane (Switch Pane, a click on a tab), but
      // only from one list to the other: a text field being edited keeps it.
      if engine.focusedSide == side, let window = table.window, let current = window.firstResponder as? ListingTableView, current !== table {
        window.makeFirstResponder(table)
      }
      refreshRowStyles()
    }

    /// Cursor colors depend on which pane has the focus; visible rows redraw for it.
    func refreshRowStyles() {
      guard let table else { return }
      table.enumerateAvailableRowViews { rowView, _ in
        rowView.needsDisplay = true
        for case let cell as NSTableCellView in rowView.subviews where cell.backgroundStyle != rowView.interiorBackgroundStyle {
          cell.backgroundStyle = rowView.interiorBackgroundStyle
        }
      }
    }

    private func syncSelection(_ pane: PaneSnapshot) {
      guard let table else { return }
      let count = engine.rowCount(side)
      if app.preferences.selectionStyle == .finder {
        var rows = IndexSet()
        if pane.itemsSelected > 0 {
          rows = IndexSet(engine.selectedRows(side))
        } else if pane.cursorRow >= 0, pane.cursorRow < count {
          rows.insert(Int(pane.cursorRow))
        }
        table.selectRowIndexes(rows, byExtendingSelection: false)
      } else if pane.cursorRow >= 0, pane.cursorRow < count {
        table.selectRowIndexes([Int(pane.cursorRow)], byExtendingSelection: false)
      } else {
        table.deselectAll(nil)
      }
    }

    // MARK: Keyboard cursor and scrolling

    /// The rows that are completely visible.
    func fullyVisibleRows() -> ClosedRange<Int>? {
      guard let table, table.numberOfRows > 0 else { return nil }
      var visible = table.visibleRect
      let inset = table.enclosingScrollView?.contentInsets.top ?? 0
      visible.origin.y += inset
      visible.size.height -= inset
      let range = table.rows(in: visible)
      guard range.length > 0 else { return nil }
      var first = range.location, last = range.location + range.length - 1
      if table.rect(ofRow: first).minY < visible.minY - 0.5, first < last { first += 1 }
      if table.rect(ofRow: last).maxY > visible.maxY + 0.5, last > first { last -= 1 }
      return first...last
    }

    /// Scrolls without animation so `row` keeps the margin from the edges that
    /// Settings asks for: 0 lets it touch the edge, 10 keeps it centered, except
    /// near the start and end of the list.
    func scroll(toKeep row: Int) {
      guard let table, let clip = table.enclosingScrollView?.contentView, row >= 0, row < table.numberOfRows,
            let visible = fullyVisibleRows() else { return }
      let rowsShown = visible.count
      let margin = Int((Double(rowsShown - 1) / 2 * Double(app.preferences.scrollMargin) / 10).rounded(.down))
      var first = visible.lowerBound
      if row - margin < first { first = row - margin }
      if row + margin > first + rowsShown - 1 { first = row + margin - rowsShown + 1 }
      first = min(max(0, first), max(0, table.numberOfRows - rowsShown))
      guard first != visible.lowerBound else { return }
      let inset = table.enclosingScrollView?.contentInsets.top ?? 0
      var origin = clip.bounds.origin
      origin.y = table.rect(ofRow: first).minY - inset
      if first == 0 { origin.y = -inset }
      clip.setBoundsOrigin(origin)
      table.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    /// Up, Down, Page Up, Page Down, Home and End move the cursor (and, with
    /// Shift in Finder style, extend the selection), then scroll by the margin rule.
    func moveCursor(_ key: String, extend: Bool) {
      guard let table, table.numberOfRows > 0 else { return }
      let count = table.numberOfRows
      let current = pane.cursorRow >= 0 && pane.cursorRow < count ? Int(pane.cursorRow) : max(table.selectedRow, 0)
      let page = max(1, (fullyVisibleRows()?.count ?? 10) - 1)
      let target: Int
      switch key {
      case "Up": target = current - 1
      case "Down": target = current + 1
      case "PageUp": target = current - page
      case "PageDown": target = current + page
      case "Home": target = 0
      default: target = count - 1
      }
      let row = min(max(0, target), count - 1)
      syncing = true
      if extend && app.preferences.selectionStyle == .finder {
        table.selectRowIndexes(IndexSet(integersIn: min(current, row)...max(current, row)), byExtendingSelection: true)
      } else {
        table.selectRowIndexes([row], byExtendingSelection: false)
      }
      syncing = false
      engine.setCursor(side, row: row)
      if extend && app.preferences.selectionStyle == .finder { engine.setSelectedRows(side, rows: Array(table.selectedRowIndexes)) }
      scroll(toKeep: row)
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { engine.rowCount(side) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
      guard let column = tableColumn?.identifier.rawValue else { return nil }
      let id = NSUserInterfaceItemIdentifier("cell-\(column)")
      let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? ListingCell) ?? ListingCell(identifier: id, withIcon: column == "name")
      cell.configure(row: row(index), column: column, coordinator: self, rowIndex: index)
      return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
      let view = ListingRowView()
      view.coordinator = self
      view.rowIndex = row
      return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
      guard !syncing, let table else { return }
      if app.preferences.selectionStyle == .finder {
        let rows = Array(table.selectedRowIndexes)
        let cursor = table.selectedRow >= 0 ? table.selectedRow : rows.last ?? -1
        if cursor >= 0 { engine.setCursor(side, row: cursor) }
        engine.setSelectedRows(side, rows: rows.count > 1 ? rows : [])
      } else if table.selectedRow >= 0 {
        engine.setCursor(side, row: table.selectedRow)
      }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
      guard !syncing, let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
      let field: PaneSort.Field = key == "size" ? .size : key == "date" ? .date : .name
      let order = PaneSort.make(field, ascending: descriptor.ascending)
      if order != pane.sort { engine.setSort(side, order) }
    }

    @objc func doubleClicked(_ sender: Any?) {
      guard let table, table.clickedRow >= 0 else { return }
      let index = table.clickedRow
      engine.setCursor(side, row: index)
      if !engine.openRow(side, row: index) {
        app.focusPane(side)
        app.run("open_in_editor")
      }
    }

    /// A click on a list focuses its pane. Any other move of the keyboard
    /// (SwiftUI restoring focus after an update, for one) goes back to the
    /// focused pane's list: the engine's focused side is the truth.
    func becameFocused() {
      let type = NSApp.currentEvent?.type
      let clicked = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
      Trace.write("list \(side) became first responder (focused side \(engine.focusedSide), click \(clicked))")
      if clicked {
        if engine.focusedSide != side { engine.setFocusedSide(side) }
      } else if engine.focusedSide != side {
        DispatchQueue.main.async { [app] in app.focusPane(app.engine.focusedSide) }
      }
      table?.needsDisplay = true
    }

    // MARK: Header menu: column visibility

    func menuNeedsUpdate(_ menu: NSMenu) {
      menu.removeAllItems()
      let pane = self.pane
      let permissions = NSMenuItem(title: "Permissions", action: #selector(togglePermissions), keyEquivalent: "")
      permissions.target = self
      permissions.state = pane.showPermissions ? .on : .off
      let owner = NSMenuItem(title: "Owner", action: #selector(toggleOwner), keyEquivalent: "")
      owner.target = self
      owner.state = pane.showOwnerGroup ? .on : .off
      menu.addItem(permissions)
      menu.addItem(owner)
    }
    @objc func togglePermissions() { engine.setColumns(side, permissions: !pane.showPermissions, ownerGroup: pane.showOwnerGroup) }
    @objc func toggleOwner() { engine.setColumns(side, permissions: pane.showPermissions, ownerGroup: !pane.showOwnerGroup) }

    // MARK: Drag and drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow index: Int) -> (any NSPasteboardWriting)? {
      let r = row(index)
      let item = NSPasteboardItem()
      item.setString("\(side)", forType: ListingTableView.rowType)
      if !r.path.hasPrefix("fc-ssh:") && !r.path.hasPrefix("fc-archive:") {
        item.setString(URL(fileURLWithPath: r.path).absoluteString, forType: .fileURL)
      }
      return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
      if let source = info.draggingPasteboard.string(forType: ListingTableView.rowType), Int(source) == side { return [] }
      tableView.setDropRow(-1, dropOperation: .on)
      return NSEvent.modifierFlags.contains(.command) ? .move : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
      let move = NSEvent.modifierFlags.contains(.command)
      if let source = info.draggingPasteboard.string(forType: ListingTableView.rowType), let from = Int(source), from != side {
        // The other pane is the default destination, so the drop target needs no extra state.
        app.focusPane(from)
        app.run(move ? "move" : "copy")
        return true
      }
      let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
      guard !urls.isEmpty else { return false }
      var request = DialogRequest.empty
      request.name = move ? "Move" : "Copy"
      request.side = side
      request.selected = urls.map(\.path)
      request.origin = urls[0].deletingLastPathComponent().path
      request.target = pane.encoded
      app.handle(request)
      return true
    }

    // MARK: Anchors: pane.left.row[name=...]

    func screenRect(for id: String) -> CGRect? {
      guard let table, let window = table.window, let name = AnchorRegistry.qualifier(id, "name"),
            let index = engine.rowNamed(side, name) else { return nil }
      table.scrollRowToVisible(index)
      var rect = table.rect(ofRow: index)
      if let column = AnchorRegistry.qualifier(id, "column"), let c = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == column }) {
        rect = rect.intersection(table.rect(ofColumn: c))
      } else {
        rect.size.width = min(rect.width, table.tableColumns.first.map { $0.width + 8 } ?? rect.width)
      }
      let visible = table.visibleRect
      rect = rect.intersection(visible)
      guard !rect.isNull, !rect.isEmpty else { return nil }
      return window.convertToScreen(table.convert(rect, to: nil))
    }

    func perform(anchor id: String) -> Bool {
      guard let name = AnchorRegistry.qualifier(id, "name"), let index = engine.rowNamed(side, name) else { return false }
      app.focusPane(side)
      engine.setCursor(side, row: index)
      return true
    }
  }
}

final class ListingHeaderView: NSTableHeaderView {}

/// Keeps the table as wide as the visible area, so the name column absorbs
/// size changes and Size and Date stay in view.
final class ListingScrollView: NSScrollView {
  override func tile() {
    super.tile()
    guard let table = documentView as? NSTableView else { return }
    let width = contentView.bounds.width
    if abs(table.frame.width - width) > 0.5 { table.setFrameSize(NSSize(width: width, height: table.frame.height)) }
    // The name column takes whatever the other visible columns leave.
    guard let name = table.tableColumns.first(where: { $0.identifier.rawValue == "name" }) else { return }
    let spacing = table.intercellSpacing.width
    let others = table.tableColumns.filter { !$0.isHidden && $0 !== name }.reduce(0) { $0 + $1.width + spacing }
    let wanted = max(name.minWidth, width - others - spacing)
    if abs(name.width - wanted) > 0.5 { name.width = wanted }
  }
}

/// The pane's table: knows its side and tells the app when it takes focus.
final class ListingTableView: NSTableView {
  static let rowType = NSPasteboard.PasteboardType("com.perun.filecommander.row")
  var side = 0
  weak var coordinator: ListingView.Coordinator?

  /// Cursor keys move the cursor ourselves: the table's own handling scrolls
  /// with animation and Page Up/Down would only scroll.
  override func keyDown(with event: NSEvent) {
    guard let chord = KeyChord(event: event), ["Up", "Down", "PageUp", "PageDown", "Home", "End"].contains(chord.key),
          chord.modifiers.isEmpty || chord.modifiers == [.shift], let coordinator else {
      super.keyDown(with: event)
      return
    }
    MainActor.assumeIsolated { coordinator.moveCursor(chord.key, extend: chord.modifiers == [.shift]) }
  }

  override func becomeFirstResponder() -> Bool {
    let ok = super.becomeFirstResponder()
    if ok { MainActor.assumeIsolated { coordinator?.becameFocused(); coordinator?.refreshRowStyles() } }
    return ok
  }
  override func resignFirstResponder() -> Bool {
    let ok = super.resignFirstResponder()
    MainActor.assumeIsolated { coordinator?.refreshRowStyles() }
    return ok
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let point = convert(event.locationInWindow, from: nil)
    let index = row(at: point)
    guard let coordinator else { return nil }
    return MainActor.assumeIsolated {
      if index >= 0 { coordinator.engine.setCursor(side, row: index) }
      coordinator.app.focusPane(side)
      return ContextMenu.make(app: coordinator.app)
    }
  }
}

/// Draws the size gauge, marked rows and the cursor in theme colors.
final class ListingRowView: NSTableRowView {
  weak var coordinator: ListingView.Coordinator?
  var rowIndex = 0

  override func drawBackground(in dirtyRect: NSRect) {
    MainActor.assumeIsolated {
      guard let coordinator else { return }
      let theme = coordinator.app.theme
      if coordinator.row(rowIndex).selected && coordinator.app.preferences.selectionStyle == .commander {
        theme.nsColor("listing.marked.background").setFill()
        bounds.fill()
      }
      if !isSelected { drawGauge(theme.nsColor("listing.gauge")) }
    }
  }

  override func drawSelection(in dirtyRect: NSRect) {
    MainActor.assumeIsolated {
      guard let coordinator else { return }
      let focused = coordinator.engine.focusedSide == coordinator.side && window?.firstResponder === superview
      let theme = coordinator.app.theme
      theme.nsColor(focused ? "listing.cursor" : "listing.cursor.inactive").setFill()
      NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
      // On the cursor the size bar is drawn on top, in a color made for it.
      drawGauge(theme.nsColor(focused ? "listing.gauge.cursor" : "listing.gauge.cursor.inactive"))
    }
  }

  /// A thin bar along the bottom of the row: the item's size against the largest in the folder.
  @MainActor
  private func drawGauge(_ color: NSColor) {
    guard let coordinator else { return }
    let row = coordinator.row(rowIndex)
    guard !row.isDirectory, row.size > 0 else { return }
    let largest = max(coordinator.pane.largestItem, 1)
    let width = (bounds.width - 16) * CGFloat(Double(row.size) / Double(largest))
    color.setFill()
    NSBezierPath(roundedRect: NSRect(x: 8, y: bounds.maxY - 4, width: max(width, 2), height: 2), xRadius: 1, yRadius: 1).fill()
  }

  override var interiorBackgroundStyle: NSView.BackgroundStyle {
    let focused = MainActor.assumeIsolated { coordinator?.engine.focusedSide == coordinator?.side } && window?.firstResponder === superview
    return isSelected && focused ? .emphasized : .normal
  }
}

/// One cell: an icon and name, or a right-aligned size, or plain text.
final class ListingCell: NSTableCellView {
  private let label = NSTextField(labelWithString: "")
  private let icon = NSImageView()
  private let withIcon: Bool

  init(identifier: NSUserInterfaceItemIdentifier, withIcon: Bool) {
    self.withIcon = withIcon
    super.init(frame: .zero)
    self.identifier = identifier
    label.lineBreakMode = .byTruncatingMiddle
    label.translatesAutoresizingMaskIntoConstraints = false
    label.cell?.truncatesLastVisibleLine = true
    addSubview(label)
    textField = label
    if withIcon {
      icon.translatesAutoresizingMaskIntoConstraints = false
      icon.symbolConfiguration = .init(scale: .medium)
      addSubview(icon)
      imageView = icon
      NSLayoutConstraint.activate([
        icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
        icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        icon.widthAnchor.constraint(equalToConstant: 18),
        label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
      ])
    } else {
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2).isActive = true
    }
    NSLayoutConstraint.activate([
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }
  required init?(coder: NSCoder) { fatalError() }

  private var labelColor = NSColor.labelColor
  private var iconColor: NSColor?

  /// The row tells its cells when it becomes the emphasized cursor; then the
  /// text turns white, and back to its own color afterwards.
  override var backgroundStyle: NSView.BackgroundStyle {
    didSet { applyColors() }
  }

  private func applyColors() {
    let emphasized = backgroundStyle == .emphasized
    label.textColor = emphasized ? .alternateSelectedControlTextColor : labelColor
    if withIcon { icon.contentTintColor = emphasized ? .alternateSelectedControlTextColor : iconColor }
  }

  /// Size colors by magnitude: over 1 MB yellow, over 50 MB yellow and bold,
  /// over 1 GB red, over 10 GB red and bold.
  static func sizeStyle(_ size: Int64) -> (color: String, bold: Bool) {
    let mb: Int64 = 1 << 20, gb: Int64 = 1 << 30
    if size > 10 * gb { return ("listing.size.huge", true) }
    if size > gb { return ("listing.size.huge", false) }
    if size > 50 * mb { return ("listing.size.large", true) }
    if size > mb { return ("listing.size.large", false) }
    return ("listing.size", false)
  }

  @MainActor
  func configure(row: Row, column: String, coordinator: ListingView.Coordinator, rowIndex: Int) {
    let theme = coordinator.app.theme
    let marked = row.selected && coordinator.app.preferences.selectionStyle == .commander
    let bold = { (font: NSFont) in NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
    label.alignment = column == "size" ? .right : .left
    toolTip = nil
    switch column {
    case "name":
      label.stringValue = row.name
      label.font = marked ? bold(theme.nsFont("listing.name")) : theme.nsFont("listing.name")
      icon.image = FileIcons.image(for: row)
      if marked { labelColor = theme.nsColor("listing.marked.text") }
      else if row.kind == .error || row.kind == .notFound { labelColor = theme.nsColor("listing.error") }
      else if row.isDirectory { labelColor = theme.nsColor("listing.directory") }
      else if row.isLink { labelColor = theme.nsColor("listing.symlink") }
      else if [.block, .character, .fifo, .socket].contains(row.kind) { labelColor = theme.nsColor("listing.special") }
      else if row.isExecutable { labelColor = theme.nsColor("listing.executable") }
      else { labelColor = theme.nsColor("listing.text") }
      iconColor = row.isDirectory ? theme.nsColor("listing.directory") : labelColor.withAlphaComponent(0.85)
      var tip = row.path
      if row.isLink { tip += "\n→ \(row.linkTarget)" }
      if !row.warning.isEmpty { tip += "\n\(row.warning)" }
      toolTip = tip
    case "size":
      let known = !row.isDirectory && row.size >= 0
      label.stringValue = known ? Format.bytes(row.size) : "—"
      let style = known ? ListingCell.sizeStyle(row.size) : ("listing.size", false)
      label.font = style.1 ? bold(theme.nsFont("listing.size")) : theme.nsFont("listing.size")
      labelColor = theme.nsColor(style.0)
    case "date":
      label.stringValue = ListingCell.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(row.modified)))
      label.font = theme.nsFont("listing.date")
      labelColor = marked ? theme.nsColor("listing.marked.text") : theme.nsColor("listing.date")
    case "permissions":
      label.stringValue = row.permissions
      label.font = theme.nsFont("listing.meta")
      labelColor = theme.nsColor("listing.date")
    default:
      label.stringValue = row.owner.isEmpty ? "" : "\(row.owner):\(row.group)"
      label.font = theme.nsFont("listing.meta")
      labelColor = theme.nsColor("listing.date")
    }
    applyColors()
  }

  static let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    f.doesRelativeDateFormatting = true
    return f
  }()
}

enum FileIcons {
  static func image(for row: Row) -> NSImage? {
    let name: String
    if row.isLink { name = row.isDirectory ? "folder.badge.questionmark" : "arrow.up.right.square" }
    else if row.isDirectory { name = "folder.fill" }
    else if row.kind == .error || row.kind == .notFound { name = "exclamationmark.triangle" }
    else if [.block, .character].contains(row.kind) { name = "externaldrive" }
    else if [.fifo, .socket].contains(row.kind) { name = "cable.connector" }
    else {
      let ext = (row.name as NSString).pathExtension.lowercased()
      switch ext {
      case "jpg", "jpeg", "png", "gif", "heic", "tiff", "webp", "bmp": name = "photo"
      case "mov", "mp4", "m4v", "avi", "mkv": name = "film"
      case "flac", "mp3", "wav", "aac", "m4a", "ogg": name = "music.note"
      case "7z", "zip", "tar", "gz", "xz", "bz2", "rar": name = "archivebox"
      case "md", "txt", "rtf", "pdf", "doc", "docx": name = "doc.text"
      case "js", "ts", "cpp", "hpp", "c", "h", "swift", "py", "rs", "go", "java", "json", "html", "css", "lua", "sh": name = "chevron.left.forwardslash.chevron.right"
      default: name = row.isExecutable ? "terminal" : "doc"
      }
    }
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)
  }
}
