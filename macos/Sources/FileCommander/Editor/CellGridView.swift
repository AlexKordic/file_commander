import AppKit
import CoreText
import FreshKit

/// What the grid needs from its owner: where input goes, and the settings that
/// shape it.
@MainActor
protocol CellGridDelegate: AnyObject {
  var connected: Bool { get }
  func grid(_ grid: CellGridView, send input: SceneInput)
  func gridDidResize(_ grid: CellGridView, columns: Int, rows: Int)
  /// The chord is an app shortcut (Quit, Hide, the switch key, ...) that the
  /// editor must not see; returns true when the owner handled it.
  func grid(_ grid: CellGridView, handleAppChord event: NSEvent) -> Bool
  func gridPaste(_ grid: CellGridView)
  func grid(_ grid: CellGridView, point: CGPoint, in pane: ComposePresentation, extend: Bool, count: Int)
  func grid(_ grid: CellGridView, scroll delta: CGPoint, in pane: ComposePresentation)
  func grid(_ grid: CellGridView, revealCaretIn pane: ComposePresentation)
  func grid(_ grid: CellGridView, replace text: String, range: NSRange, in pane: ComposePresentation)
  func grid(_ grid: CellGridView, pendingTextFor pane: WirePane) -> ComposePendingPreview?
  func grid(_ grid: CellGridView, commit text: ComposePendingText, initial: ComposePendingText,
            after: UUID?, afterAction: Bool, virtualPrefix: ComposeVirtualSelections?, in pane: ComposePresentation)
  func grid(_ grid: CellGridView, recover text: String)
  var optionAsAlt: Bool { get }
}

@MainActor
struct ComposePendingPreview {
  let token: UUID
  let target: ComposePresentation
  let text: ComposePendingText?
  let afterAction: Bool
  let prefixToken: UUID?
  var selection: ComposePointer.Preview? = nil
  var virtualSelection: ComposeVirtualSelections? = nil
  var virtualPrefix: ComposeVirtualSelections? = nil
}

/// Draws Fresh's frame as cells, the way its terminal interface does, and turns
/// keyboard, mouse and text input into scene messages. Every glyph sits on its
/// cell column; box-drawing lines are drawn as lines so they join across rows.
@MainActor
final class CellGridView: NSView, @preconcurrency NSTextInputClient {
  weak var delegate: CellGridDelegate?
  let store: SceneStore
  /// What VoiceOver calls the editor: the active tab's name.
  var title = "Editor"
  /// The last frame applied, for telemetry's draw records.
  var shownSequence = 0

  // Metrics.
  private(set) var cellWidth: CGFloat = 8
  private(set) var cellHeight: CGFloat = 16
  private var ascent: CGFloat = 12
  private var fonts: [CTFont] = []  // regular, bold, italic, bold italic
  private var glyphCache: [[UInt16: CGGlyph]] = [[:], [:], [:], [:]]
  private var sentSize = (columns: 0, rows: 0)

  /// Colors for cells that leave theirs to the terminal default.
  var defaultForeground = NSColor.textColor
  var defaultBackground = NSColor.textBackgroundColor
  var caretColor = NSColor.controlAccentColor

  // Caret and composed text.
  private var caretOn = true
  private var blink: Timer?
  private var marked = ""
  private struct Composition {
    let target: ComposePresentation
    var text: ComposePendingText
    let initial: ComposePendingText
    let after: UUID?
    let afterAction: Bool
    var virtualPrefix: ComposeVirtualSelections? = nil
  }
  private var composition: Composition?
  private var compositionDragAnchor: Int?
  private var lastDragCell: (Int, Int)?
  private var lastHoverCell: (Int, Int)?
  private var scrollRemainder: CGFloat = 0
  private var horizontalRemainder: CGFloat = 0
  private(set) var composePanes: [UInt64: ComposePresentation] = [:]
  weak var composeImageController: ComposeImageController?
  weak var composeViewportController: ComposeViewportController?
  private var composeGeometryRevision: UInt64 = 0
  var richPopupProjection = false
  var popupCapture: UInt64?
  var popupHover: UInt64?
  private var composeDrag: UInt64?
  private var composeCaretIdentity: ComposePresentation.Identity?
  private var composeCaretRevision: UInt64 = 0
  private var composeCarets: [UInt64: WireComposeCaret] = [:]
  private var bodyFont = NSFont.systemFont(ofSize: 16)
  private var monoFont = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
  private var composePreferences = ComposePreferences()
  private var composeZoom = 1.0
  var composePalette: ComposePaneLayout.Palette?
  private struct ImageTip: Equatable { var rect: CGRect; var text: String }
  private var imageTips: [ImageTip] = []
  private struct LinkTip: Equatable { var rect: CGRect; var links: [ComposeLink] }
  private var linkTips: [LinkTip] = []
  private var accessibleImages: [ComposeAccessibilityImage.ID: ComposeAccessibilityImage] = [:]
  private var accessibleImageLabels: [ComposeAccessibilityImage.ID: String] = [:]

  init(store: SceneStore) {
    self.store = store
    super.init(frame: .zero)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    setFont(.monospacedSystemFont(ofSize: 13, weight: .regular))
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override var isOpaque: Bool { true }

  // MARK: Metrics

  func setFont(_ font: NSFont) {
    let base = NSFontManager.shared.convert(font, toNotHaveTrait: [.boldFontMask, .italicFontMask])
    let bold = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
    let italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
    let boldItalic = NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask)
    fonts = [base, bold, italic, boldItalic] as [CTFont]
    glyphCache = [[:], [:], [:], [:]]
    let ct = base as CTFont
    var glyph: CGGlyph = 0
    var character: UniChar = 0x4D  // "M"
    CTFontGetGlyphsForCharacters(ct, &character, &glyph, 1)
    var advance = CGSize.zero
    CTFontGetAdvancesForGlyphs(ct, .horizontal, &glyph, &advance, 1)
    cellWidth = max(1, advance.width)
    ascent = ceil(CTFontGetAscent(ct))
    cellHeight = ascent + ceil(CTFontGetDescent(ct)) + ceil(max(0, CTFontGetLeading(ct)))
    reportSize()
    rebuildCompose()
    needsDisplay = true
  }

  func setComposePreferences(_ preferences: ComposePreferences, zoom: Double) {
    let preferences = preferences.normalized, zoom = ComposePreferences.scale(zoom)
    guard preferences != composePreferences || zoom != composeZoom else { return }
    composePreferences = preferences; composeZoom = zoom
    (bodyFont, monoFont) = preferences.fonts(zoom: zoom)
    rebuildCompose()
    needsDisplay = true
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    reportSize()
  }

  /// The grid size that fits the view.
  var gridFit: (columns: Int, rows: Int) {
    (max(20, Int(bounds.width / cellWidth)), max(8, Int(bounds.height / cellHeight)))
  }

  func reportSize() {
    let size = gridFit
    guard size != sentSize, bounds.width > 0 else { return }
    sentSize = size
    delegate?.gridDidResize(self, columns: size.columns, rows: size.rows)
  }

  /// Asks the editor for the current size again (after reconnecting).
  func resendSize() {
    sentSize = (0, 0)
    reportSize()
  }

  func rect(column: Int, row: Int, count: Int = 1) -> NSRect {
    NSRect(x: CGFloat(column) * cellWidth, y: CGFloat(row) * cellHeight, width: CGFloat(count) * cellWidth, height: cellHeight)
  }

