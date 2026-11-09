import AppKit
import FreshKit

/// Fresh's chrome drawn natively: tab bars, the status bar, split dividers,
/// scrollbars, the file explorer, the command palette, popups, context menus
/// and the trust dialog. Most surfaces use Fresh's cell geometry. Rich Compose
/// popups share measured source placement with the grid's pointer routing;
/// Fresh's retained handlers still own their behavior. Clicks pass through
/// this view to the grid. Anything not drawn here shows as cells.
@MainActor
final class ChromeView: NSView {
  let store: SceneStore
  unowned let grid: CellGridView

  /// Regions whose change redraws the chrome.
  private static let regions: Set<String> = [
    "panes", "separators", "statusbar", "palette", "popups", "contextMenu", "trustDialog", "fileExplorer", "cursor",
  ]

  init(store: SceneStore, grid: CellGridView) {
    self.store = store
    self.grid = grid
    super.init(frame: .zero)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  override var isFlipped: Bool { true }
  override var isOpaque: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func apply(_ change: SceneChange) {
    if change.isHello || change.sizeChanged || change.themeChanged || !change.regions.isDisjoint(with: ChromeView.regions) {
      needsDisplay = true
    }
  }

  func themeChanged() { needsDisplay = true }

  // MARK: Colors

  private var theme: SceneTheme { store.theme }
  private var editorBackground: NSColor { grid.defaultBackground }
  private var editorText: NSColor { grid.defaultForeground }
  private var muted: NSColor { theme.muted.map(NSColor.init(scene:)) ?? editorText.withAlphaComponent(0.55) }
  private var accent: NSColor { theme.accent.map(NSColor.init(scene:)) ?? .controlAccentColor }
  private var barBackground: NSColor { editorBackground.blended(withFraction: 0.07, of: theme.isDark ? .black : .black) ?? editorBackground }
  private var panelBackground: NSColor { theme.popupBackground.map(NSColor.init(scene:)) ?? editorBackground.blended(withFraction: 0.06, of: theme.isDark ? .white : .black) ?? editorBackground }
  private var panelText: NSColor { theme.popupForeground.map(NSColor.init(scene:)) ?? editorText }
  /// Selected rows in lists and menus: the Mac accent color with white text.
  private var selectionFill: NSColor { .controlAccentColor }
  private var selection: NSColor { theme.selection.map(NSColor.init(scene:)) ?? NSColor.selectedContentBackgroundColor }
  private var divider: NSColor { editorText.withAlphaComponent(theme.isDark ? 0.14 : 0.16) }

  // MARK: Geometry

  private func box(_ r: CellRect) -> NSRect {
    NSRect(x: CGFloat(r.x) * grid.cellWidth, y: CGFloat(r.y) * grid.cellHeight,
           width: CGFloat(r.width) * grid.cellWidth, height: CGFloat(r.height) * grid.cellHeight)
  }

  // MARK: Drawing

  /// Rectangles drawn this pass; the caret is drawn on top when it falls in one.
  private var covered: [NSRect] = []

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext, store.width > 0 else { return }
    covered = []
    drawSeparators()
    for pane in store.panes {
      drawScrollbar(pane)
      drawTabBar(pane)
    }
    drawExplorer()
    drawStatusBar()
    drawPopups(context)
    drawPalette(context)
    drawContextMenu()
    drawTrustDialog()
    drawCaretIfCovered(context)
  }

  private func drawCaretIfCovered(_ context: CGContext) {
    guard let cursor = store.cursor else { return }
    let cell = grid.rect(column: cursor.column, row: cursor.row)
    guard covered.contains(where: { $0.intersects(cell) }), window?.isKeyWindow == true else { return }
    accent.setFill()
    NSRect(x: cell.minX, y: cell.minY + 1, width: 2, height: cell.height - 2).fill()
  }

  // MARK: Dividers and scrollbars

