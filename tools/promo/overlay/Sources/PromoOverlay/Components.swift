import AppKit
import OverlayCore
import QuartzCore

// Every component draws into layers of the overlay's root layer, whose
// geometry is flipped: points from the terminal window's top-left, y down.

/// Lower-third caption card: a title and an optional subtitle.
final class CaptionComponent {
  private let card = CALayer()
  private let title: CATextLayer
  private let sub: CATextLayer
  private let theme: Theme
  private let titleFont: NSFont
  private let subFont: NSFont
  private var content = ("", "")
  private(set) var visible = false
  /// Where the card is, or was last shown; key badges line up above it.
  private(set) var frame: CGRect?

  init(host: CALayer, theme: Theme, scale: CGFloat) {
    self.theme = theme
    titleFont = NSFont.systemFont(ofSize: theme.captionTitleSize, weight: .semibold)
    subFont = NSFont.systemFont(ofSize: theme.captionSubSize, weight: .regular)
    title = makeText(titleFont, color: color(theme.captionTitleColor), scale: scale)
    sub = makeText(subFont, color: color(theme.captionSubColor), scale: scale)
    card.backgroundColor = color(theme.captionBackground)
    card.cornerRadius = theme.captionCornerRadius
    card.borderWidth = 1
    card.borderColor = color(theme.captionBorder)
    card.shadowColor = CGColor(gray: 0, alpha: 1)
    card.shadowOpacity = 0.5
    card.shadowRadius = 24
    card.shadowOffset = .zero
    card.opacity = 0
    card.addSublayer(title)
    card.addSublayer(sub)
    host.addSublayer(card)
  }

  private func layout(in bounds: CGRect) -> (card: CGRect, title: CGRect, sub: CGRect) {
    let padX: CGFloat = 32, padY: CGFloat = 18
    let maxText = max(80, bounds.width * theme.captionMaxWidth - 2 * padX)
    let titleSize = textSize(content.0, font: titleFont, maxWidth: maxText)
    let subSize = content.1.isEmpty ? .zero : textSize(content.1, font: subFont, maxWidth: maxText)
    let gap: CGFloat = content.1.isEmpty ? 0 : 6
    let width = max(titleSize.width, subSize.width) + 2 * padX
    let height = titleSize.height + gap + subSize.height + 2 * padY
    let frame = CGRect(x: bounds.midX - width / 2, y: bounds.maxY - bounds.height * theme.captionBottom - height,
                       width: width, height: height).integral
    let inner = frame.width - 2 * padX
    return (frame, CGRect(x: padX, y: padY, width: inner, height: titleSize.height),
            CGRect(x: padX, y: padY + titleSize.height + gap, width: inner, height: subSize.height))
  }

  func show(_ text: String, _ subtitle: String, in bounds: CGRect) {
    content = (text, subtitle)
    let frames = layout(in: bounds)
    frame = frames.card
    if !visible {
      CALayer.immediately {
        card.frame = frames.card
        title.frame = frames.title
        sub.frame = frames.sub
        title.string = text
        sub.string = subtitle
      }
      card.tween("opacity", to: 1, duration: theme.captionIn, from: 0)
      card.tween("transform", to: identity, duration: theme.captionIn, easing: .outBack, from: translation(0, 24))
    } else {
      crossfade(title, to: text)
      crossfade(sub, to: subtitle)
      let move = 0.28
      card.tween("bounds", to: NSValue(rect: CGRect(origin: .zero, size: frames.card.size)), duration: move, easing: .inOutCubic)
      card.tween("position", to: NSValue(point: CGPoint(x: frames.card.midX, y: frames.card.midY)), duration: move, easing: .inOutCubic)
      for (layer, frame) in [(title, frames.title), (sub, frames.sub)] {
        layer.tween("bounds", to: NSValue(rect: CGRect(origin: .zero, size: frame.size)), duration: move, easing: .inOutCubic)
        layer.tween("position", to: NSValue(point: CGPoint(x: frame.midX, y: frame.midY)), duration: move, easing: .inOutCubic)
      }
      card.tween("opacity", to: 1, duration: 0.15)
      card.tween("transform", to: identity, duration: 0.15)
    }
    visible = true
  }

  func hide() {
    guard visible else { return }
    visible = false
    card.tween("opacity", to: 0, duration: theme.captionOut, easing: .inCubic)
    card.tween("transform", to: translation(0, 12), duration: theme.captionOut, easing: .inCubic)
  }

  func relayout(in bounds: CGRect) {
    guard visible else { return }
    let frames = layout(in: bounds)
    frame = frames.card
    CALayer.immediately {
      card.frame = frames.card
      title.frame = frames.title
      sub.frame = frames.sub
    }
  }

