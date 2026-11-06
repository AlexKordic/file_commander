import Foundation

/// A presentation of native text not yet acknowledged by Fresh. Source ranges
/// always refer to one immutable real snapshot. Following conversions retain
/// the preceding preview for queries, but send only their own delta, after an
/// immutable edit receipt supplies its real source coordinates.
public struct ComposePendingText {
  public private(set) var presentation: ComposeComposition
  private let baseline: ComposeComposition?
  private let active: Set<UInt64>
  private var newlyIncluded: [UInt64: ComposeMarkedText] = [:]
  public private(set) var observedCursors: [WireComposeCursorAnchor]
  private var committedEdits: [UInt64: Edit]?

  private struct Edit {
    var offset: Int
    var removed: String
    var inserted: NSAttributedString
    var marked, selected: NSRange
    var display: NSRange
    var selectionLength: Int? = nil
    var leading = "", trailing = ""
  }

  public var markedRange: NSRange { presentation.markedRange }
  public var selectedRange: NSRange { presentation.selectedRange }
  public var ordered: [UInt64] { presentation.ordered.filter { active.contains($0) } }
  public var recoveryTexts: [String] {
    let texts = baseline == nil ? ordered.map { presentation.values[$0]!.draft.string }
      : ordered.compactMap { (committedEdits?[$0] ?? edit(for: $0))?.inserted.string }
    var seen: Set<String> = []
    return texts.filter { !$0.isEmpty && seen.insert($0).inserted }
  }

  public init?(pane: WireComposePane, text: NSAttributedString, selected: NSRange, replacement: NSRange) {
    guard let value = ComposeComposition(pane: pane, text: text, selected: selected, replacement: replacement) else { return nil }
    presentation = value; baseline = nil; active = Set(value.ordered)
    observedCursors = Self.anchors(pane)
  }

  public init?(following previous: ComposePendingText, pane: WireComposePane,
               text: NSAttributedString, selected: NSRange, replacement: NSRange) {
    guard previous.committedEdits != nil else { return nil }
    let base = previous.presentation
    let broadcast = replacement.location == NSNotFound
    let targets = broadcast ? Set(pane.cursors.map(\.id)) : [base.primaryID]
    guard !targets.isEmpty else { return nil }
    var values = base.values
    let missing = targets.subtracting(Set(base.ordered))
    var added: [UInt64: ComposeMarkedText] = [:]
    if !missing.isEmpty {
      guard broadcast, let raw = ComposeComposition(pane: pane, text: text, selected: selected, replacement: replacement) else { return nil }
      for id in missing {
        guard let value = raw.values[id] else { return nil }
        // The receipt must later prove this original cursor/range was retained.
        values[id] = value; added[id] = value
      }
    }
    let (relative, overflow) = broadcast ? (0, false) : replacement.location.subtractingReportingOverflow(base.selectedRange.location)
    guard !overflow else { return nil }
    for id in base.ordered where targets.contains(id) {
      var value = values[id]!
      guard let range = broadcast ? value.selectedRange
        : Self.range(at: value.selectedRange.location, offset: relative, length: replacement.length),
        value.update(text, selected: selected, replacement: range) else { return nil }
      values[id] = value
    }
    guard let value = ComposeComposition(primary: base.primaryID, values: values) else { return nil }
    presentation = value; baseline = base; active = targets
    newlyIncluded = added; observedCursors = previous.observedCursors
  }

  @discardableResult
  public mutating func update(_ text: NSAttributedString, selected: NSRange, replacement: NSRange) -> Bool {
    guard committedEdits == nil else { return false }
    let broadcast = replacement.location == NSNotFound
    let (relative, overflow) = broadcast ? (0, false) : replacement.location.subtractingReportingOverflow(markedRange.location)
    guard !overflow else { return false }
    var values = presentation.values
    for id in ordered {
      var value = values[id]!
      guard let range = Self.range(at: value.markedRange.location, offset: relative,
        length: broadcast ? value.markedRange.length : replacement.length),
        value.update(text, selected: selected, replacement: range) else { return false }
      values[id] = value
    }
    guard let next = ComposeComposition(primary: presentation.primaryID, values: values) else { return false }
    presentation = next; return true
  }

