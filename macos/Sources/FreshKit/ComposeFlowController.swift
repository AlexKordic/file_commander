import Foundation

/// A demanded complete text/geometry generation. One worker lives at a time,
/// even when cancellation or a connection reset cannot stop it immediately.
/// Retained logical text keeps its original owner. Geometry can be reused only
/// after publication binds it to the current logical presentation.
@MainActor
public final class ComposeFlowController {
  public enum Status: Equatable { case idle, waiting, measuring, ready, failed }
  public private(set) var status: Status = .idle
  public private(set) var generation = UUID()
  public private(set) var flow: ComposeFlowMeasurement?
  /// Logical text is published before shaping and survives same-document
  /// geometry/source refreshes with its original owner, never a cropped value.
  public private(set) var presentation: ComposeDocumentPresentation?
  public var onChange: (() -> Void)?

  public typealias Measure = @Sendable (ComposeDocumentSnapshot, ComposeFlowMeasurement.Environment,
    ComposeFlowMeasurement?, ComposeDocumentOverlay?, ComposeDocumentPresentation) async throws -> ComposeFlowMeasurement
  private struct Target {
    let snapshot: ComposeDocumentSnapshot
    let environment: ComposeFlowMeasurement.Environment
    let overlay: ComposeDocumentOverlay?
    let prepared: ComposeDocumentPresentation?
  }
  private let measure: Measure
  private var target: Target?
  private var previous: ComposeFlowMeasurement?
  private var worker: Task<Void, Never>?
  private var workerID: UUID?

  public init(measure: @escaping Measure = { snapshot, environment, previous, overlay, presentation in
    try ComposeFlowMeasurement.measure(snapshot, environment: environment, overlay: overlay, reusing: previous, presentation: presentation)
  }) { self.measure = measure }
  deinit { worker?.cancel() }

  /// A missing snapshot withholds geometry while retaining the logical value
  /// and one same-document geometry candidate. Hide/disconnect/source replacement
  /// must use reset to release these as well.
  public func update(snapshot: ComposeDocumentSnapshot?, environment: ComposeFlowMeasurement.Environment?, overlay: ComposeDocumentOverlay? = nil) {
    func sameOverlay(_ old: ComposeDocumentOverlay?) -> Bool {
      switch (old,overlay) {
      case (nil,nil): return true
      case (let a?,let b?): return a.isEquivalent(to:b)
      default: return false
      }
    }
    if let snapshot, let environment, let target,
       target.snapshot.baseline.id == snapshot.baseline.id,
       target.snapshot.baseline.digest == snapshot.baseline.digest,
       target.snapshot.document.owner == snapshot.document.owner,
       target.snapshot.document.selectionRevision == snapshot.document.selectionRevision,
       target.snapshot.document.decorationRevision == snapshot.document.decorationRevision,
       target.environment.isEquivalent(to: environment), sameOverlay(target.overlay) { return }
    if snapshot == nil, target == nil, flow == nil { return }
    generation = UUID(); flow = nil; worker?.cancel()
    if let snapshot, let environment {
      let prepared = presentation?.updatingSelection(snapshot, overlay: overlay)
      target = .init(snapshot: snapshot, environment: environment, overlay: overlay, prepared: prepared)
      if let previous, !previous.document.owner.isSameDocument(as: snapshot.document.owner) { self.previous = nil }
      if let presentation, !presentation.document.owner.isSameDocument(as: snapshot.document.owner) { self.presentation = nil }
      if let prepared { presentation = prepared }
      status = .waiting; beginIfPossible()
    } else { target = nil; status = .idle }
    onChange?()
  }

  public func reset() {
    generation = UUID(); target = nil; previous = nil; flow = nil; presentation = nil; status = .idle
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
    let work = Task.detached(priority: .userInitiated) { [weak self] in
      try Task.checkCancellation()
      guard let presentation = target.prepared ?? ComposeDocumentPresentation(target.snapshot, overlay: target.overlay) else {
        throw ComposeFlowMeasurement.Failure.unavailable
      }
      await self?.prepared(presentation, generation: generation)
      try Task.checkCancellation()
      return try await measure(target.snapshot, target.environment, previous, target.overlay, presentation)
    }
    worker = Task { [weak self] in
      let result = await withTaskCancellationHandler(operation: { await work.result }, onCancel: { work.cancel() })
      self?.finished(id: id, generation: generation, target: target, result: result)
    }
  }

  private func prepared(_ value: ComposeDocumentPresentation, generation: UUID) {
    guard self.generation == generation, let target,
          value.document === target.snapshot.document, value.overlay?.id == target.overlay?.id else { return }
    presentation = value; onChange?()
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
            value.environment.isEquivalent(to: current.environment), value.presentation === presentation else {
        status = .failed; onChange?(); return
      }
      previous = value; flow = value; status = .ready
    case .failure: status = .failed
    }
    onChange?()
  }
}
