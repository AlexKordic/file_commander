import Foundation

/// Text/map preparation shared by drawing and complete provisional values.
/// Fresh supplies all Markdown semantics. This performs no shaping or I/O.
struct ComposeProjectionPlan: Sendable {
  struct Draft: Sendable { let source, display: Range<Int> }
  let base: ComposeProjection
  let projection: ComposeProjection
  let images: [WireComposeImage]
  let objects: [ComposeProjection.Object]
  let sourceDisplays: [UInt64: Range<Int>]
  let draftRanges, contextRanges: [UInt64: NSRange]
  let drafts: [Draft]
  let linkEdits: [Range<Int>]

  /// Kept separate from complete preparation so unchanged drawing panes can
  /// retain their existing fast path without rebuilding a projection first.
  static func visibleImages(pane: WireComposePane, editing source: ComposeComposition?) -> [WireComposeImage]? {
    guard !pane.images.contains(where: { $0.rendered && $0.sourcePreview }),
          let start = Int(exactly: pane.sourceStart), let end = Int(exactly: pane.sourceEnd), start <= end else { return nil }
    var result: [WireComposeImage] = []
    for image in pane.images where image.rendered || image.sourcePreview {
      guard let low = Int(exactly: image.start), let high = Int(exactly: image.end),
            low < high, low >= start, high <= end else { return nil }
      let range = low..<high
      let edited = source?.values.values.contains { value in
        guard !value.source.isEmpty || value.draft.length > 0 else { return false }
        return value.source.overlaps(range) || (value.source.isEmpty && low < value.source.lowerBound && value.source.lowerBound < high)
      } ?? false
      if !edited { result.append(image) }
    }
    return result
  }

  init?(pane: WireComposePane, composition: ComposeComposition? = nil,
        virtualInsertion: ComposeVirtualInsertion? = nil, visibleImages: [WireComposeImage]? = nil,
        original verified: ComposeProjection? = nil) {
    let source = virtualInsertion?.regions ?? composition
    guard let images = visibleImages ?? Self.visibleImages(pane: pane, editing: source),
          let original = verified ?? ComposeProjection(pane) else { return nil }
    let rendered = images.filter(\.rendered).map { Int($0.start)..<Int($0.end) }
    let replacementObjects = rendered.isEmpty ? nil : original.replacingObjects(rendered)
    let base = replacementObjects?.projection ?? original
    let layered = virtualInsertion?.projected(over: base)
    let replacement: (projection: ComposeProjection, displays: [UInt64: Range<Int>])? = layered.map { ($0.projection, $0.drafts) }
      ?? (virtualInsertion == nil ? composition?.project(over: base) : nil)
    guard (composition == nil && virtualInsertion == nil) || replacement != nil else { return nil }
    let projection = replacement?.projection ?? base
    let contexts = layered?.contexts ?? replacement?.displays ?? [:]
    func units(_ ranges: [UInt64: Range<Int>]) -> [UInt64: NSRange]? {
      var result: [UInt64: NSRange] = [:]
      for (id, range) in ranges {
        guard let mapped = projection.textIndex.units(for: range) else { return nil }
        result[id] = mapped
      }
      return result
    }
    guard let draftRanges = units(replacement?.displays ?? [:]), let contextRanges = units(contexts) else { return nil }
    var drafts: [Draft] = []
    for (id, range) in contexts {
      guard let value = source?.values[id] else { return nil }
      if !value.source.isEmpty || value.draft.length > 0 { drafts.append(.init(source: value.source, display: range)) }
    }
    self.base = base; self.projection = projection; self.images = images
    objects = replacementObjects?.objects ?? []; sourceDisplays = contexts
    self.draftRanges = draftRanges; self.contextRanges = contextRanges; self.drafts = drafts
    linkEdits = source?.values.values.filter { !$0.source.isEmpty || $0.draft.length > 0 }.map(\.source) ?? []
  }
}