  @discardableResult
  public mutating func select(_ range: NSRange) -> Bool {
    guard committedEdits == nil, range.location != NSNotFound else { return false }
    let (relative, overflow) = range.location.subtractingReportingOverflow(markedRange.location)
    guard !overflow else { return false }
    var values = presentation.values
    for id in ordered {
      var value = values[id]!
      guard let range = Self.range(at: value.markedRange.location, offset: relative, length: range.length),
            value.select(range) else { return false }
      values[id] = value
    }
    guard let next = ComposeComposition(primary: presentation.primaryID, values: values) else { return false }
    presentation = next; return true
  }

  public func substring(for range: NSRange) -> (text: NSAttributedString, range: NSRange)? {
    presentation.substring(for: range)
  }

  /// Predict only the newline policy declared by this Fresh snapshot. CR files
  /// use LF in memory, while CRLF files retain CRLF. Unknown older peers cannot
  /// provide a reliable multiline preview.
  public func committed(nativeNewline policy: UInt32) -> ComposePendingText? {
    guard committedEdits == nil else { return self }
    var next = self, values = presentation.values, edits: [UInt64: Edit] = [:]
    for id in ordered {
      let value = values[id]!
      if baseline != nil {
        guard var edit = edit(for: id), let normalized = Self.normalize(edit.inserted, policy: policy) else { return nil }
        let text = NSMutableAttributedString(attributedString: value.draft)
        text.replaceCharacters(in: edit.display, with: normalized)
        guard let updated = ComposeMarkedText(context: value.context, range: value.originalRange, source: value.source,
          text: text, selected: NSRange(location: edit.display.location + normalized.length, length: 0),
          marked: NSRange(location: edit.display.location + normalized.length, length: 0)) else { return nil }
        edit.inserted = normalized; edit.selected = NSRange(location: normalized.length, length: 0); edit.marked = edit.selected
        edits[id] = edit; values[id] = updated
      } else {
        guard let normalized = Self.normalize(value.draft, policy: policy),
              let updated = ComposeMarkedText(context: value.context, range: value.originalRange, source: value.source,
                text: normalized, selected: NSRange(location: normalized.length, length: 0),
                marked: NSRange(location: normalized.length, length: 0)) else { return nil }
        values[id] = updated
      }
    }
    guard let composition = ComposeComposition(primary: presentation.primaryID, values: values) else { return nil }
    next.presentation = composition; next.committedEdits = edits; return next
  }

  /// Only real, receipt-bound ranges can become wire replacements.
  public func replacement(scope: WireComposeScope, epoch: UInt64) -> ComposeReplacement? {
    guard baseline == nil else { return nil }
    return ComposeReplacement(scope: scope, epoch: epoch, composition: presentation, observedCursors: observedCursors)
  }