  func cell(at point: NSPoint) -> (column: Int, row: Int) {
    let column = Int(point.x / cellWidth), row = Int(point.y / cellHeight)
    return (min(max(0, column), max(0, store.width - 1)), min(max(0, row), max(0, store.height - 1)))
  }

  // MARK: Updates

  /// Redraws what a scene message changed.
  func apply(_ change: SceneChange) {
    if change.isHello { popupCapture = nil; popupHover = nil }
    if change.isHello || change.sizeChanged || change.themeChanged || change.regions.contains("panes") {
      rebuildCompose()
      needsDisplay = true
    }
    if change.sizeChanged || change.themeChanged || change.isHello {
      needsDisplay = true
      return
    }
    for row in change.rows { setNeedsDisplay(rowRect(row)) }
    if change.cursorChanged {
      restartBlink()
      NSAccessibility.post(element: self, notification: .selectedTextChanged)
    }
    if !change.rows.isEmpty { NSAccessibility.post(element: self, notification: .valueChanged) }
  }

  private func rebuildCompose() {
    if let composition {
      let target = composition.target
      let current = store.panes.first { $0.leaf == target.identity.leaf && $0.hasBuffer && $0.buffer == target.identity.buffer }
      let live = Set(current?.compose.cursors.map(\.id) ?? [])
      if UInt64(store.windowID) != target.identity.window || current?.hasCompose != true
          || current?.compose.viewport.epoch != target.pane.compose.viewport.epoch
          || current?.compose.focused != true || (!composition.afterAction && !composition.text.presentation.values.keys.allSatisfy(live.contains)) {
        cancelComposition(recover: true, rebuild: false)
      } else if current?.compose.keyboard == false || !composeInputAllowed {
        finishComposition(rebuild: false)
      }
    }
    let old = focusedCompose
    let previous = composePanes
    var next: [UInt64: ComposePresentation] = [:]
    for pane in store.panes {
      if let value = presentation(pane, reuse: previous[pane.leaf],
        sharingMeasurementsWith: Array(previous.values) + Array(next.values)) { next[pane.leaf] = value }
    }
    composePanes = next
    if let composition, composePanes[composition.target.identity.leaf] == nil {
      cancelComposition(recover: true, rebuild: false)
      rebuildCompose(); needsDisplay = true; return
    }
    updateComposeTooltips()
    updateAccessibleImages()
    if old?.layout.text.projection.text != focusedCompose?.layout.text.projection.text {
      NSAccessibility.post(element: self, notification: .valueChanged)
    }
    if old?.selectedRanges != focusedCompose?.selectedRanges {
      NSAccessibility.post(element: self, notification: .selectedTextChanged)
    }
    if window?.firstResponder === self {
      inputContext?.invalidateCharacterCoordinates()
      let next = focusedCompose
      if #available(macOS 15.4, *), marked.isEmpty,
         old?.identity != next?.identity || old?.pane.compose.bufferRevision != next?.pane.compose.bufferRevision
          || old?.textServiceSelectedRange != next?.textServiceSelectedRange {
        inputContext?.textInputClientDidUpdateSelection()
      }
    }
  }

  private func updateComposeTooltips() {
    var tips: [ImageTip] = []
    var links: [LinkTip] = []
    for pane in composePanes.values {
      if !pane.layout.links.isEmpty { links.append(LinkTip(rect: pane.bounds, links: pane.layout.links)) }
      for placed in pane.layout.text.attachments {
        let rect = placed.rect.offsetBy(dx: pane.origin.x, dy: pane.origin.y).intersection(pane.bounds)
        guard !rect.isEmpty, !rect.isNull,
              let image = pane.image(start: UInt64(placed.attachment.source.lowerBound)) else { continue }
        tips.append(ImageTip(rect: rect, text: pane.layout.imageDescription(image)))
      }
    }
    tips.sort { a, b in a.rect.minY == b.rect.minY ? a.rect.minX < b.rect.minX : a.rect.minY < b.rect.minY }
    links.sort { a, b in a.rect.minY == b.rect.minY ? a.rect.minX < b.rect.minX : a.rect.minY < b.rect.minY }
    guard tips != imageTips || links != linkTips else { return }
    removeAllToolTips(); imageTips = tips; linkTips = links
    for tip in tips { _ = addToolTip(tip.rect, owner: self, userData: nil) }
    // Resolve one hovered glyph on demand. Constructing selection rectangles
    // for every link would repeatedly scan the complete fragment list.
    for tip in links { _ = addToolTip(tip.rect, owner: self, userData: nil) }
  }

  func composeImageDescription(at point: NSPoint) -> String? {
    imageTips.first { $0.rect.contains(point) }?.text
  }

  func composeLinkDescription(at point: NSPoint) -> String? {
    guard delegate?.connected == true, popup(at: point) == nil else { return nil }
    guard let pane = composePanes.values.first(where: { $0.bounds.contains(point) }) else { return nil }
    let local = CGPoint(x: point.x - pane.origin.x, y: point.y - pane.origin.y)
    let character = ComposeAccessibilityText(pane: pane).character(at: local)
    guard character.location != NSNotFound, character.length > 0,
          let link = pane.layout.link(atUTF16: character.location) else { return nil }
    return link.target.isEmpty ? "Current document" : link.target
  }

