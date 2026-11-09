import Foundation

/// Parser-owned link metadata mapped into the same displayed UTF-16 space as
/// native text and accessibility. A destination never authorizes a fetch/open.
public struct ComposeLink: Equatable {
  public let source: Range<Int>
  public let range: NSRange
  /// Present only for a complete parsed destination, including an empty self-link.
  public let target: String?
  public let targetBytes: UInt64?
  /// Tooltip text only; it is never a destination that can be opened.
  public let preview: String?

  public var tooltip: String {
    if let target { return target.isEmpty ? "Current document" : target }
    let detail = "Edit the link to inspect its full destination (\(targetBytes ?? 0) bytes)."
    if let preview { return "\(preview)…\n\(detail)" }
    return detail
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.source == rhs.source && lhs.range == rhs.range && lhs.targetBytes == rhs.targetBytes
      && sameBytes(lhs.target, rhs.target) && sameBytes(lhs.preview, rhs.preview)
  }

  private static func sameBytes(_ lhs: String?, _ rhs: String?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): return true
    case (let a?, let b?): return a.utf8.elementsEqual(b.utf8)
    default: return false
    }
  }

  static func resolving(_ pane: WireComposePane, text: ComposeTextLayout, excluding edits: [Range<Int>]) -> [Self] {
    pane.spans.compactMap { span in
      guard span.flags & 16 != 0,
            let start = Int(exactly: span.start), let end = Int(exactly: span.end), start < end,
            span.end <= pane.documentLen else { return nil }
      let source = start..<end
      if span.hasLinkTarget {
        guard !span.hasLinkTargetBytes, !span.hasLinkTargetPreview else { return nil }
      } else {
        guard span.hasLinkTargetBytes, span.linkTargetBytes > 0,
              !span.hasLinkTargetPreview || UInt64(span.linkTargetPreview.utf8.count) < span.linkTargetBytes else { return nil }
      }
      // Provisional source cannot certify a destination still owned by the
      // preceding parse. Other links remain useful during unrelated edits.
      guard !edits.contains(where: { $0.overlaps(source) || ($0.isEmpty && source.contains($0.lowerBound)) }) else { return nil }
      let from = max(start, text.projection.source.lowerBound), to = min(end, text.projection.source.upperBound)
      guard from < to, let a = text.utf16Position(for: from),
            let b = text.utf16Position(for: to, affinity: .upstream), a < b else { return nil }
      return Self(source: source, range: NSRange(location: a, length: b - a),
        target: span.hasLinkTarget ? span.linkTarget : nil,
        targetBytes: span.hasLinkTargetBytes ? span.linkTargetBytes : nil,
        preview: span.hasLinkTargetPreview ? span.linkTargetPreview : nil)
    }
  }
}
