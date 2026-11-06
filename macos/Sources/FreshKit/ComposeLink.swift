import Foundation

/// Parser-owned link metadata mapped into the same displayed UTF-16 space as
/// native text and accessibility. A destination never authorizes a fetch/open.
public struct ComposeLink: Equatable {
  public let source: Range<Int>
  public let range: NSRange
  public let target: String

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.source == rhs.source && lhs.range == rhs.range && lhs.target.utf8.elementsEqual(rhs.target.utf8)
  }

  static func resolving(_ pane: WireComposePane, text: ComposeTextLayout, excluding edits: [Range<Int>]) -> [Self] {
    pane.spans.compactMap { span in
      guard span.flags & 16 != 0, span.hasLinkTarget,
            let start = Int(exactly: span.start), let end = Int(exactly: span.end), start < end,
            span.end <= pane.documentLen else { return nil }
      let source = start..<end
      // Provisional source cannot certify a destination still owned by the
      // preceding parse. Other links remain useful during unrelated edits.
      guard !edits.contains(where: { $0.overlaps(source) || ($0.isEmpty && source.contains($0.lowerBound)) }) else { return nil }
      let from = max(start, text.projection.source.lowerBound), to = min(end, text.projection.source.upperBound)
      guard from < to, let a = text.utf16Position(for: from),
            let b = text.utf16Position(for: to, affinity: .upstream), a < b else { return nil }
      return Self(source: source, range: NSRange(location: a, length: b - a), target: span.linkTarget)
    }
  }
}
