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
    private var listingRevision: UInt64 = .max

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

    /// Brings the table in line with the engine.
    func apply(force: Bool) {
      guard let table else { return }
      let pane = self.pane
      let revision = engine.listingRevision[side]
      let themeChanged = themeRevision != app.theme.revision
      let styleChanged = style != app.preferences.selectionStyle
      if force || revision != listingRevision || themeChanged || styleChanged {
        listingRevision = revision
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
      table.needsDisplay = true
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
      if pane.cursorRow >= 0, pane.cursorRow < count { table.scrollRowToVisible(Int(pane.cursorRow)) }
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

  override func becomeFirstResponder() -> Bool {
    let ok = super.becomeFirstResponder()
    if ok { MainActor.assumeIsolated { coordinator?.becameFocused() } }
    return ok
  }
  override func resignFirstResponder() -> Bool {
    needsDisplay = true
    return super.resignFirstResponder()
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
      let row = coordinator.row(rowIndex)
      let largest = max(coordinator.pane.largestItem, 1)
      // A thin bar along the bottom of the row: the item's size against the largest in the folder.
      if !row.isDirectory, row.size > 0 {
        let width = (bounds.width - 8) * CGFloat(Double(row.size) / Double(largest))
        theme.nsColor("listing.gauge").setFill()
        NSBezierPath(roundedRect: NSRect(x: 4, y: bounds.maxY - 3, width: max(width, 2), height: 2), xRadius: 1, yRadius: 1).fill()
      }
      if row.selected && coordinator.app.preferences.selectionStyle == .commander {
        theme.nsColor("listing.marked.background").setFill()
        bounds.fill()
      }
    }
  }

  override func drawSelection(in dirtyRect: NSRect) {
    MainActor.assumeIsolated {
      guard let coordinator else { return }
      let focused = coordinator.engine.focusedSide == coordinator.side && window?.firstResponder === superview
      let color = coordinator.app.theme.nsColor(focused ? "listing.cursor" : "listing.cursor.inactive")
      color.setFill()
      NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
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

  @MainActor
  func configure(row: Row, column: String, coordinator: ListingView.Coordinator, rowIndex: Int) {
    let theme = coordinator.app.theme
    let isCursor = coordinator.table?.selectedRowIndexes.contains(rowIndex) ?? false
    let focusedPane = coordinator.engine.focusedSide == coordinator.side
    let emphasized = isCursor && focusedPane && coordinator.table?.window?.firstResponder === coordinator.table
    let marked = row.selected && coordinator.app.preferences.selectionStyle == .commander
    label.alignment = column == "size" ? .right : .left
    switch column {
    case "name":
      label.stringValue = row.name
      label.font = theme.nsFont("listing.name")
      icon.image = FileIcons.image(for: row)
      let color: NSColor
      if marked { color = theme.nsColor("listing.marked.text") }
      else if row.kind == .error || row.kind == .notFound { color = theme.nsColor("listing.error") }
      else if row.isDirectory { color = theme.nsColor("listing.directory") }
      else if row.isLink { color = theme.nsColor("listing.symlink") }
      else if [.block, .character, .fifo, .socket].contains(row.kind) { color = theme.nsColor("listing.special") }
      else if row.isExecutable { color = theme.nsColor("listing.executable") }
      else { color = theme.nsColor("listing.text") }
      label.textColor = emphasized ? .alternateSelectedControlTextColor : color
      icon.contentTintColor = emphasized ? .alternateSelectedControlTextColor : (row.isDirectory ? theme.nsColor("listing.directory") : color.withAlphaComponent(0.85))
      if marked { label.font = NSFontManager.shared.convert(label.font!, toHaveTrait: .boldFontMask) }
      var tip = row.path
      if row.isLink { tip += "\n→ \(row.linkTarget)" }
      if !row.warning.isEmpty { tip += "\n\(row.warning)" }
      toolTip = tip
    case "size":
      label.stringValue = row.isDirectory || row.size < 0 ? "—" : Format.bytes(row.size)
      label.font = theme.nsFont("listing.size")
      label.textColor = emphasized ? .alternateSelectedControlTextColor : (marked ? theme.nsColor("listing.marked.text") : theme.nsColor("listing.size"))
    case "date":
      label.stringValue = ListingCell.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(row.modified)))
      label.font = theme.nsFont("listing.date")
      label.textColor = emphasized ? .alternateSelectedControlTextColor : (marked ? theme.nsColor("listing.marked.text") : theme.nsColor("listing.date"))
    case "permissions":
      label.stringValue = row.permissions
      label.font = theme.nsFont("listing.meta")
      label.textColor = emphasized ? .alternateSelectedControlTextColor : theme.nsColor("listing.date")
    default:
      label.stringValue = row.owner.isEmpty ? "" : "\(row.owner):\(row.group)"
      label.font = theme.nsFont("listing.meta")
      label.textColor = emphasized ? .alternateSelectedControlTextColor : theme.nsColor("listing.date")
    }
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