  private func drawSeparators() {
    for separator in store.separators {
      let x = Int(separator.x), y = Int(separator.y), length = Int(separator.len)
      let vertical = separator.vertical
      let cells = box(CellRect(x: x, y: y, width: vertical ? 1 : length, height: vertical ? length : 1))
      editorBackground.setFill()
      cells.fill()
      divider.setFill()
      if vertical {
        NSRect(x: cells.midX.rounded(.down), y: cells.minY, width: 1, height: cells.height).fill()
      } else {
        NSRect(x: cells.minX, y: cells.midY.rounded(.down), width: cells.width, height: 1).fill()
      }
    }
  }

  private func drawScrollbar(_ pane: WirePane) {
    let track = CellRect(pane.vscroll)
    guard track.width > 0, track.height > 0 else { return }
    let area = box(track)
    editorBackground.setFill()
    area.fill()
    for marker in pane.markers {
      NSColor(scene: SceneColor(packed: marker.color)).setFill()
      NSRect(x: area.maxX - 3, y: area.minY + CGFloat(marker.row) * grid.cellHeight + grid.cellHeight / 2 - 1, width: 3, height: 2).fill()
    }
    let thumb: CGRect
    if grid.usesComposeScrollbar(pane) {
      guard let bar = grid.composeScrollbar(pane), bar.proportion < 1 else { return }
      let measured = grid.composeScrollbarThumb(pane, bar: bar)
      thumb = CGRect(x: area.midX - 3, y: measured.minY + 2, width: 6, height: max(1, measured.height - 4))
    } else {
      let start = Int(pane.thumbStart), end = Int(pane.thumbEnd)
      guard end > start, end - start < track.height else { return }
      thumb = NSRect(x: area.midX - 3, y: area.minY + CGFloat(start) * grid.cellHeight + 2,
        width: 6, height: max(grid.cellHeight, CGFloat(end - start) * grid.cellHeight) - 4)
    }
    editorText.withAlphaComponent(0.28).setFill()
    NSBezierPath(roundedRect: thumb, xRadius: 3, yRadius: 3).fill()
  }

  // MARK: Tabs

