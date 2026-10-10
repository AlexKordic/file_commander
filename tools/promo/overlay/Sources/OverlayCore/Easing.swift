/// Timing curves for tweens. Bézier curves use CSS-style control points, so the
/// same curve drives Core Animation and `value(at:)`.
public enum Easing: Equatable, Sendable {
  case linear
  case inCubic
  case outCubic
  case inOutCubic
  /// Overshoots slightly before settling; used for things that pop in.
  case outBack
  case spring(damping: Double, stiffness: Double)

  public init?(name: String) {
    switch name {
    case "linear": self = .linear
    case "inCubic": self = .inCubic
    case "outCubic": self = .outCubic
    case "inOutCubic": self = .inOutCubic
    case "outBack": self = .outBack
    case "spring": self = .spring(damping: 14, stiffness: 180)
    default: return nil
    }
  }

  /// Control points (x1, y1, x2, y2). A spring is approximated by `outBack`.
  public var controlPoints: (Double, Double, Double, Double) {
    switch self {
    case .linear: (0, 0, 1, 1)
    case .inCubic: (0.32, 0, 0.67, 0)
    case .outCubic: (0.33, 1, 0.68, 1)
    case .inOutCubic: (0.65, 0, 0.35, 1)
    case .outBack, .spring: (0.34, 1.56, 0.64, 1)
    }
  }

  /// Progress for a time fraction in 0...1.
  public func value(at t: Double) -> Double {
    let t = min(max(t, 0), 1)
    if case .linear = self { return t }
    let (x1, y1, x2, y2) = controlPoints
    return Easing.bezier(Easing.parameter(forX: t, x1: x1, x2: x2), y1, y2)
  }

  static func bezier(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
    let u = 1 - s
    return 3 * u * u * s * p1 + 3 * u * s * s * p2 + s * s * s
  }

  /// Bisection: x(s) is monotonic because x1 and x2 lie in 0...1.
  static func parameter(forX x: Double, x1: Double, x2: Double) -> Double {
    var low = 0.0, high = 1.0, s = x
    for _ in 0..<64 {
      let current = bezier(s, x1, x2)
      if abs(current - x) < 1e-9 { break }
      if current < x { low = s } else { high = s }
      s = (low + high) / 2
    }
    return s
  }
}
