import AppKit
import OverlayCore

final class AppDelegate: NSObject, NSApplicationDelegate {
  private let options: Options
  private let theme: Theme
  private let store: CalibrationStore
  private var controller: OverlayController!
  private var window: OverlayWindow?
  private var view: OverlayView?
  private var tracker: WindowTracker?
  private var server: EventServer?
  private var signals: [DispatchSourceSignal] = []

  init(options: Options, theme: Theme) {
    self.options = options
    self.theme = theme
    store = CalibrationStore(url: options.calibrationFile)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    controller = OverlayController(theme: theme, scheduler: LiveScheduler(),
                                   calibration: store.load(terminal: options.terminalApp), scale: scale)
    controller.onCalibrationFinished = { [weak self] saved in self?.finishCalibration(saved) }
    for signalNumber in [SIGINT, SIGTERM] {
      signal(signalNumber, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
      source.setEventHandler { [weak self] in self?.quit() }
      source.resume()
      signals.append(source)
    }
    if let replay = options.replay {
      startReplay(replay)
    } else {
      if !options.headless { startOverlay() }
      startServer()
    }
  }

  private func quit() {
    server?.stop()
    exit(0)
  }

  // MARK: Live

  private func startOverlay() {
    let window = OverlayWindow(frame: NSRect(x: 0, y: 0, width: 800, height: 600), transparent: true)
    let view = OverlayView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), controller: controller)
    window.contentView = view
    self.window = window
    self.view = view
    let tracker = WindowTracker(owner: options.terminalApp, windowID: options.windowID)
    let verbose = options.verbose, owner = options.terminalApp
    tracker.onFrame = { [weak window] (frame: CGRect?) in
      guard let window else { return }
      if verbose { print("fc-promo-overlay: \(owner) window " + (frame.map { "at \($0)" } ?? "not visible")) }
      if let frame {
        window.setFrame(WindowTracker.appKitFrame(frame), display: true)
        window.orderFrontRegardless()
      } else {
        window.orderOut(nil)
      }
    }
    tracker.start()
    self.tracker = tracker
  }

  private func startServer() {
    let server = EventServer(path: options.socket)
    server.onEvent = { [weak self] event in self?.receive(event) }
    server.onDisconnect = { [weak self] in self?.tracker?.unlock() }
    do {
      try server.start()
    } catch {
      fputs("fc-promo-overlay: cannot listen on \(options.socket): \(error)\n", stderr)
      exit(1)
    }
    self.server = server
    let calibrated = store.load(terminal: options.terminalApp) != nil
    print("fc-promo-overlay: listening on \(options.socket)" + (calibrated ? "" : " (not calibrated yet: run play.py --pattern --overlay)"))
  }

  private func receive(_ timed: TimedEvent) {
    if options.headless || options.verbose {
      print(String(format: "%8.3f  ", timed.time) + String(describing: timed.event))
    }
    if options.headless {
      if case .calibrate = timed.event { server?.send(["event": "calibration_cancelled"]) }
      return
    }
    switch timed.event {
    case .start: tracker?.lock()
    case .end: tracker?.unlock()
    default: break
    }
    controller.handle(timed)
  }

  // MARK: Calibration

  private func finishCalibration(_ saved: Calibration?) {
    if let saved {
      do {
        try store.save(saved, terminal: options.terminalApp)
        print("fc-promo-overlay: calibration saved to \(store.url.path)")
      } catch {
        fputs("fc-promo-overlay: cannot save calibration: \(error)\n", stderr)
      }
      server?.send(["event": "calibrated", "left": saved.left, "top": saved.top])
    } else {
      server?.send(["event": "calibration_cancelled"])
    }
  }

  // MARK: Replay

  private func startReplay(_ url: URL) {
    let events: [TimedEvent]
    do {
      events = try EventLog.load(url)
    } catch {
      fputs("fc-promo-overlay: cannot read \(url.path): \(error)\n", stderr)
      exit(1)
    }
    let grid = PreviewLayout.grid(of: events, fallback: options.grid)
    let layout = PreviewLayout(cols: grid.cols, rows: grid.rows, cell: options.cell)
    controller.calibration = layout.calibration
    let window = OverlayWindow(frame: NSRect(origin: .zero, size: layout.size), transparent: false)
    window.title = "fc-promo-overlay replay: \(url.lastPathComponent)"
    let view = OverlayView(frame: NSRect(origin: .zero, size: layout.size), controller: controller)
    window.contentView = view
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    self.window = window
    self.view = view
    let lines = options.backdrop.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.components(separatedBy: "\n") ?? []
    controller.handle(TimedEvent(time: 0, event: .start(cols: grid.cols, rows: grid.rows, title: "")))
    controller.setBackdrop(Backdrop.make(size: layout.size, grid: controller.grid, lines: lines, scale: window.backingScaleFactor))

    let first = events.first?.time ?? 0
    for timed in events {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + (timed.time - first) / options.speed) { [weak self] in
        self?.controller.handle(timed)
      }
    }
    let last = events.last?.time ?? 0
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + (last - first) / options.speed + 3) { NSApp.terminate(nil) }
  }
}
