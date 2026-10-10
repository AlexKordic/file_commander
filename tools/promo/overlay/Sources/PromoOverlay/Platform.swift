import AppKit
import OverlayCore

/// A transparent panel that clicks pass through. It never takes the keyboard
/// or activates the app, so the terminal keeps focus.
final class OverlayWindow: NSPanel {
  init(frame: NSRect, transparent: Bool) {
    super.init(contentRect: frame, styleMask: transparent ? [.borderless, .nonactivatingPanel] : [.titled, .closable],
               backing: .buffered, defer: false)
    isReleasedWhenClosed = false
    hidesOnDeactivate = false
    if transparent {
      isOpaque = false
      backgroundColor = .clear
      hasShadow = false
      level = .statusBar
      ignoresMouseEvents = true
      collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
  }
}

/// Hosts the controller's root layer.
final class OverlayView: NSView {
  let controller: OverlayController

  init(frame: NSRect, controller: OverlayController) {
    self.controller = controller
    super.init(frame: frame)
    layer = controller.root
    wantsLayer = true
    controller.resize(frame.size)
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  override var isFlipped: Bool { true }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    controller.resize(newSize)
  }
}

/// Follows the terminal window. Until a run starts it follows the frontmost
/// window of the terminal app; `lock()` then keeps that window even when
/// another one comes to the front. A window given by ID is always followed.
final class WindowTracker {
  private let owner: String
  private let fixed: Bool
  private var windowID: CGWindowID?
  private var locked = false
  private var last: CGRect?
  private var timer: Timer?
  /// The window's frame in Core Graphics coordinates (top-left origin), or nil if it is gone.
  var onFrame: ((CGRect?) -> Void)?

  init(owner: String, windowID: CGWindowID?) {
    self.owner = owner
    self.windowID = windowID
    fixed = windowID != nil
    locked = fixed
  }

  func start() {
    timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.poll() }
    poll()
  }

  func lock() {
    if !fixed { windowID = frontmost() ?? windowID }
    locked = true
    poll()
  }

  func unlock() { locked = fixed }

  private func poll() {
    if !locked { windowID = frontmost() }
    let frame = windowID.flatMap(Self.bounds(of:))
    if frame != last {
      last = frame
      onFrame?(frame)
    }
  }

  private func frontmost() -> CGWindowID? {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in windows {
      guard window[kCGWindowOwnerName as String] as? String == owner,
            window[kCGWindowLayer as String] as? Int == 0,
            let number = window[kCGWindowNumber as String] as? Int,
            let bounds = Self.rect(window), bounds.height > 100
      else { continue }
      return CGWindowID(number)
    }
    return nil
  }

  private static func bounds(of id: CGWindowID) -> CGRect? {
    guard let window = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
          window[kCGWindowIsOnscreen as String] as? Bool ?? false
    else { return nil }
    return rect(window)
  }

  private static func rect(_ window: [String: Any]) -> CGRect? {
    guard let dictionary = window[kCGWindowBounds as String] as? NSDictionary else { return nil }
    return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
  }

  /// Core Graphics window coordinates have a top-left origin; AppKit's are bottom-left.
  static func appKitFrame(_ frame: CGRect) -> NSRect {
    let primary = NSScreen.screens.first?.frame ?? .zero
    return NSRect(x: frame.minX, y: primary.maxY - frame.maxY, width: frame.width, height: frame.height)
  }
}

/// Unix-socket server for play.py. One client at a time; each line is a JSON event.
final class EventServer {
  let path: String
  var onEvent: ((TimedEvent) -> Void)?
  var onDisconnect: (() -> Void)?
  private var listener: Int32 = -1
  private var client: Int32 = -1
  private let lock = NSLock()

  init(path: String) { self.path = path }

  func start() throws {
    signal(SIGPIPE, SIG_IGN)
    unlink(path)
    listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: bytes)
      buffer[bytes.count] = 0
    }
    let length = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) }
    }
    guard bound == 0, listen(listener, 4) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    Thread.detachNewThread { [weak self] in self?.acceptLoop() }
  }

  func stop() {
    close(listener)
    unlink(path)
  }

  /// Sends one JSON object to the connected player, if any.
  func send(_ object: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
    data.append(0x0A)
    lock.lock()
    let fd = client
    lock.unlock()
    guard fd >= 0 else { return }
    data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
  }

  private func acceptLoop() {
    while true {
      let fd = accept(listener, nil, nil)
      if fd < 0 {
        if errno == EINTR { continue }
        return
      }
      lock.lock()
      client = fd
      lock.unlock()
      send(["event": "ready"])
      serve(fd)
      lock.lock()
      client = -1
      lock.unlock()
      close(fd)
      DispatchQueue.main.async { [weak self] in self?.onDisconnect?() }
    }
  }

  private func serve(_ fd: Int32) {
    var pending = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = read(fd, &chunk, chunk.count)
      if count <= 0 { return }
      pending.append(contentsOf: chunk[0..<count])
      while let newline = pending.firstIndex(of: 0x0A) {
        let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
        pending.removeSubrange(pending.startIndex...newline)
        if let event = EventDecoder.decode(line) {
          DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
        }
      }
    }
  }
}

/// Reads an events.jsonl file written by play.py --events.
enum EventLog {
  static func load(_ url: URL) throws -> [TimedEvent] {
    try String(contentsOf: url, encoding: .utf8)
      .split(separator: "\n")
      .compactMap { EventDecoder.decode(String($0)) }
  }
}
