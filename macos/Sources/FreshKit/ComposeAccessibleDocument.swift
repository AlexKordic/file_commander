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
    guard owns(window: window, pane: pane), let part = ComposeProjection(pane.compose) else { return nil }
    return projection.certifiedRange(of: part)
  }
}