  private func drawTabBar(_ pane: WirePane) {
    guard pane.tabBar.hasBar else { return }
    let barRect = CellRect(pane.tabBar.bar)
    guard barRect.width > 0 else { return }
    let bar = box(barRect)
    barBackground.setFill()
    bar.fill()
    var taken: [CellRect] = []
    let font = NSFont.systemFont(ofSize: max(10, grid.cellHeight * 0.68))
    for tab in pane.tabBar.tabs {
      let cells = CellRect(tab.rect)
      let closeCells = CellRect(tab.closeRect)
      taken.append(cells)
      if closeCells.width > 0 { taken.append(closeCells) }
      let rect = box(cells).insetBy(dx: 1, dy: 0)
      let active = tab.active
      if active {
        editorBackground.setFill()
        rect.fill()
        selectionFill.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 2).fill()
      } else {
        divider.setFill()
        NSRect(x: rect.maxX, y: rect.minY + 3, width: 1, height: rect.height - 6).fill()
      }
      let close = closeCells.width > 0 ? box(closeCells) : nil
      var labelRect = rect.insetBy(dx: grid.cellWidth, dy: 0)
      if let close { labelRect.size.width = max(0, close.minX - labelRect.minX - 2) }
      let modified = tab.modified
      var label = tab.label
      if modified, label.hasSuffix("*") { label.removeLast() }  // the dot says it
      drawLabel(label, in: labelRect, font: active ? .systemFont(ofSize: font.pointSize, weight: .medium) : font,
                color: active ? editorText : muted)
      if var close {
        close.origin.x = max(close.minX, labelRect.maxX)
        drawSymbol(modified ? "circle.fill" : "xmark", in: close, size: modified ? 6 : 8, color: active ? editorText : muted)
      }
    }
    // The bar's other controls (new tab, scroll arrows) are cells; draw their glyphs natively.
    for row in barRect.y..<(barRect.y + barRect.height) where row < store.grid.count {
      var column = 0
      for run in store.grid[row] {
        for character in run.text {
          defer { column += 1 }
          guard column >= barRect.x, column < barRect.x + barRect.width, character != " ",
                !taken.contains(where: { $0.contains(column: column, row: row) }) else { continue }
          let cell = grid.rect(column: column, row: row)
          switch character {
          case "+": drawSymbol("plus", in: cell, size: 10, color: muted)
          case "<": drawSymbol("chevron.left", in: cell, size: 9, color: muted)
          case ">": drawSymbol("chevron.right", in: cell, size: 9, color: muted)
          default: drawLabel(String(character), in: cell, font: font, color: muted, alignment: .center)
          }
        }
      }
    }
    covered.append(bar)
  }

  // MARK: Status bar

  private func drawStatusBar() {
    guard let status = store.statusBar else { return }
    let cells = CellRect(status.rect)
    let bar = box(cells)
    (theme.statusBackground.map(NSColor.init(scene:)) ?? barBackground).setFill()
    bar.fill()
    divider.setFill()
    NSRect(x: bar.minX, y: bar.minY, width: bar.width, height: 1).fill()
    let text = theme.statusForeground.map(NSColor.init(scene:)) ?? muted
    let font = NSFont.systemFont(ofSize: max(10, grid.cellHeight * 0.66))
    for segment in status.segments {
      var label = segment.text
      guard !label.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
      var rect = box(CellRect(x: Int(segment.x), y: cells.y, width: Int(segment.w), height: 1))
      let name = segment.name
      let symbol: String? = [
        "lsp": "bolt.fill", "warning": "exclamationmark.triangle.fill", "remote": "network", "trust": "lock.shield",
        "terminalRestart": "arrow.clockwise",
      ][name]
      if let symbol {
        drawSymbol(symbol, in: NSRect(x: rect.minX, y: rect.minY, width: grid.cellHeight, height: rect.height), size: 9,
                   color: name == "warning" ? .systemYellow : text)
        rect.origin.x += grid.cellHeight
        rect.size.width -= grid.cellHeight
        label = label.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
      }
      drawLabel(label.trimmingCharacters(in: .whitespaces), in: rect, font: font, color: text)
    }
    covered.append(bar)
  }

  // MARK: File explorer

  private func drawExplorer() {
    guard let explorer = store.fileExplorer else { return }
    let cells = CellRect(explorer.rect)
    guard cells.width > 1 else { return }
    let panel = box(CellRect(x: cells.x, y: cells.y, width: cells.width - 1, height: cells.height))
    barBackground.setFill()
    panel.fill()
    divider.setFill()
    NSRect(x: panel.maxX, y: panel.minY, width: 1, height: panel.height).fill()
    let font = NSFont.systemFont(ofSize: max(10, grid.cellHeight * 0.7))
    let title = (explorer.title.isEmpty ? "Explorer" : explorer.title).trimmingCharacters(in: .whitespaces)
    drawLabel(title.uppercased(), in: box(CellRect(x: cells.x + 1, y: cells.y, width: cells.width - 2, height: 1)),
              font: .systemFont(ofSize: font.pointSize - 1, weight: .semibold), color: muted)
    let rows = explorer.rows
    let height = max(0, min(Int(explorer.viewportHeight), cells.height - 1))
    let viewport = explorer.viewportRows.map { Int($0) }
    let selected = explorer.hasSelected ? Int(explorer.selected) : nil
    let focused = window?.isKeyWindow == true
    for (line, index) in viewport.prefix(height).enumerated() where index < rows.count {
      let row = rows[index]
      let rect = box(CellRect(x: cells.x, y: cells.y + 1 + line, width: cells.width - 1, height: 1))
      if index == selected {
        (focused ? selection : selection.withAlphaComponent(0.5)).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 0.5), xRadius: 4, yRadius: 4).fill()
      }
      let depth = CGFloat(row.depth)
      let isDirectory = row.isDir
      var x = rect.minX + 6 + depth * 12
      if isDirectory {
        drawSymbol(row.expanded ? "chevron.down" : "chevron.right",
                   in: NSRect(x: x, y: rect.minY, width: 10, height: rect.height), size: 8, color: muted)
      }
      x += 12
      let icon = isDirectory ? NSWorkspace.shared.icon(for: .folder)
        : NSWorkspace.shared.icon(for: .init(filenameExtension: (row.name as NSString).pathExtension) ?? .data)
      let side = min(rect.height - 2, 14)
      icon.draw(in: NSRect(x: x, y: rect.midY - side / 2, width: side, height: side), from: .zero, operation: .sourceOver,
                fraction: 1, respectFlipped: true, hints: nil)
      x += side + 5
      drawLabel(row.name, in: NSRect(x: x, y: rect.minY, width: max(0, rect.maxX - x - 4), height: rect.height),
                font: font, color: editorText)
    }
    covered.append(panel)
  }

  // MARK: Popups

  private func drawPopups(_ context: CGContext) {
    for popup in store.popups {
      guard let presentation = grid.popupPresentation(popup) else { continue }
      if popup.hasGrid {
        drawPopupPicture(presentation, context)
        covered.append(presentation.placement.clip)
        continue
      }
      let cells = CellRect(popup.rect)
      let rect = box(cells)
      drawPanel(rect)
      let inner = CellRect(popup.contentRect)
      if !popup.title.isEmpty, inner.y > cells.y {
        drawLabel(popup.title, in: box(CellRect(x: cells.x + 1, y: cells.y, width: cells.width - 2, height: 1)),
                  font: .systemFont(ofSize: grid.cellHeight * 0.66, weight: .semibold), color: muted)
      }
      let scroll = Int(popup.scrollOffset)
      switch popup.content.content {
      case .list(let list)?:
        let items = list.items
        let selected = Int(list.selected)
        let font = NSFont.systemFont(ofSize: max(10, grid.cellHeight * 0.72))
        for line in 0..<inner.height {
          let index = scroll + line
          guard index < items.count else { break }
          let item = items[index]
          let row = box(CellRect(x: inner.x, y: inner.y + line, width: inner.width, height: 1))
          if index == selected {
            selectionFill.setFill()
            NSBezierPath(roundedRect: row.insetBy(dx: 2, dy: 0.5), xRadius: 4, yRadius: 4).fill()
          }
          let color = index == selected ? NSColor.white : (item.disabled ? muted : panelText)
          var text = item.text
          if !item.icon.isEmpty { text = item.icon + " " + text }
          let detail = item.hasDetail ? item.detail : nil
          let detailWidth = detail.map { min(row.width * 0.45, ($0 as NSString).size(withAttributes: [.font: font]).width + 12) } ?? 0
          drawLabel(text, in: NSRect(x: row.minX + 8, y: row.minY, width: row.width - 16 - detailWidth, height: row.height),
                    font: font, color: color)
          if let detail {
            drawLabel(detail, in: NSRect(x: row.maxX - detailWidth - 8, y: row.minY, width: detailWidth, height: row.height),
                      font: font, color: index == selected ? NSColor.white.withAlphaComponent(0.8) : muted, alignment: .right)
          }
        }
      case .lines(let content)?:
        // Hover docs and other text: Fresh's styled runs, one per cell, on the panel.
        let lines = content.lines
        for line in 0..<inner.height {
          let index = scroll + line
          guard index < lines.count else { break }
          var column = inner.x
          for run in CellRun.runs(lines[index]) {
            let (fg, _) = grid.colors(run)
            grid.drawText(run, column: column, row: inner.y + line, color: fg ?? panelText, context: context)
            column += run.cells
          }
        }
      case nil:
        break
      }
      covered.append(rect)
    }
  }

  private func drawPopupPicture(_ presentation: ComposePopupPresentation, _ context: CGContext) {
    let placement = presentation.placement
    context.saveGState()
    defer { context.restoreGState() }
    context.clip(to: placement.clip)
    context.translateBy(x: placement.translation.x, y: placement.translation.y)
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    let cells = CellRect(presentation.popup.rect)
    panelBackground.setFill()
    placement.original.fill()
    for row in presentation.popup.grid.rows {
      guard Int(row.index) < cells.height else { continue }
      let y = cells.y + Int(row.index)
      var column = cells.x
      for run in CellRun.runs(row) {
        let (fg, bg) = grid.colors(run)
        if let bg { bg.setFill(); grid.rect(column: column, row: y, count: run.cells).fill() }
        grid.drawText(run, column: column, row: y, color: fg ?? panelText, context: context)
        if run.underline {
          (fg ?? panelText).setFill()
          NSRect(x: CGFloat(column) * grid.cellWidth, y: CGFloat(y + 1) * grid.cellHeight - 2,
                 width: CGFloat(run.cells) * grid.cellWidth, height: 1).fill()
        }
        column += run.cells
      }
    }
  }

  // MARK: Palette

  /// The command palette and pickers. Fresh lays out `visibleCount` rows down
  /// from `listRect`; they become native rows. The box's other rows (the query
  /// of an overlay prompt, mode hints, a toolbar) keep Fresh's own text, drawn
  /// on the native panel, so the caret still lines up with the query.
  private func drawPalette(_ context: CGContext) {
    guard let palette = store.palette, palette.hasListRect else { return }
    let list = CellRect(palette.listRect)
    let suggestions = palette.suggestions
    let selected = palette.hasSelected ? Int(palette.selected) : nil
    let start = Int(palette.scrollStart)
    let count = min(Int(palette.visibleCount), max(0, suggestions.count - start))
    let outer = palette.hasOuterRect ? CellRect(palette.outerRect)
      : CellRect(x: list.x - 1, y: list.y, width: list.width + 2, height: max(1, count))
    let rect = box(outer)
    drawPanel(rect)
    let rows = list.y..<(list.y + count)
    for row in outer.y..<(outer.y + outer.height) where !rows.contains(row) {
      drawCells(row: row, from: outer.x + 1, to: outer.x + outer.width - 1, context: context)
    }
    let font = NSFont.systemFont(ofSize: max(10, grid.cellHeight * 0.72))
    for line in 0..<count {
      let item = suggestions[start + line]
      let row = box(CellRect(x: list.x, y: list.y + line, width: list.width, height: 1))
      let isSelected = start + line == selected
      if isSelected {
        selectionFill.setFill()
        NSBezierPath(roundedRect: row.insetBy(dx: 3, dy: 0.5), xRadius: 4, yRadius: 4).fill()
      }
      let color = isSelected ? NSColor.white : (item.disabled ? muted : panelText)
      let key = item.hasKeybinding ? item.keybinding : nil
      let keyWidth = key.map { ($0 as NSString).size(withAttributes: [.font: font]).width + 16 } ?? 0
      let text = item.text
      var textRect = NSRect(x: row.minX + 10, y: row.minY, width: row.width - 20 - keyWidth, height: row.height)
      drawLabel(text, in: textRect, font: font, color: color)
      if !item.description_p.isEmpty {
        let description = item.description_p
        let used = (text as NSString).size(withAttributes: [.font: font]).width + 14
        textRect.origin.x += used
        textRect.size.width -= used
        drawLabel(description, in: textRect, font: font, color: isSelected ? NSColor.white.withAlphaComponent(0.75) : muted)
      }
      if let key {
        drawLabel(key, in: NSRect(x: row.maxX - keyWidth - 6, y: row.minY, width: keyWidth, height: row.height), font: font,
                  color: isSelected ? NSColor.white.withAlphaComponent(0.85) : muted, alignment: .right)
      }
    }
    covered.append(rect)
  }

  /// Draws a row's cells from `from` up to `to` as the grid would, on top of a native background.
  private func drawCells(row: Int, from: Int, to: Int, context: CGContext) {
    guard row >= 0, row < store.grid.count else { return }
    var column = 0
    for run in store.grid[row] {
      defer { column += run.cells }
      guard column + run.cells > from, column < to else { continue }
      let (fg, _) = grid.colors(run)
      grid.drawText(run, column: column, row: row, color: fg ?? editorText, context: context)
    }
  }

  // MARK: Context menu

  private func drawContextMenu() {
    guard let menu = store.contextMenu else { return }
    let items = menu.items
    let x = Int(menu.x), y = Int(menu.y)
    let width = (items.map(\.count).max() ?? 8) + 4
    let rect = box(CellRect(x: x, y: y, width: width, height: items.count + 2))
    drawPanel(rect)
    let highlighted = Int(menu.highlighted)
    let font = NSFont.menuFont(ofSize: max(10, grid.cellHeight * 0.72))
    for (index, item) in items.enumerated() {
      let row = box(CellRect(x: x, y: y + 1 + index, width: width, height: 1))
      if index == highlighted {
        selectionFill.setFill()
        NSBezierPath(roundedRect: row.insetBy(dx: 4, dy: 0.5), xRadius: 4, yRadius: 4).fill()
      }
      drawLabel(item, in: row.insetBy(dx: 12, dy: 0), font: font, color: index == highlighted ? .white : panelText)
    }
    covered.append(rect)
  }

  // MARK: Trust dialog

  private func drawTrustDialog() {
    guard let dialog = store.trustDialog else { return }
    let cells = CellRect(dialog.dialog)
    NSColor.black.withAlphaComponent(0.25).setFill()
    bounds.fill()
    let rect = box(cells)
    drawPanel(rect)
    let font = NSFont.systemFont(ofSize: max(11, grid.cellHeight * 0.75))
    drawLabel(dialog.title, in: box(CellRect(x: cells.x + 2, y: cells.y + 1, width: cells.width - 4, height: 1)),
              font: .boldSystemFont(ofSize: font.pointSize), color: panelText)
    drawLabel(dialog.path, in: box(CellRect(x: cells.x + 2, y: cells.y + 2, width: cells.width - 4, height: 1)),
              font: .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular), color: muted)
    for option in dialog.options {
      let row = box(CellRect(option.rect))
      let selected = option.selected
      drawSymbol(selected ? "largecircle.fill.circle" : "circle", in: NSRect(x: row.minX, y: row.minY, width: grid.cellHeight, height: row.height),
                 size: 11, color: selected ? selectionFill : muted)
      var text = option.label
      if !option.description_p.isEmpty { text += " — " + option.description_p }
      drawLabel(text, in: NSRect(x: row.minX + grid.cellHeight + 4, y: row.minY, width: row.width - grid.cellHeight - 4, height: row.height),
                font: font, color: panelText)
    }
    for (r, label, primary) in [(dialog.ok, dialog.okLabel.isEmpty ? "OK" : dialog.okLabel, true),
                                (dialog.quit, dialog.quitLabel.isEmpty ? "Quit" : dialog.quitLabel, false)] {
      let button = box(CellRect(r)).insetBy(dx: 0, dy: 1)
      (primary ? selectionFill : panelBackground.blended(withFraction: 0.12, of: panelText) ?? panelBackground).setFill()
      NSBezierPath(roundedRect: button, xRadius: 5, yRadius: 5).fill()
      drawLabel(label.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")), in: button, font: font,
                color: primary ? .white : panelText, alignment: .center)
    }
    covered.append(rect)
  }

  // MARK: Primitives

  private func drawPanel(_ rect: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 10
    shadow.shadowOffset = NSSize(width: 0, height: -3)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.set()
    panelBackground.setFill()
    let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    divider.setStroke()
    path.lineWidth = 1
    path.stroke()
  }

  private func drawLabel(_ text: String, in rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
    guard rect.width > 2, !text.isEmpty else { return }
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byTruncatingTail
    style.alignment = alignment
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
    let height = ceil(font.ascender - font.descender)
    (text as NSString).draw(with: NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height),
                            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
  }

  private func drawSymbol(_ name: String, in rect: NSRect, size: CGFloat, color: NSColor) {
    let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold).applying(.init(paletteColors: [color]))
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
    let target = NSRect(x: rect.midX - image.size.width / 2, y: rect.midY - image.size.height / 2, width: image.size.width, height: image.size.height)
    image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
  }
}
