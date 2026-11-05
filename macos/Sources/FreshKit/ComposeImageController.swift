import Foundation

/// Visible-image scheduling and decoded-image cache for one scene connection.
/// Fresh resolves resources; this controller never opens a local file or URL.
@MainActor
public final class ComposeImageController {
  public struct Demand: Sendable {
    public var scope: WireComposeScope
    public var image: WireComposeImage
    public var authority, document: UInt64
    public var maximumDimension: Int
    public init(scope: WireComposeScope, image: WireComposeImage, authority: UInt64, document: UInt64, maximumDimension: Int) {
      self.scope = scope; self.image = image; self.authority = authority; self.document = document
      self.maximumDimension = min(2048, max(1, maximumDimension))
    }
    fileprivate var key: Key { .init(window: scope.windowID, buffer: scope.buffer, authority: authority, document: document, target: image.target) }
  }
  fileprivate struct Key: Hashable {
    var window, buffer, authority, document: UInt64
    var target: String
  }
  private struct Work {
    var demand: Demand
    var request: WireComposeAssetRequest
    var started: TimeInterval
  }
  private struct Decode {
    var demand: Demand
    var cancelled: Bool
    var version, digest: Data
  }
  private struct Cached {
    var state: ComposeImageState
    var dimension: Int
    var used: UInt64
    var retry: TimeInterval
    var version = Data(), digest = Data()
    var verified: TimeInterval = 0
    var attemptDimension = 0
    var cost: Int { state.asset?.cost ?? 0 }
  }

  public var onChange: (() -> Void)?
  private let send: (WireComposeAssetRequest) -> Void
  private let decode: @Sendable (Data, Int) throws -> ComposeImageAsset
  private let maximumCacheBytes: Int
  private let refreshInterval: TimeInterval
  private let now: () -> TimeInterval
  private let queue: OperationQueue
  private var receiver = ComposeAssetReceiver()
  private var nextID: UInt64 = 0
  private var clock: UInt64 = 0
  private var demands: [Demand] = []
  private var work: [UInt64: Work] = [:]
  private var decoding: [UUID: Decode] = [:]
  private var cache: [Key: Cached] = [:]
  private var deferred: Set<Key> = []
  private var timer: Timer?
  private var pumping = false
  private var revalidationRequested = false

  public init(maximumCacheBytes: Int = 64 << 20,
              refreshInterval: TimeInterval = 5,
              now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
              decode: @escaping @Sendable (Data, Int) throws -> ComposeImageAsset = { try ComposeImageAsset.decode($0, maximumDimension: $1) },
              send: @escaping (WireComposeAssetRequest) -> Void) {
    self.maximumCacheBytes = max(0, maximumCacheBytes)
    self.refreshInterval = refreshInterval.isFinite ? min(60, max(1, refreshInterval)) : 5
    self.now = now
    self.decode = decode; self.send = send
    queue = OperationQueue(); queue.name = "fc.compose.image-decode"; queue.maxConcurrentOperationCount = 2
    queue.qualityOfService = .userInitiated
  }

  public var outstandingCount: Int { work.count + decoding.count }
  public var decodedBytes: Int { cache.values.reduce(0) { $0 + $1.cost } }

  deinit { timer?.invalidate() }

  public func state(scope: WireComposeScope, image: WireComposeImage, authority: UInt64, document: UInt64) -> ComposeImageState {
    let key = Key(window: scope.windowID, buffer: scope.buffer, authority: authority, document: document, target: image.target)
    return cache[key]?.state ?? (deferred.contains(key) ? .failed("Preview memory limit reached") : .loading)
  }

