import Foundation

/// One input-method conversion, bound to all of its original cursor/source
/// snapshots. Updates are validated on copies before any caret is changed.
public struct ComposeComposition {
  public let primaryID: UInt64
  public private(set) var values: [UInt64: ComposeMarkedText]
  private let order: [UInt64]
  private let starts: [UInt64: Int]
  public var primary: ComposeMarkedText { values[primaryID]! }
  public var ordered: [UInt64] { order }
  public var markedRange: NSRange { shifted(primary.markedRange, by: shift(before: primaryID)) }
  public var selectedRange: NSRange { shifted(primary.selectedRange, by: shift(before: primaryID)) }

  /// Marked/selected clauses change caret feedback, not shaped text. Include
  /// raw context because a replacement can reveal part of an atomic conceal.
  func hasSameLayout(as other: Self) -> Bool {
    guard primaryID == other.primaryID, ordered == other.ordered else { return false }
    return ordered.allSatisfy { id in
      let a = values[id]!, b = other.values[id]!
      return a.source == b.source && a.originalRange == b.originalRange
        && a.draft.string.utf8.elementsEqual(b.draft.string.utf8) && a.draft.isEqual(to: b.draft)
        && a.context.source == b.context.source && a.context.range == b.context.range
        && a.context.documentLength == b.context.documentLength
        && a.context.text.utf8.elementsEqual(b.context.text.utf8)
    }
  }

  public init?(primary: UInt64, values: [UInt64: ComposeMarkedText]) {
    guard values[primary] != nil, Self.valid(values) else { return nil }
    primaryID = primary; self.values = values
    order = values.keys.sorted { values[$0]!.source.lowerBound < values[$1]!.source.lowerBound }
    var offset = 0, starts: [UInt64: Int] = [:]
    for id in order {
      let value = values[id]!
      starts[id] = value.originalRange.location + offset
      offset += value.draft.length - value.originalRange.length
    }
    self.starts = starts
  }

  public init?(pane: WireComposePane, text: NSAttributedString, selected: NSRange, replacement: NSRange) {
    guard let cursor = pane.cursors.first(where: \.primary) ?? pane.cursors.first,
          pane.hasTextContext, let primaryContext = ComposeTextContext(pane.textContext, documentLength: pane.documentLen) else { return nil }
    let broadcast = replacement.location == NSNotFound
    let contexts = [primaryContext] + pane.textChunks.compactMap { chunk -> ComposeTextContext? in
      let wire = WireComposeTextContext.with { $0.text = chunk.text; $0.sourceStart = chunk.sourceStart; $0.utf16Start = chunk.utf16Start }
      return ComposeTextContext(wire, documentLength: pane.documentLen)
    }
    var values: [UInt64: ComposeMarkedText] = [:]
    for caret in pane.cursors where broadcast || caret.id == cursor.id {
      let low = min(caret.position, caret.hasAnchor ? caret.anchor : caret.position)
      let high = max(caret.position, caret.hasAnchor ? caret.anchor : caret.position)
      let raw = contexts.first { context in Int(exactly: caret.position).map { $0 >= context.source.lowerBound && $0 <= context.source.upperBound } ?? false }
      let fallbackPosition = caret.id == cursor.id ? (caret.hasAnchor && caret.position < caret.anchor ? primaryContext.selection.location : NSMaxRange(primaryContext.selection)) : nil
      let position = caret.hasUtf16Position ? Int(exactly: caret.utf16Position) : Int(exactly: caret.position).flatMap { raw?.utf16Position(for: $0) } ?? fallbackPosition
      let anchor = caret.hasAnchor ? (caret.hasUtf16Anchor ? Int(exactly: caret.utf16Anchor)
        : Int(exactly: caret.anchor).flatMap { raw?.utf16Position(for: $0) }
          ?? (caret.id == cursor.id ? (caret.position < caret.anchor ? NSMaxRange(primaryContext.selection) : primaryContext.selection.location) : nil)) : position
      guard let position, let anchor else { return nil }
      guard let context = raw?.selecting(NSRange(location: min(position, anchor), length: abs(position - anchor))),
            let a = Int(exactly: low), let b = Int(exactly: high) else { return nil }
      let range = broadcast ? context.selection : replacement
      let source = broadcast || replacement == primaryContext.selection ? a..<b : context.sourceRange(forUTF16: replacement)
      guard let source, let value = ComposeMarkedText(context: context, range: range, source: source, text: text, selected: selected) else { return nil }
      guard values.updateValue(value, forKey: caret.id) == nil else { return nil }
    }
    self.init(primary: cursor.id, values: values)
  }