  public func resolved(pane: WireComposePane, edited: [UInt64], preserved: [UInt64] = []) -> ComposePendingText? {
    guard Set(edited).count == edited.count, Set(preserved).count == preserved.count else { return nil }
    let edited = Set(edited), preserved = Set(preserved)
    guard baseline != nil, active.isSubset(of: edited.union(preserved)) else { return nil }
    // A later receipt must not silently renew a cursor that an earlier
    // transaction could not prove. Keep provenance through the whole chain.
    let observed = Self.anchors(pane).filter { edited.contains($0.id) || preserved.contains($0.id) }
    var pane = pane
    pane.cursors = pane.cursors.filter { active.contains($0.id) }
    guard pane.cursors.count == active.count, pane.cursors.allSatisfy({ $0.hasUtf16Position }) else { return nil }
    for index in pane.cursors.indices { pane.cursors[index].primary = pane.cursors[index].id == presentation.primaryID }
    guard let fresh = ComposeComposition(pane: pane, text: NSAttributedString(string: ""),
      selected: NSRange(location: 0, length: 0), replacement: NSRange(location: NSNotFound, length: 0)) else { return nil }
    // `fresh` validated unique IDs. Keep receipt lookup linear in caret count.
    let cursors = Dictionary(uniqueKeysWithValues: pane.cursors.map { ($0.id, $0) })
    var values: [UInt64: ComposeMarkedText] = [:]
    for id in ordered {
      guard let edit = committedEdits?[id] ?? edit(for: id), let target = fresh.values[id],
            let cursor = cursors[id],
            let byte = Int(exactly: cursor.position), let unit = Int(exactly: cursor.utf16Position),
            target.context.utf16Position(for: byte) == unit else { return nil }
      let range: NSRange, source: Range<Int>
      if let length = edit.selectionLength {
        guard preserved.contains(id), !edited.contains(id), target.originalRange.length == length,
              let expanded = Self.range(at: target.originalRange.location, offset: -edit.leading.utf16.count,
                length: length + edit.leading.utf16.count + edit.trailing.utf16.count),
              edit.leading.isEmpty || Self.exact(target.context.exactText(for: NSRange(location: expanded.location, length: edit.leading.utf16.count)), edit.leading),
              edit.trailing.isEmpty || Self.exact(target.context.exactText(for: NSRange(location: NSMaxRange(target.originalRange), length: edit.trailing.utf16.count)), edit.trailing),
              target.source.lowerBound >= edit.leading.utf8.count,
              edit.trailing.utf8.count <= Int(pane.documentLen) - target.source.upperBound else { return nil }
        range = expanded
        source = (target.source.lowerBound - edit.leading.utf8.count)..<(target.source.upperBound + edit.trailing.utf8.count)
      } else {
        let (position, overflow) = target.originalRange.location.addingReportingOverflow(edit.offset)
        guard !overflow, position >= 0, target.originalRange.length == 0 else { return nil }
        range = NSRange(location: position, length: edit.removed.utf16.count)
        guard target.context.sourceRange(forUTF16: target.originalRange) == target.source,
              let raw = target.context.exactText(for: range), Array(raw.utf16) == Array(edit.removed.utf16),
              let captured = target.context.sourceRange(forUTF16: range) else { return nil }
        source = captured
      }
      guard let value = ComposeMarkedText(context: target.context, range: range, source: source,
        text: edit.inserted, selected: edit.selected, marked: edit.marked) else { return nil }
      values[id] = value
    }
    guard let composition = ComposeComposition(primary: presentation.primaryID, values: values) else { return nil }
    return ComposePendingText(presentation: composition, committed: committedEdits != nil, observedCursors: observed)
  }

  private init(presentation: ComposeComposition, committed: Bool, observedCursors: [WireComposeCursorAnchor]) {
    self.presentation = presentation; baseline = nil; active = Set(presentation.ordered)
    self.observedCursors = observedCursors
    committedEdits = committed ? [:] : nil
  }