  private func crossfade(_ layer: CATextLayer, to text: String) {
    guard (layer.string as? String) != text else { return }
    if Motion.animated {
      let fade = CATransition()
      fade.type = .fade
      fade.duration = 0.2
      layer.add(fade, forKey: "fade")
    }
    CALayer.immediately { layer.string = text }
  }
}

/// A glowing frame around cells, optionally dimming everything else.
final class HighlightComponent {
  private let frameLayer = CAShapeLayer()
  private let dim = CAShapeLayer()
  private let tag: CATextLayer
  private let theme: Theme
  private let scheduler: Scheduler
  private var shown = false
  private var token = 0

  init(host: CALayer, theme: Theme, scheduler: Scheduler, scale: CGFloat) {
    self.theme = theme
    self.scheduler = scheduler
    dim.fillColor = CGColor(gray: 0, alpha: 1)
    dim.fillRule = .evenOdd
    dim.opacity = 0
    frameLayer.fillColor = nil
    frameLayer.strokeColor = color(theme.accent)
    frameLayer.lineWidth = theme.highlightLineWidth
    frameLayer.lineJoin = .round
    frameLayer.shadowColor = color(theme.accent)
    frameLayer.shadowRadius = 10
    frameLayer.shadowOpacity = 0.9
    frameLayer.shadowOffset = .zero
    frameLayer.opacity = 0
    tag = makeText(NSFont.systemFont(ofSize: 14, weight: .semibold), color: CGColor(gray: 1, alpha: 1), scale: scale)
    tag.backgroundColor = color(theme.accent)
    tag.cornerRadius = 6
    tag.opacity = 0
    host.addSublayer(dim)
    host.addSublayer(frameLayer)
    host.addSublayer(tag)
  }

  func show(_ rect: CGRect, style: String, label: String, bounds: CGRect) {
    token += 1
    let mine = token
    let radius = max(0, min(8, rect.width / 2 - 0.5, rect.height / 2 - 0.5))
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    if shown {
      frameLayer.tween("path", to: path, duration: theme.highlightMove, easing: .inOutCubic)
      frameLayer.tween("opacity", to: 1, duration: 0.1)
    } else {
      CALayer.immediately { frameLayer.path = path }
      frameLayer.tween("strokeEnd", to: 1, duration: theme.highlightIn, from: 0)
      frameLayer.tween("opacity", to: 1, duration: theme.highlightIn * 0.6, from: 0)
    }
    let hole = CGMutablePath()
    hole.addRect(bounds)
    hole.addPath(path)
    CALayer.immediately { dim.path = hole }
    dim.tween("opacity", to: style == "spotlight" ? theme.spotlightDim : 0, duration: 0.3)
    if label.isEmpty {
      tag.tween("opacity", to: 0, duration: 0.15)
    } else {
      let font = NSFont.systemFont(ofSize: 14, weight: .semibold)
      let size = textSize(label, font: font)
      CALayer.immediately {
        tag.string = label
        tag.frame = CGRect(x: rect.minX, y: rect.minY - size.height - 10, width: size.width + 16, height: size.height + 4)
      }
      tag.tween("opacity", to: 1, duration: 0.2)
    }
    shown = true
    scheduler.after(theme.highlightLinger) { [weak self] in
      guard let self, self.token == mine else { return }
      self.hide()
    }
  }

  func hide() {
    guard shown else { return }
    token += 1
    shown = false
    frameLayer.tween("opacity", to: 0, duration: 0.3, easing: .inCubic)
    dim.tween("opacity", to: 0, duration: 0.3)
    tag.tween("opacity", to: 0, duration: 0.2)
  }
}

/// A macOS-style arrow that glides along a slight arc and clicks.
final class PointerComponent {
  private let arrow = CAShapeLayer()
  private let ripple = CAShapeLayer()
  private let theme: Theme
  private let scheduler: Scheduler
  private var shown = false
  private var token = 0

