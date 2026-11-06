import Foundation

/// One acknowledged scroll at a time, with optimistic, coalesced intentions
/// for each pane. Text input uses its own ordered channel and never waits for
/// a wheel acknowledgment. Backend source markers own the durable position.
@MainActor
public final class ComposeViewportController {
  private struct Target: Hashable {
    var window, leaf, buffer: UInt64
    init(_ scope: WireComposeScope) { window = scope.windowID; leaf = scope.leaf; buffer = scope.buffer }
  }
  private var latest: [Target: WireComposeViewportRequest] = [:]
  private var inFlight: WireComposeViewportRequest?
  private var nextID: UInt64 = 0
  private let send: (WireComposeViewportRequest) -> Void
  public var onChange: (() -> Void)?
  public private(set) var userScrollGeneration: UInt64 = 0

  public init(send: @escaping (WireComposeViewportRequest) -> Void) { self.send = send }

  public func value(scope: WireComposeScope, remote: WireComposeViewport) -> WireComposeViewport {
    guard let pending = latest[Target(scope)], pending.scope.bufferRevision <= scope.bufferRevision,
          pending.epoch == remote.epoch, pending.id > remote.sequence else { return remote }
    if pending.scope.bufferRevision != scope.bufferRevision {
      // An edit can invalidate queued source coordinates while horizontal
      // translation remains meaningful. Draw the backend's current source anchor.
      var current = remote; current.horizontalOffset = pending.horizontalOffset
      return current
    }
    return .with {
      $0.position = pending.position; $0.affinity = pending.affinity
      $0.offset = pending.offset; $0.horizontalOffset = pending.horizontalOffset; $0.epoch = pending.epoch; $0.sequence = pending.id
    }
  }

  @discardableResult
  public func move(scope: WireComposeScope, from current: WireComposeViewport, to desired: WireComposeViewport, user: Bool) -> Bool {
    guard desired.epoch == current.epoch, desired.affinity <= 1, desired.offset.isFinite,
          abs(desired.offset) <= 100_000, desired.horizontalOffset.isFinite,
          (0...100_000_000).contains(desired.horizontalOffset) else { return false }
    // A physical scroll also wins over a queued key's later caret reveal when
    // it reaches a document boundary and does not actually move the viewport.
    if user { userScrollGeneration &+= 1 }
    guard desired.position != current.position || desired.affinity != current.affinity || abs(desired.offset - current.offset) > 0.01
      || abs(desired.horizontalOffset - current.horizontalOffset) > 0.01 else { return false }
    nextID += 1
    let request = WireComposeViewportRequest.with {
      $0.id = nextID; $0.scope = scope; $0.position = desired.position
      $0.affinity = desired.affinity; $0.offset = desired.offset; $0.epoch = desired.epoch
      $0.horizontalOffset = desired.horizontalOffset
    }
    latest[Target(scope)] = request
    pump()
    onChange?()
    return true
  }

  public func observe(window: UInt64, panes: [WirePane], reply: WireComposeViewportReply?) {
    let previous = latest
    latest = latest.filter { target, request in
      guard target.window == window else { return true }
      guard let pane = panes.first(where: { $0.leaf == target.leaf }),
            (pane.hasBuffer && pane.buffer == target.buffer) || pane.tabBar.tabs.contains(where: { $0.hasBufferID && $0.bufferID == target.buffer }) else { return false }
      // A modal or an inactive tab can omit its Compose projection.
      guard pane.hasBuffer, pane.buffer == target.buffer, pane.hasCompose, pane.compose.hasViewport else { return true }
      return request.epoch == pane.compose.viewport.epoch && request.scope.bufferRevision <= pane.compose.bufferRevision
        && request.id > pane.compose.viewport.sequence
    }
    if let reply, let pending = inFlight, reply.id == pending.id {
      if latest[Target(pending.scope)]?.id == reply.id { latest.removeValue(forKey: Target(pending.scope)) }
      inFlight = nil
    }
    pump()
    if previous != latest { onChange?() }
  }

  public func reset() {
    latest.removeAll(); inFlight = nil; nextID = 0; userScrollGeneration = 0
  }

  private func pump() {
    guard inFlight == nil, let next = latest.values.min(by: { $0.id < $1.id }) else { return }
    inFlight = next
    send(next)
  }
}
