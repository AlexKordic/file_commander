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
  }
  private struct Cached {
    var state: ComposeImageState
    var dimension: Int
    var used: UInt64
    var retry: TimeInterval
    var cost: Int { if case .ready(let asset) = state { return asset.cost }; return 0 }
  }

  public var onChange: (() -> Void)?
  private let send: (WireComposeAssetRequest) -> Void
  private let decode: @Sendable (Data, Int) throws -> ComposeImageAsset
  private let maximumCacheBytes: Int
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

  public init(maximumCacheBytes: Int = 64 << 20,
              decode: @escaping @Sendable (Data, Int) throws -> ComposeImageAsset = { try ComposeImageAsset.decode($0, maximumDimension: $1) },
              send: @escaping (WireComposeAssetRequest) -> Void) {
    self.maximumCacheBytes = max(0, maximumCacheBytes)
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
  public func update(_ wanted: [Demand]) {
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
    clock &+= 1
    for demand in demands { if cache[demand.key] != nil { cache[demand.key]?.used = clock } }
    func current(_ demand: Demand) -> Bool {
      demands.contains { $0.key == demand.key && $0.scope.bufferRevision == demand.scope.bufferRevision }
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
      case .failed(_, let message):
        cache[pending.demand.key] = .init(state: .failed(message), dimension: 0, used: clock,
          retry: ProcessInfo.processInfo.systemUptime + 5)
        onChange?()
      case .loaded(_, let bytes):
        let token = UUID(), demand = pending.demand, decode = self.decode
        decoding[token] = .init(demand: demand, cancelled: false)
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
    update([]); receiver.reset(); nextID = 0; cache.removeAll(); deferred.removeAll()
  }

  /// Explicit refresh; automatic resource-change invalidation is qualified
  /// separately from source-buffer edits, which must not refetch every image.
  public func reloadVisible() {
    let wanted = demands
    update([])
    for demand in wanted { cache.removeValue(forKey: demand.key) }
    deferred.removeAll(); update(wanted); onChange?()
  }

  private func decoded(_ token: UUID, result: Result<ComposeImageAsset, Error>) {
    guard let pending = decoding.removeValue(forKey: token) else { return }
    if !pending.cancelled {
      let state: ComposeImageState
      switch result {
      case .success(let asset): state = .ready(asset)
      case .failure(let error): state = .failed(error.localizedDescription)
      }
      cache[pending.demand.key] = .init(state: state, dimension: pending.demand.maximumDimension, used: clock, retry: .infinity)
      trimCache()
      onChange?()
    }
    pump()
  }

  private func pump() {
    guard !pumping else { return }
    pumping = true
    defer { pumping = false; updateTimer() }
    let now = ProcessInfo.processInfo.systemUptime
    for demand in demands {
      if deferred.contains(demand.key) { continue }
      if work.values.contains(where: { $0.demand.key == demand.key }) || decoding.values.contains(where: { !$0.cancelled && $0.demand.key == demand.key }) { continue }
      if let cached = cache[demand.key] {
        if case .ready = cached.state, cached.dimension >= demand.maximumDimension { continue }
        if case .failed = cached.state, now < cached.retry { continue }
      }
      guard outstandingCount < ComposeAssetReceiver.maximumRequests else { break }
      nextID += 1
      let request = WireComposeAssetRequest.with {
        $0.id = nextID; $0.scope = demand.scope; $0.start = demand.image.start; $0.end = demand.image.end
        $0.authority = demand.authority; $0.document = demand.document
      }
      guard receiver.register(request) else { break }
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
    let now = ProcessInfo.processInfo.systemUptime
    for (id, pending) in work where now - pending.started >= 15 {
      work.removeValue(forKey: id); receiver.cancel(id)
      send(.with { $0.id = id; $0.cancel = true })
      cache[pending.demand.key] = .init(state: .failed("Image load timed out"), dimension: 0, used: clock, retry: now + 5)
      onChange?()
    }
    pump()
  }
}
