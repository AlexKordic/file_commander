import Foundation

/// Complete, parser-owned source navigation. Search covers full parsed labels,
/// including offscreen text; these labels are never interpreted as Markdown.
public struct ComposeSemanticIndex: Sendable {
  public struct Entry: Sendable {
    public let source: Range<Int>
    /// Heading levels 1–6, link 16, image 17.
    public let kind: UInt32
    public let label: String
  }
  public let owner: WireComposeIndexOwner
  public let entries: [Entry]
  private let searchLabels: [Data]
  private let byKind: [UInt32: [Int]]
  public enum Failure: Error { case invalidChunk, metadataBudget, searchBudget }
  public static let maximumEntries = 262_144
  public static let maximumLabelBytes = 32 << 20
  private static let maximumSearchBytes = 64 << 20

  /// Run off the UI thread. Folding all labels here keeps a rotor query from
  /// repeatedly normalizing a multi-megabyte heading on the main thread.
  public init(owner: WireComposeIndexOwner, entries: [Entry]) throws {
    self.owner = owner; self.entries = entries
    var labels: [Data] = [], kinds: [UInt32: [Int]] = [:], bytes = 0
    guard entries.count <= Self.maximumEntries else { throw Failure.metadataBudget }
    for (index, entry) in entries.enumerated() {
      try Task.checkCancellation()
      let label = try Self.fold(entry.label, maximumBytes: Self.maximumSearchBytes - bytes)
      guard label.count <= Self.maximumSearchBytes - bytes else { throw Failure.searchBudget }
      bytes += label.count; labels.append(label)
      kinds[entry.kind, default: []].append(index)
      if (1...6).contains(entry.kind) { kinds[0, default: []].append(index) }
    }
    searchLabels = labels; byKind = kinds
  }

  /// CFStringFold changes a mutable string in place. Repeated accent removals
  /// can repeatedly move the remaining multi-megabyte suffix. Fold bounded
  /// runs instead, keeping every following Grapheme_Extend with its base so a
  /// boundary cannot turn an accent into a standalone character. An unusually
  /// large combining sequence stays whole; no label or search tail is cut off.
  static func fold(_ text: String, maximumBytes: Int = maximumSearchBytes, runBytes: Int = 16 << 10) throws -> Data {
    let scalars = text.unicodeScalars
    var start = scalars.startIndex, at = start, bytes = 0, result = Data()
    let locale = Locale(identifier: "en_US_POSIX")
    func append(_ end: String.UnicodeScalarView.Index) throws {
      try Task.checkCancellation()
      let folded = String(scalars[start..<end]).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
      guard folded.utf8.count <= maximumBytes - result.count else { throw Failure.searchBudget }
      result.append(contentsOf: folded.utf8)
    }
    while at < scalars.endIndex {
      let scalar = scalars[at]
      if bytes >= runBytes && !scalar.properties.isGraphemeExtend {
        try append(at); start = at; bytes = 0
      }
      bytes += scalar.value < 0x80 ? 1 : (scalar.value < 0x800 ? 2 : (scalar.value < 0x10000 ? 3 : 4))
      scalars.formIndex(after: &at)
    }
    try append(at)
    return result
  }

  /// Kind 0 means all heading levels. A nil current item includes the first
  /// (or last) matching item. A retained item is addressed by its source ordinal.
  public func find(kind: UInt32, after current: Int?, forward: Bool, filter: String = "") -> Int? {
    guard let candidates = byKind[kind], !candidates.isEmpty else { return nil }
    guard let needle = try? Self.fold(filter) else { return nil }
    var low = 0, high = candidates.count
    if let current {
      while low < high {
        let mid = low + (high - low) / 2
        if candidates[mid] < current || (forward && candidates[mid] == current) { low = mid + 1 }
        else { high = mid }
      }
    }
    var at = current == nil ? (forward ? 0 : candidates.count - 1) : (forward ? low : low - 1)
    while at >= 0 && at < candidates.count {
      let ordinal = candidates[at]
      if needle.isEmpty || searchLabels[ordinal].range(of: needle) != nil { return ordinal }
      at += forward ? 1 : -1
    }
    return nil
  }
}

/// One complete generation for the current source owner. Subscription begins
/// only when assistive navigation is queried, and source/focus/connection
/// changes retire both transport state and prepared search results.
@MainActor
public final class ComposeSemanticController {
  public enum Status: Equatable { case idle, loading, ready, failed(String) }
  public private(set) var status: Status = .idle
  public private(set) var generation = UUID()
  public private(set) var index: ComposeSemanticIndex?
  public private(set) var owner: WireComposeIndexOwner?
  public var onChange: (() -> Void)?
  private let send: (WireComposeIndexRequest) -> Void
  private var receiver: ComposeSemanticReceiver?
  private var nextID: UInt64 = 0
  private var activated = false
  private var building: Task<Void, Never>?

  public init(send: @escaping (WireComposeIndexRequest) -> Void) { self.send = send }
  deinit { building?.cancel() }

  public func update(owner: WireComposeIndexOwner?, supported: Bool) {
    let next = supported ? owner : nil
    guard next != self.owner else { return }
    retire(); self.owner = next
    if activated { begin() }
    onChange?()
  }

  public func activate() {
    guard !activated else { return }
    activated = true; begin(); onChange?()
  }

  public func reset() {
    retire(); owner = nil; activated = false; onChange?()
  }

  private func retire() {
    if let receiver { send(.with { $0.id = receiver.id; $0.cancel = true }) }
    receiver = nil; building?.cancel(); building = nil
    generation = UUID(); index = nil; status = .idle
  }

