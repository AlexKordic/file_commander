import Foundation

/// One immutable broadcast conversion over a pending prefix. Draft regions
/// are folded back onto real source ranges; synthetic region keys are never
/// cursor identities or wire coordinates. Several carets may edit one region.
public struct ComposeVirtualInsertion {
  // Synthetic region identities stay inside the presentation implementation.
  let regions: ComposeComposition
  public var sourceRanges: [Range<Int>] { regions.ordered.compactMap {
    let value = regions.values[$0]!
    return value.source.isEmpty && value.draft.length == 0 ? nil : value.source
  } }
  public let primaryID: UInt64
  public let cursors: [UInt64: ComposeVirtualSelections.Cursor]
  public let marked: [UInt64: NSRange]
  public let drafts: [UInt64: NSRange]
  private let placements: [UInt64: Placement]
  private struct Placement { let region: UInt64; let range, marked: NSRange }
  private struct Edit { let range: NSRange; let text: NSAttributedString; let marked, selected: NSRange }
  private struct Group { var original: NSRange; var source: Range<Int> }

  public init?(selections: ComposeVirtualSelections, text: NSAttributedString, selected: NSRange) {
    self.init(selections: selections, edits: selections.cursors.mapValues {
      Edit(range: $0.selection, text: text, marked: NSRange(location: 0, length: text.length), selected: selected)
    })
  }

  public init?(selections: ComposeVirtualSelections, drafts: [UInt64: ComposeMarkedText]) {
    self.init(selections: selections, edits: drafts.mapValues {
      Edit(range: $0.originalRange, text: $0.draft, marked: $0.marked, selected: $0.selected)
    })
  }

