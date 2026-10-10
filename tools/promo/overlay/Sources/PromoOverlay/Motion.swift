import AppKit
import OverlayCore
import QuartzCore

/// Snapshots render final states, so they turn animation off.
enum Motion {
  static var animated = true
}

/// Delayed work. The live overlay uses wall-clock time; snapshots use a virtual
/// clock that the event replay advances.
protocol Scheduler: AnyObject {
  func after(_ delay: Double, _ work: @escaping () -> Void)
}

final class LiveScheduler: Scheduler {
  func after(_ delay: Double, _ work: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }
}

final class VirtualScheduler: Scheduler {
  private(set) var now = 0.0
  private var tasks: [(due: Double, order: Int, work: () -> Void)] = []
  private var counter = 0

  func after(_ delay: Double, _ work: @escaping () -> Void) {
    counter += 1
    tasks.append((now + delay, counter, work))
  }

  /// Runs every task due by `time`, in order, including tasks they schedule.
  func advance(to time: Double) {
    while let next = tasks.indices.filter({ tasks[$0].due <= time })
      .min(by: { (tasks[$0].due, tasks[$0].order) < (tasks[$1].due, tasks[$1].order) }) {
      let task = tasks.remove(at: next)
      now = task.due
      task.work()
    }
    now = max(now, time)
  }
}

extension Easing {
  var timingFunction: CAMediaTimingFunction {
    let (x1, y1, x2, y2) = controlPoints
    return CAMediaTimingFunction(controlPoints: Float(x1), Float(y1), Float(x2), Float(y2))
  }
}

extension CALayer {
  /// Tweens `keyPath` from its current on-screen value to `value`. The model
  /// value changes at once, so a tween that interrupts this one starts where
  /// the layer is now instead of jumping.
  func tween(_ keyPath: String, to value: Any?, duration: Double, easing: Easing = .outCubic,
             from: Any? = nil, delay: Double = 0, completion: (() -> Void)? = nil) {
    let animate = Motion.animated && duration > 0
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if animate {
      let start = from ?? (presentation() ?? self).value(forKeyPath: keyPath)
      let animation: CABasicAnimation
      if case let .spring(damping, stiffness) = easing {
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.damping = damping
        spring.stiffness = stiffness
        spring.duration = spring.settlingDuration
        animation = spring
      } else {
        animation = CABasicAnimation(keyPath: keyPath)
        animation.duration = duration
        animation.timingFunction = easing.timingFunction
      }
      animation.fromValue = start
      animation.toValue = value
      if delay > 0 {
        animation.beginTime = CACurrentMediaTime() + delay
        animation.fillMode = .backwards
      }
      if let completion { CATransaction.setCompletionBlock(completion) }
      setValue(value, forKeyPath: keyPath)
      add(animation, forKey: keyPath)
    } else {
      setValue(value, forKeyPath: keyPath)
    }
    CATransaction.commit()
    if !animate { completion?() }
  }

  /// Changes properties without implicit animations.
  static func immediately(_ changes: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    changes()
    CATransaction.commit()
  }
}

func translation(_ dx: CGFloat, _ dy: CGFloat) -> NSValue {
  NSValue(caTransform3D: CATransform3DMakeTranslation(dx, dy, 0))
}

let identity = NSValue(caTransform3D: CATransform3DIdentity)

func color(_ hex: String) -> CGColor {
  let c = RGBA(hex: hex) ?? RGBA(r: 1, g: 0, b: 1)
  return CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
}

func textSize(_ text: String, font: NSFont, maxWidth: CGFloat = .greatestFiniteMagnitude) -> CGSize {
  let bounds = (text as NSString).boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                attributes: [.font: font])
  return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
}

func makeText(_ font: NSFont, color: CGColor, scale: CGFloat, alignment: CATextLayerAlignmentMode = .center) -> CATextLayer {
  let layer = CATextLayer()
  layer.font = font
  layer.fontSize = font.pointSize
  layer.foregroundColor = color
  layer.contentsScale = scale
  layer.alignmentMode = alignment
  layer.isWrapped = true
  layer.truncationMode = .end
  return layer
}