  /// Order demands nearest the viewport first. Duplicate references share a
  /// resource read/cache entry while source ranges remain on each attachment.
  public func update(_ wanted: [Demand], revalidate: Bool = false) {
    var unique: [Demand] = [], indexes: [Key: Int] = [:]
    for demand in wanted {
      if let index = indexes[demand.key] {
        unique[index].maximumDimension = max(unique[index].maximumDimension, demand.maximumDimension)
      } else {
        indexes[demand.key] = unique.count; unique.append(demand)
      }
    }
    if unique.map(\.key) != demands.map(\.key) { deferred.removeAll() }
    demands = unique
    revalidationRequested = revalidationRequested || revalidate
    if revalidationRequested && !demands.isEmpty {
      for demand in demands { cache[demand.key]?.retry = 0 }
      revalidationRequested = false
    }
    clock &+= 1
    for demand in demands { if cache[demand.key] != nil { cache[demand.key]?.used = clock } }
    func current(_ demand: Demand) -> Bool {
      // Keep an in-flight reference while it is visible in any split. The
      // deduplicated representative can change as viewport ordering changes.
      wanted.contains { $0.key == demand.key && $0.scope.bufferRevision == demand.scope.bufferRevision
        && $0.scope.leaf == demand.scope.leaf && $0.image.start == demand.image.start && $0.image.end == demand.image.end }
    }
    for (id, pending) in work where !current(pending.demand) {
      receiver.cancel(id); work.removeValue(forKey: id)
      send(.with { $0.id = id; $0.cancel = true })
    }
    for (token, pending) in decoding where !current(pending.demand) { decoding[token]?.cancelled = true }
    trimCache()
    pump()
  }