  @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
                  userData: UnsafeMutableRawPointer?) -> String {
    composeImageDescription(at: point) ?? composeLinkDescription(at: point) ?? ""
  }

  func composeSnapshot(_ pane: WirePane) -> ComposePresentation? { presentation(pane, includePending: false) }

  private func presentation(_ input: WirePane, reuse: ComposePresentation? = nil,
                            sharingMeasurementsWith peers: [ComposePresentation]? = nil,
                            measuredBase: ComposePresentation? = nil, includePending: Bool = true) -> ComposePresentation? {
    var pane = input
    let pending = includePending ? delegate?.grid(self, pendingTextFor: input) : nil
    let selection = pending?.selection
    if let selection, let cursor = selection.pane.cursors.first(where: { $0.id == selection.caret.id }),
       let index = pane.compose.cursors.firstIndex(where: { $0.id == cursor.id }) {
      pane.compose.cursors[index] = cursor
      pane.compose.textContext = selection.pane.textContext
    }
    let overlay = includePending ? composition ?? pending.flatMap { pending in pending.text.map {
      Composition(target: pending.target, text: $0, initial: $0, after: nil, afterAction: false, virtualPrefix: pending.virtualPrefix)
    } } : nil
    let virtualInsertion = overlay?.virtualPrefix.flatMap { prefix in overlay?.text.virtualInsertion(over: prefix) }
    if overlay?.virtualPrefix != nil && virtualInsertion == nil { return nil }
    let preedit = overlay.flatMap { value -> ComposeComposition? in
      guard value.target.identity == .init(window: UInt64(store.windowID), leaf: input.leaf, buffer: input.buffer),
            input.compose.viewport.epoch == value.target.pane.compose.viewport.epoch else { return nil }
      pane = value.target.pane; pane.content = input.content
      if input.compose.bufferRevision == pane.compose.bufferRevision {
        // Formatting can finish after an edit receipt. Use that projection
        // while retaining the captured cursor and raw text-service context.
        let ranges = virtualInsertion?.sourceRanges ?? value.text.presentation.values.values.map(\.source)
        if ranges.allSatisfy({ $0.lowerBound >= input.compose.sourceStart && $0.upperBound <= input.compose.sourceEnd }) {
          let captured = pane.compose
          pane.compose = input.compose; pane.compose.cursors = captured.cursors
          pane.compose.textContext = captured.textContext; pane.compose.textChunks = captured.textChunks
        }
        pane.compose.viewport = input.compose.viewport; pane.compose.topByte = input.compose.topByte
      }
      pane.compose.focused = input.compose.focused; pane.compose.keyboard = input.compose.keyboard
      return value.text.presentation
    }
    if preedit == nil, pane.hasCompose, !pane.compose.projectionUsable, let reuse, reuse.pane.compose.formattingReady,
       reuse.identity == .init(window: UInt64(store.windowID), leaf: pane.leaf, buffer: pane.buffer),
       reuse.pane.compose.viewport.epoch == pane.compose.viewport.epoch,
       store.composeAcceptances[pane.leaf]?.permits(reuse.pane, window: UInt64(store.windowID)) ?? true,
       reuse.pane.compose.assetAuthority == pane.compose.assetAuthority,
       reuse.pane.compose.assetDocument == pane.compose.assetDocument {
      // Retain the whole old source/map pair, including its revision and
      // anchor. Relabeling old coordinates as current would corrupt input.
      pane = reuse.pane
      pane.content = input.content
      pane.compose.focused = input.compose.focused
      pane.compose.keyboard = input.compose.keyboard
    }
    let virtualSelection = composition == nil ? pending?.virtualSelection : nil
    let scope = WireComposeScope.with {
      $0.windowID = UInt64(store.windowID); $0.leaf = pane.leaf; $0.buffer = pane.buffer
      $0.bufferRevision = pane.compose.bufferRevision
      $0.projectionRevision = pane.compose.projectionRevision; $0.selectionRevision = pane.compose.selectionRevision
    }
    let images = Dictionary(uniqueKeysWithValues: pane.compose.images.map { image in
      (image.start, composeImageController?.state(scope: scope, image: image,
        authority: pane.compose.assetAuthority, document: pane.compose.assetDocument) ?? .loading)
    })
    let viewport = pane.compose.hasViewport ? composeViewportController?.value(scope: scope, remote: pane.compose.viewport) ?? pane.compose.viewport : nil
    var caretStates = composeCaretIdentity == .init(window: UInt64(store.windowID), leaf: pane.leaf, buffer: pane.buffer)
      && composeCaretRevision == pane.compose.bufferRevision ? composeCarets : [:]
    if let selection { caretStates[selection.caret.id] = selection.caret }
    return ComposePresentation(pane: pane, window: UInt64(store.windowID),
      cell: CGSize(width: cellWidth, height: cellHeight), body: bodyFont, monospace: monoFont,
      typography: composePreferences.typography(zoom: composeZoom), pageWidth: composePreferences.pageWidth * composeZoom,
      reuse: reuse, sharingMeasurementsWith: peers ?? Array(composePanes.values),
      measuredBase: measuredBase,
      caretStates: caretStates, images: images, viewport: viewport, composition: preedit,
      pendingSelection: selection != nil || virtualSelection != nil,
      virtualInsertion: virtualInsertion, virtualSelections: virtualSelection,
      environmentLike: reuse ?? composePanes[pane.leaf], geometryRevision: composeGeometryRevision)
  }

  /// Geometry for a deferred key is measured with the same fonts, width and
  /// images, but never replaces a visible pane or starts offscreen image I/O.
  func composeMeasurement(identity: ComposePresentation.Identity, projection: WireComposePane) -> ComposePresentation? {
    guard projection.projectionUsable, identity.window == UInt64(store.windowID), var pane = store.panes.first(where: { $0.leaf == identity.leaf && $0.hasBuffer && $0.buffer == identity.buffer }),
          pane.hasCompose, pane.compose.bufferRevision == projection.bufferRevision,
          pane.compose.selectionRevision == projection.selectionRevision,
          pane.compose.assetDocument == projection.assetDocument else { return nil }
    pane.compose = projection
    return presentation(pane, reuse: composePanes[pane.leaf], includePending: false)
  }

  func composeInputSnapshot(_ pane: WirePane, measuredBase: ComposePresentation? = nil) -> ComposePresentation? {
    // The captured base supplies only an immutable layout candidate. Current
    // presentation state still owns held-source fallback, scope and viewport.
    let identity = ComposePresentation.Identity(window: UInt64(store.windowID), leaf: pane.leaf, buffer: pane.buffer)
    let base = measuredBase.flatMap {
      $0.identity == identity && $0.pane.compose.viewport.epoch == pane.compose.viewport.epoch ? $0 : nil
    }
    return presentation(pane, reuse: composePanes[pane.leaf], measuredBase: base, includePending: false)
  }

  func refreshComposeImages(geometryChanged: Bool = false) {
    if geometryChanged { composeGeometryRevision &+= 1 }
    rebuildCompose(); needsDisplay = true
  }

  func composeImageDemands() -> [ComposeImageController.Demand] {
    let scale = window?.backingScaleFactor ?? 2
    return composePanes.values.flatMap { pane in
      let near = pane.bounds.insetBy(dx: 0, dy: -pane.bounds.height / 2)
      return pane.layout.text.attachments.compactMap { placed -> (CGFloat, ComposeImageController.Demand)? in
        let rect = placed.rect.offsetBy(dx: pane.origin.x, dy: pane.origin.y)
        guard rect.intersects(near), let image = pane.image(start: UInt64(placed.attachment.source.lowerBound)) else { return nil }
        let maximum = image.sourcePreview ? max(rect.width, rect.height)
          : image.block ? max(pane.layout.text.size.width, 480) : CTFontGetSize(pane.body) * 8
        return (abs(rect.midY - pane.bounds.midY), .init(scope: pane.scope, image: image,
          authority: pane.pane.compose.assetAuthority, document: pane.pane.compose.assetDocument,
          maximumDimension: Int(ceil(maximum * scale))))
      }
    }.sorted { $0.0 < $1.0 }.map(\.1)
  }

  func applyComposeCarets(_ states: [WireComposeCaret], identity: ComposePresentation.Identity?) {
    composeCaretIdentity = identity
    composeCaretRevision = identity.flatMap { target in store.panes.first(where: { $0.leaf == target.leaf && $0.hasBuffer && $0.buffer == target.buffer })?.compose.bufferRevision } ?? 0
    composeCarets = Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0) })
    rebuildCompose()
    needsDisplay = true
  }

  var composeInputAllowed: Bool {
    store.palette == nil && store.trustDialog == nil && store.settings == nil
      && store.keybindingEditor == nil && store.contextMenu == nil
  }

  var focusedCompose: ComposePresentation? {
    guard composeInputAllowed else { return nil }
    return composePanes.values.first { $0.pane.compose.focused && $0.pane.compose.keyboard }
  }

  private func compose(at point: CGPoint) -> ComposePresentation? {
    guard composeInputAllowed else { return nil }
    if popup(at: point) != nil { return nil }
    return composePanes.values.first { $0.bounds.contains(point) }
  }

  var caretRect: CGRect? {
    if let compose = focusedCompose { return compose.caret }
    return store.cursor.map { rect(column: $0.column, row: $0.row) }
  }

  private func rowRect(_ row: Int) -> NSRect {
    NSRect(x: 0, y: CGFloat(row) * cellHeight, width: bounds.width, height: cellHeight)
  }

  // MARK: Drawing

  override func draw(_ dirtyRect: NSRect) {
    guard EditorTelemetry.shared.isOn else { return drawCells(dirtyRect) }
    let started = ProcessInfo.processInfo.systemUptime
    drawCells(dirtyRect)
    EditorTelemetry.shared.record([
      "ev": "draw", "t": EditorTelemetry.ms(started), "ms": EditorTelemetry.ms(ProcessInfo.processInfo.systemUptime - started),
      "rows": Int((dirtyRect.height / cellHeight).rounded(.up)), "seq": shownSequence,
    ])
  }

  private func drawCells(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    defaultBackground.setFill()
    dirtyRect.fill()
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    let scale = window?.backingScaleFactor ?? 2
    let firstRow = max(0, Int(dirtyRect.minY / cellHeight))
    let lastRow = min(store.grid.count - 1, Int(dirtyRect.maxY / cellHeight))
    if firstRow <= lastRow { for row in firstRow...lastRow {
      let top = CGFloat(row) * cellHeight
      var column = 0
      for run in store.grid[row] {
        let (_, bg) = colors(run)
        if let bg {
          let x0 = (CGFloat(column) * cellWidth * scale).rounded() / scale
          let x1 = (CGFloat(column + run.cells) * cellWidth * scale).rounded() / scale
          context.setFillColor(bg.cgColor)
          context.fill(CGRect(x: x0, y: top, width: x1 - x0, height: cellHeight))
        }
        column += run.cells
      }
      column = 0
      for run in store.grid[row] {
        let (fg, _) = colors(run)
        drawText(run, column: column, row: row, color: fg ?? defaultForeground, context: context)
        if run.underline {
          context.setFillColor((fg ?? defaultForeground).cgColor)
          context.fill(CGRect(x: CGFloat(column) * cellWidth, y: top + ascent + 1, width: CGFloat(run.cells) * cellWidth, height: 1))
        }
        column += run.cells
      }
    } }
    for pane in composePanes.values {
      pane.draw(in: context, dirty: dirtyRect, foreground: defaultForeground, background: defaultBackground,
                selection: store.theme.selection.map(NSColor.init(scene:)) ?? .selectedTextBackgroundColor, palette: composePalette)
    }
    drawCaret(context)
  }

  func colors(_ run: CellRun) -> (NSColor?, NSColor?) {
    let fg = run.foreground.map(NSColor.init(scene:))
    let bg = run.background.map(NSColor.init(scene:))
    if run.reverse { return (bg ?? defaultBackground, fg ?? defaultForeground) }
    return (fg, bg)
  }

  func drawText(_ run: CellRun, column start: Int, row: Int, color: NSColor, context: CGContext) {
    let style = (run.bold ? 1 : 0) + (run.italic ? 2 : 0)
    let font = fonts[style]
    let baseline = CGFloat(row) * cellHeight + ascent
    var glyphs: [CGGlyph] = []
    var positions: [CGPoint] = []
    context.setFillColor(color.cgColor)
    var column = start
    for character in run.text {
      defer { column += 1 }
      if character == " " { continue }
      let x = CGFloat(column) * cellWidth
      if let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
         BoxDrawing.draw(scalar, in: CGRect(x: x, y: CGFloat(row) * cellHeight, width: cellWidth, height: cellHeight), context: context) {
        continue
      }
      let utf16 = Array(character.utf16)
      if utf16.count == 1, let glyph = glyph(for: utf16[0], style: style) {
        glyphs.append(glyph)
        positions.append(CGPoint(x: x, y: -baseline))  // text space: the text matrix flips y
        continue
      }
      // Emoji, combining marks and characters the font lacks: let Core Text
      // shape and substitute, then pin the result to the cell.
      let attributed = NSAttributedString(string: String(character), attributes: [
        .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
      ])
      let line = CTLineCreateWithAttributedString(attributed)
      context.textPosition = CGPoint(x: x, y: -baseline)
      CTLineDraw(line, context)
      // The text position is the text matrix's translation: left set, it would
      // move every glyph drawn after this one, whose positions are absolute.
      context.textPosition = .zero
    }
    if !glyphs.isEmpty { CTFontDrawGlyphs(font, glyphs, positions, glyphs.count, context) }
  }

  private func glyph(for unit: UInt16, style: Int) -> CGGlyph? {
    if let cached = glyphCache[style][unit] { return cached == 0 ? nil : cached }
    var character = unit
    var glyph: CGGlyph = 0
    let found = CTFontGetGlyphsForCharacters(fonts[style], &character, &glyph, 1)
    glyphCache[style][unit] = found ? glyph : 0
    return found && glyph != 0 ? glyph : nil
  }

  private func drawCaret(_ context: CGContext) {
    guard let cell = caretRect else { return }
    context.saveGState()
    defer { context.restoreGState() }
    if let compose = focusedCompose { context.clip(to: compose.bounds) }
    if composition == nil, !marked.isEmpty {
      // Text being composed in an input method, drawn at the caret until it is committed.
      let attributes: [NSAttributedString.Key: Any] = [
        .font: focusedCompose?.body ?? fonts[0], NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        NSAttributedString.Key(kCTUnderlineStyleAttributeName as String): CTUnderlineStyle.single.rawValue,
      ]
      let line = CTLineCreateWithAttributedString(NSAttributedString(string: marked, attributes: attributes))
      let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
      defaultBackground.setFill()
      NSRect(x: cell.minX, y: cell.minY, width: width, height: cell.height).fill()
      context.setFillColor(defaultForeground.cgColor)
      let baseline = focusedCompose.map { CTFontGetAscent($0.body) } ?? ascent
      context.textPosition = CGPoint(x: cell.minX, y: cell.minY + baseline)
      CTLineDraw(line, context)
      context.textPosition = .zero
      return
    }
    let focused = window?.isKeyWindow == true && window?.firstResponder === self
    context.setFillColor(caretColor.cgColor)
    context.setStrokeColor(caretColor.cgColor)
    if !focused {
      context.stroke(cell.insetBy(dx: 0.5, dy: 0.5), width: 1)
    } else if caretOn {
      for rect in focusedCompose?.carets ?? [cell] {
        context.fill(CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height))
      }
    }
  }

  // MARK: Accessibility

  /// Rich text ranges address the displayed projection; grid mode retains its
  /// row value. Neither path substitutes raw-source text for the spoken value.
  override func isAccessibilityElement() -> Bool { true }
  override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
  override func accessibilityRoleDescription() -> String? { "editor" }
  override func accessibilityLabel() -> String? { title }
  override func accessibilityValue() -> Any? { focusedCompose?.layout.text.projection.text ?? store.lines.joined(separator: "\n") }

  override func accessibilitySelectedTextRange() -> NSRange {
    if let compose = focusedCompose { return compose.selectedRange }
    guard let cursor = store.cursor else { return NSRange(location: 0, length: 0) }
    let before = store.lines.prefix(cursor.row).reduce(0) { $0 + ($1 as NSString).length + 1 }
    let line = cursor.row < store.grid.count ? store.text(row: cursor.row) : ""
    let column = (String(line.prefix(cursor.column)) as NSString).length
    return NSRange(location: before + column, length: 0)
  }

  override func accessibilitySelectedTextRanges() -> [NSValue]? {
    (focusedCompose?.selectedRanges ?? [accessibilitySelectedTextRange()]).map { NSValue(range: $0) }
  }

  override func accessibilitySelectedText() -> String? { accessibilityString(for: accessibilitySelectedTextRange()) }
  override func accessibilityNumberOfCharacters() -> Int { (accessibilityValue() as? NSString)?.length ?? 0 }

  override func accessibilityString(for range: NSRange) -> String? {
    guard let text = accessibilityValue() as? NSString, range.location >= 0, range.location <= text.length,
          range.length >= 0, range.length <= text.length - range.location else { return nil }
    return text.substring(with: range)
  }

  override func accessibilityRange(for index: Int) -> NSRange {
    guard let pane = focusedCompose else { return super.accessibilityRange(for: index) }
    return ComposeAccessibilityText(pane: pane).character(at: index)
  }

  override func accessibilityLine(for index: Int) -> Int {
    guard let pane = focusedCompose else { return super.accessibilityLine(for: index) }
    return ComposeAccessibilityText(pane: pane).line(at: index)
  }

  override func accessibilityRange(forLine line: Int) -> NSRange {
    guard let pane = focusedCompose else { return super.accessibilityRange(forLine: line) }
    guard pane.layout.text.fragments.indices.contains(line) else { return ComposeAccessibilityText.missing }
    return pane.layout.text.fragments[line].range
  }

  override func accessibilityVisibleCharacterRange() -> NSRange {
    guard let pane = focusedCompose else { return super.accessibilityVisibleCharacterRange() }
    return ComposeAccessibilityText(pane: pane).visibleRange
  }

  override func accessibilityInsertionPointLineNumber() -> Int {
    guard let pane = focusedCompose else { return store.cursor?.row ?? 0 }
    if let caret = pane.caret, let line = pane.layout.text.fragments.firstIndex(where: {
      $0.range.location <= pane.selectedRange.location && pane.selectedRange.location <= $0.contentEnd
        && abs($0.rect.minY + pane.origin.y - caret.minY) < 0.5
    }) { return line }
    return ComposeAccessibilityText(pane: pane).line(at: pane.selectedRange.location)
  }

  override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
    guard let pane = focusedCompose, let base = ComposeAccessibilityText(pane: pane).attributed(range) else { return nil }
    let result = NSMutableAttributedString(attributedString: base)
    for placed in pane.layout.text.attachments where !placed.attachment.preview {
      guard let start = pane.layout.text.utf16Position(for: placed.attachment.source.lowerBound),
            let end = pane.layout.text.utf16Position(for: placed.attachment.source.upperBound, affinity: .upstream),
            let image = accessibleImages[.init(pane, source: placed.attachment.source)] else { continue }
      let overlap = NSIntersectionRange(range, NSRange(location: start, length: end - start))
      if overlap.length > 0 {
        result.addAttribute(.accessibilityAttachment, value: image,
          range: NSRange(location: overlap.location - range.location, length: overlap.length))
      }
    }
    return result
  }

  override func accessibilityStyleRange(for index: Int) -> NSRange {
    guard let pane = focusedCompose else { return super.accessibilityStyleRange(for: index) }
    let text = ComposeAccessibilityText(pane: pane)
    guard index >= 0, index < text.text.length,
          let attributed = text.attributed(NSRange(location: 0, length: text.text.length)) else { return text.character(at: index) }
    var range = NSRange()
    _ = attributed.attributes(at: index, effectiveRange: &range)
    return range
  }

  override func accessibilityFrame(for range: NSRange) -> NSRect {
    guard let pane = focusedCompose, let rect = ComposeAccessibilityText(pane: pane).bounds(for: range) else { return .zero }
    return accessibilityScreenRect(rect)
  }

  func accessibilityScreenRect(_ rect: CGRect) -> CGRect {
    guard let window else { return .zero }
    return window.convertToScreen(convert(rect, to: nil))
  }

  override func accessibilityRange(for point: NSPoint) -> NSRange {
    guard let pane = focusedCompose, let window, point.x.isFinite, point.y.isFinite else { return ComposeAccessibilityText.missing }
    let point = convert(window.convertPoint(fromScreen: point), from: nil)
    guard pane.bounds.contains(point) else { return ComposeAccessibilityText.missing }
    let local = CGPoint(x: point.x - pane.origin.x, y: point.y - pane.origin.y)
    if let image = pane.layout.text.attachments.first(where: { $0.rect.contains(local) }),
       let start = pane.layout.text.utf16Position(for: image.attachment.source.lowerBound),
       let end = pane.layout.text.utf16Position(for: image.attachment.source.upperBound, affinity: .upstream) {
      return NSRange(location: start, length: end - start)
    }
    return ComposeAccessibilityText(pane: pane).character(at: local)
  }

  override func accessibilityChildren() -> [Any]? {
    guard let pane = focusedCompose else { return super.accessibilityChildren() }
    return pane.layout.text.attachments.compactMap { accessibleImages[.init(pane, source: $0.attachment.source)] }
  }

  override func accessibilityVisibleChildren() -> [Any]? {
    guard let pane = focusedCompose else { return super.accessibilityVisibleChildren() }
    let visible = accessibilityScreenRect(pane.bounds)
    return (accessibilityChildren() ?? []).filter { ($0 as? ComposeAccessibilityImage)?.accessibilityFrame().intersects(visible) == true }
  }

  func isCurrentAccessibilityImage(_ image: ComposeAccessibilityImage) -> Bool {
    let id = image.id
    guard delegate?.connected == true, accessibleImages[id] === image, UInt64(store.windowID) == id.window,
          let pane = store.panes.first(where: { $0.leaf == id.leaf && $0.hasBuffer && $0.buffer == id.buffer }),
          pane.hasCompose, pane.compose.viewport.epoch == id.epoch, pane.compose.bufferRevision == id.revision,
          pane.compose.assetDocument == id.document, pane.compose.assetAuthority == id.authority else { return false }
    return true
  }

  /// Scene numbers can repeat after a backend restart. Old AX objects must
  /// not regain ownership when a new connection supplies the same numbers.
  func invalidateAccessibleImages() {
    let hadImages = !accessibleImages.isEmpty
    accessibleImages.removeAll(); accessibleImageLabels.removeAll()
    if hadImages { NSAccessibility.post(element: self, notification: .layoutChanged) }
  }

  override func accessibilityHitTest(_ point: NSPoint) -> Any? {
    for image in accessibilityChildren() ?? [] {
      if let image = image as? ComposeAccessibilityImage, image.accessibilityFrame().contains(point) { return image }
    }
    return super.accessibilityHitTest(point)
  }

  private func updateAccessibleImages() {
    let old = Set(accessibleImages.keys)
    var next: [ComposeAccessibilityImage.ID: ComposeAccessibilityImage] = [:]
    var labels: [ComposeAccessibilityImage.ID: String] = [:]
    if delegate?.connected == true, let pane = focusedCompose {
      for placed in pane.layout.text.attachments {
        let id = ComposeAccessibilityImage.ID(pane, source: placed.attachment.source)
        next[id] = accessibleImages[id] ?? ComposeAccessibilityImage(id: id, grid: self)
        if let image = pane.image(start: id.start, end: id.end) {
          labels[id] = pane.layout.imageDescription(image)
        }
      }
    }
    accessibleImages = next
    for (id, label) in labels where accessibleImageLabels[id] != nil && accessibleImageLabels[id] != label {
      NSAccessibility.post(element: next[id]!, notification: .titleChanged)
    }
    accessibleImageLabels = labels
    if old != Set(next.keys) { NSAccessibility.post(element: self, notification: .layoutChanged) }
  }

  // MARK: Caret blink

  func restartBlink() {
    caretOn = true
    blink?.invalidate()
    blink = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.caretOn.toggle()
        self.setNeedsDisplayCaret()
      }
    }
    setNeedsDisplayCaret()
  }

  private func setNeedsDisplayCaret() {
    if let compose = focusedCompose { setNeedsDisplay(compose.bounds); return }
    guard let cursor = store.cursor else { return }
    setNeedsDisplay(rowRect(cursor.row))
  }

  override func becomeFirstResponder() -> Bool {
    restartBlink()
    return true
  }

  override func resignFirstResponder() -> Bool {
    finishComposition()
    blink?.invalidate()
    setNeedsDisplayCaret()
    return true
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.acceptsMouseMovedEvents = true
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
  }

  // MARK: Keyboard

  /// The key press that brought the window forward. It belongs to the window
  /// it was typed in, but AppKit can deliver it here a second time (as a menu
  /// key equivalent), so it is swallowed.
  var showingEvent: TimeInterval?

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard window?.isKeyWindow == true, window?.firstResponder === self, event.type == .keyDown else { return false }
    if event.timestamp == showingEvent { return true }
    if delegate?.grid(self, handleAppChord: event) == true { return true }
    if event.modifierFlags.contains(.command) && AppChords.reserved(event) { return false }
    keyDown(with: event)
    return true
  }

  override func keyDown(with event: NSEvent) {
    if event.timestamp == showingEvent { return }
    restartBlink()
    if hasMarkedText() {
      if inputContext?.handleEvent(event) != true { interpretKeyEvents([event]) }
      return
    }
    let flags = event.modifierFlags
    if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "v",
       !flags.contains(.shift), !flags.contains(.option), !flags.contains(.control) {
      delegate?.gridPaste(self)
      return
    }
    if let key = SceneKeys.message(keyCode: event.keyCode, charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                                   command: flags.contains(.command), control: flags.contains(.control),
                                   option: flags.contains(.option), shift: flags.contains(.shift),
                                   optionAsAlt: delegate?.optionAsAlt ?? false) {
      delegate?.grid(self, send: .key(key))
      return
    }
    if inputContext?.handleEvent(event) != true { interpretKeyEvents([event]) }
  }

  // MARK: Text input

  func insertText(_ string: Any, replacementRange: NSRange) {
    let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    if var current = composition {
      guard current.text.update(NSAttributedString(string: text), selected: NSRange(location: text.utf16.count, length: 0), replacement: replacementRange) else {
        delegate?.grid(self, recover: text); cancelComposition(recover: true); return
      }
      composition = current; finishComposition(); return
    }
    marked = ""
    if let pane = focusedCompose {
      if replacementRange.location != NSNotFound || delegate?.grid(self, pendingTextFor: pane.pane) != nil {
        setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0), replacementRange: replacementRange)
        finishComposition()
      } else if !text.isEmpty {
        delegate?.grid(self, send: .text(text))
      }
      setNeedsDisplayCaret()
      return
    }
    for key in SceneKeys.typing(text) { delegate?.grid(self, send: .key(key)) }
    setNeedsDisplayCaret()
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    let text = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
    if var current = composition {
      guard current.text.update(text, selected: selectedRange, replacement: replacementRange) else { return }
      composition = current; rebuildCompose(); revealCompositionCaret(); needsDisplay = true; return
    }
    if let target = focusedCompose, target.textContext != nil, target.cursor != nil {
      let pending = delegate?.grid(self, pendingTextFor: target.pane)
      let prefix = pending?.text
      let root = pending.flatMap { $0.text == nil ? nil : $0.target } ?? target
      let value: ComposePendingText?
      if let selection = pending?.virtualSelection {
        value = ComposePendingText(afterAction: selection, pane: root.pane.compose, text: text, selected: selectedRange, replacement: replacementRange)
      } else {
        value = prefix.flatMap {
          ComposePendingText(following: $0, pane: root.pane.compose, text: text, selected: selectedRange, replacement: replacementRange, virtualBase: pending?.virtualPrefix)
        } ?? (prefix == nil ? ComposePendingText(pane: root.pane.compose, text: text, selected: selectedRange, replacement: replacementRange) : nil)
      }
      guard let value else { delegate?.grid(self, recover: text.string); return }
      let action = pending?.virtualSelection != nil || replacementRange.location == NSNotFound && pending?.afterAction == true
      let after = action ? pending?.token : (prefix == nil ? nil : (pending?.prefixToken ?? pending?.token))
      let basis = pending?.virtualSelection.flatMap { selection in
        ComposePendingText(afterAction: selection, pane: root.pane.compose, text: NSAttributedString(string: ""),
          selected: NSRange(location: 0, length: 0), replacement: NSRange(location: NSNotFound, length: 0))
      } ?? value
      composition = Composition(target: root, text: value, initial: basis, after: after, afterAction: action,
        virtualPrefix: pending?.virtualSelection ?? pending?.virtualPrefix)
      marked = ""; rebuildCompose(); revealCompositionCaret(); needsDisplay = true; return
    }
    marked = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    setNeedsDisplayCaret()
  }

  func unmarkText() {
    if composition != nil { finishComposition(); return }
    marked = ""
    setNeedsDisplayCaret()
  }

  private func revealCompositionCaret() {
    guard composition != nil, let pane = focusedCompose else { return }
    delegate?.grid(self, revealCaretIn: pane)
  }

  func finishComposition(rebuild: Bool = true) {
    guard let current = composition else { return }
    composition = nil
    compositionDragAnchor = nil
    if let committed = current.text.committed(nativeNewline: current.target.pane.compose.nativeNewline) {
      delegate?.grid(self, commit: committed, initial: current.initial, after: current.after, afterAction: current.afterAction, virtualPrefix: current.virtualPrefix, in: current.target)
    } else {
      for text in current.text.recoveryTexts { delegate?.grid(self, recover: text) }
    }
    inputContext?.discardMarkedText()
    if rebuild { rebuildCompose(); needsDisplay = true }
  }

  /// Only a draft explicitly following this queued edit can use its receipt.
  /// A later scene's cursor is never substituted for the captured owner.
  func resolveComposition(after token: UUID, edit: WireComposeEditReceipt?, result: WireComposeEditReceipt?) {
    guard let current = composition, current.after == token else { return }
    let target = current.target
    let receipt = current.afterAction ? result : edit
    guard let receipt, receipt.matches(target.scope, epoch: target.pane.compose.viewport.epoch),
          UInt64(store.windowID) == receipt.window,
          store.panes.contains(where: { $0.leaf == receipt.leaf && $0.buffer == receipt.buffer && $0.hasCompose
            && $0.compose.viewport.epoch == receipt.epoch }),
          let text = current.afterAction ? current.text.afterAction(current.initial, pane: receipt.pane)
            : current.text.resolved(pane: receipt.pane, edited: receipt.cursors, preserved: receipt.preservedCursors) else {
      cancelComposition(recover: true); return
    }
    var pane = target.pane; pane.compose = receipt.pane
    composition = nil
    guard let next = composeSnapshot(pane) else {
      composition = current; cancelComposition(recover: true); return
    }
    composition = Composition(target: next, text: text, initial: text, after: nil, afterAction: false)
    rebuildCompose(); revealCompositionCaret(); needsDisplay = true
    inputContext?.invalidateCharacterCoordinates()
  }

  func cancelComposition(recover: Bool, rebuild: Bool = true) {
    guard let current = composition else { return }
    composition = nil
    compositionDragAnchor = nil
    if recover {
      for text in current.text.recoveryTexts { delegate?.grid(self, recover: text) }
    }
    inputContext?.discardMarkedText()
    if rebuild { rebuildCompose(); needsDisplay = true }
  }

  func hasMarkedText() -> Bool { composition != nil || !marked.isEmpty }
  func markedRange() -> NSRange { composition?.text.markedRange ?? (marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: marked.utf16.count)) }
  private var textServicePreview: ComposeComposition? { composition?.text.presentation ?? focusedCompose?.layout.composition }
  func selectedRange() -> NSRange { (composition == nil ? focusedCompose?.virtualSelections?.selection : nil) ?? textServicePreview?.selectedRange ?? (!marked.isEmpty ? NSRange(location: marked.utf16.count, length: 0) : focusedCompose?.textServiceSelectedRange ?? NSRange(location: 0, length: 0)) }
  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.underlineStyle, .markedClauseSegment] }
  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
    if composition == nil, let selection = focusedCompose?.virtualSelections,
       let result = selection.substring(forProposedRange: range) {
      actualRange?.pointee = result.range; return result.text
    }
    if let preview = textServicePreview {
      guard let result = preview.substring(for: range) else { actualRange?.pointee = NSRange(location: NSNotFound, length: 0); return nil }
      actualRange?.pointee = result.range; return result.text
    }
    guard marked.isEmpty, let pane = focusedCompose, range.location != NSNotFound else { return nil }
    if let context = pane.textContext {
      guard let result = context.substring(forProposedRange: range) else {
        actualRange?.pointee = NSRange(location: NSNotFound, length: 0); return nil
      }
      actualRange?.pointee = result.range
      return NSAttributedString(string: result.text)
    }
    let text = pane.layout.text.projection.text as NSString
    guard range.location >= 0, range.location <= text.length, range.length >= 0 else { return nil }
    let clipped = NSRange(location: range.location, length: min(range.length, text.length-range.location))
    let adjusted = text.rangeOfComposedCharacterSequences(for: clipped)
    actualRange?.pointee = adjusted
    return NSAttributedString(string: text.substring(with: adjusted))
  }
  func characterIndex(for point: NSPoint) -> Int {
    guard marked.isEmpty, let pane = focusedCompose, let window else { return NSNotFound }
    let point = convert(window.convertPoint(fromScreen: point), from: nil)
    guard pane.bounds.contains(point), let hit = pane.hit(at: point) else { return NSNotFound }
    if pane.layout.composition != nil,
       let display = pane.layout.text.hitUTF16(at: CGPoint(x: point.x - pane.origin.x, y: point.y - pane.origin.y)) {
      return pane.preeditDocumentPosition(display) ?? NSNotFound
    }
    return pane.textServiceIndex(for: hit.source, affinity: hit.affinity) ?? NSNotFound
  }
  override func doCommand(by selector: Selector) {
    if selector == #selector(NSResponder.cancelOperation(_:)), composition != nil {
      cancelComposition(recover: false); return
    }
    let keys = ["moveLeft:": "ArrowLeft", "moveRight:": "ArrowRight", "moveUp:": "ArrowUp", "moveDown:": "ArrowDown",
      "deleteBackward:": "Backspace", "deleteForward:": "Delete", "insertNewline:": "Enter", "insertTab:": "Tab"]
    guard let key = keys[NSStringFromSelector(selector)] else { return }
    finishComposition(); delegate?.grid(self, send: .key(.with { $0.key = key }))
  }

  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    if marked.isEmpty, let pane = focusedCompose, let window {
      guard let area = pane.textServiceRect(for: range) else { actualRange?.pointee = NSRange(location: NSNotFound, length: 0); return .zero }
      actualRange?.pointee = area.range
      return window.convertToScreen(convert(area.rect.offsetBy(dx: pane.origin.x, dy: pane.origin.y), to: nil))
    }
    guard let local = caretRect, let window else { return .zero }
    return window.convertToScreen(convert(local, to: nil))
  }

  // MARK: Mouse

  private func selectComposition(at point: CGPoint, extend: Bool) -> Bool {
    guard var current = composition, let pane = focusedCompose, let draft = pane.layout.draftDisplayRange,
          let display = pane.layout.text.hitUTF16(at: CGPoint(x: point.x - pane.origin.x, y: point.y - pane.origin.y)) else { return false }
    let index: Int
    if compositionDragAnchor != nil { index = min(NSMaxRange(draft), max(draft.location, display)) }
    else {
      guard display >= draft.location, display <= NSMaxRange(draft) else { return false }
      index = display
    }
    let position = current.text.presentation.virtualStart(for: current.text.presentation.primaryID) + index - draft.location
    let anchor = extend ? compositionDragAnchor ?? current.text.selectedRange.location : position
    guard current.text.select(NSRange(location: min(position, anchor), length: abs(position - anchor))) else { return false }
    compositionDragAnchor = anchor; composition = current
    rebuildCompose(); revealCompositionCaret(); needsDisplay = true; inputContext?.invalidateCharacterCoordinates()
    return true
  }

  private func sendMouse(_ kind: WireMouseKind, _ event: NSEvent, button: WireMouseButton = .left, count: Int = 1, steps: Int = 1) {
    if sendPopupMouse(kind, point: point(of: event), flags: event.modifierFlags, button: button, count: count, steps: steps) { return }
    let (column, row) = cell(at: point(of: event))
    let flags = event.modifierFlags
    delegate?.grid(self, send: .mouse(WireMouse.with {
      $0.kind = kind
      $0.button = button
      $0.col = UInt32(clamping: column)
      $0.row = UInt32(clamping: row)
      $0.n = UInt32(clamping: steps)
      $0.count = UInt64(clamping: count)
      $0.ctrl = flags.contains(.control)
      $0.alt = flags.contains(.option)
      $0.shift = flags.contains(.shift)
    }))
  }

  /// Where an event happened in this view. A synthesized event (a scroll
  /// benchmark's) has no window, and its location is on the screen.
  private func point(of event: NSEvent) -> NSPoint {
    guard event.window == nil, let window else { return convert(event.locationInWindow, from: nil) }
    return convert(window.convertPoint(fromScreen: event.locationInWindow), from: nil)
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    lastDragCell = nil
    let point = point(of: event)
    popupCapture = nil
    if sendPopupMouse(.down, point: point, flags: event.modifierFlags, count: event.clickCount) { return }
    let captured = compose(at: point)
    if composition != nil {
      if inputContext?.handleEvent(event) == true { return }
      if selectComposition(at: point, extend: event.modifierFlags.contains(.shift)) { return }
      finishComposition()
    }
    if let pane = captured ?? compose(at: point) {
      composeDrag = pane.identity.leaf
      delegate?.grid(self, point: point, in: pane, extend: event.modifierFlags.contains(.shift), count: event.clickCount)
      return
    }
    sendMouse(.down, event, count: event.clickCount)
  }

  override func mouseDragged(with event: NSEvent) {
    if sendPopupMouse(.drag, point: point(of: event), flags: event.modifierFlags) { return }
    if compositionDragAnchor != nil, composition != nil { _ = selectComposition(at: point(of: event), extend: true); return }
    if let leaf = composeDrag, let pane = composePanes[leaf] {
      delegate?.grid(self, point: point(of: event), in: pane, extend: true, count: 1)
      return
    }
    let cell = cell(at: convert(event.locationInWindow, from: nil))
    guard lastDragCell.map({ $0 != cell }) ?? true else { return }
    lastDragCell = cell
    sendMouse(.drag, event)
  }

  override func mouseUp(with event: NSEvent) {
    if sendPopupMouse(.up, point: point(of: event), flags: event.modifierFlags) { return }
    if compositionDragAnchor != nil { compositionDragAnchor = nil; return }
    if composeDrag != nil { composeDrag = nil; return }
    sendMouse(.up, event)
  }
  override func rightMouseDown(with event: NSEvent) {
    finishComposition()
    window?.makeFirstResponder(self)
    if !sendPopupMouse(.down, point: point(of: event), flags: event.modifierFlags, button: .right) {
      sendMouse(.down, event, button: .right)
    }
  }
  override func rightMouseUp(with event: NSEvent) {
    if !sendPopupMouse(.up, point: point(of: event), flags: event.modifierFlags, button: .right) { sendMouse(.up, event, button: .right) }
  }
  override func otherMouseDown(with event: NSEvent) {
    finishComposition()
    if !sendPopupMouse(.down, point: point(of: event), flags: event.modifierFlags, button: .middle) { sendMouse(.down, event, button: .middle) }
  }
  override func otherMouseUp(with event: NSEvent) {
    if !sendPopupMouse(.up, point: point(of: event), flags: event.modifierFlags, button: .middle) { sendMouse(.up, event, button: .middle) }
  }

  override func mouseMoved(with event: NSEvent) {
    if sendPopupMouse(.moved, point: point(of: event), flags: event.modifierFlags) { return }
    if compose(at: point(of: event)) != nil { return }
    let cell = cell(at: convert(event.locationInWindow, from: nil))
    guard lastHoverCell.map({ $0 != cell }) ?? true else { return }
    lastHoverCell = cell
    sendMouse(.moved, event)
  }

  /// A trackpad moves three rows per scroll step, as one wheel notch does in
  /// Fresh; a wheel sends a step per notch.
  override func scrollWheel(with event: NSEvent) {
    if popup(at: point(of: event)) == nil, let pane = compose(at: point(of: event)), pane.pane.compose.hasViewport {
      let scale = event.hasPreciseScrollingDeltas ? 1 : CTFontGetSize(pane.body) * 3
      let delta = CGPoint(x: -event.scrollingDeltaX * scale, y: -event.scrollingDeltaY * scale)
      if delta != .zero { delegate?.grid(self, scroll: delta, in: pane) }
      return
    }
    let precise = event.hasPreciseScrollingDeltas
    let step = precise ? cellHeight * 3 : 1
    scrollRemainder += event.scrollingDeltaY
    horizontalRemainder += event.scrollingDeltaX
    let vertical = Int(scrollRemainder / step)
    let horizontal = Int(horizontalRemainder / (precise ? cellWidth * 3 : 1))
    if EditorTelemetry.shared.isOn {
      EditorTelemetry.shared.record([
        "ev": "wheel", "et": EditorTelemetry.ms(event.timestamp), "dy": Double(event.scrollingDeltaY),
        "dx": Double(event.scrollingDeltaX), "precise": precise, "phase": Int(event.phase.rawValue),
        "mom": Int(event.momentumPhase.rawValue), "steps": vertical, "cell": Double(cellHeight),
        "at": [cell(at: point(of: event)).column, cell(at: point(of: event)).row], "win": event.window != nil,
      ])
    }
    if vertical != 0 {
      scrollRemainder -= CGFloat(vertical) * step
      sendMouse(vertical > 0 ? .scrollUp : .scrollDown, event, steps: min(8, abs(vertical)))
    }
    if horizontal != 0 {
      horizontalRemainder -= CGFloat(horizontal) * (precise ? cellWidth * 3 : 1)
      sendMouse(horizontal > 0 ? .scrollLeft : .scrollRight, event, steps: min(8, abs(horizontal)))
    }
    if event.phase == .ended || event.momentumPhase == .ended {
      scrollRemainder = 0
      horizontalRemainder = 0
    }
  }
}

