import Foundation

/// Provisional input-method text over an immutable Fresh source snapshot.
/// No buffer mutation occurs until the owner sends `draft` as one replacement.
public struct ComposeMarkedText {
  public let context: ComposeTextContext
  public private(set) var originalRange: NSRange
  public private(set) var source: Range<Int>
  public private(set) var draft: NSAttributedString
  public private(set) var marked: NSRange
  public private(set) var selected: NSRange

  public init?(context: ComposeTextContext, range: NSRange, source: Range<Int>,
               text: NSAttributedString, selected: NSRange) {
    guard Self.end(range) != nil, Self.valid(selected, in: text.string), source.lowerBound >= 0,
          range.location <= Int.max - text.length,
          range.location <= NSMaxRange(context.range), NSMaxRange(range) >= context.range.location else { return nil }
    self.context = context; originalRange = range; self.source = source
    draft = text.copy() as! NSAttributedString
    marked = NSRange(location: 0, length: text.length); self.selected = selected
  }

  public var markedRange: NSRange { NSRange(location: originalRange.location + marked.location, length: marked.length) }
  public var selectedRange: NSRange { NSRange(location: originalRange.location + selected.location, length: selected.length) }

  @discardableResult
  public mutating func select(_ range: NSRange) -> Bool {
    guard let end = Self.end(range), range.location >= originalRange.location,
          end <= originalRange.location + draft.length else { return false }
    let local = NSRange(location: range.location - originalRange.location, length: range.length)
    guard Self.valid(local, in: draft.string) else { return false }
    selected = local; return true
  }

  /// Explicit replacement ranges address the provisional document, including
  /// existing marked text. A partial update can leave unmarked draft on either
  /// side; that text still commits with this one source transaction.
  @discardableResult
  public mutating func update(_ text: NSAttributedString, selected: NSRange, replacement: NSRange) -> Bool {
    guard Self.valid(selected, in: text.string) else { return false }
    let range = replacement.location == NSNotFound ? markedRange : replacement
    guard let end = Self.end(range) else { return false }
    let oldEnd = NSMaxRange(originalRange), virtualEnd = originalRange.location + draft.length
    let start = min(originalRange.location, range.location)
    let (stop, overflow) = oldEnd.addingReportingOverflow(max(0, end - virtualEnd))
    guard !overflow else { return false }
    let prefixRange = NSRange(location: start, length: originalRange.location - start)
    let suffixRange = NSRange(location: oldEnd, length: stop - oldEnd)
    guard let prefix = prefixRange.length == 0 ? "" : context.exactText(for: prefixRange),
          let suffix = suffixRange.length == 0 ? "" : context.exactText(for: suffixRange) else { return false }
    let value = NSMutableAttributedString(string: prefix)
    value.append(draft); value.append(NSAttributedString(string: suffix))
    let local = NSRange(location: range.location - start, length: range.length)
    guard Self.valid(local, in: value.string) else { return false }
    let a = start == originalRange.location ? source.lowerBound
      : context.sourceRange(forUTF16: NSRange(location: start, length: 0))?.lowerBound
    let b = stop == oldEnd ? source.upperBound
      : context.sourceRange(forUTF16: NSRange(location: stop, length: 0))?.lowerBound
    guard let a, let b, a <= b else { return false }
    value.replaceCharacters(in: local, with: text)
    guard start <= Int.max - value.length else { return false }
    originalRange = NSRange(location: start, length: stop - start); source = a..<b
    draft = value.copy() as! NSAttributedString
    marked = NSRange(location: local.location, length: text.length)
    self.selected = NSRange(location: local.location + selected.location, length: selected.length)
    return true
  }

