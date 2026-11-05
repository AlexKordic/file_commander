import Foundation

/// A bounded snapshot of Fresh's raw Markdown for native text services. UTF-16
/// indices are document-wide, independent of viewport and syntax concealment.
public struct ComposeTextContext {
  public let text: String
  public let source: Range<Int>
  public let range: NSRange
  public let selection: NSRange
  private let utf16ToSource: [Int: Int]
  private let sourceToUTF16: [Int: Int]

  public init?(_ wire: WireComposeTextContext, documentLength: UInt64) {
    guard let document = Int(exactly: documentLength), let start = Int(exactly: wire.sourceStart),
          let base = Int(exactly: wire.utf16Start), start <= document, base <= start,
          wire.text.utf8.count <= document - start,
          let a = Int(exactly: wire.selectionStart), let b = Int(exactly: wire.selectionEnd),
          a <= b, b <= document else { return nil }
    var units = base, byte = start, toSource = [base: start], toUTF16 = [start: base]
    for scalar in wire.text.unicodeScalars {
      units += scalar.utf16.count; byte += scalar.utf8.count
      toSource[units] = byte; toUTF16[byte] = units
    }
    text = wire.text; source = start..<byte
    range = NSRange(location: base, length: units - base)
    selection = NSRange(location: a, length: b - a)
    utf16ToSource = toSource; sourceToUTF16 = toUTF16
  }

  public func utf16Position(for source: Int) -> Int? { sourceToUTF16[source] }

  public func exactText(for proposed: NSRange) -> String? {
    guard sourceRange(forUTF16: proposed) != nil else { return nil }
    return (text as NSString).substring(with: NSRange(location: proposed.location - range.location, length: proposed.length))
  }

  public func exactText(forSource proposed: Range<Int>) -> String? {
    guard let a = sourceToUTF16[proposed.lowerBound], let b = sourceToUTF16[proposed.upperBound] else { return nil }
    return exactText(for: NSRange(location: a, length: b - a))
  }

  public func sourceRange(forUTF16 proposed: NSRange) -> Range<Int>? {
    guard proposed.location >= 0, proposed.location != NSNotFound, proposed.length >= 0, proposed.location <= NSMaxRange(range),
          proposed.length <= NSMaxRange(range) - proposed.location,
          let start = utf16ToSource[proposed.location],
          let end = utf16ToSource[NSMaxRange(proposed)] else { return nil }
    return start..<end
  }

  /// AppKit allows a bounded or grapheme-adjusted answer. Never manufacture
  /// text outside the supplied snapshot or split a surrogate/combining cluster.
  public func substring(forProposedRange proposed: NSRange) -> (text: String, range: NSRange)? {
    guard proposed.location >= 0, proposed.location != NSNotFound, proposed.length >= 0 else { return nil }
    let (end, overflow) = proposed.location.addingReportingOverflow(proposed.length)
    guard !overflow else { return nil }
    let start = max(range.location, proposed.location), stop = min(NSMaxRange(range), end)
    guard start <= stop else { return nil }
    let value = text as NSString
    let local = NSRange(location: start - range.location, length: stop - start)
    let adjusted = value.rangeOfComposedCharacterSequences(for: local)
    return (value.substring(with: adjusted), NSRange(location: range.location + adjusted.location, length: adjusted.length))
  }
}