  /// A new conversion started while a preceding native commit was pending.
  /// Only its receipt's edited cursors can supply the new insertion basis.
  /// Unchanged context outside an expanded range must agree with that receipt.
  public func following(_ initial: ComposeComposition, pane: WireComposePane, edited: [UInt64]) -> ComposeComposition? {
    guard primaryID == initial.primaryID, Set(ordered) == Set(initial.ordered), Set(edited).count == edited.count,
          Set(ordered).isSubset(of: Set(edited)), pane.hasTextContext else { return nil }
    var pane = pane
    pane.cursors = pane.cursors.filter { values[$0.id] != nil }
    guard pane.cursors.count == values.count, pane.cursors.allSatisfy({
      (!$0.hasAnchor || $0.anchor == $0.position) && $0.hasUtf16Position
    }) else { return nil }
    for index in pane.cursors.indices { pane.cursors[index].primary = pane.cursors[index].id == primaryID }
    guard let fresh = ComposeComposition(pane: pane, text: NSAttributedString(string: ""),
      selected: NSRange(location: 0, length: 0), replacement: NSRange(location: NSNotFound, length: 0)) else { return nil }
    var rebased: [UInt64: ComposeMarkedText] = [:]
    for id in ordered {
      guard let value = values[id], let basis = initial.values[id], let target = fresh.values[id] else { return nil }
      let prefix = basis.originalRange.location - value.originalRange.location
      let suffix = NSMaxRange(value.originalRange) - NSMaxRange(basis.originalRange)
      guard prefix >= 0, suffix >= 0, target.originalRange.length == 0,
            target.context.sourceRange(forUTF16: target.originalRange) == target.source,
            target.originalRange.location >= prefix, suffix <= Int.max - target.originalRange.location else { return nil }
      let range = NSRange(location: target.originalRange.location - prefix, length: prefix + suffix)
      // A range extending outside the initial conversion cannot silently take
      // different surrounding bytes from the predecessor or another edit.
      for (old, new) in [
        (NSRange(location: value.originalRange.location, length: prefix), NSRange(location: range.location, length: prefix)),
        (NSRange(location: NSMaxRange(basis.originalRange), length: suffix), NSRange(location: target.originalRange.location, length: suffix)),
      ] where old.length > 0 {
        guard let before = value.context.exactText(for: old), before == target.context.exactText(for: new) else { return nil }
      }
      guard let source = target.context.sourceRange(forUTF16: range),
            let next = ComposeMarkedText(context: target.context, range: range, source: source,
              text: value.draft, selected: value.selected, marked: value.marked) else { return nil }
      rebased[id] = next
    }
    return ComposeComposition(primary: primaryID, values: rebased)
  }

  public func virtualStart(for id: UInt64) -> Int { starts[id]! }

  @discardableResult
  public mutating func update(_ text: NSAttributedString, selected: NSRange, replacement: NSRange) -> Bool {
    let range = replacement.location == NSNotFound ? markedRange : replacement
    guard range.location != NSNotFound, range.location >= 0 else { return false }
    let relative = range.location - virtualStart(for: primaryID)
    var updated = values
    for id in ordered {
      var value = values[id]!
      let (location, overflow) = value.originalRange.location.addingReportingOverflow(relative)
      guard !overflow, location >= 0,
            value.update(text, selected: selected, replacement: NSRange(location: location, length: range.length)) else { return false }
      updated[id] = value
    }
    guard let next = ComposeComposition(primary: primaryID, values: updated) else { return false }
    self = next; return true
  }

  @discardableResult
  public mutating func select(_ range: NSRange) -> Bool {
    guard range.location >= 0, range.location != NSNotFound else { return false }
    let relative = range.location - virtualStart(for: primaryID)
    var updated = values
    for id in ordered {
      var value = values[id]!
      let (location, overflow) = value.originalRange.location.addingReportingOverflow(relative)
      guard !overflow, location >= 0,
            value.select(NSRange(location: location, length: range.length)) else { return false }
      updated[id] = value
    }
    values = updated; return true
  }

  public func substring(for proposed: NSRange) -> (text: NSAttributedString, range: NSRange)? {
    guard proposed.location >= 0, proposed.location != NSNotFound, proposed.length >= 0,
          proposed.length <= Int.max - proposed.location else { return nil }
    let context = primary.context
    var start = min(context.range.location, primary.originalRange.location)
    var end = max(NSMaxRange(context.range), NSMaxRange(primary.originalRange))
    let ids = ordered.filter { id in
      let range = values[id]!.originalRange
      return range.location <= end && NSMaxRange(range) >= start
    }
    for id in ids { start = min(start, values[id]!.originalRange.location); end = max(end, NSMaxRange(values[id]!.originalRange)) }
    let text = NSMutableAttributedString(string: "")
    var position = start
    for id in ids {
      let value = values[id]!
      guard let raw = position == value.originalRange.location ? "" : context.exactText(for: NSRange(location: position, length: value.originalRange.location - position)) else { return nil }
      text.append(NSAttributedString(string: raw)); text.append(value.draft)
      position = NSMaxRange(value.originalRange)
    }
    guard let suffix = position == end ? "" : context.exactText(for: NSRange(location: position, length: end - position)) else { return nil }
    text.append(NSAttributedString(string: suffix))
    let included = Set(ids)
    let before = ordered.filter { !included.contains($0) && NSMaxRange(values[$0]!.originalRange) <= start }
      .reduce(0) { $0 + values[$1]!.draft.length - values[$1]!.originalRange.length }
    let base = start + before
    let a = max(base, proposed.location), b = min(base + text.length, NSMaxRange(proposed))
    guard a <= b else { return nil }
    let range = (text.string as NSString).rangeOfComposedCharacterSequences(for: NSRange(location: a - base, length: b - a))
    return (text.attributedSubstring(from: range), NSRange(location: base + range.location, length: range.length))
  }

