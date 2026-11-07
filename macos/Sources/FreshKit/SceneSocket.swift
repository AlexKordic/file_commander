import Darwin
import Foundation

/// The channel between the app and the scene socket of the Fresh session File
/// Commander manages: protobuf messages in a type-length-value stream
/// (`SceneWire`) over an owner-only Unix socket the session names in its
/// handshake (`fc_scene`). There is no TCP port, no HTTP and no WebSocket.
///
/// The app says hello (`ClientHello`), Fresh answers with the whole scene
/// (`ServerHello`) and then a `Frame` whenever something changed. Messages are
/// read and decoded on a thread of their own and delivered to `onMessage` on
/// the main queue, in order. Writes go through a serial queue, so `send` never
/// blocks the caller.
public final class SceneSocket: @unchecked Sendable {
  public enum Failure: Error, CustomStringConvertible {
    case path(String)
    case system(String, Int32)
    case closed
    case alreadyOpen

    public var description: String {
      switch self {
      case .path(let path): return "Scene socket path is too long: \(path)"
      case .system(let call, let code): return "\(call) failed: \(String(cString: strerror(code)))"
      case .closed: return "The editor connection was cancelled."
      case .alreadyOpen: return "The editor is already connected."
      }
    }
  }

  /// The socket's send and receive buffers.
  static let bufferSize: Int32 = 4 << 20

  public let path: String
  /// Called on the main queue with each decoded message.
  public var onMessage: (@MainActor (SceneMessage) -> Void)?
  /// Independently paced auxiliary data. These messages never advance the
  /// scene sequence and must not receive a render-frame Applied acknowledgment.
  public var onIndexChunk: (@MainActor (WireComposeIndexChunk) -> Void)?
  public var onDocumentChunk: (@MainActor (WireComposeDocumentChunk) -> Void)?
  /// Called on the main queue once, when the connection ends; the argument says why.
  public var onClose: (@MainActor (String?) -> Void)?
  /// Called on the write queue after each message is written, for telemetry:
  /// its number in sending order (what a frame's `ack` counts), its type and
  /// kind as telemetry names them, its payload's size, and when the write
  /// finished (system uptime).
  public var onSent: (@Sendable (_ number: Int, _ type: String, _ kind: String?, _ bytes: Int, _ at: TimeInterval) -> Void)?

  private var fd: Int32 = -1
  private let writes = DispatchQueue(label: "fc.scene.write")
  private let state = NSLock()
  private var closed = false
  private var terminalReason: String?
  /// Messages written so far; touched only on the write queue.
  private var written = 0
  /// Messages handed to `send` so far, under `state`.
  private var requestedCount = 0

  public init(path: String) { self.path = path }

  deinit { if fd >= 0 { Darwin.close(fd) } }