/// App shortcuts the editor leaves to the menus.
enum AppChords {
  static func reserved(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
    switch (key, flags.subtracting(.capsLock)) {
    case ("q", .command), ("h", .command), ("h", [.command, .option]), ("m", .command), ("`", .command), ("~", [.command, .shift]),
         (",", .command), ("f", [.command, .control]):
      return true
    default:
      return false
    }
  }
}

extension NSColor {
  convenience init(scene color: SceneColor) {
    self.init(srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255, blue: CGFloat(color.blue) / 255, alpha: 1)
  }
}

/// Box-drawing characters drawn as lines, so they meet exactly across cells
/// and rows whatever the font and line height.
enum BoxDrawing {
  private struct Arms { var up = 0, down = 0, left = 0, right = 0 }  // 0 none, 1 light, 2 heavy

  private static let table: [UInt32: Arms] = [
    0x2500: Arms(left: 1, right: 1), 0x2501: Arms(left: 2, right: 2),
    0x2502: Arms(up: 1, down: 1), 0x2503: Arms(up: 2, down: 2),
    0x250C: Arms(down: 1, right: 1), 0x2510: Arms(down: 1, left: 1),
    0x2514: Arms(up: 1, right: 1), 0x2518: Arms(up: 1, left: 1),
    0x251C: Arms(up: 1, down: 1, right: 1), 0x2524: Arms(up: 1, down: 1, left: 1),
    0x252C: Arms(down: 1, left: 1, right: 1), 0x2534: Arms(up: 1, left: 1, right: 1),
    0x253C: Arms(up: 1, down: 1, left: 1, right: 1),
    0x256D: Arms(down: 1, right: 1), 0x256E: Arms(down: 1, left: 1),
    0x256F: Arms(up: 1, left: 1), 0x2570: Arms(up: 1, right: 1),
    0x250F: Arms(down: 2, right: 2), 0x2513: Arms(down: 2, left: 2),
    0x2517: Arms(up: 2, right: 2), 0x251B: Arms(up: 2, left: 2),
  ]

  /// Draws the character if it is a box-drawing line; false otherwise.
  static func draw(_ scalar: Unicode.Scalar, in cell: CGRect, context: CGContext) -> Bool {
    guard let arms = table[scalar.value] else { return false }
    let light: CGFloat = 1, heavy: CGFloat = 2
    let midX = (cell.midX).rounded(.down), midY = (cell.midY).rounded(.down)
    func width(_ weight: Int) -> CGFloat { weight == 2 ? heavy : light }
    if arms.up > 0 { context.fill(CGRect(x: midX, y: cell.minY, width: width(arms.up), height: midY - cell.minY + width(arms.up))) }
    if arms.down > 0 { context.fill(CGRect(x: midX, y: midY, width: width(arms.down), height: cell.maxY - midY)) }
    if arms.left > 0 { context.fill(CGRect(x: cell.minX, y: midY, width: midX - cell.minX + width(arms.left), height: width(arms.left))) }
    if arms.right > 0 { context.fill(CGRect(x: midX, y: midY, width: cell.maxX - midX, height: width(arms.right))) }
    return true
  }
}
