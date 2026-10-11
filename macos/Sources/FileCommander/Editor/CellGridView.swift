import AppKit
import CoreText
import FreshKit

/// What the grid needs from its owner: where input goes, and the settings that
/// shape it.
@MainActor
protocol CellGridDelegate: AnyObject {
  func grid(_ grid: CellGridView, send message: [String: Any])
  func gridDidResize(_ grid: CellGridView, columns: Int, rows: Int)
  /// The chord is an app shortcut (Quit, Hide, the switch key, ...) that the
  /// editor must not see; returns true when the owner handled it.
  func grid(_ grid: CellGridView, handleAppChord event: NSEvent) -> Bool
  func gridPaste(_ grid: CellGridView)
  var optionAsAlt: Bool { get }
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
  private var lastDragCell: (Int, Int)?
  private var lastHoverCell: (Int, Int)?
  private var scrollRemainder: CGFloat = 0
  private var horizontalRemainder: CGFloat = 0

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
    guard firstRow <= lastRow else { return drawCaret(context) }
    for row in firstRow...lastRow {
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
    guard let cursor = store.cursor, cursor.row < store.height else { return }
    let cell = rect(column: cursor.column, row: cursor.row)
    if !marked.isEmpty {
      // Text being composed in an input method, drawn at the caret until it is committed.
      let attributes: [NSAttributedString.Key: Any] = [
        .font: fonts[0], NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        NSAttributedString.Key(kCTUnderlineStyleAttributeName as String): CTUnderlineStyle.single.rawValue,
      ]
      let width = CGFloat(marked.count) * cellWidth
      defaultBackground.setFill()
      NSRect(x: cell.minX, y: cell.minY, width: width, height: cellHeight).fill()
      let line = CTLineCreateWithAttributedString(NSAttributedString(string: marked, attributes: attributes))
      context.setFillColor(defaultForeground.cgColor)
      context.textPosition = CGPoint(x: cell.minX, y: -(cell.minY + ascent))
      CTLineDraw(line, context)
      return
    }
    let focused = window?.isKeyWindow == true && window?.firstResponder === self
    context.setFillColor(caretColor.cgColor)
    context.setStrokeColor(caretColor.cgColor)
    if !focused {
      context.stroke(cell.insetBy(dx: 0.5, dy: 0.5), width: 1)
    } else if caretOn {
      context.fill(CGRect(x: cell.minX, y: cell.minY, width: 2, height: cellHeight))
    }
  }

  // MARK: Accessibility

  /// VoiceOver reads the visible text, one line per row, with the caret's place.
  override func isAccessibilityElement() -> Bool { true }
  override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
  override func accessibilityRoleDescription() -> String? { "editor" }
  override func accessibilityLabel() -> String? { title }
  override func accessibilityValue() -> Any? { store.lines.joined(separator: "\n") }

  override func accessibilitySelectedTextRange() -> NSRange {
    guard let cursor = store.cursor else { return NSRange(location: 0, length: 0) }
    let before = store.lines.prefix(cursor.row).reduce(0) { $0 + ($1 as NSString).length + 1 }
    let line = cursor.row < store.grid.count ? store.text(row: cursor.row) : ""
    let column = (String(line.prefix(cursor.column)) as NSString).length
    return NSRange(location: before + column, length: 0)
  }

  override func accessibilityInsertionPointLineNumber() -> Int { store.cursor?.row ?? 0 }

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
    guard let cursor = store.cursor else { return }
    setNeedsDisplay(rowRect(cursor.row))
  }

  override func becomeFirstResponder() -> Bool {
    restartBlink()
    return true
  }

  override func resignFirstResponder() -> Bool {
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
      inputContext?.handleEvent(event)
      return
    }
    let flags = event.modifierFlags
    if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "v",
       !flags.contains(.shift), !flags.contains(.option), !flags.contains(.control) {
      delegate?.gridPaste(self)
      return
    }
    if let message = SceneKeys.message(keyCode: event.keyCode, charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                                       command: flags.contains(.command), control: flags.contains(.control),
                                       option: flags.contains(.option), shift: flags.contains(.shift),
                                       optionAsAlt: delegate?.optionAsAlt ?? false) {
      delegate?.grid(self, send: message)
      return
    }
    inputContext?.handleEvent(event)
  }

  // MARK: Text input

  func insertText(_ string: Any, replacementRange: NSRange) {
    let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    marked = ""
    for message in SceneKeys.typing(text) { delegate?.grid(self, send: message) }
    setNeedsDisplayCaret()
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    marked = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    setNeedsDisplayCaret()
  }

  func unmarkText() {
    marked = ""
    setNeedsDisplayCaret()
  }

  func hasMarkedText() -> Bool { !marked.isEmpty }
  func markedRange() -> NSRange { marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: marked.utf16.count) }
  func selectedRange() -> NSRange { NSRange(location: marked.utf16.count, length: 0) }
  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.underlineStyle] }
  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
  func characterIndex(for point: NSPoint) -> Int { 0 }
  override func doCommand(by selector: Selector) {}

  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    guard let cursor = store.cursor, let window else { return .zero }
    let local = rect(column: cursor.column, row: cursor.row)
    return window.convertToScreen(convert(local, to: nil))
  }

  // MARK: Mouse

  private func modifiers(_ event: NSEvent) -> [String: Any] {
    ["ctrl": event.modifierFlags.contains(.control), "alt": event.modifierFlags.contains(.option),
     "shift": event.modifierFlags.contains(.shift)]
  }

  private func sendMouse(_ kind: String, _ event: NSEvent, button: String = "left", extra: [String: Any] = [:]) {
    let (column, row) = cell(at: point(of: event))
    var message: [String: Any] = ["type": "mouse", "kind": kind, "button": button, "col": column, "row": row]
    message.merge(modifiers(event)) { a, _ in a }
    message.merge(extra) { _, b in b }
    delegate?.grid(self, send: message)
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
    sendMouse("down", event, extra: ["count": event.clickCount])
  }

  override func mouseDragged(with event: NSEvent) {
    let cell = cell(at: convert(event.locationInWindow, from: nil))
    guard lastDragCell.map({ $0 != cell }) ?? true else { return }
    lastDragCell = cell
    sendMouse("drag", event)
  }

  override func mouseUp(with event: NSEvent) { sendMouse("up", event) }
  override func rightMouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    sendMouse("down", event, button: "right")
  }
  override func rightMouseUp(with event: NSEvent) { sendMouse("up", event, button: "right") }
  override func otherMouseDown(with event: NSEvent) { sendMouse("down", event, button: "middle") }
  override func otherMouseUp(with event: NSEvent) { sendMouse("up", event, button: "middle") }

  override func mouseMoved(with event: NSEvent) {
    let cell = cell(at: convert(event.locationInWindow, from: nil))
    guard lastHoverCell.map({ $0 != cell }) ?? true else { return }
    lastHoverCell = cell
    sendMouse("moved", event)
  }

  /// A trackpad moves three rows per scroll step, as one wheel notch does in
  /// Fresh; a wheel sends a step per notch.
  override func scrollWheel(with event: NSEvent) {
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
      sendMouse(vertical > 0 ? "scrollup" : "scrolldown", event, extra: ["n": min(8, abs(vertical))])
    }
    if horizontal != 0 {
      horizontalRemainder -= CGFloat(horizontal) * (precise ? cellWidth * 3 : 1)
      sendMouse(horizontal > 0 ? "scrollleft" : "scrollright", event, extra: ["n": min(8, abs(horizontal))])
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
