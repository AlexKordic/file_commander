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
  private var requiresActionResult = false
  private var actionBroadcast = true

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
  public enum PointOrigin {
    case inserted(cursor: UInt64, position: ComposeAcceptedEdits.InsertedPosition)
    case before(Int)
  }
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
    observedCursors = Self.anchors(pane); actionBroadcast = replacement.location == NSNotFound
  }

  public init?(afterAction selections: ComposeVirtualSelections, pane: WireComposePane,
               text: NSAttributedString, selected: NSRange, replacement: NSRange) {
    guard let virtual = selections.actionPane(like: pane) else { return nil }
    self.init(pane: virtual, text: text, selected: selected, replacement: replacement)
    requiresActionResult = true
  }

  public func virtualInsertion(over selections: ComposeVirtualSelections) -> ComposeVirtualInsertion? {
    guard requiresActionResult else { return nil }
    return ComposeVirtualInsertion(selections: selections, drafts: presentation.values)
  }

  public init?(following previous: ComposePendingText, pane: WireComposePane,
               text: NSAttributedString, selected: NSRange, replacement: NSRange, virtualBase: ComposeVirtualSelections? = nil) {
    guard previous.committedEdits != nil else { return nil }
    let base = previous.presentation
    let broadcast = replacement.location == NSNotFound
    let sourcePane = previous.requiresActionResult ? virtualBase?.actionPane(like: pane) : pane
    let group = sourcePane?.cursors.map(\.id) ?? base.ordered
    let targets = broadcast ? Set(group) : [base.primaryID]
    guard !targets.isEmpty else { return nil }
    var values = base.values
    let missing = targets.subtracting(Set(base.ordered))
    var added: [UInt64: ComposeMarkedText] = [:]
    if !missing.isEmpty {
      guard broadcast, let sourcePane, let raw = ComposeComposition(pane: sourcePane, text: text, selected: selected, replacement: replacement) else { return nil }
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
    requiresActionResult = previous.requiresActionResult; actionBroadcast = broadcast
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

  public func provisionalSelections(over base: ComposeVirtualSelections? = nil, pane: WireComposePane? = nil) -> ComposeVirtualSelections? {
    if requiresActionResult {
      guard let base else { return nil }
      return virtualInsertion(over: base)?.provisionalSelections()
    }
    guard let pane else { return ComposeVirtualSelections(prefix: presentation) }
    // A primary-only prefix still needs the untouched carets and their raw
    // contexts when a later click starts a broadcast conversion.
    let missing = Set(pane.cursors.map(\.id)).subtracting(Set(presentation.ordered))
    if missing.isEmpty { return ComposeVirtualSelections(prefix: presentation) }
    guard let raw = ComposeComposition(pane: pane, text: NSAttributedString(string: ""), selected: NSRange(location: 0, length: 0),
      replacement: NSRange(location: NSNotFound, length: 0)) else { return nil }
    var values = presentation.values
    for cursor in pane.cursors where missing.contains(cursor.id) {
      guard let original = raw.values[cursor.id], let byte = Int(exactly: cursor.position),
            let unit = original.context.utf16Position(for: byte),
            let marker = ComposeMarkedText(context: original.context, range: NSRange(location: unit, length: 0), source: byte..<byte,
              text: NSAttributedString(string: ""), selected: NSRange(location: 0, length: 0), marked: NSRange(location: 0, length: 0)) else { return nil }
      values[cursor.id] = marker
    }
    guard let augmented = ComposeComposition(primary: presentation.primaryID, values: values) else { return nil }
    func map(_ unit: Int) -> Int? {
      var shift = 0
      for id in presentation.ordered {
        let value = presentation.values[id]!, range = value.originalRange
        if range.location <= unit && unit < NSMaxRange(range) { return nil }
        if NSMaxRange(range) <= unit { shift += value.draft.length - range.length }
      }
      let (position, overflow) = unit.addingReportingOverflow(shift)
      return !overflow && position >= 0 ? position : nil
    }
    var cursors: [UInt64: ComposeVirtualSelections.Cursor] = [:]
    for cursor in pane.cursors {
      if let value = presentation.values[cursor.id] {
        let start = augmented.virtualStart(for: cursor.id)
        cursors[cursor.id] = .init(position: start + NSMaxRange(value.selected),
          anchor: value.selected.length == 0 ? nil : start + value.selected.location)
      } else {
        guard let original = raw.values[cursor.id] else { return nil }
        let backwards = cursor.hasAnchor && cursor.position < cursor.anchor
        guard let position = map(backwards ? original.originalRange.location : NSMaxRange(original.originalRange)) else { return nil }
        let anchor: Int?
        if cursor.hasAnchor {
          guard let point = map(backwards ? NSMaxRange(original.originalRange) : original.originalRange.location) else { return nil }; anchor = point
        } else { anchor = nil }
        cursors[cursor.id] = .init(position: position, anchor: anchor)
      }
    }
    return ComposeVirtualSelections(prefix: augmented, primary: presentation.primaryID, cursors: cursors)
  }

  public func pointer(scope: WireComposeScope, epoch: UInt64, displayed: ComposeComposition,
                      point: Int, basis: ComposeVirtualSelections, affinity: ComposeProjection.Affinity,
                      extend: Bool, count: Int, nativeNewline: UInt32) -> ComposePendingPointer? {
    guard committedEdits != nil else { return nil }
    guard let normalizedPoint = normalizedPosition(point,displayed: displayed,nativeNewline: nativeNewline) else { return nil }
    let owners = ordered.compactMap { id -> (UInt64, Int, ComposeAcceptedEdits.InsertedPosition?)? in
      basis.cursors[id].map { (id, $0.position, insertedPosition(cursor: id,offset: normalizedPoint-presentation.virtualStart(for: id))) }
    }.sorted {
      if ($0.2 == nil) != ($1.2 == nil) { return $0.2 != nil }
      return abs($0.1-normalizedPoint) < abs($1.1-normalizedPoint)
    }
    for (id, caret, inserted) in owners {
      let low = min(caret, normalizedPoint), length = abs(caret - normalizedPoint)
      guard let raw = basis.substring(for: NSRange(location: low, length: length)) else { continue }
      return ComposePendingPointer(scope: scope, epoch: epoch, cursor: id, text: raw.string,
        caretOffset: caret - low, offset: normalizedPoint - low, affinity: affinity, extend: extend, count: count,inserted: inserted)
    }
    return nil
  }

  public func normalizedPosition(_ point: Int, displayed: ComposeComposition, nativeNewline: UInt32) -> Int? {
    guard committedEdits != nil, point >= 0 else { return nil }
    var normalizedPoint = point
    for id in displayed.ordered {
      guard let shown = displayed.values[id], let value = presentation.values[id], shown.source == value.source,
            shown.originalRange == value.originalRange else { return nil }
      let same = shown.draft.string.utf16.elementsEqual(value.draft.string.utf16)
      let change: NSRange
      if same { change = NSRange(location: 0,length: 0) }
      else if baseline != nil, let edit = committedEdits?[id] {
        change = edit.display
        guard ComposeTextIndex(shown.draft.string).bytes(for: change) != nil,
              (shown.draft.string as NSString).replacingCharacters(in: change,with: edit.inserted.string)
                .utf16.elementsEqual(value.draft.string.utf16) else { return nil }
      } else {
        change = NSRange(location: 0,length: shown.draft.length)
        guard let normalized = Self.normalize(shown.draft,policy: nativeNewline),
              normalized.string.utf16.elementsEqual(value.draft.string.utf16) else { return nil }
      }
      let start = displayed.virtualStart(for: id), end = start + shown.draft.length
      if start <= point && point <= end {
        let offset = point - start
        guard ComposeTextIndex(shown.draft.string).byte(forUnit: offset) != nil else { return nil }
        let normalizedOffset: Int
        if same || offset < change.location { normalizedOffset = offset }
        else if offset > NSMaxRange(change) { normalizedOffset = offset+value.draft.length-shown.draft.length }
        else {
          let inserted = shown.draft.attributedSubstring(from: change)
          guard let local = Self.normalizedOffset(offset-change.location,in: inserted,policy: nativeNewline) else { return nil }
          normalizedOffset = change.location+local
        }
        normalizedPoint = presentation.virtualStart(for: id)+normalizedOffset
        break
      }
      if end < point { normalizedPoint += value.draft.length - shown.draft.length }
    }
    return normalizedPoint
  }

  /// Capture a displayed draft point against this committed prefix. A commit
  /// can normalize newlines, so convert the captured prefix before retaining
  /// its offset. Receipt resolution still proves the actual resulting text.
  public func pointer(scope: WireComposeScope, epoch: UInt64, displayed: ComposeComposition,
                      cursor: UInt64, offset: Int, affinity: ComposeProjection.Affinity,
                      extend: Bool, count: Int, nativeNewline: UInt32) -> ComposePendingPointer? {
    guard committedEdits != nil, let value = presentation.values[cursor], let shown = displayed.values[cursor],
          value.source == shown.source, value.originalRange == shown.originalRange, value.selected.length == 0,
          offset >= 0, offset <= shown.draft.length,
          let position = normalizedPosition(displayed.virtualStart(for: cursor)+offset,displayed: displayed,nativeNewline: nativeNewline) else { return nil }
    let normalizedOffset = position-presentation.virtualStart(for: cursor)
    return ComposePendingPointer(scope: scope, epoch: epoch, cursor: cursor, text: value.draft.string,
      caretOffset: value.selected.location, offset: normalizedOffset, affinity: affinity, extend: extend, count: count,
      inserted: insertedPosition(cursor: cursor,offset: normalizedOffset))
  }

  private func insertedPosition(cursor: UInt64, offset: Int) -> ComposeAcceptedEdits.InsertedPosition? {
    guard let value = presentation.values[cursor], offset >= 0, offset <= value.draft.length else { return nil }
    if baseline == nil { return .init(text: value.draft.string,offsetUTF16: offset) }
    guard let edit = committedEdits?[cursor], offset >= edit.display.location,
          offset-edit.display.location <= edit.inserted.length else { return nil }
    return .init(text: edit.inserted.string,offsetUTF16: offset-edit.display.location)
  }

  private static func normalizedOffset(_ offset: Int, in text: NSAttributedString, policy: UInt32) -> Int? {
    guard ComposeTextIndex(text.string).byte(forUnit: offset) != nil else { return nil }
    let value = text.string as NSString
    guard let prefix = normalize(NSAttributedString(string: value.substring(to: offset)),policy: policy) else { return nil }
    // A point between an existing CR/LF pair keeps that scalar boundary in a
    // CRLF buffer. Normalizing the truncated prefix alone adds a spurious LF.
    let splitPair = policy == 2 && offset > 0 && offset < value.length
      && value.character(at: offset-1) == 13 && value.character(at: offset) == 10
    return prefix.length-(splitPair ? 1:0)
  }

  /// Walk an immutable provisional point back through this transaction. An
  /// insertion binds to a genuine cursor and exact payload; an unchanged
  /// position stays on the preceding provisional axis, without reading a gap
  /// between bounded raw chunks or manufacturing a source byte offset.
  public struct Origins {
    fileprivate struct Delta { let cursor: UInt64; let before, after: NSRange; let text: String }
    fileprivate let deltas: [Delta]
    fileprivate let contexts: [ComposeTextContext]
    public var retainedTextBytes: Int { deltas.reduce(0) { $0 + $1.text.utf8.count } }

    public func origin(atProvisionalUTF16 point: Int, affinity: ComposeProjection.Affinity = .downstream) -> PointOrigin? {
      guard point >= 0 else { return nil }
      let candidates = affinity == .upstream ? deltas : Array(deltas.reversed())
      for delta in candidates where delta.after.location <= point && point <= NSMaxRange(delta.after) {
        guard let inserted = ComposeAcceptedEdits.InsertedPosition(text: delta.text,offsetUTF16: point-delta.after.location) else { return nil }
        return .inserted(cursor: delta.cursor,position: inserted)
      }
      var shift = 0
      for delta in deltas {
        if point < delta.after.location { break }
        shift += delta.after.length-delta.before.length
      }
      let (before, overflow) = point.subtractingReportingOverflow(shift)
      return overflow || before < 0 ? nil : .before(before)
    }

    public func sourcePosition(beforePendingAtUTF16 point: Int, documentLength: UInt64) -> Int? {
      guard let length = Int(exactly: documentLength) else { return nil }
      return contexts.lazy.compactMap { context in
        context.documentLength == length
          ? context.sourceRange(forUTF16: NSRange(location: point, length: 0))?.lowerBound : nil
      }.first
    }
  }

  /// Freeze just this delta and bounded raw contexts, without retaining all
  /// earlier cumulative prefixes or attributed input values in a queue node.
  public func origins() -> Origins? {
    guard committedEdits != nil else { return nil }
    var deltas: [Origins.Delta] = []
    for id in ordered {
      let value = presentation.values[id]!
      let before: NSRange, text: String, display: Int
      if let baseline {
        guard let edit = committedEdits?[id] else { return nil }
        text = edit.inserted.string; display = edit.display.location
        if let original = newlyIncluded[id], let length = edit.selectionLength {
          guard let start = baseline.virtualPosition(forOriginalUTF16: original.originalRange.location),
                let range = Self.range(at: start,offset: -edit.leading.utf16.count,
                  length: length+edit.leading.utf16.count+edit.trailing.utf16.count) else { return nil }
          before = range
        } else {
          guard let previous = baseline.values[id],
                let range = Self.range(at: baseline.virtualStart(for: id)+NSMaxRange(previous.selected),
                  offset: edit.offset,length: edit.removed.utf16.count) else { return nil }
          before = range
        }
      } else { before = value.originalRange; text = value.draft.string; display = 0 }
      if before.length == 0 && text.isEmpty { continue }
      let after = NSRange(location: presentation.virtualStart(for: id)+display,length: text.utf16.count)
      deltas.append(.init(cursor: id,before: before,after: after,text: text))
    }
    deltas.sort { ($0.before.location, $0.before.length) < ($1.before.location, $1.before.length) }
    var shift = 0, previous: NSRange?
    for delta in deltas {
      let (start, overflow) = delta.before.location.addingReportingOverflow(shift)
      guard !overflow, start == delta.after.location,
            previous.map({ NSMaxRange($0) <= delta.before.location && $0.location != delta.before.location }) ?? true else { return nil }
      shift += delta.after.length-delta.before.length; previous = delta.before
    }
    return Origins(deltas: deltas, contexts: requiresActionResult ? [] : presentation.values.values.map(\.context))
  }

  public func origin(atProvisionalUTF16 point: Int, affinity: ComposeProjection.Affinity = .downstream) -> PointOrigin? {
    origins()?.origin(atProvisionalUTF16: point, affinity: affinity)
  }

  public func sourcePosition(beforePendingAtUTF16 point: Int, documentLength: UInt64) -> Int? {
    guard !requiresActionResult, let length = Int(exactly: documentLength) else { return nil }
    return presentation.values.values.lazy.compactMap { value in
      value.context.documentLength == length
        ? value.context.sourceRange(forUTF16: NSRange(location: point,length: 0))?.lowerBound : nil
    }.first
  }

  /// Only real, receipt-bound ranges can become wire replacements.
  public func replacement(scope: WireComposeScope, epoch: UInt64) -> ComposeReplacement? {
    guard baseline == nil, !requiresActionResult else { return nil }
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

  /// Rebuild a later conversion over its predecessor's rebound preview. Only
  /// the captured delta is replayed; source coordinates come from that new
  /// prefix and its real receipt. A confirmed action can introduce carets that
  /// were unavailable in the earlier preview, using the broadcast input intent.
  public func replaying(over previous: ComposePendingText, pane: WireComposePane,
                        aliases: [UInt64: UInt64], virtualBase: ComposeVirtualSelections? = nil) -> ComposePendingText? {
    guard baseline != nil, previous.committedEdits != nil, Set(aliases.values).count == aliases.count else { return nil }
    let inverse = Dictionary(uniqueKeysWithValues: aliases.map { ($0.value, $0.key) })
    let sourcePane = previous.requiresActionResult ? virtualBase?.actionPane(like: pane) : pane
    let group = sourcePane?.cursors.map(\.id) ?? previous.presentation.ordered
    let targets = actionBroadcast ? Set(group) : [previous.presentation.primaryID]
    guard !targets.isEmpty else { return nil }
    var values = previous.presentation.values, added: [UInt64: ComposeMarkedText] = [:]
    let missing = targets.subtracting(Set(values.keys))
    if !missing.isEmpty {
      guard let sourcePane, let raw = ComposeComposition(pane: sourcePane, text: NSAttributedString(string: ""),
        selected: NSRange(location: 0, length: 0), replacement: NSRange(location: NSNotFound, length: 0)) else { return nil }
      for id in missing {
        guard let value = raw.values[id] else { return nil }; values[id] = value; added[id] = value
      }
    }
    for id in targets {
      let mapped = inverse[id].flatMap { active.contains($0) ? $0 : nil }
      let template = mapped ?? (aliases[id] == nil && active.contains(id) ? id : presentation.primaryID)
      guard active.contains(template), let intent = committedEdits?[template] ?? edit(for: template), var value = values[id] else { return nil }
      let range: NSRange
      if let length = intent.selectionLength {
        guard let original = added[id], original.originalRange.length == length,
              let expanded = Self.range(at: original.originalRange.location, offset: -intent.leading.utf16.count,
                length: length + intent.leading.utf16.count + intent.trailing.utf16.count),
              intent.leading.isEmpty || Self.exact(original.context.exactText(for: NSRange(location: expanded.location, length: intent.leading.utf16.count)), intent.leading),
              intent.trailing.isEmpty || Self.exact(original.context.exactText(for: NSRange(location: NSMaxRange(original.originalRange), length: intent.trailing.utf16.count)), intent.trailing) else { return nil }
        range = expanded
      } else {
        guard let (capture, removed) = Self.replayedRange(intent, before: baseline?.values[template], after: value, policy: pane.nativeNewline),
              let known = value.substring(for: capture), known.range.location <= capture.location,
              NSMaxRange(capture) <= NSMaxRange(known.range),
              Self.exact(known.text.attributedSubstring(from: NSRange(location: capture.location - known.range.location, length: capture.length)).string,
                removed) else { return nil }
        range = capture
      }
      guard value.update(intent.inserted, selected: intent.selected, replacement: range) else { return nil }
      guard let marked = Self.range(at: value.marked.location, offset: intent.marked.location, length: intent.marked.length),
            let updated = ComposeMarkedText(context: value.context, range: value.originalRange, source: value.source,
              text: value.draft, selected: value.selected, marked: marked) else { return nil }
      values[id] = updated
    }
    guard let composition = ComposeComposition(primary: previous.presentation.primaryID, values: values) else { return nil }
    let result = ComposePendingText(presentation: composition, baseline: previous.presentation, active: targets,
      newlyIncluded: added, observed: previous.observedCursors, requiresAction: previous.requiresActionResult, broadcast: actionBroadcast)
    return committedEdits == nil ? result : result.committed(nativeNewline: pane.nativeNewline)
  }

  /// An earlier action can change the newline policy before this prefix is
  /// inserted. Rebase points through that exact owned normalization, including
  /// replacements spanning its edges. Text outside the prefix stays literal.
  private static func replayedRange(_ edit: Edit, before: ComposeMarkedText?, after: ComposeMarkedText,
                                    policy: UInt32) -> (NSRange, String)? {
    guard let before, !exact(before.draft.string, after.draft.string),
          let normalized = normalize(before.draft, policy: policy), exact(normalized.string, after.draft.string) else {
      return range(at: NSMaxRange(after.selectedRange), offset: edit.offset, length: edit.removed.utf16.count).map { ($0, edit.removed) }
    }
    guard let old = range(at: NSMaxRange(before.selectedRange), offset: edit.offset, length: edit.removed.utf16.count),
          let known = before.substring(for: old), known.range.location <= old.location, NSMaxRange(old) <= NSMaxRange(known.range),
          exact(known.text.attributedSubstring(from: NSRange(location: old.location-known.range.location, length: old.length)).string,
            edit.removed) else { return nil }
    let start = old.location-before.originalRange.location, end = NSMaxRange(old)-before.originalRange.location
    func point(_ value: Int) -> Int? {
      if value < 0 { return value }
      if value <= before.draft.length { return normalizedOffset(value, in: before.draft, policy: policy) }
      let (mapped, overflow) = value.addingReportingOverflow(normalized.length-before.draft.length)
      return overflow ? nil : mapped
    }
    guard let a = point(start), let b = point(end), b >= a,
          let mapped = range(at: after.originalRange.location, offset: a, length: b-a) else { return nil }
    let literal = edit.removed as NSString
    let leading = start < 0 ? min(old.length, -start) : 0
    let trailing = end > before.draft.length ? min(old.length, end-before.draft.length) : 0
    var removed = literal.substring(to: leading)
    if end > 0 && start < before.draft.length {
      guard let low = point(max(0, start)), let high = point(min(before.draft.length, end)), high >= low else { return nil }
      removed += (normalized.string as NSString).substring(with: NSRange(location: low, length: high-low))
    }
    removed += literal.substring(from: literal.length-trailing)
    return (mapped, removed)
  }

  private init(presentation: ComposeComposition, baseline: ComposeComposition, active: Set<UInt64>,
               newlyIncluded: [UInt64: ComposeMarkedText], observed: [WireComposeCursorAnchor], requiresAction: Bool, broadcast: Bool) {
    self.presentation = presentation; self.baseline = baseline; self.active = active
    self.newlyIncluded = newlyIncluded; observedCursors = observed
    requiresActionResult = requiresAction; actionBroadcast = broadcast
  }

  /// A conversion begun after a queued non-text action follows that action's
  /// resulting selections. Its entered text is retained; expansions outside
  /// the initial conversion still require the same surrounding source. For a
  /// caret created by the action, use the primary conversion's input intent.
  /// Already submitted prefixes are excluded from the resulting replacement.
  public func afterAction(_ initial: ComposePendingText, pane: WireComposePane, aliases: [UInt64: UInt64] = [:]) -> ComposePendingText? {
    guard Set(aliases.values).count == aliases.count else { return nil }
    let inverse = Dictionary(uniqueKeysWithValues: aliases.map { ($0.value, $0.key) })
    let observed = Self.anchors(pane)
    var pane = pane
    if !actionBroadcast {
      pane.cursors = pane.cursors.filter(\.primary)
      guard pane.cursors.count == 1 else { return nil }
      pane.cursors[0].primary = true
    }
    guard let fresh = ComposeComposition(pane: pane, text: NSAttributedString(string: ""),
      selected: NSRange(location: 0, length: 0), replacement: NSRange(location: NSNotFound, length: 0)) else { return nil }
    let cursors = Dictionary(uniqueKeysWithValues: pane.cursors.map { ($0.id, $0) })
    var values: [UInt64: ComposeMarkedText] = [:]
    for id in fresh.ordered {
      let mapped = inverse[id].flatMap { active.contains($0) ? $0 : nil }
      let template = mapped ?? (aliases[id] == nil && active.contains(id) ? id : presentation.primaryID)
      guard let intent = intent(for: template, initial: initial), let target = fresh.values[id],
            let cursor = cursors[id], cursor.hasUtf16Position,
            let byte = Int(exactly: cursor.position), let unit = Int(exactly: cursor.utf16Position),
            target.context.utf16Position(for: byte) == unit else { return nil }
      let left = intent.leading.utf16.count, right = intent.trailing.utf16.count
      guard let range = Self.range(at: target.originalRange.location, offset: -left,
        length: target.originalRange.length + left + right),
        left == 0 || Self.exact(target.context.exactText(for: NSRange(location: range.location, length: left)), intent.leading),
        right == 0 || Self.exact(target.context.exactText(for: NSRange(location: NSMaxRange(target.originalRange), length: right)), intent.trailing),
        target.source.lowerBound >= intent.leading.utf8.count,
        intent.trailing.utf8.count <= Int(pane.documentLen) - target.source.upperBound else { return nil }
      let source = (target.source.lowerBound - intent.leading.utf8.count)..<(target.source.upperBound + intent.trailing.utf8.count)
      guard let value = ComposeMarkedText(context: target.context, range: range, source: source,
        text: intent.inserted, selected: intent.selected, marked: intent.marked) else { return nil }
      values[id] = value
    }
    guard let composition = ComposeComposition(primary: fresh.primaryID, values: values) else { return nil }
    let result = ComposePendingText(presentation: composition, committed: false, observedCursors: observed)
    return committedEdits == nil ? result : result.committed(nativeNewline: pane.nativeNewline)
  }

  private func intent(for id: UInt64, initial: ComposePendingText) -> Edit? {
    if baseline != nil {
      guard var current = committedEdits?[id] ?? edit(for: id), let start = initial.edit(for: id) else { return nil }
      if current.selectionLength == nil {
        let left = start.offset - current.offset
        let right = current.offset + current.removed.utf16.count - start.offset - start.removed.utf16.count
        let old = current.removed as NSString
        guard left >= 0, right >= 0, left + right <= old.length else { return nil }
        current.leading = old.substring(to: left); current.trailing = old.substring(from: old.length - right)
      }
      return current
    }
    guard let current = presentation.values[id], let start = initial.presentation.values[id] else { return nil }
    let left = start.originalRange.location - current.originalRange.location
    let right = NSMaxRange(current.originalRange) - NSMaxRange(start.originalRange)
    guard left >= 0, right >= 0,
      let leading = left == 0 ? "" : current.context.exactText(for: NSRange(location: current.originalRange.location, length: left)),
      let trailing = right == 0 ? "" : current.context.exactText(for: NSRange(location: NSMaxRange(start.originalRange), length: right)) else { return nil }
    return Edit(offset: 0, removed: "", inserted: current.draft, marked: current.marked, selected: current.selected,
      display: NSRange(location: 0, length: current.draft.length), leading: leading, trailing: trailing)
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
    value.map { $0.utf16.elementsEqual(expected.utf16) } ?? false
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
