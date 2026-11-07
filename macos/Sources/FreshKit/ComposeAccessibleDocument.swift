import Foundation

/// A complete projected text value, independent of the native drawing window.
/// Fresh must supply the same conceal/replacement map as its visible Compose
/// panes. Neither raw Markdown nor a collection of observed crops is complete
/// evidence for this model. It contains no layout and never reparses Markdown.
// Every field is immutable. The private NSString is bridged from an immutable
// Swift String and never escapes; Foundation does not declare it Sendable.
public final class ComposeAccessibleDocument: @unchecked Sendable {
  public let owner: WireComposeIndexOwner
  public let selectionRevision: UInt64
  public let decorationRevision: UInt64?
  public let projection: ComposeProjection
  private let value: NSString
  public var characterCount: Int { projection.textIndex.utf16Count }
  public var text: String { projection.text }

  public init?(window: UInt64, pane: WirePane) {
    guard pane.hasBuffer, pane.hasCompose, pane.compose.projectionUsable,
          pane.compose.sourceStart == 0, pane.compose.sourceEnd == pane.compose.documentLen,
          pane.compose.hasViewport, pane.compose.viewport.epoch != 0,
          let projection = ComposeProjection(pane.compose) else { return nil }
    owner = Self.owner(window: window, pane: pane)
    selectionRevision = pane.compose.selectionRevision
    decorationRevision = pane.compose.hasDecorationRevision ? pane.compose.decorationRevision : nil
    self.projection = projection; value = projection.text as NSString
  }

  private static func owner(window: UInt64, pane: WirePane) -> WireComposeIndexOwner {
    .with {
      $0.window = window; $0.leaf = pane.leaf; $0.buffer = pane.buffer
      $0.epoch = pane.compose.viewport.epoch; $0.revision = pane.compose.bufferRevision
      $0.authority = pane.compose.assetAuthority; $0.document = pane.compose.assetDocument
      $0.length = pane.compose.documentLen
    }
  }

  public func owns(window: UInt64, pane: WirePane) -> Bool {
    pane.hasBuffer && pane.hasCompose && pane.compose.projectionUsable
      && Self.owner(window: window, pane: pane) == owner && pane.compose.selectionRevision == selectionRevision
      && (pane.compose.hasDecorationRevision ? pane.compose.decorationRevision : nil) == decorationRevision
  }

  /// A new selection/formatting generation can share its immutable scalar
  /// index only after complete literal text and every source-map segment agree.
  /// This shares data, not action or connection ownership; callers still bind
  /// publication/actions to their current coordinator generation.
  public func reusingCoordinates(window: UInt64, pane: WirePane) -> ComposeAccessibleDocument? {
    guard pane.hasBuffer, pane.hasCompose, pane.compose.projectionUsable,
          Self.owner(window: window,pane: pane) == owner,
          pane.compose.sourceStart == 0, pane.compose.sourceEnd == owner.length,
          projection.text.utf8.elementsEqual(pane.compose.text.utf8),
          pane.compose.segments.count == projection.segments.count else { return nil }
    for (wire, known) in zip(pane.compose.segments,projection.segments) {
      let kind: UInt32
      switch known.kind {case .copy: kind=0;case .hidden: kind=1;case .replacement: kind=2;case .insertion: kind=3}
      guard wire.kind == kind, wire.sourceStart == UInt64(known.source.lowerBound), wire.sourceEnd == UInt64(known.source.upperBound),
            wire.displayStart == UInt64(known.display.lowerBound), wire.displayEnd == UInt64(known.display.upperBound) else { return nil }
    }
    return .init(sharing:self,selection:pane.compose.selectionRevision,
      decoration:pane.compose.hasDecorationRevision ? pane.compose.decorationRevision : nil)
  }

  private init(sharing previous: ComposeAccessibleDocument, selection: UInt64, decoration: UInt64?) {
    owner=previous.owner;selectionRevision=selection;decorationRevision=decoration
    projection=previous.projection;value=previous.value
  }

  public func string(for range: NSRange) -> String? {
    guard projection.textIndex.bytes(for: range) != nil else { return nil }
    return value.substring(with: range)
  }

  public func character(at index: Int) -> NSRange? {
    guard index >= 0, index <= characterCount else { return nil }
    return index == characterCount ? NSRange(location: index, length: 0) : value.rangeOfComposedCharacterSequence(at: index)
  }

  public func sourceRange(for range: NSRange, insertion: Int? = nil) -> Range<Int>? {
    projection.sourceRange(forUTF16: range, insertion: insertion)
  }

  public func displayedRange(for source: Range<Int>) -> NSRange? {
    guard let start = projection.utf16Position(for: source.lowerBound) else { return nil }
    if source.isEmpty { return NSRange(location: start, length: 0) }
    guard
          let end = projection.utf16Position(for: source.upperBound, affinity: .upstream), start <= end else { return nil }
    return NSRange(location: start, length: end - start)
  }

