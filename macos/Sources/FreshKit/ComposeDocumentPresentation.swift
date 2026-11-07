import Foundation

/// A complete logical value, including local drafts, over an unchanged Fresh
/// baseline. Layout can arrive later without changing this coordinate space.
public final class ComposeDocumentPresentation: Sendable {
  public enum Location: Equatable, Sendable {
    case source(Int)
    case draft(region: UInt64, offsetUTF16: Int)
  }
  public struct Endpoint: Equatable, Sendable {
    public let presentation: UUID
    public let location: Location
  }
  public let id = UUID()
  public let document: ComposeAccessibleDocument
  public let overlay: ComposeDocumentOverlay?
  public let projection: ComposeProjection
  public let selectedRanges: [NSRange]?
  let plan: ComposeProjectionPlan
  public struct ImageRange: Sendable {
    public let source: Range<Int>
    public let range: NSRange
  }
  final class ImageInventory: Sendable {
    let indices: [Range<Int>: Int]
    let rendered: [ImageRange]
    init(_ images: [WireComposeImage], projection: ComposeProjection) {
      var indices: [Range<Int>: Int] = [:]
      var rendered: [ImageRange] = []
      indices.reserveCapacity(images.count)
      for (index, image) in images.enumerated() {
        let source = Int(image.start)..<Int(image.end)
        if indices[source] == nil { indices[source] = index }
        if image.rendered, let start = projection.utf16Position(for: source.lowerBound),
           let end = projection.utf16Position(for: source.upperBound, affinity: .upstream), start < end {
          rendered.append(.init(source: source, range: NSRange(location: start, length: end - start)))
        }
      }
      self.indices = indices
      self.rendered = rendered.sorted { $0.range.location < $1.range.location }
    }
  }
  private let imageInventory: ImageInventory
  private let selectionOverride: Bool
  public var text: String { projection.text }
  public var characterCount: Int { projection.textIndex.utf16Count }
  public var images: [WireComposeImage] { plan.images }

  public convenience init?(_ snapshot: ComposeDocumentSnapshot, overlay: ComposeDocumentOverlay? = nil) {
    guard overlay?.owns(snapshot.document) ?? true,
          let prepared = Self.prepare(snapshot, overlay: overlay) else { return nil }
    self.init(snapshot, overlay: overlay, prepared: prepared)
  }

  init(_ snapshot: ComposeDocumentSnapshot, overlay: ComposeDocumentOverlay?, prepared: ComposeProjectionPlan,
       imageInventory: ImageInventory? = nil) {
    document = snapshot.document; self.overlay = overlay; plan = prepared; projection = prepared.projection
    self.imageInventory = imageInventory ?? ImageInventory(prepared.images, projection: prepared.projection)
    selectionOverride = false
    selectedRanges = Self.selections(snapshot, overlay: overlay, plan: prepared)
  }

  private init(selecting previous: ComposeDocumentPresentation, ranges: [NSRange]) {
    document = previous.document; overlay = previous.overlay; projection = previous.projection; plan = previous.plan
    imageInventory = previous.imageInventory; selectedRanges = ranges; selectionOverride = true
  }

  public func selecting(_ ranges: [NSRange]) -> ComposeDocumentPresentation? {
    guard !ranges.isEmpty, ranges.count <= 1024, ranges.allSatisfy(contains) else { return nil }
    let sorted = ranges.sorted { ($0.location, $0.length) < ($1.location, $1.length) }
    guard zip(sorted, sorted.dropFirst()).allSatisfy({ NSMaxRange($0) <= $1.location && $0.location != $1.location }) else { return nil }
    return .init(selecting: self, ranges: ranges)
  }

  func sharesLayout(with other: ComposeDocumentPresentation) -> Bool {
    document === other.document && imageInventory === other.imageInventory
  }

  private static func prepare(_ snapshot: ComposeDocumentSnapshot, overlay: ComposeDocumentOverlay?) -> ComposeProjectionPlan? {
    let composition = overlay?.composition?.restore(), insertion = overlay?.insertion?.restore()
    guard overlay?.composition == nil || composition != nil, overlay?.insertion == nil || insertion != nil else { return nil }
    return ComposeProjectionPlan(pane: snapshot.pane, composition: composition, virtualInsertion: insertion,
      original: snapshot.document.projection)
  }