  private init?(selections: ComposeVirtualSelections, edits: [UInt64: Edit]) {
    let prefix = selections.prefix
    guard !edits.isEmpty, Set(edits.keys).isSubset(of: Set(selections.cursors.keys)) else { return nil }
    for edit in edits.values {
      let units = Array(edit.text.string.utf16)
      func valid(_ range: NSRange) -> Bool {
        guard range.location >= 0, range.length >= 0, range.location <= units.count, range.length <= units.count - range.location else { return false }
        return [range.location, NSMaxRange(range)].allSatisfy { at in
          at == 0 || at == units.count || !(0xd800...0xdbff).contains(units[at - 1]) || !(0xdc00...0xdfff).contains(units[at])
        }
      }
      guard valid(edit.marked), valid(edit.selected), selections.substring(for: edit.range) != nil else { return nil }
    }
    let targets = edits.sorted { $0.value.range.location < $1.value.range.location }
    guard zip(targets, targets.dropFirst()).allSatisfy({
      $0.value.range.location != $1.value.range.location && NSMaxRange($0.value.range) <= $1.value.range.location
    }) else { return nil }
    let rawContexts = prefix.ordered.map { prefix.values[$0]!.context }
    guard let document = rawContexts.first?.documentLength,
          rawContexts.allSatisfy({ $0.documentLength == document }) else { return nil }
    func original(_ point: Int, end: Bool) -> Int? {
      var shift = 0
      for id in prefix.ordered {
        let value = prefix.values[id]!, start = prefix.virtualStart(for: id)
        if point < start { break }
        if point <= start + value.draft.length { return end ? NSMaxRange(value.originalRange) : value.originalRange.location }
        shift += value.draft.length - value.originalRange.length
      }
      let (result, overflow) = point.subtractingReportingOverflow(shift)
      return !overflow && result >= 0 ? result : nil
    }
    func virtual(_ point: Int, end: Bool) -> Int? {
      var shift = 0
      for id in prefix.ordered {
        let value = prefix.values[id]!, start = value.originalRange.location
        if point < start { break }
        if point <= NSMaxRange(value.originalRange) { return prefix.virtualStart(for: id) + (end ? value.draft.length : 0) }
        shift += value.draft.length - value.originalRange.length
      }
      let (result, overflow) = point.addingReportingOverflow(shift)
      return !overflow && result >= 0 ? result : nil
    }
    func source(_ point: Int) -> Int? {
      rawContexts.lazy.compactMap { $0.sourceRange(forUTF16: NSRange(location: point, length: 0))?.lowerBound }.first
    }
    var groups = prefix.ordered.map { id in
      let value = prefix.values[id]!
      return Group(original: value.originalRange, source: value.source)
    }
    var owners: [UInt64: NSRange] = [:]
    for (id, edit) in targets {
      let range = edit.range
      guard let start = original(range.location, end: false), let end = original(NSMaxRange(range), end: true), start <= end,
            let first = source(start), let last = source(end), first <= last else { return nil }
      let original = NSRange(location: start, length: end - start)
      groups.append(Group(original: original, source: first..<last)); owners[id] = original
    }
    groups.sort { $0.original.location < $1.original.location }
    var merged: [Group] = []
    for group in groups {
      if let last = merged.last, group.original.location <= NSMaxRange(last.original) {
        let length = max(NSMaxRange(group.original), NSMaxRange(last.original)) - last.original.location
        merged[merged.count - 1] = Group(original: NSRange(location: last.original.location, length: length),
          source: min(last.source.lowerBound, group.source.lowerBound)..<max(last.source.upperBound, group.source.upperBound))
      } else { merged.append(group) }
    }
    var values: [UInt64: ComposeMarkedText] = [:], placements: [UInt64: Placement] = [:]
    for (index, group) in merged.enumerated() {
      let key = UInt64(index + 1)
      guard let start = virtual(group.original.location, end: false), let end = virtual(NSMaxRange(group.original), end: true), start <= end,
            let raw = selections.substring(for: NSRange(location: start, length: end - start)) else { return nil }
      let members = targets.filter { id, _ in
        guard let range = owners[id] else { return false }
        return group.original.location <= range.location && NSMaxRange(range) <= NSMaxRange(group.original)
      }
      let result = NSMutableAttributedString(attributedString: raw)
      for (_, edit) in members.reversed() {
        let range = edit.range
        guard range.location >= start, NSMaxRange(range) <= end else { return nil }
        result.replaceCharacters(in: NSRange(location: range.location - start, length: range.length), with: edit.text)
      }
      let context: ComposeTextContext
      if let existing = rawContexts.first(where: { $0.sourceRange(forUTF16: group.original) == group.source }) { context = existing }
      else {
        var position = group.original.location, originalText = ""
        while position < NSMaxRange(group.original) {
          guard let raw = rawContexts.filter({ $0.range.location <= position && position < NSMaxRange($0.range) })
            .max(by: { NSMaxRange($0.range) < NSMaxRange($1.range) }) else { return nil }
          let stop = min(NSMaxRange(group.original), NSMaxRange(raw.range))
          guard let part = raw.exactText(for: NSRange(location: position, length: stop - position)) else { return nil }
          originalText += part; position = stop
        }
        guard originalText.utf8.count == group.source.count,
              let merged = ComposeTextContext(.with {
                $0.text = originalText; $0.sourceStart = UInt64(group.source.lowerBound); $0.utf16Start = UInt64(group.original.location)
                $0.selectionStart = UInt64(group.original.location); $0.selectionEnd = UInt64(group.original.location)
              }, documentLength: UInt64(document)) else { return nil }
        context = merged
      }
      guard let value = ComposeMarkedText(context: context, range: group.original, source: group.source,
        text: result, selected: NSRange(location: 0, length: 0), marked: NSRange(location: 0, length: 0)) else { return nil }
      values[key] = value
      var shift = 0
      for (id, edit) in members {
        let location = edit.range.location - start + shift
        placements[id] = Placement(region: key, range: NSRange(location: location, length: edit.text.length), marked: edit.marked)
        shift += edit.text.length - edit.range.length
      }
    }
    guard let first = values.keys.min(), let regions = ComposeComposition(primary: first, values: values) else { return nil }
    var cursors: [UInt64: ComposeVirtualSelections.Cursor] = [:], marked: [UInt64: NSRange] = [:], drafts: [UInt64: NSRange] = [:]
    for (id, place) in placements {
      guard let edit = edits[id] else { return nil }
      let start = regions.virtualStart(for: place.region) + place.range.location
      drafts[id] = NSRange(location: start, length: place.range.length)
      marked[id] = NSRange(location: start + edit.marked.location, length: edit.marked.length)
      cursors[id] = .init(position: start + NSMaxRange(edit.selected), anchor: edit.selected.length == 0 ? nil : start + edit.selected.location)
    }
    func map(_ point: Int) -> Int? {
      var shift = 0
      for (_, edit) in targets {
        if point < edit.range.location { break }
        guard point > NSMaxRange(edit.range) || point == NSMaxRange(edit.range) && edit.range.length > 0 else { return nil }
        shift += edit.text.length - edit.range.length
      }
      let (result, overflow) = point.addingReportingOverflow(shift)
      return !overflow && result >= 0 ? result : nil
    }
    for (id, cursor) in selections.cursors where edits[id] == nil {
      guard let point = map(cursor.position) else { return nil }
      let anchor: Int?
      if let old = cursor.anchor { guard let result = map(old) else { return nil }; anchor = result } else { anchor = nil }
      cursors[id] = .init(position: point, anchor: anchor, affinity: cursor.affinity)
    }
    guard cursors.count == selections.cursors.count else { return nil }
    self.regions = regions; primaryID = selections.primaryID; self.cursors = cursors; self.marked = marked; self.drafts = drafts; self.placements = placements
  }

  public func provisionalSelections() -> ComposeVirtualSelections? {
    ComposeVirtualSelections(prefix: regions, primary: primaryID, cursors: cursors)
  }

  public func project(over base: ComposeProjection) -> (projection: ComposeProjection, marked: [UInt64: Range<Int>])? {
    guard let result = projected(over: base) else { return nil }
    var marked: [UInt64: Range<Int>] = [:]
    for (id, place) in placements {
      guard let display = result.contexts[place.region], let value = regions.values[place.region] else { continue }
      let text = value.draft.string as NSString
      let start = display.lowerBound + text.substring(to: place.range.location + place.marked.location).utf8.count
      let end = start + text.substring(with: NSRange(location: place.range.location + place.marked.location, length: place.marked.length)).utf8.count
      marked[id] = start..<end
    }
    return (result.projection, marked)
  }

  func projected(over base: ComposeProjection) -> (projection: ComposeProjection, drafts: [UInt64: Range<Int>], contexts: [UInt64: Range<Int>])? {
    guard let result = regions.project(over: base) else { return nil }
    var drafts: [UInt64: Range<Int>] = [:]
    for (id, place) in placements {
      guard let display = result.displays[place.region], let value = regions.values[place.region] else { continue }
      let text = value.draft.string as NSString
      let start = display.lowerBound + text.substring(to: place.range.location).utf8.count
      let end = start + text.substring(with: place.range).utf8.count
      drafts[id] = start..<end
    }
    return (result.projection, drafts, result.displays)
  }
}