  init(host: CALayer, theme: Theme, scheduler: Scheduler) {
    self.theme = theme
    self.scheduler = scheduler
    let scale = theme.pointerSize / 21
    let outline: [(CGFloat, CGFloat)] = [(0, 0), (0, 17), (4.2, 13.4), (7, 20), (10, 18.8), (7.3, 12.2), (12.5, 12.2)]
    let path = CGMutablePath()
    path.addLines(between: outline.map { CGPoint(x: $0.0 * scale, y: $0.1 * scale) })
    path.closeSubpath()
    arrow.path = path
    arrow.fillColor = CGColor(gray: 1, alpha: 1)
    arrow.strokeColor = CGColor(gray: 0, alpha: 1)
    arrow.lineWidth = 1.3
    arrow.lineJoin = .round
    arrow.bounds = CGRect(x: 0, y: 0, width: 13 * scale, height: 21 * scale)
    arrow.anchorPoint = .zero
    arrow.shadowColor = CGColor(gray: 0, alpha: 1)
    arrow.shadowOpacity = 0.45
    arrow.shadowRadius = 3
    arrow.shadowOffset = CGSize(width: 0, height: 2)
    arrow.opacity = 0
    ripple.path = CGPath(ellipseIn: CGRect(x: -22, y: -22, width: 44, height: 44), transform: nil)
    ripple.fillColor = color(theme.accent).copy(alpha: 0.18)
    ripple.strokeColor = color(theme.accent)
    ripple.lineWidth = 3
    ripple.opacity = 0
    host.addSublayer(ripple)
    host.addSublayer(arrow)
  }

  func move(to target: CGPoint, duration: Double, click: Bool, bounds: CGRect) {
    token += 1
    let mine = token
    let start: CGPoint
    if shown {
      start = (arrow.presentation() ?? arrow).position
    } else {
      start = CGPoint(x: bounds.maxX - bounds.width * 0.12, y: bounds.maxY - bounds.height * 0.2)
      CALayer.immediately { arrow.position = start }
      arrow.tween("opacity", to: 1, duration: 0.2, from: 0)
      shown = true
    }
    if Motion.animated {
      let dx = target.x - start.x, dy = target.y - start.y
      let distance = hypot(dx, dy)
      let mid = CGPoint(x: (start.x + target.x) / 2, y: (start.y + target.y) / 2)
      let lift = min(90, distance * 0.18)
      let control = distance > 1 ? CGPoint(x: mid.x - dy / distance * lift, y: mid.y + dx / distance * lift) : mid
      let curve = CGMutablePath()
      curve.move(to: start)
      curve.addQuadCurve(to: target, control: control)
      let glide = CAKeyframeAnimation(keyPath: "position")
      glide.path = curve
      glide.duration = duration
      glide.timingFunction = Easing.inOutCubic.timingFunction
      CALayer.immediately {
        arrow.position = target
        arrow.add(glide, forKey: "glide")
      }
    } else {
      CALayer.immediately { arrow.position = target }
    }
    if click {
      scheduler.after(duration) { [weak self] in self?.clickEffect(at: target) }
    }
    scheduler.after(duration + theme.pointerLinger) { [weak self] in
      guard let self, self.token == mine else { return }
      self.hide()
    }
  }

  func hide() {
    guard shown else { return }
    shown = false
    arrow.tween("opacity", to: 0, duration: 0.3)
  }

  private func clickEffect(at point: CGPoint) {
    if Motion.animated {
      let press = CAKeyframeAnimation(keyPath: "transform.scale")
      press.values = [1, 0.8, 1]
      press.keyTimes = [0, 0.35, 1]
      press.duration = 0.25
      arrow.add(press, forKey: "press")
    }
    CALayer.immediately { ripple.position = point }
    ripple.tween("transform.scale", to: 1.6, duration: 0.45, from: 0.3)
    ripple.tween("opacity", to: 0, duration: 0.45, from: 0.85)
  }
}

/// Key badges stacked at the right, one per key press; quick repeats merge.
final class BadgeComponent {
  private struct Badge {
    let layer: CALayer
    let text: CATextLayer
  }

  private var badges: [Badge] = []
  private var keys = KeyCoalescer()
  private let theme: Theme
  private let scheduler: Scheduler
  private let scale: CGFloat
  private let font: NSFont
  private weak var host: CALayer?
  private var token = 0

  init(host: CALayer, theme: Theme, scheduler: Scheduler, scale: CGFloat) {
    self.host = host
    self.theme = theme
    self.scheduler = scheduler
    self.scale = scale
    font = NSFont.monospacedSystemFont(ofSize: theme.badgeSize, weight: .semibold)
  }

  var height: CGFloat { textSize("Ag", font: font).height + 14 }

  func key(_ label: String, at time: Double, anchor: CGPoint) {
    let (text, merges) = keys.add(label, at: time)
    add(text, merging: merges, anchor: anchor)
  }

  func typed(_ text: String, anchor: CGPoint) {
    keys.reset()
    add("“\(text)”", merging: false, anchor: anchor)
  }

  func clear() {
    token += 1
    keys.reset()
    for badge in badges { fadeOut(badge) }
    badges.removeAll()
  }

