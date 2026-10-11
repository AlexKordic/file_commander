import Darwin
import Foundation

/// A WebSocket client over a Unix socket: the channel between the app and the
/// scene bridge of the Fresh session File Commander manages. The session
/// listens on an owner-only socket in its socket directory and names it in its
/// handshake (`fc_scene`); there is no TCP port.
///
/// Messages are JSON text frames. Frames are read and parsed on a thread of
/// their own and delivered to `onMessage` on the main queue, in order. Writes
/// go through a serial queue, so `send` never blocks the caller.
public final class SceneSocket: @unchecked Sendable {
  public enum Failure: Error, CustomStringConvertible {
    case path(String)
    case system(String, Int32)
    case handshake(String)

    public var description: String {
      switch self {
      case .path(let path): return "Scene socket path is too long: \(path)"
      case .system(let call, let code): return "\(call) failed: \(String(cString: strerror(code)))"
      case .handshake(let detail): return "Scene handshake failed: \(detail)"
      }
    }
  }

  /// The socket's send and receive buffers.
  static let bufferSize: Int32 = 4 << 20

  public let path: String
  /// Called on the main queue with each parsed message.
  public var onMessage: (@MainActor (SceneMessage) -> Void)?
  /// Called on the main queue once, when the connection ends; the argument says why.
  public var onClose: (@MainActor (String?) -> Void)?
  /// Called on the write queue after each message is written, for telemetry:
  /// its number in sending order (what a frame's `ack` counts), its `type` and
  /// `kind`, its size, and when the write finished (system uptime).
  public var onSent: (@Sendable (_ number: Int, _ type: String, _ kind: String?, _ bytes: Int, _ at: TimeInterval) -> Void)?

  private var fd: Int32 = -1
  private let writes = DispatchQueue(label: "fc.scene.write")
  private let state = NSLock()
  private var closed = false
  /// Messages written so far; touched only on the write queue.
  private var written = 0

  public init(path: String) { self.path = path }

  deinit { if fd >= 0 { Darwin.close(fd) } }