  public func project(over base: ComposeProjection) -> (projection: ComposeProjection, displays: [UInt64: Range<Int>])? {
    let visible = ordered.filter { values[$0]!.source.lowerBound <= base.source.upperBound && values[$0]!.source.upperBound >= base.source.lowerBound }
    var projection = base
    // Unchanged caret contexts carry no edit and must not reveal a conceal.
    for id in visible.reversed() where !values[id]!.source.isEmpty || values[id]!.draft.length > 0 {
      guard let replacement = values[id]!.projection(over: projection) else { return nil }
      projection = replacement.projection
    }
    var displays: [UInt64: Range<Int>] = [:]
    for id in visible {
      let value = values[id]!
      if let segment = projection.segments.first(where: { $0.source == value.source && $0.kind != .copy && $0.display.count == value.draft.string.utf8.count }) {
        displays[id] = segment.display
      } else if value.source.isEmpty, value.draft.length == 0, let position = projection.displayPosition(for: value.source.lowerBound, affinity: .upstream) {
        displays[id] = position..<position
      } else { return nil }
    }
    return (projection, displays)
  }

  public func draftPosition(at virtual: Int) -> (id: UInt64, offset: Int)? {
    // Prefer the primary at a shared end/start boundary for candidate queries.
    for id in [primaryID] + ordered.filter({ $0 != primaryID }) {
      let start = virtualStart(for: id)
      if virtual >= start && virtual <= start + values[id]!.draft.length { return (id, virtual - start) }
    }
    return nil
  }

  public func sourcePosition(at virtual: Int) -> Int? {
    var shift = 0
    for id in ordered {
      let value = values[id]!, start = value.originalRange.location + shift
      if virtual >= start && virtual <= start + value.draft.length { return nil }
      if virtual < start { break }
      shift += value.draft.length - value.originalRange.length
    }
    let (original, overflow) = virtual.subtractingReportingOverflow(shift)
    guard !overflow, original >= 0 else { return nil }
    return values.values.lazy.compactMap { $0.context.sourceRange(forUTF16: NSRange(location: original, length: 0))?.lowerBound }.first
  }

  /// Byte position in the derived raw provisional document, for internal
  /// action-intent contexts only. This is never a Fresh source coordinate.
  func virtualSourcePosition(atUTF16 position: Int) -> Int? {
    if let point = draftPosition(at: position), let value = values[point.id] {
      let shift = ordered.prefix(while: { $0 != point.id }).reduce(0) {
        $0 + values[$1]!.draft.string.utf8.count - values[$1]!.source.count
      }
      let local = (value.draft.string as NSString).substring(to: point.offset).utf8.count
      return value.source.lowerBound + shift + local
    }
    guard let source = sourcePosition(at: position) else { return nil }
    let shift = ordered.filter { values[$0]!.source.upperBound <= source }.reduce(0) {
      $0 + values[$1]!.draft.string.utf8.count - values[$1]!.source.count
    }
    let (result, overflow) = source.addingReportingOverflow(shift)
    return !overflow && result >= 0 ? result : nil
  }

  public func virtualPosition(for source: Int) -> Int? {
    guard let original = values.values.lazy.compactMap({ $0.context.utf16Position(for: source) }).first else { return nil }
    let offset = ordered.filter { NSMaxRange(values[$0]!.originalRange) <= original }
      .reduce(0) { $0 + values[$1]!.draft.length - values[$1]!.originalRange.length }
    return original + offset
  }

  private func shift(before id: UInt64) -> Int {
    starts[id]! - values[id]!.originalRange.location
  }

  private func shifted(_ range: NSRange, by offset: Int) -> NSRange { NSRange(location: range.location + offset, length: range.length) }

  private static func valid(_ values: [UInt64: ComposeMarkedText]) -> Bool {
    let ordered = values.values.sorted { $0.source.lowerBound < $1.source.lowerBound }
    return zip(ordered, ordered.dropFirst()).allSatisfy {
      $0.source.lowerBound != $1.source.lowerBound && $0.source.upperBound <= $1.source.lowerBound
        && NSMaxRange($0.originalRange) <= $1.originalRange.location
    }
  }
}