  private func add(_ text: String, merging: Bool, anchor: CGPoint) {
    token += 1
    let mine = token
    var leaving: [Badge] = []
    if merging, let last = badges.last {
      resize(last, to: text)
      last.layer.tween("transform.scale", to: 1, duration: 0.25, easing: .outBack, from: 1.15)
    } else {
      let badge = make(text)
      // Adding or removing a sublayer outside a disabled transaction crossfades
      // the whole host layer, which ghosts every badge.
      CALayer.immediately { host?.addSublayer(badge.layer) }
      badges.append(badge)
      while badges.count > max(1, theme.badgeMax) { leaving.append(badges.removeFirst()) }
    }
    layout(anchor: anchor, leaving: leaving)
    scheduler.after(theme.badgeLinger) { [weak self] in
      guard let self, self.token == mine else { return }
      self.clear()
    }
  }

  private func make(_ text: String) -> Badge {
    let layer = CALayer()
    layer.backgroundColor = color(theme.badgeBackground)
    layer.cornerRadius = 9
    layer.borderWidth = 1
    layer.borderColor = CGColor(gray: 1, alpha: 0.25)
    layer.shadowColor = CGColor(gray: 0, alpha: 1)
    layer.shadowOpacity = 0.4
    layer.shadowRadius = 8
    layer.shadowOffset = .zero
    let label = makeText(font, color: color(theme.badgeTextColor), scale: scale)
    label.isWrapped = false
    layer.addSublayer(label)
    let badge = Badge(layer: layer, text: label)
    resize(badge, to: text)
    layer.opacity = 0
    return badge
  }

  private func resize(_ badge: Badge, to text: String) {
    let size = textSize(text, font: font)
    CALayer.immediately {
      badge.text.string = text
      badge.layer.bounds = CGRect(x: 0, y: 0, width: size.width + 26, height: size.height + 14)
      badge.text.frame = CGRect(x: 13, y: 7, width: size.width, height: size.height)
    }
  }

  /// Right-aligns the row. Badges pushed out by a new one slide along with the
  /// row while they fade, and a new badge waits for the row to make room, so
  /// badges never overlap mid-animation.
  private func layout(anchor: CGPoint, leaving: [Badge] = []) {
    let slide = 0.18
    var right = anchor.x
    for badge in badges.reversed() + leaving.reversed() {
      let width = badge.layer.bounds.width
      let position = CGPoint(x: right - width / 2, y: anchor.y)
      if badge.layer.opacity == 0 {
        let delay = badges.count > 1 ? slide * 0.6 : 0
        CALayer.immediately { badge.layer.position = position }
        badge.layer.tween("opacity", to: 1, duration: theme.badgeIn * 0.6, from: 0, delay: delay)
        badge.layer.tween("transform.scale", to: 1, duration: theme.badgeIn, easing: .outBack, from: 0.6, delay: delay)
      } else {
        badge.layer.tween("position", to: NSValue(point: position), duration: slide, easing: .outCubic)
      }
      right -= width + 10
    }
    for badge in leaving { fadeOut(badge, duration: slide) }
  }

  private func fadeOut(_ badge: Badge, duration: Double? = nil) {
    badge.layer.tween("opacity", to: 0, duration: duration ?? theme.badgeOut) {
      CALayer.immediately { badge.layer.removeFromSuperlayer() }
    }
  }
}

/// A red glow around the window and a stamp when FC is killed.
final class CrashComponent {
  private let glow = CAShapeLayer()
  private let stamp: CATextLayer
  private let theme: Theme
  private let scheduler: Scheduler
  private let font = NSFont.systemFont(ofSize: 72, weight: .black)

  init(host: CALayer, theme: Theme, scheduler: Scheduler, scale: CGFloat) {
    self.theme = theme
    self.scheduler = scheduler
    glow.fillColor = nil
    glow.strokeColor = color(theme.crashColor)
    glow.lineWidth = 14
    glow.shadowColor = color(theme.crashColor)
    glow.shadowRadius = 40
    glow.shadowOpacity = 1
    glow.shadowOffset = .zero
    glow.opacity = 0
    stamp = makeText(font, color: color(theme.crashColor), scale: scale)
    stamp.isWrapped = false
    stamp.borderColor = color(theme.crashColor)
    stamp.borderWidth = 6
    stamp.cornerRadius = 12
    stamp.opacity = 0
    host.addSublayer(glow)
    host.addSublayer(stamp)
  }

