import Foundation

/// Measurement-only projected text, owned by this pane's source revision.
/// It supplies no editable characters, source guesses or visual column count.
struct ComposeHangingContext {
  let wire: WireComposeHangingContext
  let prefixUTF16: Int

  init?(_ wire: WireComposeHangingContext, item: WireComposeSpan) {
    guard item.role == 13, item.hasContentStart, item.start <= item.contentStart, item.contentStart < item.end,
          wire.itemStart == item.start, wire.contentStart == item.contentStart,
          let prefix = Int(exactly: wire.prefixEnd) else { return nil }
    let bytes = Array(wire.text.utf8)
    guard prefix >= 0, prefix < bytes.count,
          let marker = String(bytes: bytes[..<prefix], encoding: .utf8),
          !marker.contains(where: { $0.isNewline }),
          let first = String(bytes: bytes[prefix...], encoding: .utf8), first.count == 1,
          !first.contains(where: { $0.isNewline }) else { return nil }
    for span in wire.spans {
      guard let a = Int(exactly: span.start), let b = Int(exactly: span.end),
            a >= 0, a < b, b <= bytes.count, !span.hasContentStart,
            String(bytes: bytes[..<a], encoding: .utf8) != nil,
            String(bytes: bytes[..<b], encoding: .utf8) != nil else { return nil }
    }
    self.wire = wire; prefixUTF16 = marker.utf16.count
  }
}
