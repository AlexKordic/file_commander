import Foundation

/// Reassembles bounded binary image responses. Requests retain their source
/// identity, so a caller can discard obsolete results before scheduling Image
/// I/O decoding. There is no filesystem access or image decoding on this path.
public struct ComposeAssetReceiver {
  public static let maximumBytes = 16 << 20
  public static let maximumChunkBytes = 128 << 10
  public static let maximumRequests = 4

  public enum Event {
    case loaded(request: WireComposeAssetRequest, bytes: Data)
    case failed(request: WireComposeAssetRequest, message: String)
  }

  private struct Pending {
    var request: WireComposeAssetRequest
    var total: Int?
    var bytes = Data()
  }
  private var pending: [UInt64: Pending] = [:]
  private var lastID: UInt64 = 0

  public init() {}

  public var activeRequests: [WireComposeAssetRequest] { pending.values.map(\.request) }

  /// Register before sending. IDs belong to one socket connection and must
  /// increase; a cancelled id must never be reused for a different resource.
  @discardableResult
  public mutating func register(_ request: WireComposeAssetRequest) -> Bool {
    guard request.id > lastID, request.hasScope, request.end > request.start, !request.cancel,
          pending[request.id] == nil, pending.count < Self.maximumRequests else { return false }
    lastID = request.id
    pending[request.id] = Pending(request: request)
    return true
  }

  public mutating func cancel(_ id: UInt64) { pending.removeValue(forKey: id) }

  /// Returns the ids whose server reads can be cancelled as a pane, document,
  /// source revision or filesystem authority changes.
  public mutating func retain(where keep: (WireComposeAssetRequest) -> Bool) -> [UInt64] {
    let removed = pending.values.filter { !keep($0.request) }.map { $0.request.id }
    for id in removed { pending.removeValue(forKey: id) }
    return removed
  }

  /// Reset when opening a new socket connection, whose id namespace is fresh.
  public mutating func reset() { pending.removeAll(); lastID = 0 }

  public mutating func receive(_ chunk: WireComposeAssetChunk) -> Event? {
    guard var state = pending.removeValue(forKey: chunk.id) else { return nil }
    func failed(_ message: String) -> Event { .failed(request: state.request, message: message) }
    // A source/authority cancellation can arrive after earlier data chunks.
    // Its error terminates the request regardless of the old stream offset.
    if !chunk.error.isEmpty { return failed(chunk.error) }
    guard let total = Int(exactly: chunk.total), total <= Self.maximumBytes,
          chunk.data.count <= Self.maximumChunkBytes,
          chunk.offset == UInt64(state.bytes.count), total >= state.bytes.count,
          chunk.data.count <= total - state.bytes.count,
          state.total == nil || state.total == total else {
      return failed("Invalid or oversized image response")
    }
    if state.total == nil {
      state.total = total
      state.bytes.reserveCapacity(total)
    }
    state.bytes.append(chunk.data)
    if chunk.done {
      guard state.bytes.count == total else { return failed("Incomplete image response") }
      return .loaded(request: state.request, bytes: state.bytes)
    }
    guard state.bytes.count < total else { return failed("Image response lacks its final marker") }
    pending[chunk.id] = state
    return nil
  }
}
