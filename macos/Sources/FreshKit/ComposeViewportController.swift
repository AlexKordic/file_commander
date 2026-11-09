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
  private struct Seek {
    let request: WireComposeViewportRequest
    let length: UInt64
  }
  private var seeks: [Target: Seek] = [:]
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
      if pending.hasRegion { $0.region = pending.region }
    }
  }

  public func seeking(scope: WireComposeScope) -> UInt64? {
    guard let seek = seeks[Target(scope)], seek.request.scope.bufferRevision == scope.bufferRevision else { return nil }
    return seek.request.region
  }

  /// A thumb can point into an unmeasured UTF-8 scalar. Ask Fresh to normalize
  /// that region before promoting it to a durable source anchor. Cursor and
  /// terminal-client viewports remain untouched.
  @discardableResult
  public func seek(scope: WireComposeScope, from current: WireComposeViewport, position: UInt64, length: UInt64) -> Bool {
    guard position <= length, Int(exactly: length) != nil, current.epoch != 0,
          current.affinity <= 1, current.offset.isFinite, abs(current.offset) <= 100_000,
          current.horizontalOffset.isFinite, (0...100_000_000).contains(current.horizontalOffset) else { return false }
    let target = Target(scope)
    if let previous = seeks[target], previous.request.scope == scope, previous.request.epoch == current.epoch,
       previous.request.region == position { return false }
    var probe = current; probe.region = position
    userScrollGeneration &+= 1
    enqueue(scope: scope, desired: probe)
    seeks[target] = .init(request: latest[target]!, length: length)
    onChange?()
    return true
  }

  @discardableResult
  public func move(scope: WireComposeScope, from current: WireComposeViewport, to desired: WireComposeViewport, user: Bool) -> Bool {
    guard desired.epoch == current.epoch, desired.affinity <= 1, desired.offset.isFinite,
          abs(desired.offset) <= 100_000, desired.horizontalOffset.isFinite,
          (0...100_000_000).contains(desired.horizontalOffset),
          !desired.hasRegion || Int(exactly: desired.region) != nil else { return false }
    // A physical scroll also wins over a queued key's later caret reveal when
    // it reaches a document boundary and does not actually move the viewport.
    if user { userScrollGeneration &+= 1 }
    let cancelledSeek = seeks.removeValue(forKey: Target(scope)) != nil
    guard desired.position != current.position || desired.affinity != current.affinity || abs(desired.offset - current.offset) > 0.01
      || abs(desired.horizontalOffset - current.horizontalOffset) > 0.01
      || desired.hasRegion != current.hasRegion || desired.region != current.region else {
      if cancelledSeek { onChange?() }
      return false
    }
    enqueue(scope: scope, desired: desired)
    onChange?()
    return true
  }

  private func enqueue(scope: WireComposeScope, desired: WireComposeViewport) {
    nextID += 1
    let request = WireComposeViewportRequest.with {
      $0.id = nextID; $0.scope = scope; $0.position = desired.position
      $0.affinity = desired.affinity; $0.offset = desired.offset; $0.epoch = desired.epoch
      $0.horizontalOffset = desired.horizontalOffset
      if desired.hasRegion { $0.region = desired.region }
    }
    latest[Target(scope)] = request
    pump()
  }

  public func observe(window: UInt64, panes: [WirePane], reply: WireComposeViewportReply?) {
    let previous = latest
    var resolved: [(WireComposeScope, WireComposeViewport, UInt64)] = []
    seeks = seeks.filter { target, seek in
      guard target.window == window else { return false }
      guard let pane = panes.first(where: { $0.leaf == target.leaf && $0.hasBuffer && $0.buffer == target.buffer }),
            pane.hasCompose, pane.compose.hasViewport, pane.compose.viewport.epoch == seek.request.epoch,
            pane.compose.bufferRevision == seek.request.scope.bufferRevision,
            pane.compose.documentLen == seek.length else { return false }
      if reply?.id == seek.request.id, reply?.accepted == false { return false }
      let remote = pane.compose.viewport
      guard remote.sequence >= seek.request.id else { return true }
      if remote.sequence == seek.request.id, remote.hasRegion, remote.region <= seek.request.region,
         seek.request.region - remote.region <= 3, remote.region <= seek.length {
        resolved.append((seek.request.scope, remote, remote.region))
      }
      return false
    }
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
    for (scope, remote, position) in resolved {
      var next = remote; next.position = position; next.affinity = 0; next.offset = 0; next.clearRegion()
      _ = move(scope: scope, from: remote, to: next, user: false)
    }
    pump()
    if previous != latest { onChange?() }
  }

  public func reset() {
    latest.removeAll(); seeks.removeAll(); inFlight = nil; nextID = 0; userScrollGeneration = 0
  }

  private func pump() {
    guard inFlight == nil, let next = latest.values.min(by: { $0.id < $1.id }) else { return }
    inFlight = next
    send(next)
  }
}