  /// Connects and says hello; `telemetry` asks Fresh for frame timing. Blocks
  /// briefly for the connect; call it off the main thread when that matters.
  /// An instance is one-use. Closing before/during connect prevents ownership
  /// of the completed descriptor; duplicate opens do not replace a live one.
  public func open(telemetry: Bool, richCompose: Bool = false, measuredTables: Bool = false, paragraphWindows: Bool = false) throws {
    state.lock()
    let failure: Failure? = closed ? .closed : (fd >= 0 ? .alreadyOpen : nil)
    state.unlock()
    if let failure { throw failure }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw Failure.system("socket", errno) }
    var installed = false
    defer { if !installed { Darwin.close(fd) } }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
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
    let hello = SceneInput.hello(telemetry: telemetry, richCompose: richCompose, measuredTables: measuredTables,
      paragraphWindows: paragraphWindows, nativePopupProjection: richCompose)
    let payload = hello.payload()
    let helloBytes = SceneWire.message(hello.kind, payload: payload)
    state.lock()
    guard !closed else { state.unlock(); throw Failure.closed }
    guard self.fd < 0 else { state.unlock(); throw Failure.alreadyOpen }
    self.fd = fd
    installed = true
    // Commit ownership and the first queued message together. A concurrent
    // resize/key cannot get ahead of the hello after observing an open fd.
    enqueue(helloBytes, payloadCount: payload.count, name: hello.telemetryName)
    state.unlock()
    let thread = Thread { [weak self] in self?.readLoop(requireRegionProbes: richCompose) }
    thread.name = "fc.scene.read"
    thread.qualityOfService = .userInteractive
    thread.start()
  }

  /// Queues a message only while connected. Initial hello admission is atomic
  /// with publishing the descriptor, and queue order matches requested order.
  public func send(_ input: SceneInput) {
    guard isOpen else { return }
    let payload = input.payload()
    let bytes = SceneWire.message(input.kind, payload: payload)
    let name = input.telemetryName
    state.lock()
    guard !closed, fd >= 0 else { state.unlock(); return }
    enqueue(bytes, payloadCount: payload.count, name: name)
    state.unlock()
  }

  /// Called with state locked so requested order is also queue order.
  private func enqueue(_ bytes: [UInt8], payloadCount: Int, name: (type: String, kind: String?)) {
    requestedCount += 1
    writes.async { [weak self] in
      guard let self, self.isOpen else { return }
      do { try self.writeAll(bytes) }
      catch { self.end(reason: String(describing: error)); return }
      self.written += 1
      self.onSent?(self.written, name.type, name.kind, payloadCount, ProcessInfo.processInfo.systemUptime)
    }
  }

  /// Messages admitted to the write queue so far. They are written in this order, so a
  /// frame whose `ack` reaches this number shows all of them.
  public var requested: Int {
    state.lock()
    defer { state.unlock() }
    return requestedCount
  }

  /// Ends an active connection; `onClose` follows when its reader exits.
  /// Closing an unopened instance prevents a later open.
  public func close() {
    end(reason: nil)
  }

  /// The first terminal cause wins. A transmit failure must also wake the
  /// reader, whose single completion delivers normal connection recovery.
  @discardableResult
  private func end(reason: String?) -> String? {
    state.lock()
    let wasClosed = closed
    if !wasClosed { closed = true; terminalReason = reason }
    let descriptor = fd
    let finalReason = terminalReason
    state.unlock()
    if !wasClosed, descriptor >= 0 { shutdown(descriptor, SHUT_RDWR) }
    return finalReason
  }

  public var isOpen: Bool {
    state.lock()
    defer { state.unlock() }
    return fd >= 0 && !closed
  }

  // MARK: Reading

  private func readLoop(requireRegionProbes: Bool) {
    var buffer = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 262_144)
    var reason: String?
    var greeted = false
    var documentReads = false
    loop: while true {
      // One read can bring many messages; what they used is dropped once, after.
      var start = 0
      do {
        while let (kind, payload, length) = try SceneWire.readMessage(buffer, at: start) {
          start += length
          if kind == SceneWire.Kind.error.rawValue {
            let error = try? WireError(serializedBytes: Array(buffer[payload]))
            reason = "the editor closed the connection: " + (error?.reason ?? "an error")
            break loop
          }
          let started = ProcessInfo.processInfo.systemUptime
          if kind == SceneWire.Kind.composeDocumentChunk.rawValue {
            guard greeted, documentReads else {
              reason = "the editor sent an unnegotiated complete document chunk"
              break loop
            }
            guard payload.count <= 128 << 10 else {
              reason = "the editor sent an oversized complete document chunk"
              break loop
            }
            let chunk = try WireComposeDocumentChunk(serializedBytes: Array(buffer[payload]))
            DispatchQueue.main.async { [weak self] in
              MainActor.assumeIsolated { self?.onDocumentChunk?(chunk) }
            }
            continue
          }
          if kind == SceneWire.Kind.composeIndexChunk.rawValue {
            guard greeted else {
              reason = "the editor sent document navigation before its hello"
              break loop
            }
            guard payload.count <= 128 << 10 else {
              reason = "the editor sent an oversized document navigation chunk"
              break loop
            }
            let index = try WireComposeIndexChunk(serializedBytes: buffer[payload])
            DispatchQueue.main.async { [weak self] in
              MainActor.assumeIsolated { self?.onIndexChunk?(index) }
            }
            continue
          }
          guard var message = SceneMessage(kind: kind, payload: buffer[payload]) else {
            reason = "the editor sent a message the app can't read (type \(kind))"
            break loop
          }
          if !greeted {
            guard message.isHello else {
              reason = "the editor sent a frame before its hello"
              break loop
            }
            guard message.protocolVersion == SceneWire.version else {
              reason = "the editor uses an incompatible scene protocol"
              break loop
            }
            guard !requireRegionProbes || message.composeRegionProbes else {
              reason = "This editor backend is too old for native Compose. Use Restart editor backend in the command palette to upgrade it."
              break loop
            }
            guard !requireRegionProbes || message.nativePopupProjection else {
              reason = "This editor backend is too old for native Compose popups. Use Restart editor backend in the command palette to upgrade it."
              break loop
            }
            greeted = true
            documentReads = message.composeDocumentText
          } else if message.isHello {
            reason = "the editor sent more than one hello"
            break loop
          }
          message.receivedAt = started
          message.parseSeconds = ProcessInfo.processInfo.systemUptime - started
          message.bytes = payload.count
          DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onMessage?(message) }
          }
        }
      } catch {
        reason = "the editor sent bytes the app can't read: \(error)"
        break
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
    let finalReason = end(reason: reason)
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated { self?.onClose?(finalReason) }
    }
  }

  private func writeAll(_ bytes: [UInt8]) throws {
    var offset = 0
    while offset < bytes.count {
      let n = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
      if n <= 0 {
        if n < 0 && errno == EINTR { continue }
        throw Failure.system("write", n == 0 ? EIO : errno)
      }
      offset += n
    }
  }
}