  public func string(for range: NSRange) -> String? {
    guard projection.textIndex.bytes(for: range) != nil else { return nil }
    return (text as NSString).substring(with: range)
  }

  public func contains(_ range: NSRange) -> Bool { projection.textIndex.bytes(for: range) != nil }

  public func image(source: Range<Int>) -> WireComposeImage? {
    imageInventory.indices[source].map { plan.images[$0] }
  }

  public func imageRanges(intersecting range: NSRange) -> ArraySlice<ImageRange> {
    let images = imageInventory.rendered
    guard contains(range), range.length > 0 else { return images[0..<0] }
    var low = 0, high = images.count
    while low < high {
      let mid = low + (high - low) / 2
      if NSMaxRange(images[mid].range) <= range.location { low = mid + 1 } else { high = mid }
    }
    let first = low, end = NSMaxRange(range)
    high = images.count
    while low < high {
      let mid = low + (high - low) / 2
      if images[mid].range.location < end { low = mid + 1 } else { high = mid }
    }
    return images[first..<low]
  }

  /// Selection-only local changes need no full text preparation or shaping.
  /// Keep the exact verified baseline and shared immutable projection plan.
  func updatingSelection(_ snapshot: ComposeDocumentSnapshot, overlay next: ComposeDocumentOverlay?) -> ComposeDocumentPresentation? {
    guard document === snapshot.document, next?.owns(document) ?? true else { return nil }
    switch (overlay, next) {
    case (nil, nil): if !selectionOverride { return self }
    case (let a?, let b?) where a.id == b.id: if !selectionOverride { return self }
    case (let a?, let b?) where a.isEquivalent(to: b): break
    case (nil, let b?) where b.sourceComposition == nil: break
    case (let a?, nil) where a.sourceComposition == nil: break
    case (let a?, let b?) where a.hasSameLayout(as: b): break
    default: return nil
    }
    return .init(snapshot, overlay: next, prepared: plan, imageInventory: imageInventory)
  }

  public func character(at index: Int) -> NSRange? {
    guard index >= 0, index <= characterCount else { return nil }
    return index == characterCount ? NSRange(location: index, length: 0)
      : (text as NSString).rangeOfComposedCharacterSequence(at: index)
  }

  public func displayedRange(for source: Range<Int>) -> NSRange? {
    guard let start = projection.utf16Position(for: source.lowerBound) else { return nil }
    if source.isEmpty { return NSRange(location: start, length: 0) }
    guard let end = projection.utf16Position(for: source.upperBound, affinity: .upstream), start <= end else { return nil }
    return NSRange(location: start, length: end-start)
  }

  /// A draft position is not silently widened to its original source range.
  /// Endpoints must be resolved by a predecessor receipt before a wire action.
  /// IDs here are presentation region keys, not Fresh cursor identities.
  public func endpoint(atUTF16 index: Int, affinity: ComposeProjection.Affinity = .downstream) -> Endpoint? {
    guard projection.textIndex.byte(forUnit: index) != nil else { return nil }
    if let source = overlay?.sourceComposition {
      let candidates = source.values.keys.sorted {
        source.values[$0]!.source.lowerBound < source.values[$1]!.source.lowerBound
      }
      for key in affinity == .upstream ? candidates : candidates.reversed() {
        let value = source.values[key]!
        guard !value.source.isEmpty || !value.text.isEmpty, let range = plan.contextRanges[key],
              range.location <= index, index <= NSMaxRange(range) else { continue }
        return .init(presentation: id, location: .draft(region: key, offsetUTF16: index-range.location))
      }
    }
    guard let byte = projection.textIndex.byte(forUnit: index),
          let source = projection.sourcePosition(at: byte, affinity: affinity) else { return nil }
    return .init(presentation: id, location: .source(source))
  }

  public func range(window: UInt64, pane: WirePane, projection part: ComposeProjection) -> NSRange? {
    guard document.owns(window: window, pane: pane) else { return nil }
    return projection.certifiedRange(of: part)
  }

