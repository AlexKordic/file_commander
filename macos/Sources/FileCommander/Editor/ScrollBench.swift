import AppKit
import ExplainerKit

/// A trackpad flick, as the events a real one sends: a short finger phase
/// that speeds up to `speed`, the lift, then momentum that decays by `decay`
/// per event until it is below half a point. Events come every `interval`
/// seconds (120 Hz, as a trackpad reports). Negative deltas scroll down.
struct ScrollGesture {
  enum Phase { case began, changed, ended, momentumBegan, momentum, momentumEnded }
  struct Event { var at: TimeInterval; var delta: Double; var phase: Phase }

  var speed: Double  // points per second at the lift; negative scrolls down
  var fingerSeconds = 0.12
  var decay = 0.975
  var interval = 1.0 / 120
  var maxMomentumSeconds = 4.0

  var events: [Event] {
    var out: [Event] = []
    let fingerCount = max(2, Int(fingerSeconds / interval))
    for i in 0..<fingerCount {
      // Speeds up from a quarter to full speed while the finger moves.
      let fraction = 0.25 + 0.75 * Double(i + 1) / Double(fingerCount)
      out.append(Event(at: Double(i) * interval, delta: speed * interval * fraction, phase: i == 0 ? .began : .changed))
    }
    var t = Double(fingerCount) * interval
    out.append(Event(at: t, delta: 0, phase: .ended))
    t += interval * 2
    var delta = speed * interval
    var first = true
    while abs(delta) >= 0.5, t - Double(fingerCount) * interval < maxMomentumSeconds {
      out.append(Event(at: t, delta: delta, phase: first ? .momentumBegan : .momentum))
      first = false
      delta *= decay
      t += interval
    }
    out.append(Event(at: t, delta: 0, phase: .momentumEnded))
    return out
  }

  /// The distance the gesture asks for, in points.
  var distance: Double { events.reduce(0) { $0 + $1.delta } }
}

/// Plays scroll gestures into a view on a timer of its own: each event is
/// handed to the view on the main queue at the time a trackpad would send it,
/// so a busy main thread delays it as it delays a real one, and its timestamp
/// is when it was sent. (Synthesized scroll events posted to the app's event
/// queue reach no window, so they go to the view's `scrollWheel` directly.)
final class ScrollInjector: @unchecked Sendable {
  private let queue = DispatchQueue(label: "fc.scroll.inject", qos: .userInteractive)

  /// Plays `gesture` at the middle of `view`. Returns when the last event was posted.
  @MainActor
  func play(_ gesture: ScrollGesture, into view: NSView, record: String) async {
    guard let window = view.window else { return }
    let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    let screen = window.convertPoint(toScreen: center)
    let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.y
    let location = CGPoint(x: screen.x, y: primaryHeight - screen.y)  // CG: top-left origin
    let windowNumber = window.windowNumber
    let events = gesture.events
    let target = WeakView(view)
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      queue.async {
        let start = ProcessInfo.processInfo.systemUptime
        for event in events {
          let wait = start + event.at - ProcessInfo.processInfo.systemUptime
          if wait > 0 { Thread.sleep(forTimeInterval: wait) }
          guard let nsEvent = ScrollInjector.make(event, location: location, windowNumber: windowNumber) else { continue }
          if EditorTelemetry.shared.isOn {
            EditorTelemetry.shared.record(["ev": "inject", "to": record, "dy": event.delta, "phase": "\(event.phase)"])
          }
          let event = UncheckedEvent(nsEvent)
          DispatchQueue.main.async { MainActor.assumeIsolated { ScrollInjector.deliver(event.event, to: target.view) } }
        }
        done.resume()
      }
    }
  }

  /// Hands one event to the view. A scroll view that ignores it (AppKit's own
  /// scroll tracking takes only events from the window server) is moved by the
  /// event's delta, as `NSScrollView` moves for a trackpad.
  @MainActor
  static func deliver(_ event: NSEvent, to view: NSView?) {
    guard let view else { return }
    guard let scrollView = view as? NSScrollView else { return view.scrollWheel(with: event) }
    let clip = scrollView.contentView
    let before = clip.bounds.origin
    scrollView.scrollWheel(with: event)
    guard clip.bounds.origin == before, event.scrollingDeltaY != 0 else { return }
    let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
    clip.scroll(to: NSPoint(x: before.x, y: min(maxY, max(0, before.y - event.scrollingDeltaY))))
    scrollView.reflectScrolledClipView(clip)
  }

  static func make(_ event: ScrollGesture.Event, location: CGPoint, windowNumber: Int) -> NSEvent? {
    let points = Int32(event.delta.rounded())
    guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: points, wheel2: 0, wheel3: 0) else {
      return nil
    }
    cg.location = location
    cg.timestamp = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
    cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(points))
    cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: event.delta)
    cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowNumber))
    cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowNumber))
    let (scroll, momentum): (Int64, Int64) = switch event.phase {
    case .began: (1, 0)
    case .changed: (2, 0)
    case .ended: (4, 0)
    case .momentumBegan: (0, 1)
    case .momentum: (0, 2)
    case .momentumEnded: (0, 3)
    }
    cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: scroll)
    cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
    return NSEvent(cgEvent: cg)
  }
}

