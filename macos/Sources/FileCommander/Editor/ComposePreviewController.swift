import Foundation
import FreshKit

/// One actual worker per window, including across cancellation/reset. Each
/// visible leaf retains only its newest request; no detached replacement worker
/// starts while an old Core Text operation is still running.
@MainActor
final class ComposePreviewController {
  struct Owner: Hashable, Sendable {
    let window, leaf, buffer, epoch, authority, document: UInt64
    init(window: UInt64, pane: WirePane) {
      self.window = window; leaf = pane.leaf; buffer = pane.buffer
      epoch = pane.compose.viewport.epoch; authority = pane.compose.assetAuthority; document = pane.compose.assetDocument
    }
  }
  enum Status: Equatable { case waiting, measuring, ready, failed }
  typealias Prepare = @Sendable (ComposePreviewRequest) async throws -> ComposePreviewResult
  private struct Entry {
    let owner: Owner
    let token: UUID
    let request: ComposePreviewRequest
    var status: Status = .waiting
    var result: ComposePreviewResult?
  }
  private let prepare: Prepare
  private var entries: [UInt64: Entry] = [:]
  private var waiting: [UInt64] = []
  private var worker: Task<Void, Never>?
  private var workerID: UUID?
  private var active: Owner?
  var onChange: (() -> Void)?
  var onFailure: ((Owner) -> Void)?
  var workerCount: Int { worker == nil ? 0 : 1 }
  var retainedRequestCount: Int { entries.count }

  init(prepare: @escaping Prepare = { try $0.prepare() }) { self.prepare = prepare }
  deinit { worker?.cancel() }

  func result(owner: Owner, request: ComposePreviewRequest) -> ComposePreviewResult? {
    if let entry = entries[owner.leaf], entry.owner == owner, entry.request.isEquivalent(to: request) {
      return entry.result
    }
    entries[owner.leaf] = Entry(owner: owner, token: UUID(), request: request)
    if !waiting.contains(owner.leaf) { waiting.append(owner.leaf) }
    if active?.leaf == owner.leaf { worker?.cancel() }
    beginIfPossible()
    return nil
  }

  func status(owner: Owner) -> Status? {
    entries[owner.leaf].flatMap { $0.owner == owner ? $0.status : nil }
  }

  /// A validated reuse-only hit needs no queued shape or retained result.
  func discard(owner: Owner) {
    guard entries[owner.leaf]?.owner == owner else { return }
    entries.removeValue(forKey: owner.leaf); waiting.removeAll { $0 == owner.leaf }
    if active == owner { worker?.cancel() }
  }

  func retain(owners: Set<Owner>) {
    entries = entries.filter { owners.contains($0.value.owner) }
    waiting.removeAll { entries[$0] == nil }
    if let active, !owners.contains(active) { worker?.cancel() }
  }

  func reset() {
    entries.removeAll(); waiting.removeAll(); worker?.cancel()
    // Keep worker/ID/active until the actual operation returns.
  }

  private func beginIfPossible() {
    guard worker == nil else { return }
    while !waiting.isEmpty {
      let leaf = waiting.removeFirst()
      guard var entry = entries[leaf], entry.status == .waiting else { continue }
      let id = UUID(), prepare = prepare, request = entry.request
      entry.status = .measuring; entries[leaf] = entry
      workerID = id; active = entry.owner
      let work = Task.detached(priority: .userInitiated) {
        try Task.checkCancellation()
        return try await prepare(request)
      }
      worker = Task { [weak self] in
        let result = await withTaskCancellationHandler(operation: { await work.result }, onCancel: { work.cancel() })
        self?.finished(id: id, entry: entry, result: result)
      }
      return
    }
  }

  private func finished(id: UUID, entry: Entry, result: Result<ComposePreviewResult, Error>) {
    guard workerID == id else { return }
    worker = nil; workerID = nil; active = nil
    var failure: Owner?
    if var current = entries[entry.owner.leaf], current.owner == entry.owner, current.token == entry.token {
      switch result {
      case .success(let prepared): current.status = .ready; current.result = prepared
      case .failure: current.status = .failed; failure = current.owner
      }
      entries[entry.owner.leaf] = current
    }
    beginIfPossible()
    if let failure { onFailure?(failure) }
    onChange?()
  }
}
