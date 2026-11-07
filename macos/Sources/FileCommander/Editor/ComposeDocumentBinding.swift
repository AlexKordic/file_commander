import Foundation
import FreshKit

/// Action provenance captured with a requested logical generation, before its
/// worker can run or an input receipt can remove the originating queue node.
/// It retains delta origins, not pane layouts, images or earlier full prefixes.
@MainActor
struct ComposeDocumentBinding {
  struct Node {
    let token: UUID
    let revision: UInt64
    let predecessor: UUID?
    let selector: Bool
    let origins: ComposePendingText.Origins?
    let hasText: Bool
    let cursors: [UInt64]
  }
  let document: ObjectIdentifier
  let overlay: ComposeDocumentOverlay?
  let scope: WireComposeScope
  let marker: UInt64
  let nodes: [Node]
  let latest: ComposePendingText?
  let active: (token: UUID, text: ComposePendingText, after: UUID?)?
  let displayed: ComposeComposition?
  let primary: UInt64
  let newline: UInt32
  var selectedBy: UUID? = nil

  func matches(_ snapshot: ComposeDocumentSnapshot, overlay: ComposeDocumentOverlay?) -> Bool {
    guard document == ObjectIdentifier(snapshot.document) else { return false }
    switch (self.overlay, overlay) {
    case (nil, nil): return true
    case (let a?, let b?): return a.isEquivalent(to: b)
    default: return false
    }
  }

  func action(_ ranges: [NSRange], in model: ComposeDocumentPresentation, replacement: String?) -> ComposeDocumentAction? {
    guard document == ObjectIdentifier(model.document), !ranges.isEmpty, ranges.count <= 1024,
          ranges.allSatisfy(model.contains) else { return nil }
    let sorted = ranges.sorted { ($0.location, $0.length) < ($1.location, $1.length) }
    guard zip(sorted, sorted.dropFirst()).allSatisfy({ NSMaxRange($0) <= $1.location && $0.location != $1.location }) else { return nil }
    var nodes = nodes, latest = latest
    if let active {
      guard let committed = active.text.committed(nativeNewline: newline), let origins = committed.origins() else { return nil }
      let group = committed.presentation.values.keys.sorted {
        if ($0 == committed.presentation.primaryID) != ($1 == committed.presentation.primaryID) { return $0 == committed.presentation.primaryID }
        return $0 < $1
      }
      nodes.append(.init(token: active.token, revision: scope.bufferRevision, predecessor: active.after,
        selector: false, origins: origins, hasText: true, cursors: group))
      latest = committed
    }
    func cursor(_ id: UInt64, node: Node?) -> ComposeDocumentAction.Cursor {
      let group = node?.cursors ?? [], index = group.firstIndex(of: id)
      var node = node, visited: Set<UUID> = []
      while let current = node, visited.insert(current.token).inserted, let predecessor = current.predecessor,
            let parent = nodes.first(where: { $0.token == predecessor }) {
        if parent.selector, let index { return .selectedGroup(parent.token, ordinal: index) }
        node = parent
      }
      return .known(id)
    }
    func position(_ endpoint: ComposeDocumentPresentation.Endpoint, affinity: ComposeProjection.Affinity) -> ComposeDocumentAction.Position? {
      if case .source(let byte) = endpoint.location { return .source(byte, affinity: affinity) }
      guard let point = model.provisionalPosition(of: endpoint), let latest,
            let displayed,
            var original = latest.normalizedPosition(point, displayed: displayed, nativeNewline: newline) else { return nil }
      for node in nodes.reversed() {
        guard let origins = node.origins else { if node.hasText { return nil }; continue }
        guard let origin = origins.origin(atProvisionalUTF16: original, affinity: affinity) else { return nil }
        switch origin {
        case .inserted(let id, let inserted):
          return .inserted(node.token, cursor: cursor(id, node: node), position: inserted, affinity: affinity)
        case .before(let before): original = before
        }
      }
      for node in nodes where node.revision == model.document.owner.revision {
        if let byte = node.origins?.sourcePosition(beforePendingAtUTF16: original, documentLength: model.document.owner.length) {
          return .source(byte, affinity: affinity)
        }
      }
      return nil
    }
    var bounds: [ComposeDocumentAction.Bounds] = []
    for range in ranges {
      let affinity: ComposeProjection.Affinity = range.length == 0 ? .downstream : .upstream
      guard let a = model.endpoint(atUTF16: range.location), let b = model.endpoint(atUTF16: NSMaxRange(range), affinity: affinity),
            let start = position(a, affinity: .downstream), let end = position(b, affinity: affinity) else { return nil }
      bounds.append(.init(start: start, end: end))
    }
    let id: ComposeDocumentAction.Cursor
    if let selectedBy { id = .selectedGroup(selectedBy, ordinal: 0) }
    else if let selector = nodes.last, selector.selector { id = .selectedGroup(selector.token, ordinal: 0) }
    else { id = cursor(primary, node: nodes.last(where: { $0.origins != nil })) }
    return .init(owner: model.document.owner, scope: scope, bounds: bounds,
      kind: replacement.map { .replacement($0, cursor: id) } ?? .selection)
  }
}
