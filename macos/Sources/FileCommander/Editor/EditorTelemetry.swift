import Foundation

/// Timing records for the native editor, for finding where its latency comes
/// from. While Settings › Editor › Record Editor Timing is on, each record is
/// one JSON line in `<profile>/telemetry/editor-<date>.jsonl`:
///
/// - `wheel`: a scroll event as it reaches the editor (`et`, the event's own
///   time, shows how long it waited for the main thread), its deltas and
///   phases, and the rows it was turned into.
/// - `send`: a message written to Fresh: its number (what a frame's `ack`
///   counts), type and kind.
/// - `frame`: a frame from Fresh: when the reader had it, parsing, when the main
///   thread applied it and for how long, the rows it changed, and Fresh's own
///   timing (`ack`, `build`, `diff`, `queued`, `owed`, `top`).
/// - `draw`: one redraw of the cells, its duration and rows, and the last
///   frame it shows.
///
/// Times are milliseconds of system uptime, the clock `NSEvent.timestamp` uses.
/// `macos/tools/editor_telemetry.py` summarizes a file.
final class EditorTelemetry: @unchecked Sendable {
  static let shared = EditorTelemetry()

  /// Recordings stop growing past this size.
  private static let limit = 200 * 1024 * 1024
  private let queue = DispatchQueue(label: "fc.editor.telemetry", qos: .utility)
  private let lock = NSLock()
  private var on = false
  private var handle: FileHandle?
  private var buffer = Data()
  private var size = 0
  private var flushing = false
  private(set) var url: URL?

  /// Recording; cheap to check on every event.
  var isOn: Bool {
    lock.lock()
    defer { lock.unlock() }
    return on
  }

  /// Starts a new recording in `directory`.
  func start(directory: URL) {
    stop()
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let url = directory.appendingPathComponent("editor-\(formatter.string(from: Date())).jsonl")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard FileManager.default.createFile(atPath: url.path, contents: nil), let handle = try? FileHandle(forWritingTo: url) else { return }
    queue.sync {
      self.handle = handle
      self.buffer = Data()
      self.size = 0
    }
    self.url = url
    lock.lock()
    on = true
    lock.unlock()
    record(["ev": "session", "date": ISO8601DateFormatter().string(from: Date()),
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""])
  }

  /// Ends the recording, writing what is buffered.
  func stop() {
    lock.lock()
    let wasOn = on
    on = false
    lock.unlock()
    guard wasOn else { return }
    queue.sync {
      self.writeBuffer()
      try? self.handle?.close()
      self.handle = nil
    }
  }

  /// Records one event; `t` (now) is added unless given.
  func record(_ fields: [String: Any]) {
    guard isOn else { return }
    var fields = fields
    if fields["t"] == nil { fields["t"] = EditorTelemetry.now() }
    queue.async {
      guard self.handle != nil, self.size < EditorTelemetry.limit,
            let data = try? JSONSerialization.data(withJSONObject: fields) else { return }
      self.buffer.append(data)
      self.buffer.append(0x0A)
      self.size += data.count + 1
      if self.buffer.count > 256 * 1024 {
        self.writeBuffer()
      } else if !self.flushing {
        // Written in batches, half a second apart, to keep disk writes off the hot path.
        self.flushing = true
        self.queue.asyncAfter(deadline: .now() + 0.5) {
          self.flushing = false
          self.writeBuffer()
        }
      }
    }
  }

  private func writeBuffer() {
    guard let handle, !buffer.isEmpty else { return }
    try? handle.write(contentsOf: buffer)
    buffer.removeAll(keepingCapacity: true)
  }

  /// Milliseconds of system uptime, rounded to microseconds.
  static func now() -> Double { ms(ProcessInfo.processInfo.systemUptime) }

  static func ms(_ seconds: TimeInterval) -> Double { (seconds * 1_000_000).rounded() / 1000 }
}