  public func receive(_ chunks: [WireComposeAssetChunk]) {
    for chunk in chunks {
      guard let event = receiver.receive(chunk), let pending = work.removeValue(forKey: chunk.id) else { continue }
      switch event {
      case .failed(_, let message, let retryable):
        failed(pending.demand, message: message, retryable: retryable)
      case .unchanged(_, let version, let digest):
        if var cached = cache[pending.demand.key], cached.digest == digest, digest == pending.request.knownDigest {
          let wasStale: Bool
          if case .stale(let asset, _) = cached.state { cached.state = .ready(asset); wasStale = true } else { wasStale = false }
          cached.version = version; cached.retry = now() + refreshInterval; cached.used = clock
          cached.attemptDimension = 0
          if pending.request.knownVersion.isEmpty || version != pending.request.knownVersion { cached.verified = now() }
          cache[pending.demand.key] = cached
          if wasStale { onChange?() }
        }
        // If eviction discarded the decoded resource, the next pump requests
        // bytes again (or retains the bounded-cache fallback).
      case .loaded(_, let bytes, let version, let digest):
        let token = UUID(), demand = pending.demand, decode = self.decode
        decoding[token] = .init(demand: demand, cancelled: false, version: version, digest: digest)
        queue.addOperation { [weak self] in
          let result = Result { try decode(bytes, demand.maximumDimension) }
          DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.decoded(token, result: result) }
          }
        }
      }
    }
    trimCache()
    pump()
  }

  /// A fresh socket gets a new id namespace. Already running decodes retain
  /// their slots until they finish, so repeated reconnects cannot queue an
  /// unbounded number of compressed images behind the two decode workers.
  public func reset() {
    update([]); receiver.reset(); nextID = 0; cache.removeAll(); deferred.removeAll(); revalidationRequested = false
  }

  /// Explicit refresh bypasses the stat shortcut, retaining both the existing
  /// preview and digest deduplication while Fresh checks actual content.
  public func reloadVisible() {
    let wanted = demands
    update([])
    for demand in wanted {
      if cache[demand.key]?.state.asset == nil { cache[demand.key]?.digest = Data() }
      cache[demand.key]?.version = Data(); cache[demand.key]?.retry = 0
    }
    deferred.removeAll(); update(wanted); onChange?()
  }

  private func decoded(_ token: UUID, result: Result<ComposeImageAsset, Error>) {
    guard let pending = decoding.removeValue(forKey: token) else { return }
    if !pending.cancelled {
      var notify = true
      switch result {
      case .success(let asset):
        cache[pending.demand.key] = .init(state: .ready(asset), dimension: pending.demand.maximumDimension, used: clock,
          retry: now() + refreshInterval, version: pending.version, digest: pending.digest, verified: now())
      case .failure(let error):
        let permanent: Bool
        if let error = error as? ComposeImageAsset.Failure {
          switch error { case .invalid, .unsupported, .dimensions: permanent = true; case .decode: permanent = false }
        } else { permanent = false }
        if permanent {
          cache[pending.demand.key] = .init(state: .failed(error.localizedDescription), dimension: pending.demand.maximumDimension, used: clock,
            retry: now() + refreshInterval, version: pending.version, digest: pending.digest, verified: now())
        } else { failed(pending.demand, message: error.localizedDescription, retryable: true); notify = false }
      }
      trimCache()
      if notify { onChange?() }
    }
    pump()
  }

  private func pump() {
    guard !pumping else { return }
    pumping = true
    defer { pumping = false; updateTimer() }
    let now = self.now()
    for demand in demands {
      if deferred.contains(demand.key) { continue }
      if work.values.contains(where: { $0.demand.key == demand.key }) || decoding.values.contains(where: { !$0.cancelled && $0.demand.key == demand.key }) { continue }
      if let cached = cache[demand.key] {
        if cached.state.asset == nil || cached.dimension >= demand.maximumDimension || cached.attemptDimension >= demand.maximumDimension {
          if now < cached.retry { continue }
        }
      }
      guard outstandingCount < ComposeAssetReceiver.maximumRequests else { break }
      nextID += 1
      let request = WireComposeAssetRequest.with {
        $0.id = nextID; $0.scope = demand.scope; $0.start = demand.image.start; $0.end = demand.image.end
        $0.authority = demand.authority; $0.document = demand.document
        if let cached = cache[demand.key], cached.digest.count == 32,
           cached.state.asset == nil || cached.dimension >= demand.maximumDimension {
          // Periodic content validation also covers filesystems that cache
          // attributes or have coarse timestamps. Fresh hashes on the host.
          if now - cached.verified < max(60, refreshInterval) { $0.knownVersion = cached.version }
          $0.knownDigest = cached.digest
        }
      }
      guard receiver.register(request) else { break }
      // Reserve the next attempt before sending. Source edits may cancel this
      // request, but cannot turn every typed character into another SSH read.
      if cache[demand.key] == nil {
        cache[demand.key] = .init(state: .loading, dimension: 0, used: clock, retry: now + refreshInterval)
      }
      cache[demand.key]?.retry = now + refreshInterval
      cache[demand.key]?.attemptDimension = demand.maximumDimension
      work[request.id] = .init(demand: demand, request: request, started: now)
      send(request)
    }
  }

  private func trimCache() {
    let visible = Set(demands.map(\.key))
    while decodedBytes > maximumCacheBytes || cache.count > 128 {
      guard let victim = cache.min(by: { a, b in
        let av = visible.contains(a.key), bv = visible.contains(b.key)
        return av == bv ? a.value.used < b.value.used : !av
      })?.key else { break }
      cache.removeValue(forKey: victim)
      if visible.contains(victim) { deferred.insert(victim) }
    }
  }

  private func updateTimer() {
    let retry = demands.contains { cache[$0.key]?.retry.isFinite == true }
    if demands.isEmpty || work.isEmpty && !retry { timer?.invalidate(); timer = nil; return }
    guard timer == nil else { return }
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
  }

  private func tick() {
    let now = self.now()
    for (id, pending) in work where now - pending.started >= 15 {
      work.removeValue(forKey: id); receiver.cancel(id)
      send(.with { $0.id = id; $0.cancel = true })
      failed(pending.demand, message: "Image load timed out", retryable: true)
    }
    pump()
  }

  private func failed(_ demand: Demand, message: String, retryable: Bool) {
    if retryable, var cached = cache[demand.key], let asset = cached.state.asset {
      cached.state = .stale(asset, message); cached.retry = now() + refreshInterval; cached.used = clock
      cache[demand.key] = cached
    } else {
      cache[demand.key] = .init(state: .failed(message), dimension: 0, used: clock, retry: now() + refreshInterval)
    }
    trimCache()
    onChange?()
  }
}
