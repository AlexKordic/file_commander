import AppKit
import FreshKit

/// Fresh's chrome drawn natively: tab bars, the status bar, split dividers,
/// scrollbars, the file explorer, the command palette, popups, context menus
/// and the trust dialog. Each surface covers exactly the cells Fresh laid it
/// out on, so the cell grid underneath stays the source of truth: clicks pass
/// through this view to the grid, which sends them to Fresh at those cells, and
/// Fresh's own hit-testing answers them. Anything not drawn here shows as cells.
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
  private var selection: NSColor { theme.selection.map(NSColor.init(scene:)) ?? NSColor.selectedContentBackgroundColor }
  private var divider: NSColor { editorText.withAlphaComponent(theme.isDark ? 0.14 : 0.16) }

  // MARK: Geometry

  private func box(_ r: CellRect) -> NSRect {
    NSRect(x: CGFloat(r.x) * grid.cellWidth, y: CGFloat(r.y) * grid.cellHeight,
           width: CGFloat(r.width) * grid.cellWidth, height: CGFloat(r.height) * grid.cellHeight)
  }

  private func region(_ key: String) -> [String: Any]? { store.regions[key] as? [String: Any] }

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
    for separator in store.regions["separators"] as? [[String: Any]] ?? [] {
      let x = separator["x"] as? Int ?? 0, y = separator["y"] as? Int ?? 0, length = separator["len"] as? Int ?? 0
      let vertical = separator["vertical"] as? Bool ?? true
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

  private func drawScrollbar(_ pane: [String: Any]) {
    guard let track = CellRect(pane["vscroll"]), track.width > 0, track.height > 0 else { return }
    let area = box(track)
    editorBackground.setFill()
    area.fill()
    let start = pane["thumbStart"] as? Int ?? 0, end = pane["thumbEnd"] as? Int ?? 0
    for marker in pane["vscrollMarkers"] as? [[String: Any]] ?? [] {
      guard let row = marker["row"] as? Int else { continue }
      (SceneColor(marker["color"]).map(NSColor.init(scene:)) ?? accent).setFill()
      NSRect(x: area.maxX - 3, y: area.minY + CGFloat(row) * grid.cellHeight + grid.cellHeight / 2 - 1, width: 3, height: 2).fill()
    }
    guard end > start, end - start < track.height else { return }
    let thumb = NSRect(x: area.midX - 3, y: area.minY + CGFloat(start) * grid.cellHeight + 2,
                       width: 6, height: max(grid.cellHeight, CGFloat(end - start) * grid.cellHeight) - 4)
    editorText.withAlphaComponent(0.28).setFill()
    NSBezierPath(roundedRect: thumb, xRadius: 3, yRadius: 3).fill()
  }

  // MARK: Tabs

  private func drawTabBar(_ pane: [String: Any]) {
    guard let barRect = CellRect(pane["tabBar"]), barRect.width > 0 else { return }
    let bar = box(barRect)
    barBackground.setFill()
    bar.fill()
    let tabs = pane["tabs"] as? [[String: Any]] ?? []
    var taken: [CellRect] = []
    let font = NSFont.systemFont(ofSize: max(10, grid.cellHeight * 0.68))
    for tab in tabs {
      guard let cells = CellRect(tab["rect"]) else { continue }
      taken.append(cells)
      if let close = CellRect(tab["closeRect"]) { taken.append(close) }
      let rect = box(cells).insetBy(dx: 1, dy: 0)
      let active = tab["active"] as? Bool ?? false
      if active {
        editorBackground.setFill()
        rect.fill()
        accent.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 2).fill()
      } else {
        divider.setFill()
        NSRect(x: rect.maxX, y: rect.minY + 3, width: 1, height: rect.height - 6).fill()
      }
      let close = CellRect(tab["closeRect"]).map(box)
      var labelRect = rect.insetBy(dx: grid.cellWidth, dy: 0)
      if let close { labelRect.size.width = max(0, close.minX - labelRect.minX - 2) }
      let modified = tab["modified"] as? Bool ?? false
      var label = tab["label"] as? String ?? ""
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
    guard let status = region("statusbar"), let cells = CellRect(status["rect"]) else { return }
    let bar = box(cells)
    (theme.statusBackground.map(NSColor.init(scene:)) ?? barBackground).setFill()
    bar.fill()
    divider.setFill()
    NSRect(x: bar.minX, y: bar.minY, width: bar.width, height: 1).fill()
    let text = theme.statusForeground.map(NSColor.init(scene:)) ?? muted
    let font = NSFont.systemFont(ofSize: max(10, grid.cellHeight * 0.66))
    for segment in status["segments"] as? [[String: Any]] ?? [] {
      guard var label = segment["text"] as? String, !label.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
      let x = segment["x"] as? Int ?? 0, w = segment["w"] as? Int ?? 0
      var rect = box(CellRect(x: x, y: cells.y, width: w, height: 1))
      let name = segment["name"] as? String ?? ""
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
    guard let explorer = region("fileExplorer"), let cells = CellRect(explorer["rect"]), cells.width > 1 else { return }
    let panel = box(CellRect(x: cells.x, y: cells.y, width: cells.width - 1, height: cells.height))
    barBackground.setFill()
    panel.fill()
    divider.setFill()
    NSRect(x: panel.maxX, y: panel.minY, width: 1, height: panel.height).fill()
    let font = NSFont.systemFont(ofSize: max(10, grid.cellHeight * 0.7))
    let title = (explorer["title"] as? String ?? "Explorer").trimmingCharacters(in: .whitespaces)
    drawLabel(title.uppercased(), in: box(CellRect(x: cells.x + 1, y: cells.y, width: cells.width - 2, height: 1)),
              font: .systemFont(ofSize: font.pointSize - 1, weight: .semibold), color: muted)
    let rows = explorer["rows"] as? [[String: Any]] ?? []
    let start = explorer["scrollOffset"] as? Int ?? 0
    let height = max(0, min(explorer["viewportHeight"] as? Int ?? cells.height - 1, cells.height - 1))
    let viewport = explorer["viewportRows"] as? [Int] ?? Array(start..<(start + height))
    let selected = explorer["selected"] as? Int
    let focused = window?.isKeyWindow == true
    for (line, index) in viewport.prefix(height).enumerated() where index < rows.count {
      let row = rows[index]
      let rect = box(CellRect(x: cells.x, y: cells.y + 1 + line, width: cells.width - 1, height: 1))
      if index == selected {
        (focused ? selection : selection.withAlphaComponent(0.5)).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 0.5), xRadius: 4, yRadius: 4).fill()
      }
      let depth = CGFloat(row["depth"] as? Int ?? 0)
      let isDirectory = row["isDir"] as? Bool ?? false
      var x = rect.minX + 6 + depth * 12
      if isDirectory {
        drawSymbol(row["expanded"] as? Bool == true ? "chevron.down" : "chevron.right",
                   in: NSRect(x: x, y: rect.minY, width: 10, height: rect.height), size: 8, color: muted)
      }
      x += 12
      let icon = isDirectory ? NSWorkspace.shared.icon(for: .folder)
        : NSWorkspace.shared.icon(for: .init(filenameExtension: ((row["name"] as? String ?? "") as NSString).pathExtension) ?? .data)
      let side = min(rect.height - 2, 14)
      icon.draw(in: NSRect(x: x, y: rect.midY - side / 2, width: side, height: side), from: .zero, operation: .sourceOver,
                fraction: 1, respectFlipped: true, hints: nil)
      x += side + 5
      drawLabel(row["name"] as? String ?? "", in: NSRect(x: x, y: rect.minY, width: max(0, rect.maxX - x - 4), height: rect.height),
                font: font, color: editorText)
    }
    covered.append(panel)
  }

  // MARK: Popups

  private func drawPopups(_ context: CGContext) {
    for popup in store.regions["popups"] as? [[String: Any]] ?? [] {
      guard let cells = CellRect(popup["rect"]) else { continue }
      let rect = box(cells)
      drawPanel(rect)
      let inner = CellRect(popup["contentRect"]) ?? cells
      let content = popup["content"] as? [String: Any] ?? [:]
      if let title = popup["title"] as? String, !title.isEmpty, inner.y > cells.y {
        drawLabel(title, in: box(CellRect(x: cells.x + 1, y: cells.y, width: cells.width - 2, height: 1)),
                  font: .systemFont(ofSize: grid.cellHeight * 0.66, weight: .semibold), color: muted)
      }
      let scroll = popup["scrollOffset"] as? Int ?? 0
      if content["type"] as? String == "list" {
        let items = content["items"] as? [[String: Any]] ?? []
        let selected = content["selected"] as? Int ?? -1
        let font = NSFont.systemFont(ofSize: max(10, grid.cellHeight * 0.72))
        for line in 0..<inner.height {
          let index = scroll + line
          guard index < items.count else { break }
          let item = items[index]
          let row = box(CellRect(x: inner.x, y: inner.y + line, width: inner.width, height: 1))
          if index == selected {
            accent.setFill()
            NSBezierPath(roundedRect: row.insetBy(dx: 2, dy: 0.5), xRadius: 4, yRadius: 4).fill()
          }
          let color = index == selected ? NSColor.white : (item["disabled"] as? Bool == true ? muted : panelText)
          var text = item["text"] as? String ?? ""
          if let icon = item["icon"] as? String, !icon.isEmpty { text = icon + " " + text }
          let detail = item["detail"] as? String
          let detailWidth = detail.map { min(row.width * 0.45, ($0 as NSString).size(withAttributes: [.font: font]).width + 12) } ?? 0
          drawLabel(text, in: NSRect(x: row.minX + 8, y: row.minY, width: row.width - 16 - detailWidth, height: row.height),
                    font: font, color: color)
          if let detail {
            drawLabel(detail, in: NSRect(x: row.maxX - detailWidth - 8, y: row.minY, width: detailWidth, height: row.height),
                      font: font, color: index == selected ? NSColor.white.withAlphaComponent(0.8) : muted, alignment: .right)
          }
        }
      } else {
        // Hover docs and other text: Fresh's styled runs, one per cell, on the panel.
        let lines = content["lines"] as? [[Any]] ?? []
        for line in 0..<inner.height {
          let index = scroll + line
          guard index < lines.count else { break }
          var column = inner.x
          for run in CellRun.row(lines[index]) {
            let (fg, _) = grid.colors(run)
            grid.drawText(run, column: column, row: inner.y + line, color: fg ?? panelText, context: context)
            column += run.cells
          }
        }
      }
      covered.append(rect)
    }
  }

  // MARK: Palette

  private func drawPalette(_ context: CGContext) {
    guard let palette = region("palette") else { return }
    let suggestions = palette["suggestions"] as? [[String: Any]] ?? []
    let selected = palette["selected"] as? Int
    let start = palette["scrollStart"] as? Int ?? 0
    let font = NSFont.systemFont(ofSize: max(10, grid.cellHeight * 0.72))
    if let outer = CellRect(palette["outerRect"]) {
      let rect = box(outer)
      drawPanel(rect)
      let title = palette["title"] as? String ?? ""
      if !title.isEmpty {
        drawLabel(title, in: box(CellRect(x: outer.x + 1, y: outer.y, width: outer.width - 2, height: 1)),
                  font: .systemFont(ofSize: font.pointSize - 1, weight: .semibold), color: muted)
      }
      // The query line stays on the cells (so the caret lines up); restyle its row.
      if let list = CellRect(palette["listRect"]), list.y > outer.y + 1 {
        let queryRow = list.y - 1
        let field = box(CellRect(x: outer.x + 1, y: queryRow, width: outer.width - 2, height: 1))
        editorBackground.setFill()
        NSBezierPath(roundedRect: field, xRadius: 4, yRadius: 4).fill()
        drawCells(row: queryRow, from: outer.x + 1, to: outer.x + outer.width - 1, context: context)
      }
      covered.append(rect)
    }
    if let list = CellRect(palette["listRect"]) {
      if CellRect(palette["outerRect"]) == nil {
        let rect = box(list)
        drawPanel(rect)
        covered.append(rect)
      }
      for line in 0..<list.height {
        let index = start + line
        guard index < suggestions.count else { break }
        let item = suggestions[index]
        let row = box(CellRect(x: list.x, y: list.y + line, width: list.width, height: 1))
        let isSelected = index == selected
        if isSelected {
          accent.setFill()
          NSBezierPath(roundedRect: row.insetBy(dx: 3, dy: 0.5), xRadius: 4, yRadius: 4).fill()
        }
        let color = isSelected ? NSColor.white : (item["disabled"] as? Bool == true ? muted : panelText)
        let key = item["keybinding"] as? String
        let keyWidth = key.map { ($0 as NSString).size(withAttributes: [.font: font]).width + 16 } ?? 0
        let description = item["description"] as? String
        var textRect = NSRect(x: row.minX + 10, y: row.minY, width: row.width - 20 - keyWidth, height: row.height)
        drawLabel(item["text"] as? String ?? "", in: textRect, font: font, color: color)
        if let description, !description.isEmpty {
          let used = ((item["text"] as? String ?? "") as NSString).size(withAttributes: [.font: font]).width + 14
          textRect.origin.x += used
          textRect.size.width -= used
          drawLabel(description, in: textRect, font: font, color: isSelected ? NSColor.white.withAlphaComponent(0.75) : muted)
        }
        if let key {
          drawLabel(key, in: NSRect(x: row.maxX - keyWidth - 6, y: row.minY, width: keyWidth, height: row.height), font: font,
                    color: isSelected ? NSColor.white.withAlphaComponent(0.85) : muted, alignment: .right)
        }
      }
    }
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
    guard let menu = region("contextMenu") else { return }
    let items = menu["items"] as? [String] ?? []
    let x = menu["x"] as? Int ?? 0, y = menu["y"] as? Int ?? 0
    let width = (items.map(\.count).max() ?? 8) + 4
    let rect = box(CellRect(x: x, y: y, width: width, height: items.count + 2))
    drawPanel(rect)
    let highlighted = menu["highlighted"] as? Int ?? -1
    let font = NSFont.menuFont(ofSize: max(10, grid.cellHeight * 0.72))
    for (index, item) in items.enumerated() {
      let row = box(CellRect(x: x, y: y + 1 + index, width: width, height: 1))
      if index == highlighted {
        accent.setFill()
        NSBezierPath(roundedRect: row.insetBy(dx: 4, dy: 0.5), xRadius: 4, yRadius: 4).fill()
      }
      drawLabel(item, in: row.insetBy(dx: 12, dy: 0), font: font, color: index == highlighted ? .white : panelText)
    }
    covered.append(rect)
  }

  // MARK: Trust dialog

  private func drawTrustDialog() {
    guard let dialog = region("trustDialog"), let cells = CellRect(dialog["dialog"]) else { return }
    NSColor.black.withAlphaComponent(0.25).setFill()
    bounds.fill()
    let rect = box(cells)
    drawPanel(rect)
    let font = NSFont.systemFont(ofSize: max(11, grid.cellHeight * 0.75))
    drawLabel(dialog["title"] as? String ?? "", in: box(CellRect(x: cells.x + 2, y: cells.y + 1, width: cells.width - 4, height: 1)),
              font: .boldSystemFont(ofSize: font.pointSize), color: panelText)
    drawLabel(dialog["path"] as? String ?? "", in: box(CellRect(x: cells.x + 2, y: cells.y + 2, width: cells.width - 4, height: 1)),
              font: .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular), color: muted)
    for option in dialog["options"] as? [[String: Any]] ?? [] {
      guard let r = CellRect(option["rect"]) else { continue }
      let row = box(r)
      let selected = option["selected"] as? Bool ?? false
      drawSymbol(selected ? "largecircle.fill.circle" : "circle", in: NSRect(x: row.minX, y: row.minY, width: grid.cellHeight, height: row.height),
                 size: 11, color: selected ? accent : muted)
      var text = option["label"] as? String ?? ""
      if let description = option["description"] as? String, !description.isEmpty { text += " — " + description }
      drawLabel(text, in: NSRect(x: row.minX + grid.cellHeight + 4, y: row.minY, width: row.width - grid.cellHeight - 4, height: row.height),
                font: font, color: panelText)
    }
    for (key, label, primary) in [("ok", dialog["okLabel"] as? String ?? "OK", true), ("quit", dialog["quitLabel"] as? String ?? "Quit", false)] {
      guard let r = CellRect(dialog[key]) else { continue }
      let button = box(r).insetBy(dx: 0, dy: 1)
      (primary ? accent : panelBackground.blended(withFraction: 0.12, of: panelText) ?? panelBackground).setFill()
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
