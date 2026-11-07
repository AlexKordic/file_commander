import CryptoKit
import Foundation

/// Verified correspondence between a native transaction's before/after source
/// spaces. The caller also binds its receipt to the acknowledged input token
/// and connection; matching text alone does not identify a transaction.
public struct ComposeAcceptedEdits: Sendable {
  public struct InsertedPosition: Sendable {
    let digest: Data
    let count, offset: Int
    public init?(text: String, offsetUTF16: Int) {
      let index = ComposeTextIndex(text)
      guard let offset = index.byte(forUnit: offsetUTF16) else { return nil }
      digest = ComposeAcceptedEdits.digest(text); count = text.utf8.count; self.offset = offset
    }
  }
  public let scope: WireComposeScope
  public let sourceRevision: UInt64
  public let sourceLength: Int
  private let anchors: [WireComposeEditAnchor]

  public init?(_ receipt: WireComposeEditReceipt, original: WireComposeScope, epoch: UInt64) {
    guard receipt.matches(original, epoch: epoch), receipt.hasSourceRevision, receipt.hasSourceLength,
          receipt.sourceRevision >= original.bufferRevision, receipt.sourceRevision <= receipt.pane.bufferRevision,
          let length = Int(exactly: receipt.sourceLength), let resultLength = Int(exactly: receipt.pane.documentLen),
          !receipt.anchors.isEmpty, receipt.anchors.count <= 1024,
          receipt.cursors.count == receipt.anchors.count, Set(receipt.cursors).count == receipt.cursors.count,
          Set(receipt.anchors.map(\.cursor)) == Set(receipt.cursors),
          Set(receipt.pane.cursors.map(\.id)).count == receipt.pane.cursors.count else { return nil }
    var before = 0, after = 0, previousStart: Int?
    let cursors = Dictionary(uniqueKeysWithValues: receipt.pane.cursors.map { ($0.id,$0) })
    for anchor in receipt.anchors {
      guard let start = Int(exactly: anchor.start), let end = Int(exactly: anchor.end), start <= end, end <= resultLength,
            let a = Int(exactly: anchor.beforeStart), let b = Int(exactly: anchor.beforeEnd),
            before <= a, a <= b, b <= length, previousStart != a, a-before <= Int.max-after,
            start == after+(a-before), anchor.digest.count == 32,
            let cursor = cursors[anchor.cursor], cursor.position == anchor.end,
            !cursor.hasAnchor || cursor.anchor == cursor.position else { return nil }
      before = b; after = end; previousStart = a
    }
    guard length-before <= Int.max-after, after+(length-before) == resultLength else { return nil }
    scope = receipt.scope; sourceRevision = receipt.sourceRevision; sourceLength = length; anchors = receipt.anchors
  }

  public func contains(cursor: UInt64) -> Bool { anchors.contains { $0.cursor == cursor } }

  public func position(_ inserted: InsertedPosition, cursor: UInt64) -> Int? {
    guard let anchor = anchors.first(where: { $0.cursor == cursor }),
          let start = Int(exactly: anchor.start), let end = Int(exactly: anchor.end),
          end-start == inserted.count, anchor.digest == inserted.digest else { return nil }
    return start+inserted.offset
  }

  /// Rebase a previously validated source endpoint through this exact accepted
  /// batch. Interiors of replaced source have no correspondence. Empty insert
  /// boundaries respect affinity; no source coordinate is inferred from text.
  public func rebased(_ position: Int, from revision: UInt64,
                      affinity: ComposeProjection.Affinity = .downstream) -> Int? {
    guard revision == sourceRevision, position >= 0, position <= sourceLength else { return nil }
    var before = 0, after = 0
    for anchor in anchors {
      let start = Int(anchor.beforeStart), end = Int(anchor.beforeEnd)
      if position < start { return after+(position-before) }
      if start == end && position == start { return Int(affinity == .upstream ? anchor.start : anchor.end) }
      if position == start { return Int(anchor.start) }
      if position < end { return nil }
      before = end; after = Int(anchor.end)
    }
    return after+(position-before)
  }

  static func digest(_ text: String) -> Data {
    var text = text
    return text.withUTF8 { bytes in
      var hash = SHA256(); hash.update(bufferPointer: UnsafeRawBufferPointer(bytes))
      return Data(hash.finalize())
    }
  }
}
