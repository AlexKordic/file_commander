import Foundation

/// One demanded complete text generation, independent from drawing crops.
/// Scene changes coalesce; at most one decode worker lives, including across
/// cancellation/reconnection. A historical binary base is never a public value.
@MainActor
public final class ComposeDocumentController {
  public enum Status: Equatable { case idle, waiting, loading, ready, failed }
  public private(set) var status: Status = .idle
  public private(set) var generation = UUID()
  public private(set) var snapshot: ComposeDocumentSnapshot?
  public private(set) var lastTransferBytes = 0
  public private(set) var lastEncoding: UInt32?
  public var onChange: (() -> Void)?

  private struct Target: Equatable {
    let owner: WireComposeIndexOwner
    let selection: UInt64
    let decoration: UInt64?
    let ready: Bool
    let editable: Bool?
    init?(window: UInt64, pane: WirePane?) {
      guard let pane, pane.hasBuffer, pane.hasCompose, pane.compose.hasViewport,
            pane.compose.viewport.epoch != 0,
            pane.compose.documentLen <= UInt64(ComposeDocumentReceiver.maximumSource) else { return nil }
      owner = .with {
        $0.window = window; $0.leaf = pane.leaf; $0.buffer = pane.buffer; $0.epoch = pane.compose.viewport.epoch
        $0.revision = pane.compose.bufferRevision; $0.authority = pane.compose.assetAuthority
        $0.document = pane.compose.assetDocument; $0.length = pane.compose.documentLen
      }
      selection = pane.compose.selectionRevision
      decoration = pane.compose.hasDecorationRevision ? pane.compose.decorationRevision : nil
      ready = pane.compose.projectionUsable && decoration != nil && pane.compose.error.isEmpty
      editable = pane.compose.hasEditable ? pane.compose.editable : nil
    }
  }
  private let send: (WireComposeDocumentRequest) -> Void
  private let decode: @Sendable (ComposeDocumentDecode) async throws -> ComposeDocumentSnapshot
  private let quietNanoseconds, timeoutNanoseconds: UInt64
  private var target: Target?
  private var activated = false
  private var nextID: UInt64 = 0
  private var lastChange: UInt64 = 0
  private var receiver: ComposeDocumentUpdateReceiver?
  private var readingTarget: Target?
  private var baseline: ComposeDocumentBaseline?
  private var prepared: ComposeDocumentSnapshot?
  private var retainedID: UInt64?
  private var scheduled: Task<Void, Never>?
  private var deadline: Task<Void, Never>?
  private var building: Task<Void, Never>?
  private var buildingID: UUID?

  public init(quietNanoseconds: UInt64 = 80_000_000, timeoutNanoseconds: UInt64 = 35_000_000_000,
              decode: @escaping @Sendable (ComposeDocumentDecode) async throws -> ComposeDocumentSnapshot = { try $0.decode() },
              send: @escaping (WireComposeDocumentRequest) -> Void) {
    self.quietNanoseconds = quietNanoseconds; self.timeoutNanoseconds = timeoutNanoseconds
    self.decode = decode; self.send = send
  }
  deinit { scheduled?.cancel(); deadline?.cancel(); building?.cancel() }

  /// Pending formatting keeps its binary base while withholding the public
  /// value. Hiding, source replacement and connection reset release it.
  public func update(window: UInt64, pane: WirePane?, supported: Bool) {
    let next = supported ? Target(window: window, pane: pane) : nil
    guard next != target else { return }
    let same = next != nil && target != nil && next!.owner.isSameDocument(as: target!.owner)
    let preparingSame = receiver != nil && next != nil && target != nil
      && next!.owner == target!.owner && next!.selection == target!.selection && next!.editable == target!.editable
    if preparingSame {
      // Preparing the normal offscreen formatter changes its global revision.
      // The read captures that revision when encoding, not when requested.
      // Cancelling here would repeatedly restart its own preparation.
      target = next; generation = UUID(); snapshot = nil; status = .loading
      lastChange = DispatchTime.now().uptimeNanoseconds; onChange?(); return
    }
    cancelRead()
    if !same { releaseBase(); building?.cancel() }
    scheduled?.cancel(); scheduled = nil
    generation = UUID(); snapshot = nil; target = next
    lastChange = DispatchTime.now().uptimeNanoseconds
    status = next == nil ? .idle : .waiting
    if activated { schedule() }
    onChange?()
  }

  public func activate() {
    guard !activated else { return }
    activated = true; schedule(); onChange?()
  }

  public func retry() {
    guard activated, target != nil, status == .failed else { return }
    generation = UUID(); status = .waiting; lastChange = DispatchTime.now().uptimeNanoseconds
    schedule(); onChange?()
  }