  /// Connects and upgrades to WebSocket. `query` is the upgrade's query, such
  /// as `?grid=1&menus=native`, so the first scene already has what the client
  /// wants. Blocks for at most a few seconds; call it off the main thread when
  /// that matters.
  public func open(query: String = "") throws {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw Failure.system("socket", errno) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      Darwin.close(fd)
      throw Failure.path(path)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: bytes)
      raw[bytes.count] = 0
    }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else {
      let code = errno
      Darwin.close(fd)
      throw Failure.system("connect", code)
    }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    // macOS gives a Unix socket 8 KiB each way, a fraction of one frame: Fresh
    // would trickle each frame out and queue the next ones behind it. Fresh
    // raises its end too. Best effort; a smaller buffer only makes it slower.
    var size = SceneSocket.bufferSize
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    self.fd = fd

    let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
    let request = "GET /ws\(query) HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
      + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
    try writeAll(Array(request.utf8))
    var buffer = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 65536)
    var headEnd: Int?
    while headEnd == nil {
      let n = read(fd, &chunk, chunk.count)
      guard n > 0 else { throw Failure.handshake(n == 0 ? "closed" : String(cString: strerror(errno))) }
      buffer.append(contentsOf: chunk[0..<n])
      headEnd = SceneSocket.headerEnd(buffer)
    }
    let head = String(decoding: buffer[0..<headEnd!], as: UTF8.self)
    guard head.split(separator: "\r\n").first?.contains(" 101 ") == true else {
      throw Failure.handshake(String(head.prefix(80)))
    }
    timeout = timeval(tv_sec: 0, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let leftover = Array(buffer[(headEnd! + 4)...])
    let thread = Thread { [weak self] in self?.readLoop(initial: leftover) }
    thread.name = "fc.scene.read"
    thread.qualityOfService = .userInteractive
    thread.start()
  }

  /// Sends one JSON message.
  public func send(_ message: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
    let frame = SceneSocket.encode(opcode: 0x1, payload: Array(data))
    let type = message["type"] as? String ?? "", kind = message["kind"] as? String
    writes.async { [weak self] in
      guard let self, (try? self.writeAll(frame)) != nil else { return }
      self.written += 1
      self.onSent?(self.written, type, kind, data.count, ProcessInfo.processInfo.systemUptime)
    }
  }

  /// Ends the connection. `onClose` follows on the main queue.
  public func close() {
    state.lock()
    let wasClosed = closed
    closed = true
    state.unlock()
    if !wasClosed, fd >= 0 { shutdown(fd, SHUT_RDWR) }
  }

  public var isOpen: Bool {
    state.lock()
    defer { state.unlock() }
    return fd >= 0 && !closed
  }

  // MARK: Reading

  private func readLoop(initial: [UInt8]) {
    var buffer = initial
    var chunk = [UInt8](repeating: 0, count: 262_144)
    var reason: String?
    loop: while true {
      // One read can bring many frames; what they used is dropped once, after.
      var start = 0
      while let (opcode, payload, used) = SceneSocket.decode(buffer, from: start) {
        start += used
        switch opcode {
        case 0x1:
          let started = ProcessInfo.processInfo.systemUptime
          if var message = SceneMessage(json: payload) {
            message.receivedAt = started
            message.parseSeconds = ProcessInfo.processInfo.systemUptime - started
            message.bytes = payload.count
            DispatchQueue.main.async { [weak self] in
              MainActor.assumeIsolated { self?.onMessage?(message) }
            }
          }
        case 0x8:
          reason = "closed by the editor"
          break loop
        case 0x9:
          let pong = SceneSocket.encode(opcode: 0xA, payload: payload)
          writes.async { [weak self] in try? self?.writeAll(pong) }
        default:
          break
        }
      }
      buffer.removeFirst(start)
      let n = read(fd, &chunk, chunk.count)
      if n > 0 {
        buffer.append(contentsOf: chunk[0..<n])
      } else {
        if n < 0 && errno == EINTR { continue }
        state.lock()
        let deliberate = closed
        state.unlock()
        reason = deliberate ? nil : (n == 0 ? "the editor closed the connection" : String(cString: strerror(errno)))
        break
      }
    }
    state.lock()
    closed = true
    state.unlock()
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated { self?.onClose?(reason) }
    }
  }

  // MARK: Framing

  private func writeAll(_ bytes: [UInt8]) throws {
    var offset = 0
    while offset < bytes.count {
      let n = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
      if n < 0 {
        if errno == EINTR { continue }
        throw Failure.system("write", errno)
      }
      offset += n
    }
  }

  static func headerEnd(_ buffer: [UInt8]) -> Int? {
    guard buffer.count >= 4 else { return nil }
    for i in 0...(buffer.count - 4) where buffer[i] == 13 && buffer[i + 1] == 10 && buffer[i + 2] == 13 && buffer[i + 3] == 10 {
      return i
    }
    return nil
  }

  /// One client frame: FIN set, masked as the protocol requires of clients.
  static func encode(opcode: UInt8, payload: [UInt8]) -> [UInt8] {
    var frame: [UInt8] = [0x80 | opcode]
    let count = payload.count
    if count < 126 {
      frame.append(0x80 | UInt8(count))
    } else if count <= 0xFFFF {
      frame.append(0x80 | 126)
      frame.append(contentsOf: [UInt8(count >> 8), UInt8(count & 0xFF)])
    } else {
      frame.append(0x80 | 127)
      frame.append(contentsOf: (0..<8).reversed().map { UInt8((UInt64(count) >> (UInt64($0) * 8)) & 0xFF) })
    }
    let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
    frame.append(contentsOf: mask)
    frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
    return frame
  }

  /// One server frame from `start` in `buffer`, or nil until it has all arrived.
  static func decode(_ buffer: [UInt8], from start: Int = 0) -> (opcode: UInt8, payload: [UInt8], used: Int)? {
    guard buffer.count >= start + 2 else { return nil }
    let opcode = buffer[start] & 0x0F
    let masked = buffer[start + 1] & 0x80 != 0
    var length = Int(buffer[start + 1] & 0x7F)
    var offset = start + 2
    if length == 126 {
      guard buffer.count >= start + 4 else { return nil }
      length = Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
      offset = start + 4
    } else if length == 127 {
      guard buffer.count >= start + 10 else { return nil }
      length = buffer[(start + 2)..<(start + 10)].reduce(0) { $0 << 8 | Int($1) }
      offset = start + 10
    }
    var mask: [UInt8] = []
    if masked {
      guard buffer.count >= offset + 4 else { return nil }
      mask = Array(buffer[offset..<(offset + 4)])
      offset += 4
    }
    guard buffer.count >= offset + length else { return nil }
    var payload = Array(buffer[offset..<(offset + length)])
    if masked { for i in payload.indices { payload[i] ^= mask[i % 4] } }
    return (opcode, payload, offset + length - start)
  }
}