  func crash(bounds: CGRect) {
    let size = textSize(theme.crashText, font: font)
    CALayer.immediately {
      glow.path = CGPath(rect: bounds.insetBy(dx: 7, dy: 7), transform: nil)
      stamp.string = theme.crashText
      stamp.bounds = CGRect(x: 0, y: 0, width: size.width + 48, height: size.height + 12)
      stamp.position = CGPoint(x: bounds.midX, y: bounds.midY)
      stamp.setAffineTransform(CGAffineTransform(rotationAngle: -8 * .pi / 180))
    }
    if Motion.animated {
      let flash = CAKeyframeAnimation(keyPath: "opacity")
      flash.values = [0, 0.95, 0]
      flash.keyTimes = [0, 0.15, 1]
      flash.duration = 0.9
      glow.add(flash, forKey: "flash")
    }
    stamp.tween("opacity", to: 1, duration: 0.12, from: 0)
    stamp.tween("transform.scale", to: 1, duration: 0.3, easing: .outBack, from: 1.8)
    scheduler.after(1.6) { [weak self] in self?.stamp.tween("opacity", to: 0, duration: 0.4) }
  }
}

/// The current scene's title, briefly, in the top-left corner.
final class SceneChipComponent {
  private let chip: CATextLayer
  private let scheduler: Scheduler
  private let font = NSFont.systemFont(ofSize: 15, weight: .semibold)
  private var token = 0

  init(host: CALayer, theme: Theme, scheduler: Scheduler, scale: CGFloat) {
    self.scheduler = scheduler
    chip = makeText(font, color: CGColor(gray: 1, alpha: 1), scale: scale)
    chip.isWrapped = false
    chip.backgroundColor = color(theme.accent)
    chip.cornerRadius = 8
    chip.opacity = 0
    host.addSublayer(chip)
  }

  func show(_ title: String, at origin: CGPoint) {
    guard !title.isEmpty else { return }
    token += 1
    let mine = token
    let size = textSize(title, font: font)
    CALayer.immediately {
      chip.string = title
      chip.frame = CGRect(x: origin.x, y: origin.y, width: size.width + 20, height: size.height + 8)
    }
    chip.tween("opacity", to: 1, duration: 0.25, from: 0)
    chip.tween("transform", to: identity, duration: 0.3, easing: .outCubic, from: translation(-16, 0))
    scheduler.after(2.4) { [weak self] in
      guard let self, self.token == mine else { return }
      self.chip.tween("opacity", to: 0, duration: 0.4)
    }
  }
}

/// Cell grid and instructions while the text-area position is calibrated.
final class CalibrationComponent {
  private let lines = CAShapeLayer()
  private let border = CAShapeLayer()
  private let panel = CALayer()
  private let info: CATextLayer
  private let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .medium)

  init(host: CALayer, theme: Theme, scale: CGFloat) {
    lines.strokeColor = color(theme.accent).copy(alpha: 0.55)
    lines.lineWidth = 0.5
    lines.fillColor = nil
    border.strokeColor = color(theme.accent)
    border.lineWidth = 2
    border.fillColor = nil
    panel.backgroundColor = CGColor(gray: 0.05, alpha: 0.92)
    panel.cornerRadius = 10
    panel.borderColor = color(theme.accent)
    panel.borderWidth = 1.5
    info = makeText(font, color: CGColor(gray: 1, alpha: 1), scale: scale, alignment: .left)
    panel.addSublayer(info)
    for layer in [lines, border, panel] {
      layer.isHidden = true
      host.addSublayer(layer)
    }
  }

  func show(grid: CellGrid, bounds: CGRect, message: String) {
    let path = CGMutablePath()
    let area = grid.textArea
    for col in 0...grid.cols {
      let x = area.minX + Double(col) * grid.cellWidth
      path.move(to: CGPoint(x: x, y: area.minY))
      path.addLine(to: CGPoint(x: x, y: area.maxY))
    }
    for row in 0...grid.rows {
      let y = area.minY + Double(row) * grid.cellHeight
      path.move(to: CGPoint(x: area.minX, y: y))
      path.addLine(to: CGPoint(x: area.maxX, y: y))
    }
    let size = textSize(message, font: font)
    CALayer.immediately {
      lines.path = path
      border.path = CGPath(rect: area, transform: nil)
      info.string = message
      info.frame = CGRect(x: 20, y: 14, width: size.width + 4, height: size.height)
      panel.frame = CGRect(x: bounds.midX - (size.width + 44) / 2, y: bounds.midY - (size.height + 28) / 2,
                           width: size.width + 44, height: size.height + 28)
      for layer in [lines, border, panel] { layer.isHidden = false }
    }
  }

  func hide() {
    CALayer.immediately {
      for layer in [lines, border, panel] { layer.isHidden = true }
    }
  }
}