private final class WeakView: @unchecked Sendable {
  weak var view: NSView?
  init(_ view: NSView) { self.view = view }
}

private struct UncheckedEvent: @unchecked Sendable {
  let event: NSEvent
  init(_ event: NSEvent) { self.event = event }
}

/// A plain AppKit text view showing a file, as the baseline to compare the
/// editor's scrolling with: it scrolls in the app itself, with no round trip.
/// Telemetry records where it has scrolled to (`tvpos`) and its draws (`tvdraw`).
@MainActor
final class TextViewBench: NSObject {
  private(set) var window: NSWindow?
  private(set) var scrollView: NSScrollView?
  private var observer: NSObjectProtocol?

  func open(path: String, font: NSFont, frame: NSRect) {
    close()
    let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "Can't read \(path)"
    let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Text View — \((path as NSString).lastPathComponent)"
    window.identifier = NSUserInterfaceItemIdentifier("textview-bench")
    window.isReleasedWhenClosed = false
    let scrollView = NSScrollView(frame: window.contentView!.bounds)
    scrollView.autoresizingMask = [.width, .height]
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    let textView = BenchTextView(frame: scrollView.bounds)
    textView.isEditable = false
    textView.font = font
    textView.string = text
    textView.isHorizontallyResizable = true
    textView.textContainer?.widthTracksTextView = false
    textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.lineHeight = NSLayoutManager().defaultLineHeight(for: font)
    scrollView.documentView = textView
    window.contentView = scrollView
    scrollView.contentView.postsBoundsChangedNotifications = true
    let lineHeight = textView.lineHeight
    observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
                                                      queue: nil) { [weak scrollView] _ in
      MainActor.assumeIsolated {
        guard let scrollView, EditorTelemetry.shared.isOn else { return }
        EditorTelemetry.shared.record(["ev": "tvpos", "top": Double(scrollView.contentView.bounds.minY / lineHeight)])
      }
    }
    window.makeKeyAndOrderFront(nil)
    self.window = window
    self.scrollView = scrollView
  }

  func close() {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    window?.close()
    window = nil
    scrollView = nil
  }
}

private final class BenchTextView: NSTextView {
  var lineHeight: CGFloat = 16

  override func draw(_ dirtyRect: NSRect) {
    guard EditorTelemetry.shared.isOn else { return super.draw(dirtyRect) }
    let started = ProcessInfo.processInfo.systemUptime
    super.draw(dirtyRect)
    EditorTelemetry.shared.record([
      "ev": "tvdraw", "t": EditorTelemetry.ms(started), "ms": EditorTelemetry.ms(ProcessInfo.processInfo.systemUptime - started),
      "top": Double(visibleRect.minY / lineHeight),
    ])
  }
}
