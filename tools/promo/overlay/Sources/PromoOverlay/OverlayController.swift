import AppKit
import OverlayCore
import QuartzCore

/// Turns player events into drawing. Owns the cell grid and every component.
final class OverlayController {
  /// Flipped root layer: points from the terminal window's top-left, y down.
  let root = CALayer()
  let theme: Theme
  private let scheduler: Scheduler
  private(set) var grid: CellGrid
  private(set) var bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
  private var cols = 120
  private var rows = 34
  private var terminal: TerminalGeometry?
  var calibration: Calibration? {
    didSet { updateGrid() }
  }

  private let backdropHost = CALayer()
  private let highlight: HighlightComponent
  private let caption: CaptionComponent
  private let chip: SceneChipComponent
  private let badges: BadgeComponent
  private let pointer: PointerComponent
  private let crash: CrashComponent
  private let calibrationGrid: CalibrationComponent

  private(set) var calibrating = false
  private var draft = GridSolver.iTermDefault
  /// Called with the saved calibration, or nil when calibration was cancelled.
  var onCalibrationFinished: ((Calibration?) -> Void)?

  init(theme: Theme, scheduler: Scheduler, calibration: Calibration?, scale: CGFloat) {
    self.theme = theme
    self.scheduler = scheduler
    self.calibration = calibration
    root.isGeometryFlipped = true
    root.addSublayer(backdropHost)
    // Sublayer order is drawing order: later components draw on top.
    highlight = HighlightComponent(host: root, theme: theme, scheduler: scheduler, scale: scale)
    caption = CaptionComponent(host: root, theme: theme, scale: scale)
    chip = SceneChipComponent(host: root, theme: theme, scheduler: scheduler, scale: scale)
    badges = BadgeComponent(host: root, theme: theme, scheduler: scheduler, scale: scale)
    pointer = PointerComponent(host: root, theme: theme, scheduler: scheduler)
    crash = CrashComponent(host: root, theme: theme, scheduler: scheduler, scale: scale)
    calibrationGrid = CalibrationComponent(host: root, theme: theme, scale: scale)
    grid = GridSolver.grid(window: bounds.size, cols: cols, rows: rows, terminal: nil, calibration: calibration)
  }

  /// Draws `layer` beneath everything else; used for previews without a terminal.
  func setBackdrop(_ layer: CALayer) {
    CALayer.immediately {
      backdropHost.sublayers?.forEach { $0.removeFromSuperlayer() }
      backdropHost.addSublayer(layer)
    }
  }

  func resize(_ size: CGSize) {
    bounds = CGRect(origin: .zero, size: size)
    CALayer.immediately {
      root.frame = bounds
      backdropHost.frame = bounds
    }
    updateGrid()
    caption.relayout(in: bounds)
  }

  private func updateGrid() {
    grid = GridSolver.grid(window: bounds.size, cols: cols, rows: rows, terminal: terminal,
                           calibration: calibrating ? draft : calibration)
    if calibrating { calibrationGrid.show(grid: grid, bounds: bounds, message: calibrationMessage) }
  }

  /// Key badges sit in a row just above the caption card, right-aligned with
  /// it, so captions and keys are read together.
  private var badgeAnchor: CGPoint {
    let card = caption.frame ?? CGRect(x: bounds.midX - bounds.width * 0.2, y: bounds.maxY - bounds.height * theme.captionBottom - 80,
                                       width: bounds.width * 0.4, height: 80)
    return CGPoint(x: card.maxX, y: card.minY - 12 - badges.height / 2)
  }

  func handle(_ timed: TimedEvent) {
    switch timed.event {
    case let .start(cols, rows, _):
      self.cols = cols
      self.rows = rows
      terminal = nil
      updateGrid()
      highlight.hide()
      caption.hide()
      badges.clear()
    case let .geometry(geometry):
      terminal = geometry
      updateGrid()
    case let .scene(_, title):
      highlight.hide()
      if theme.sceneTitles == "chip" { chip.show(title, at: CGPoint(x: grid.originX + 12, y: grid.originY + 12)) }
    case let .caption(text, sub):
      caption.show(text, sub, in: bounds)
    case .uncaption:
      caption.hide()
    case let .highlight(rect, style, label):
      highlight.show(grid.rect(rect, padding: theme.highlightPadding), style: style, label: label, bounds: bounds)
    case .unhighlight:
      highlight.hide()
    case let .pointer(rect, milliseconds, click):
      pointer.move(to: grid.center(rect), duration: Double(milliseconds) / 1000, click: click, bounds: bounds)
    case let .drag(from, to, milliseconds):
      pointer.drag(from: grid.center(from), to: grid.center(to), duration: Double(milliseconds) / 1000, bounds: bounds)
    case let .key(label):
      badges.key(label, at: timed.time, anchor: badgeAnchor)
    case let .type(text):
      badges.typed(text, anchor: badgeAnchor)
    case .launch:
      break
    case .crash:
      highlight.hide()
      crash.crash(bounds: bounds)
    case .calibrate:
      beginCalibration()
    case let .calibrateKey(key):
      calibrationKey(key)
    case .end:
      highlight.hide()
      caption.hide()
      pointer.hide()
    }
  }

  // MARK: Calibration

  func beginCalibration() {
    draft = Calibration(left: grid.originX, top: grid.originY, cellWidth: calibration?.cellWidth,
                        cellHeight: calibration?.cellHeight)
    calibrating = true
    highlight.hide()
    caption.hide()
    updateGrid()
  }

  private func calibrationKey(_ key: CalibrationKey) {
    guard calibrating else { return }
    switch key {
    case let .move(dx, dy):
      draft.left += dx
      draft.top += dy
    case let .cellWidth(delta):
      draft.cellWidth = max(1, (draft.cellWidth ?? grid.cellWidth) + delta)
    case let .cellHeight(delta):
      draft.cellHeight = max(1, (draft.cellHeight ?? grid.cellHeight) + delta)
    case .save:
      calibrating = false
      calibrationGrid.hide()
      calibration = draft
      onCalibrationFinished?(draft)
      return
    case .cancel:
      calibrating = false
      calibrationGrid.hide()
      updateGrid()
      onCalibrationFinished?(nil)
      return
    }
    updateGrid()
  }

  private var calibrationMessage: String {
    let source = draft.cellWidth == nil && terminal?.cellWidth != nil ? "reported by the terminal" : "set here"
    return """
    Calibrate the overlay: line the grid up with the coloured cells.
    Type in the terminal running play.py --pattern:
      Arrows   move the grid 1 pt     (with Shift: 10 pt)
      [  ]     cell width  -/+ 0.05   (with Shift: 0.5)
      -  =     cell height -/+ 0.05   (with Shift: 0.5)
      Enter    save        Esc  cancel

    origin \(String(format: "%.1f, %.1f", grid.originX, grid.originY)) pt   \
    cell \(String(format: "%.2f × %.2f", grid.cellWidth, grid.cellHeight)) pt (\(source))   \
    grid \(grid.cols) × \(grid.rows)
    """
  }
}