  public func reset() {
    cancelRead(); releaseBase(); building?.cancel()
    scheduled?.cancel(); scheduled = nil
    target = nil; snapshot = nil; activated = false; generation = UUID(); status = .idle
    onChange?()
  }

  private func cancelRead() {
    if let receiver { send(.with { $0.id = receiver.id; $0.cancel = true }) }
    receiver = nil; readingTarget = nil; deadline?.cancel(); deadline = nil
  }
  private func releaseBase() {
    if let retainedID { send(.with { $0.id = retainedID; $0.cancel = true }) }
    retainedID = nil; baseline = nil; prepared = nil
  }

  private func schedule() {
    guard activated, let target, target.ready, receiver == nil, building == nil, status != .failed else { return }
    scheduled?.cancel()
    let now = DispatchTime.now().uptimeNanoseconds
    let elapsed = now >= lastChange ? now-lastChange : 0
    let delay = quietNanoseconds > elapsed ? quietNanoseconds-elapsed : 0
    let generation = generation
    scheduled = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: delay) } catch { return }
      guard let self, !Task.isCancelled, self.generation == generation else { return }
      self.scheduled = nil; self.begin(target)
    }
  }

  private func begin(_ target: Target) {
    guard self.target == target, receiver == nil, building == nil, nextID < .max else { return }
    nextID += 1; status = .loading; lastTransferBytes = 0; lastEncoding = nil
    let base = baseline.flatMap { $0.id == retainedID && $0.owner.isSameDocument(as: target.owner) ? $0 : nil }
    receiver = .init(id: nextID, owner: target.owner, selection: target.selection, base: base)
    readingTarget = target
    send(.with { $0.id = nextID; $0.owner = target.owner; $0.selectionRevision = target.selection; $0.baseID = base?.id ?? 0 })
    armDeadline(nextID); onChange?()
  }

  private func armDeadline(_ id: UInt64) {
    deadline?.cancel()
    let delay = timeoutNanoseconds
    deadline = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: delay) } catch { return }
      guard let self, !Task.isCancelled, self.receiver?.id == id else { return }
      let changed = self.target != self.readingTarget
      self.cancelRead(); self.status = changed ? .waiting : .failed
      if changed { self.schedule() }; self.onChange?()
    }
  }

  public func receive(_ chunk: WireComposeDocumentChunk) {
    guard var receiver, receiver.id == chunk.id, let target else { return }
    self.receiver = nil // Move before mutation; avoid copying each accumulated prefix.
    do {
      let job = try receiver.receive(chunk)
      send(.with { $0.id = chunk.id; $0.appliedSequence = chunk.sequence })
      lastTransferBytes += chunk.data.count; lastEncoding = chunk.encoding
      guard let job else { self.receiver = receiver; armDeadline(chunk.id); return }
      readingTarget = nil; deadline?.cancel(); deadline = nil; retainedID = job.id
      let id = UUID(), generation = generation, decode = decode
      let requestID = job.id, input = job.reusing(prepared?.document)
      buildingID = id
      let work = Task.detached(priority: .userInitiated) { try await decode(input) }
      building = Task { [weak self] in
        let result = await withTaskCancellationHandler(operation: { await work.result }, onCancel: { work.cancel() })
        // Always release the worker slot, even when this outer task was
        // cancelled; a new generation waits for actual worker completion.
        self?.finished(id: id, generation: generation, target: target, request: requestID, result: result)
      }
    } catch {
      send(.with { $0.id = chunk.id; $0.cancel = true })
      let changed = self.target != readingTarget
      readingTarget = nil; deadline?.cancel(); deadline = nil; status = changed ? .waiting : .failed
      if changed { schedule() }; onChange?()
    }
  }

  private func finished(id: UUID, generation: UUID, target: Target, request: UInt64,
                        result: Result<ComposeDocumentSnapshot, Error>) {
    guard buildingID == id else { return }
    building = nil; buildingID = nil
    switch result {
    case .success(let value):
      if activated, retainedID == request, let current = self.target, value.baseline.owner.isSameDocument(as: current.owner) {
        baseline = value.baseline
        prepared = value
        if self.generation == generation, current == target, current.owner == value.document.owner,
           current.selection == value.document.selectionRevision, current.decoration == value.document.decorationRevision,
           current.editable == (value.pane.hasEditable ? value.pane.editable : nil) {
          snapshot = value; status = .ready; onChange?(); return
        }
      }
    case .failure:
      if retainedID == request { releaseBase() }
      if self.generation == generation { status = .failed; onChange?(); return }
    }
    schedule(); onChange?()
  }
}
