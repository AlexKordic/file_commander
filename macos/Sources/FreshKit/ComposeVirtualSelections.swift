import Foundation

/// Cursor intentions over one immutable provisional document. These indices
/// are document-wide UTF-16 for native presentation, never wire source bytes.
/// Cursor IDs deliberately need not be the owners of the underlying drafts.
public struct ComposeVirtualSelections {
  public struct Cursor: Equatable, Sendable {
    public let position: Int
    public let anchor: Int?
    public let affinity: ComposeProjection.Affinity
    public init(position: Int, anchor: Int? = nil, affinity: ComposeProjection.Affinity = .downstream) {
      self.position = position; self.anchor = anchor; self.affinity = affinity
    }
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

  /// A proposed accessibility group uses local identities for new carets.
  /// Only the selector's accepted Fresh receipt can bind them to real IDs.
  public func replacingGroup(with ranges: [NSRange]) -> Self? {
    guard !ranges.isEmpty, ranges.count <= 1024 else { return nil }
    var maximum = max(cursors.keys.max() ?? 0,prefix.ordered.max() ?? 0), group: [UInt64: Cursor] = [:]
    for (index, range) in ranges.enumerated() {
      guard range.location >= 0, range.location != NSNotFound, range.length >= 0,
            range.length <= Int.max-range.location else { return nil }
      let id: UInt64
      if index == 0 { id = primaryID }
      else { guard maximum < .max else { return nil }; maximum += 1; id = maximum }
      group[id] = .init(position: NSMaxRange(range),anchor: range.length == 0 ? nil : range.location)
    }
    return Self(prefix: prefix,primary: primaryID,cursors: group)
  }

  public func position(forSource source: UInt64) -> Int? {
    guard let source = Int(exactly: source) else { return nil }
    return prefix.virtualPosition(for: source)
  }

  public func movingPrimary(to position: Int, extend: Bool, affinity: ComposeProjection.Affinity = .downstream) -> ComposeVirtualSelections? {
    guard contexts.contains(where: { $0.contains(position) }), let original = cursors[primaryID] else { return nil }
    var group = cursors
    group[primaryID] = Cursor(position: position, anchor: extend ? original.anchor ?? original.position : nil, affinity: affinity)
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
  public func substring(forProposedRange range: NSRange) -> (text: NSAttributedString, range: NSRange)? {
    guard range.location >= 0, range.location != NSNotFound, range.length >= 0, range.length <= Int.max - range.location,
          let context = contexts.first(where: { $0.contains(cursors[primaryID]!.position) }) else { return nil }
    let start = max(context.range.location, range.location), end = min(NSMaxRange(context.range), NSMaxRange(range))
    guard start <= end else { return nil }
    let local = (context.text.string as NSString).rangeOfComposedCharacterSequences(for: NSRange(location: start - context.range.location, length: end - start))
    return (context.text.attributedSubstring(from: local), NSRange(location: context.range.location + local.location, length: local.length))
  }

  /// Derived contexts are used solely to retain native action intent. The
  /// PendingText owner must forbid wire replacements until its action result.
  func actionPane(like original: WireComposePane) -> WireComposePane? {
    guard let document = prefix.values.values.first?.context.documentLength else { return nil }
    var length = document
    for value in prefix.values.values {
      let inserted = value.draft.string.utf8.count
      guard value.source.count <= length, inserted <= Int.max - (length - value.source.count) else { return nil }
      length = length - value.source.count + inserted
    }
    var chunks: [ComposeTextContext] = []
    for context in contexts {
      guard let byte = prefix.virtualSourcePosition(atUTF16: context.range.location),
            let raw = ComposeTextContext(.with {
              $0.text = context.text.string; $0.sourceStart = UInt64(byte); $0.utf16Start = UInt64(context.range.location)
            }, documentLength: UInt64(length)) else { return nil }
      chunks.append(raw)
    }
    guard let primary = cursors[primaryID] else { return nil }
    let raw: ComposeTextContext
    if let existing = chunks.first(where: { $0.sourceRange(forUTF16: primary.selection) != nil }) { raw = existing }
    else {
      let range = primary.selection
      guard let text = substring(for: range), let byte = prefix.virtualSourcePosition(atUTF16: range.location),
            let combined = ComposeTextContext(.with {
              $0.text = text.string; $0.sourceStart = UInt64(byte); $0.utf16Start = UInt64(range.location)
            }, documentLength: UInt64(length)) else { return nil }
      raw = combined; chunks.append(raw)
    }
    var pane = original
    pane.documentLen = UInt64(length); pane.text = ""; pane.segments = []; pane.spans = []; pane.images = []; pane.tables = []
    pane.textContext = .with {
      $0.text = raw.text; $0.sourceStart = UInt64(raw.source.lowerBound); $0.utf16Start = UInt64(raw.range.location)
      $0.selectionStart = UInt64(primary.selection.location); $0.selectionEnd = UInt64(NSMaxRange(primary.selection))
    }
    pane.textChunks = chunks.map { context in .with {
      $0.text = context.text; $0.sourceStart = UInt64(context.source.lowerBound); $0.utf16Start = UInt64(context.range.location)
    } }
    var group: [WireComposeSelection] = []
    for (id, cursor) in cursors.sorted(by: { $0.key < $1.key }) {
      func source(_ unit: Int) -> Int? { chunks.lazy.compactMap { $0.sourceRange(forUTF16: NSRange(location: unit, length: 0))?.lowerBound }.first }
      guard let byte = source(cursor.position) else { return nil }
      var value = WireComposeSelection.with {
        $0.id = id; $0.primary = id == primaryID; $0.position = UInt64(byte); $0.utf16Position = UInt64(cursor.position)
      }
      if let anchor = cursor.anchor {
        guard let byte = source(anchor) else { return nil }
        value.anchor = UInt64(byte); value.utf16Anchor = UInt64(anchor)
      }
      group.append(value)
    }
    pane.cursors = group
    return pane
  }

}
