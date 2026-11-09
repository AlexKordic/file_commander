import Foundation

/// A text-service replacement captures source coordinates once, before queued
/// input/reflow can change its displayed range. Fresh validates and rebases it.
public struct ComposeReplacement {
  private let captured: WireComposeInput
  public var scope: WireComposeScope { captured.scope }
  public var text: String { (try? WirePaste(serializedBytes: captured.payload).text) ?? "" }
  public var texts: [String] {
    var seen: Set<String> = []
    return ([text] + captured.replacements.compactMap { $0.hasText ? $0.text : nil }).filter { seen.insert($0).inserted }
  }

  public init?(scope: WireComposeScope, epoch: UInt64, composition: ComposeComposition, observedCursors: [WireComposeCursorAnchor] = []) {
    let primary = composition.primary
    guard let value = ComposeReplacement(scope: scope, epoch: epoch, source: primary.source, cursor: composition.primaryID, text: primary.draft.string) else { return nil }
    var input = value.captured
    input.replacements = composition.ordered.filter { $0 != composition.primaryID }.map { id in
      let value = composition.values[id]!
      return .with {
        $0.start = UInt64(value.source.lowerBound); $0.end = UInt64(value.source.upperBound); $0.cursor = id
        if value.draft.string != primary.draft.string { $0.text = value.draft.string }
      }
    }
    input.observedCursors = observedCursors
    captured = input
  }

  public init?(scope: WireComposeScope, epoch: UInt64, source: Range<Int>, cursor: UInt64, text: String) {
    guard epoch != 0, source.lowerBound >= 0 else { return nil }
    captured = .with {
      $0.scope = scope; $0.bufferEpoch = epoch; $0.sourceRevision = scope.bufferRevision
      $0.kind = UInt32(SceneWire.Kind.paste.rawValue)
      $0.payload = Data(SceneInput.paste(text).payload())
      $0.replacementStart = UInt64(source.lowerBound); $0.replacementEnd = UInt64(source.upperBound)
      $0.replacementCursor = cursor
    }
  }

  /// After an acknowledged selection action, exact source endpoints and real
  /// Fresh IDs suffice even when its selected text exceeds native raw context.
  public init?(scope: WireComposeScope, epoch: UInt64, pane: WireComposePane, text: String) {
    guard scope.bufferRevision == pane.bufferRevision, pane.cursors.filter(\.primary).count == 1,
          let primary = pane.cursors.first(where: \.primary), pane.cursors.count <= 1024,
          Set(pane.cursors.map(\.id)).count == pane.cursors.count else { return nil }
    func source(_ cursor: WireComposeSelection) -> Range<Int>? {
      let other = cursor.hasAnchor ? cursor.anchor : cursor.position
      guard let start = Int(exactly: min(cursor.position, other)),
            let end = Int(exactly: max(cursor.position, other)), UInt64(end) <= pane.documentLen else { return nil }
      return start..<end
    }
    guard let range = source(primary), let value = Self(scope: scope, epoch: epoch, source: range, cursor: primary.id, text: text) else { return nil }
    var input = value.captured
    for cursor in pane.cursors where cursor.id != primary.id {
      guard let range = source(cursor) else { return nil }
      input.replacements.append(.with {
        $0.start = UInt64(range.lowerBound); $0.end = UInt64(range.upperBound); $0.cursor = cursor.id
      })
    }
    captured = input
  }

  public func input(id: UInt64) -> WireComposeInput {
    var value = captured; value.id = id; return value
  }
}