  /// Primary first, retaining complete selections rather than clipping them to
  /// a visible crop or promoting a visible secondary when the primary is away.
  public func selectedRanges(window: UInt64, pane: WirePane) -> [NSRange]? {
    guard owns(window: window, pane: pane), pane.compose.cursors.filter(\.primary).count == 1,
          Set(pane.compose.cursors.map(\.id)).count == pane.compose.cursors.count else { return nil }
    var result: [NSRange] = []
    for cursor in pane.compose.cursors.sorted(by: { a,b in a.primary != b.primary ? a.primary : a.id < b.id }) {
      let anchor = cursor.hasAnchor ? cursor.anchor : cursor.position
      guard let start = Int(exactly: min(cursor.position, anchor)), let end = Int(exactly: max(cursor.position, anchor)),
            let range = displayedRange(for: start..<end) else { return nil }
      result.append(range)
    }
    return result
  }

  /// Certify where a drawing window belongs in this value. Matching text alone
  /// is insufficient: equal-looking replacement text can own different source.
  /// Whole atomic replacements stay whole, while copied/hidden runs can split
  /// or coalesce at real source-window boundaries.
  public func range(of window: UInt64, pane: WirePane) -> NSRange? {
    guard owns(window: window, pane: pane), let part = ComposeProjection(pane.compose),
          part.source.lowerBound >= projection.source.lowerBound,
          part.source.upperBound <= projection.source.upperBound else { return nil }
    let starts = [ComposeProjection.Affinity.upstream, .downstream].compactMap {
      projection.displayPosition(for: part.source.lowerBound, affinity: $0)
    }
    let ends = [ComposeProjection.Affinity.upstream, .downstream].compactMap {
      projection.displayPosition(for: part.source.upperBound, affinity: $0)
    }
    for start in starts {
      for end in ends where start <= end {
        let range = start..<end
        guard projection.textIndex.hasBytes(range, equalTo: part.textIndex),
              let segments = sliced(source: part.source, display: range),
              same(normalized(segments), normalized(part.segments)) else { continue }
        return projection.textIndex.units(for: range)
      }
    }
    return nil
  }

  private func sliced(source: Range<Int>, display: Range<Int>) -> [ComposeProjection.Segment]? {
    var low = 0, high = projection.segments.count
    while low < high {
      let mid = low + (high - low) / 2
      if projection.segments[mid].source.upperBound < source.lowerBound { low = mid + 1 } else { high = mid }
    }
    var result: [ComposeProjection.Segment] = []
    for segment in projection.segments[low...] {
      if segment.source.lowerBound > source.upperBound { break }
      if segment.kind == .insertion {
        if segment.display.upperBound <= display.lowerBound || segment.display.lowerBound >= display.upperBound { continue }
        guard segment.display.lowerBound >= display.lowerBound, segment.display.upperBound <= display.upperBound else { return nil }
        result.append(.init(source: segment.source, display: (segment.display.lowerBound-display.lowerBound)..<(segment.display.upperBound-display.lowerBound), kind: .insertion))
        continue
      }
      let start = max(source.lowerBound, segment.source.lowerBound), end = min(source.upperBound, segment.source.upperBound)
      guard start < end else { continue }
      let mapped: Range<Int>
      switch segment.kind {
      case .copy:
        let a = segment.display.lowerBound + start - segment.source.lowerBound
        mapped = a..<(a + end - start)
      case .hidden: mapped = segment.display
      case .replacement:
        guard start == segment.source.lowerBound, end == segment.source.upperBound else { return nil }
        mapped = segment.display
      case .insertion: return nil
      }
      guard mapped.lowerBound >= display.lowerBound, mapped.upperBound <= display.upperBound else { return nil }
      result.append(.init(source: start..<end, display: (mapped.lowerBound-display.lowerBound)..<(mapped.upperBound-display.lowerBound), kind: segment.kind))
    }
    return result
  }

  private func normalized(_ segments: [ComposeProjection.Segment]) -> [ComposeProjection.Segment] {
    var result: [ComposeProjection.Segment] = []
    for segment in segments {
      if let last = result.last, (last.kind == .copy || last.kind == .hidden), last.kind == segment.kind,
         last.source.upperBound == segment.source.lowerBound, last.display.upperBound == segment.display.lowerBound {
        result[result.count-1] = .init(source: last.source.lowerBound..<segment.source.upperBound,
          display: last.display.lowerBound..<segment.display.upperBound, kind: last.kind)
      } else { result.append(segment) }
    }
    return result
  }

  private func same(_ a: [ComposeProjection.Segment], _ b: [ComposeProjection.Segment]) -> Bool {
    a.count == b.count && zip(a,b).allSatisfy { $0.source == $1.source && $0.display == $1.display && $0.kind == $1.kind }
  }
}