  public func substring(for proposed: NSRange) -> (text: NSAttributedString, range: NSRange)? {
    guard let end = Self.end(proposed) else { return nil }
    let base = min(context.range.location, originalRange.location)
    let prefix = originalRange.location > context.range.location
      ? context.exactText(for: NSRange(location: base, length: originalRange.location - base)) ?? "" : ""
    let suffix = NSMaxRange(originalRange) < NSMaxRange(context.range)
      ? context.exactText(for: NSRange(location: NSMaxRange(originalRange), length: NSMaxRange(context.range) - NSMaxRange(originalRange))) ?? "" : ""
    let value = NSMutableAttributedString(string: prefix)
    value.append(draft); value.append(NSAttributedString(string: suffix))
    guard base <= Int.max - value.length else { return nil }
    let start = max(base, proposed.location), stop = min(base + value.length, end)
    guard start <= stop else { return nil }
    let local = (value.string as NSString).rangeOfComposedCharacterSequences(for: NSRange(location: start - base, length: stop - start))
    return (value.attributedSubstring(from: local), NSRange(location: base + local.location, length: local.length))
  }

  /// A presentation-only projection keeps Fresh's original source coordinates.
  /// Preedit positions inside its replacement are addressed directly in UTF-16
  /// by the input method; this projection is never sent as editing geometry.
  public func projection(over base: ComposeProjection) -> (projection: ComposeProjection, display: Range<Int>)? {
    guard source.lowerBound <= base.source.upperBound, source.upperBound >= base.source.lowerBound else { return nil }
    var text = "", segments: [ComposeProjection.Segment] = []
    let bytes = Array(base.text.utf8)
    func append(_ value: String, source: Range<Int>, kind: ComposeProjection.Kind) {
      let start = text.utf8.count; text += value
      if !value.isEmpty || !source.isEmpty {
        segments.append(.init(source: source, display: start..<text.utf8.count, kind: kind))
      }
    }
    func retain(_ range: Range<Int>) -> Bool {
      for segment in base.segments {
        if segment.source.isEmpty {
          if range.contains(segment.source.lowerBound) {
            append(String(decoding: bytes[segment.display], as: UTF8.self), source: segment.source, kind: segment.kind)
          }
          continue
        }
        let a = max(range.lowerBound, segment.source.lowerBound), b = min(range.upperBound, segment.source.upperBound)
        guard a < b else { continue }
        let slice = a..<b
        if segment.kind == .copy {
          let start = segment.display.lowerBound + a - segment.source.lowerBound
          append(String(decoding: bytes[start..<(start + b - a)], as: UTF8.self), source: slice, kind: .copy)
        } else if segment.kind == .hidden { append("", source: slice, kind: .hidden) }
        else if slice == segment.source { append(String(decoding: bytes[segment.display], as: UTF8.self), source: slice, kind: segment.kind) }
        else {
          guard let raw = context.exactText(forSource: slice) else { return false }
          append(raw, source: slice, kind: .copy)
        }
      }
      return true
    }
    if base.source.lowerBound < source.lowerBound, !retain(base.source.lowerBound..<source.lowerBound) { return nil }
    let start = text.utf8.count
    append(draft.string, source: source, kind: source.isEmpty ? .insertion : draft.length == 0 ? .hidden : .replacement)
    let display = start..<text.utf8.count
    if source.upperBound < base.source.upperBound, !retain(source.upperBound..<base.source.upperBound) { return nil }
    guard let projection = ComposeProjection(source: min(base.source.lowerBound, source.lowerBound)..<max(base.source.upperBound, source.upperBound), text: text, segments: segments) else { return nil }
    return (projection, display)
  }

  private static func end(_ range: NSRange) -> Int? {
    guard range.location >= 0, range.location != NSNotFound, range.length >= 0 else { return nil }
    let (end, overflow) = range.location.addingReportingOverflow(range.length)
    return overflow ? nil : end
  }

  private static func valid(_ range: NSRange, in text: String) -> Bool {
    guard let end = end(range), end <= text.utf16.count else { return false }
    let units = Array(text.utf16)
    return [range.location, end].allSatisfy { index in
      index == 0 || index == units.count || !(0xdc00...0xdfff).contains(units[index])
    }
  }
}
