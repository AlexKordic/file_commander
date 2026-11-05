import Foundation

/// A text-service replacement captures source coordinates once, before queued
/// input/reflow can change its displayed range. Fresh validates and rebases it.
public struct ComposeReplacement {
  private let captured: WireComposeInput
  public var scope: WireComposeScope { captured.scope }
  public var text: String { (try? WirePaste(serializedBytes: captured.payload).text) ?? "" }

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

  public func input(id: UInt64) -> WireComposeInput {
    var value = captured; value.id = id; return value
  }
}
