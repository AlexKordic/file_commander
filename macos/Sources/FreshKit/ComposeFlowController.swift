import Foundation

/// A demanded complete text/geometry generation. One worker lives at a time,
/// even when cancellation or a connection reset cannot stop it immediately.
/// Retained geometry may be reused, but retired source ownership is not public.
@MainActor
public final class ComposeFlowController {
  public enum Status: Equatable { case idle, waiting, measuring, ready, failed }
  public private(set) var status: Status = .idle
  public private(set) var generation = UUID()
  public private(set) var flow: ComposeFlowMeasurement?
  public var onChange: (() -> Void)?

  public typealias Measure = @Sendable (ComposeDocumentSnapshot, ComposeFlowMeasurement.Environment,
    ComposeFlowMeasurement?) async throws -> ComposeFlowMeasurement
  private struct Target {
    let snapshot: ComposeDocumentSnapshot
    let environment: ComposeFlowMeasurement.Environment
  }
  private let measure: Measure
  private var target: Target?
  private var previous: ComposeFlowMeasurement?
  private var worker: Task<Void, Never>?
  private var workerID: UUID?

  public init(measure: @escaping Measure = { snapshot, environment, previous in
    try ComposeFlowMeasurement.measure(snapshot, environment: environment, reusing: previous)
  }) { self.measure = measure }
  deinit { worker?.cancel() }

  /// A missing snapshot withholds the public generation while retaining one
  /// same-document geometry candidate. Hide/disconnect/source replacement
  /// must use reset to release the candidate as well.
  public func update(snapshot: ComposeDocumentSnapshot?, environment: ComposeFlowMeasurement.Environment?) {
    if let snapshot, let environment, let target,
       target.snapshot.baseline.id == snapshot.baseline.id,
       target.snapshot.baseline.digest == snapshot.baseline.digest,
       target.snapshot.document.owner == snapshot.document.owner,
       target.snapshot.document.selectionRevision == snapshot.document.selectionRevision,
       target.snapshot.document.decorationRevision == snapshot.document.decorationRevision,
       target.environment.isEquivalent(to: environment) { return }
    if snapshot == nil, target == nil, flow == nil { return }
    generation = UUID(); flow = nil; worker?.cancel()
    if let snapshot, let environment {
      target = .init(snapshot: snapshot, environment: environment)
      if let previous, !previous.document.owner.isSameDocument(as: snapshot.document.owner) { self.previous = nil }
      status = .waiting; beginIfPossible()
    } else { target = nil; status = .idle }
    onChange?()
  }

  public func reset() {
    generation = UUID(); target = nil; previous = nil; flow = nil; status = .idle
    worker?.cancel()
    // Keep the slot until the actual worker terminates; IDs can repeat after
    // reconnect, and a cancelled task can still return a result.
    onChange?()
  }

  public func retry() {
    guard status == .failed, target != nil else { return }
    generation = UUID(); status = .waiting; beginIfPossible(); onChange?()
  }

  private func beginIfPossible() {
    guard worker == nil, let target, status != .failed else { return }
    let id = UUID(), generation = generation, measure = measure, previous = previous
    workerID = id; status = .measuring
    let work = Task.detached(priority: .userInitiated) {
      try await measure(target.snapshot, target.environment, previous)
    }
    worker = Task { [weak self] in
      let result = await withTaskCancellationHandler(operation: { await work.result }, onCancel: { work.cancel() })
      self?.finished(id: id, generation: generation, target: target, result: result)
    }
  }

  private func finished(id: UUID, generation: UUID, target: Target, result: Result<ComposeFlowMeasurement, Error>) {
    guard workerID == id else { return }
    worker = nil; workerID = nil
    guard self.generation == generation, let current = self.target,
          current.snapshot.baseline.id == target.snapshot.baseline.id else {
      beginIfPossible(); onChange?(); return
    }
    switch result {
    case .success(let value):
      guard value.document === current.snapshot.document,
            value.environment.isEquivalent(to: current.environment) else {
        status = .failed; onChange?(); return
      }
      previous = value; flow = value; status = .ready
    case .failure: status = .failed
    }
    onChange?()
  }
}
