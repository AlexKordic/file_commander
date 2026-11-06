import Foundation

/// Cursor intentions over one immutable provisional document. These indices
/// are document-wide UTF-16 for native presentation, never wire source bytes.
/// Cursor IDs deliberately need not be the owners of the underlying drafts.
public struct ComposeVirtualSelections {
  public struct Cursor: Equatable {
    public let position: Int
    public let anchor: Int?
    public init(position: Int, anchor: Int? = nil) { self.position = position; self.anchor = anchor }
    public var selection: NSRange {
      let other = anchor ?? position
      return NSRange(location: min(position, other), length: abs(position - other))
    }
  }
  let prefix: ComposeComposition
  public let primaryID: UInt64
  public let cursors: [UInt64: Cursor]
  private let contexts: [Context]

  private struct Context {
    let range: NSRange
    let text: NSAttributedString
    let units: [UInt16]
    func contains(_ position: Int) -> Bool {
      guard position >= range.location, position <= NSMaxRange(range) else { return false }
      let index = position - range.location
      return index == 0 || index == units.count
        || !(0xd800...0xdbff).contains(units[index - 1]) || !(0xdc00...0xdfff).contains(units[index])
    }
  }

  public init?(prefix: ComposeComposition, primary: UInt64? = nil, cursors: [UInt64: Cursor]? = nil) {
    let primary = primary ?? prefix.primaryID
    var contexts: [Context] = []
    for id in prefix.ordered {
      guard let snapshot = ComposeComposition(primary: id, values: prefix.values),
            let raw = snapshot.substring(for: NSRange(location: 0, length: Int.max)),
            raw.range.location >= 0, raw.range.length == raw.text.length,
            raw.range.length <= Int.max - raw.range.location else { return nil }
      let units = Array(raw.text.string.utf16)
      var duplicate = false
      for context in contexts {
        let overlap = NSIntersectionRange(context.range, raw.range)
        if overlap.length > 0 {
          let first = overlap.location - context.range.location, second = overlap.location - raw.range.location
          guard context.units[first..<(first + overlap.length)].elementsEqual(units[second..<(second + overlap.length)]) else { return nil }
        }
        if context.range == raw.range { duplicate = true }
      }
      if !duplicate { contexts.append(Context(range: raw.range, text: NSAttributedString(attributedString: raw.text), units: units)) }
    }
    let group = cursors ?? Dictionary(uniqueKeysWithValues: prefix.ordered.map { id in
      let value = prefix.values[id]!, start = prefix.virtualStart(for: id)
      return (id, Cursor(position: start + NSMaxRange(value.selected),
        anchor: value.selected.length == 0 ? nil : start + value.selected.location))
    })
    guard group[primary] != nil, group.values.allSatisfy({ cursor in
      contexts.contains { $0.contains(cursor.position) } && (cursor.anchor.map { anchor in contexts.contains { $0.contains(anchor) } } ?? true)
    }) else { return nil }
    self.prefix = prefix; self.primaryID = primary; self.cursors = group; self.contexts = contexts
  }

  private init(prefix: ComposeComposition, primary: UInt64, cursors: [UInt64: Cursor], contexts: [Context]) {
    self.prefix = prefix; primaryID = primary; self.cursors = cursors; self.contexts = contexts
  }

  public var selection: NSRange { cursors[primaryID]!.selection }

  public func movingPrimary(to position: Int, extend: Bool) -> ComposeVirtualSelections? {
    guard contexts.contains(where: { $0.contains(position) }), let original = cursors[primaryID] else { return nil }
    var group = cursors
    group[primaryID] = Cursor(position: position, anchor: extend ? original.anchor ?? original.position : nil)
    return ComposeVirtualSelections(prefix: prefix, primary: primaryID, cursors: group, contexts: contexts)
  }

  /// A bounded attributed answer from the same provisional context as the
  /// selections. It cannot invent text in a gap between distant caret chunks.
  public func substring(for range: NSRange) -> NSAttributedString? {
    guard range.location >= 0, range.location != NSNotFound, range.length >= 0,
          range.length <= Int.max - range.location else { return nil }
    let end = NSMaxRange(range)
    let result = NSMutableAttributedString(string: "")
    var position = range.location
    repeat {
      guard let context = contexts.filter({ $0.contains(position) && (position == end || NSMaxRange($0.range) > position) })
        .max(by: { NSMaxRange($0.range) < NSMaxRange($1.range) }) else { return nil }
      let stop = min(end, NSMaxRange(context.range))
      guard context.contains(stop) else { return nil }
      result.append(context.text.attributedSubstring(from: NSRange(location: position - context.range.location, length: stop - position)))
      position = stop
    } while position < end
    return NSAttributedString(attributedString: result)
  }
}