  /// The local provisional raw axis used by native input, never a wire source
  /// position. Region keys stay local; the queue must find the owning genuine
  /// transaction/cursor and resolve its accepted insertion proof.
  public func provisionalPosition(of endpoint: Endpoint) -> Int? {
    guard endpoint.presentation == id, case .draft(let region,let offset) = endpoint.location,
          let source = overlay?.sourceComposition, let target = source.values[region],
          ComposeTextIndex(target.text).byte(forUnit: offset) != nil else { return nil }
    var shift = 0
    for key in source.values.keys.sorted(by: { source.values[$0]!.source.lowerBound < source.values[$1]!.source.lowerBound }) {
      let value = source.values[key]!
      if key == region { return value.original.location+shift+offset }
      shift += value.text.utf16.count-value.original.length
    }
    return nil
  }

  private static func selections(_ snapshot: ComposeDocumentSnapshot, overlay: ComposeDocumentOverlay?,
                                 plan: ComposeProjectionPlan) -> [NSRange]? {
    let cursors = overlay?.cursors ?? snapshot.pane.cursors
    guard cursors.filter(\.primary).count == 1, Set(cursors.map(\.id)).count == cursors.count else { return nil }
    let projection = plan.projection
    func source(_ byte: UInt64, affinity: ComposeProjection.Affinity) -> Int? {
      Int(exactly: byte).flatMap { projection.utf16Position(for: $0, affinity: affinity) }
    }
    let prefix = overlay?.selectionPrefix ?? overlay?.insertion?.regions
    let restored = prefix?.restore()
    func virtual(_ point: Int, byte: UInt64, raw: UInt64?) -> Int? {
      guard let prefix, let restored else { return nil }
      if let draft = restored.draftPosition(at: point), let value = prefix.values[draft.id] {
        if value.source.isEmpty && value.text.isEmpty {
          return projection.utf16Position(for: value.source.lowerBound)
        }
        // A virtual selection prefix may carry extra untouched caret markers
        // or differently keyed folded regions. Match actual source and bytes.
        if let match = overlay?.sourceComposition?.values.first(where: { _, other in
          value.source == other.source && value.original == other.original && value.text.utf8.elementsEqual(other.text.utf8)
        }), let range = plan.contextRanges[match.key] {
          let unit = range.location + draft.offset
          return projection.textIndex.byte(forUnit: unit) == nil ? nil : unit
        }
        return nil
      }
      if let byte = restored.sourcePosition(at: point) { return projection.utf16Position(for: byte) }
      // Offscreen original caret endpoints can be outside every bounded raw
      // chunk. Use Fresh's global raw coordinate only after proving that the
      // known edits transform exactly to the requested provisional position.
      guard let raw, let original = Int(exactly: raw) else { return nil }
      var shift = 0
      for key in restored.ordered {
        let value = restored.values[key]!, range = value.originalRange
        if original < range.location { break }
        if original < NSMaxRange(range) { return nil }
        shift += value.draft.length-range.length
      }
      guard original+shift == point else { return nil }
      return source(byte, affinity: .downstream)
    }
    var result: [NSRange] = []
    for cursor in cursors.sorted(by: { a,b in a.primary != b.primary ? a.primary : a.id < b.id }) {
      let start: Int?, end: Int?
      if let group = overlay?.virtualCursors ?? overlay?.insertion?.cursors {
        guard let value = group[cursor.id] else { return nil }
        let a = virtual(value.position, byte: cursor.position, raw: cursor.hasUtf16Position ? cursor.utf16Position : nil)
        let b = value.anchor.map { virtual($0, byte: cursor.hasAnchor ? cursor.anchor : cursor.position,
          raw: cursor.hasUtf16Anchor ? cursor.utf16Anchor : nil) } ?? a
        start = a.flatMap { x in b.map { min(x,$0) } }; end = a.flatMap { x in b.map { max(x,$0) } }
      } else if let value = overlay?.composition?.values[cursor.id], let range = plan.draftRanges[cursor.id] {
        start = range.location+value.selected.location; end = range.location+NSMaxRange(value.selected)
      } else {
        let anchor = cursor.hasAnchor ? cursor.anchor : cursor.position
        start = source(min(cursor.position,anchor), affinity: .downstream)
        end = source(max(cursor.position,anchor), affinity: .upstream)
        if cursor.position == anchor, let start { result.append(NSRange(location: start,length: 0)); continue }
      }
      guard let start, let end, start <= end,
            projection.textIndex.bytes(for: NSRange(location: start,length: end-start)) != nil else { return nil }
      result.append(NSRange(location: start,length: end-start))
    }
    return result
  }
}