  private func edit(for id: UInt64) -> Edit? {
    guard let after = presentation.values[id] else { return nil }
    if let original = newlyIncluded[id] {
      let left = original.originalRange.location - after.originalRange.location
      let right = NSMaxRange(after.originalRange) - NSMaxRange(original.originalRange)
      guard left >= 0, right >= 0,
            let leading = left == 0 ? "" : after.context.exactText(for: NSRange(location: after.originalRange.location, length: left)),
            let trailing = right == 0 ? "" : after.context.exactText(for: NSRange(location: NSMaxRange(original.originalRange), length: right)) else { return nil }
      return Edit(offset: 0, removed: "", inserted: after.draft, marked: after.marked, selected: after.selected,
        display: NSRange(location: 0, length: after.draft.length), selectionLength: original.originalRange.length,
        leading: leading, trailing: trailing)
    }
    guard let before = baseline?.values[id] else { return nil }
    let left = before.originalRange.location - after.originalRange.location
    let right = NSMaxRange(after.originalRange) - NSMaxRange(before.originalRange)
    guard left >= 0, right >= 0,
          let prefix = left == 0 ? "" : after.context.exactText(for: NSRange(location: after.originalRange.location, length: left)),
          let suffix = right == 0 ? "" : after.context.exactText(for: NSRange(location: NSMaxRange(before.originalRange), length: right)) else { return nil }
    let old = Array((prefix + before.draft.string + suffix).utf16), new = Array(after.draft.string.utf16)
    var start = 0
    let limit = min(min(old.count, new.count), min(after.marked.location, after.selected.location))
    while start < limit && old[start] == new[start] { start += 1 }
    while start > 0 && (!Self.boundary(old, start) || !Self.boundary(new, start)) { start -= 1 }
    let requiredEnd = max(NSMaxRange(after.marked), NSMaxRange(after.selected))
    var end = 0
    while end < old.count - start && end < new.count - max(start, requiredEnd),
          old[old.count - 1 - end] == new[new.count - 1 - end] { end += 1 }
    while end > 0 && (!Self.boundary(old, old.count - end) || !Self.boundary(new, new.count - end)) { end -= 1 }
    let display = NSRange(location: start, length: new.count - end - start)
    guard after.marked.location >= start, after.selected.location >= start else { return nil }
    return Edit(offset: start - left - NSMaxRange(before.selected),
      removed: String(decoding: old[start..<(old.count - end)], as: UTF16.self),
      inserted: after.draft.attributedSubstring(from: display),
      marked: NSRange(location: after.marked.location - start, length: after.marked.length),
      selected: NSRange(location: after.selected.location - start, length: after.selected.length), display: display)
  }

  private static func anchors(_ pane: WireComposePane) -> [WireComposeCursorAnchor] {
    pane.cursors.map { cursor in .with {
      $0.id = cursor.id; $0.position = cursor.position
      if cursor.hasAnchor { $0.anchor = cursor.anchor }
    } }
  }

  private static func exact(_ value: String?, _ expected: String) -> Bool {
    value.map { Array($0.utf16) == Array(expected.utf16) } ?? false
  }

  private static func boundary(_ units: [UInt16], _ index: Int) -> Bool {
    index == 0 || index == units.count || !(0xdc00...0xdfff).contains(units[index])
  }

  private static func range(at base: Int, offset: Int, length: Int) -> NSRange? {
    let (location, overflow) = base.addingReportingOverflow(offset)
    guard !overflow, location >= 0, location != NSNotFound, length >= 0, length <= Int.max - location else { return nil }
    return NSRange(location: location, length: length)
  }

  private static func normalize(_ text: NSAttributedString, policy: UInt32) -> NSAttributedString? {
    let units = Array(text.string.utf16)
    if policy == 0 && units.contains(where: { $0 == 10 || $0 == 13 }) { return nil }
    guard policy <= 2 else { return nil }
    let result = NSMutableAttributedString(string: "")
    var index = 0, start = 0
    while index < units.count {
      if units[index] != 10 && units[index] != 13 { index += 1; continue }
      if index > start { result.append(text.attributedSubstring(from: NSRange(location: start, length: index - start))) }
      result.append(NSAttributedString(string: policy == 2 ? "\r\n" : "\n", attributes: text.attributes(at: index, effectiveRange: nil)))
      index += units[index] == 13 && index + 1 < units.count && units[index + 1] == 10 ? 2 : 1
      start = index
    }
    if start < units.count { result.append(text.attributedSubstring(from: NSRange(location: start, length: units.count - start))) }
    return result
  }
}