  private func begin() {
    guard let owner, owner.epoch != 0 else { return }
    nextID += 1
    receiver = .init(id: nextID, owner: owner); status = .loading
    send(.with { $0.id = nextID; $0.owner = owner })
  }

  public func receive(_ chunk: WireComposeIndexChunk) {
    guard var receiver, chunk.id == receiver.id else { return }
    // Move the accumulator out before mutation. Keeping another struct copy
    // here would copy all prior labels on every chunk through copy-on-write.
    self.receiver = nil
    do {
      let entries = try receiver.receive(chunk)
      send(.with { $0.id = chunk.id; $0.appliedSequence = chunk.sequence })
      self.receiver = entries == nil ? receiver : nil
      guard let entries else { return }
      let generation = generation, owner = receiver.owner
      // Keep expensive Unicode work away from scene drawing and source input.
      building = Task { [weak self] in
        let work = Task.detached(priority: .userInitiated) { try ComposeSemanticIndex(owner: owner, entries: entries) }
        let result = await withTaskCancellationHandler(operation: { await work.result }, onCancel: { work.cancel() })
        guard let self, !Task.isCancelled, self.generation == generation else { return }
        self.building = nil
        switch result {
        case .success(let index): self.index = index; self.status = .ready
        case .failure: self.status = .failed("Document navigation could not prepare complete search results.")
        }
        self.onChange?()
      }
    } catch {
      send(.with { $0.id = chunk.id; $0.cancel = true }); self.receiver = nil
      index = nil
      status = .failed(chunk.error.isEmpty ? "Document navigation could not load a complete index." : String(chunk.error.prefix(512)))
      onChange?()
    }
  }
}

/// Assembles one explicitly complete generation. A malformed or over-budget
/// inventory cannot leave a seemingly complete prefix available for navigation.
public struct ComposeSemanticReceiver {
  public let id: UInt64
  public let owner: WireComposeIndexOwner
  private var sequence: UInt64 = 0
  private var totals: (entries: UInt64, bytes: UInt64)?
  private var entries: [ComposeSemanticIndex.Entry] = []
  private var partial: WireComposeIndexPart?
  private var label = Data()
  private var labelBytes = 0
  private var finished = false

  public init(id: UInt64, owner: WireComposeIndexOwner) { self.id = id; self.owner = owner }

  /// Returns all entries only at completion. The caller acknowledges this
  /// chunk's sequence on the independent index channel after validation.
  public mutating func receive(_ chunk: WireComposeIndexChunk) throws -> [ComposeSemanticIndex.Entry]? {
    do { return try accept(chunk) }
    catch { entries.removeAll(); partial = nil; label = Data(); finished = true; throw error }
  }

  private mutating func accept(_ chunk: WireComposeIndexChunk) throws -> [ComposeSemanticIndex.Entry]? {
    typealias Failure = ComposeSemanticIndex.Failure
    guard !finished, id != 0, chunk.id == id, chunk.hasOwner, chunk.owner == owner,
          chunk.sequence == sequence, chunk.error.isEmpty, owner.epoch != 0,
          owner.length <= UInt64(Int.max), chunk.parts.count <= 256,
          chunk.totalEntries <= UInt64(ComposeSemanticIndex.maximumEntries),
          chunk.labelBytes <= UInt64(ComposeSemanticIndex.maximumLabelBytes) else { throw Failure.invalidChunk }
    if let totals {
      guard totals.entries == chunk.totalEntries, totals.bytes == chunk.labelBytes else { throw Failure.invalidChunk }
    } else { totals = (chunk.totalEntries, chunk.labelBytes) }
    var chunkBytes = 0
    for part in chunk.parts {
      let bytes = part.label.utf8.count
      guard part.index == UInt64(entries.count), part.index < chunk.totalEntries,
            part.start < part.end, part.end <= owner.length,
            (1...6).contains(part.kind) || part.kind == 16 || part.kind == 17,
            part.labelLength > 0, part.labelLength <= chunk.labelBytes,
            bytes > 0, bytes <= 16 << 10,
            bytes <= (64 << 10) - chunkBytes,
            bytes <= Int(chunk.labelBytes) - labelBytes,
            part.labelOffset == UInt64(label.count),
            part.labelOffset <= part.labelLength,
            UInt64(bytes) <= part.labelLength - part.labelOffset else { throw Failure.invalidChunk }
      if let partial {
        guard (partial.start, partial.end, partial.kind, partial.labelLength) ==
              (part.start, part.end, part.kind, part.labelLength) else { throw Failure.invalidChunk }
      } else {
        guard part.labelOffset == 0,
              entries.last.map({ UInt64($0.source.lowerBound) <= part.start }) ?? true else { throw Failure.invalidChunk }
        partial = part
      }
      label.append(contentsOf: part.label.utf8); labelBytes += bytes; chunkBytes += bytes
      guard part.labelDone == (label.count == Int(part.labelLength)) else { throw Failure.invalidChunk }
      if part.labelDone {
        entries.append(.init(source: Int(part.start)..<Int(part.end), kind: part.kind, label: String(decoding: label, as: UTF8.self)))
        label = Data(); partial = nil
      }
    }
    guard !chunk.parts.isEmpty || (chunk.done && chunk.totalEntries == 0 && chunk.labelBytes == 0) else { throw Failure.invalidChunk }
    if chunk.done {
      guard partial == nil, entries.count == Int(chunk.totalEntries), labelBytes == Int(chunk.labelBytes) else { throw Failure.invalidChunk }
      finished = true
      let complete = entries; entries = []
      return complete
    }
    guard entries.count < Int(chunk.totalEntries) else { throw Failure.invalidChunk }
    sequence += 1
    return nil
  }
}
