import Foundation

/// One immutable broadcast conversion over a pending prefix. Draft regions
/// are folded back onto real source ranges; synthetic region keys are never
/// cursor identities or wire coordinates. Several carets may edit one region.
public struct ComposeVirtualInsertion {
  // Synthetic region identities stay inside the presentation implementation.
  let regions: ComposeComposition
  public let primaryID: UInt64
  public let cursors: [UInt64: ComposeVirtualSelections.Cursor]
  public let marked: [UInt64: NSRange]
  private let placements: [UInt64: Placement]
  private struct Placement { let region: UInt64; let range: NSRange }
  private struct Group { var original: NSRange; var source: Range<Int> }

  public init?(selections: ComposeVirtualSelections, text: NSAttributedString, selected: NSRange) {
    let prefix = selections.prefix
    let units = Array(text.string.utf16)
    func boundary(_ at: Int) -> Bool {
      at >= 0 && at <= units.count && (at == 0 || at == units.count
        || !(0xd800...0xdbff).contains(units[at - 1]) || !(0xdc00...0xdfff).contains(units[at]))
    }
    guard selected.location >= 0, selected.length >= 0, selected.location <= units.count,
          selected.length <= units.count - selected.location, boundary(selected.location), boundary(NSMaxRange(selected)) else { return nil }
    let targets = selections.cursors.sorted { $0.value.selection.location < $1.value.selection.location }
    guard !targets.isEmpty, zip(targets, targets.dropFirst()).allSatisfy({
      $0.value.selection.location != $1.value.selection.location && NSMaxRange($0.value.selection) <= $1.value.selection.location
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
    for (id, cursor) in targets {
      let range = cursor.selection
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
      for (_, cursor) in members.reversed() {
        let range = cursor.selection
        guard range.location >= start, NSMaxRange(range) <= end else { return nil }
        result.replaceCharacters(in: NSRange(location: range.location - start, length: range.length), with: text)
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
      for (id, cursor) in members {
        let location = cursor.selection.location - start + shift
        placements[id] = Placement(region: key, range: NSRange(location: location, length: text.length))
        shift += text.length - cursor.selection.length
      }
    }
    guard let first = values.keys.min(), let regions = ComposeComposition(primary: first, values: values) else { return nil }
    var cursors: [UInt64: ComposeVirtualSelections.Cursor] = [:], marked: [UInt64: NSRange] = [:]
    for (id, place) in placements {
      let start = regions.virtualStart(for: place.region) + place.range.location
      marked[id] = NSRange(location: start, length: text.length)
      cursors[id] = .init(position: start + NSMaxRange(selected), anchor: selected.length == 0 ? nil : start + selected.location)
    }
    guard cursors.count == selections.cursors.count else { return nil }
    self.regions = regions; primaryID = selections.primaryID; self.cursors = cursors; self.marked = marked; self.placements = placements
  }

  public func project(over base: ComposeProjection) -> (projection: ComposeProjection, marked: [UInt64: Range<Int>])? {
    guard let result = regions.project(over: base) else { return nil }
    var marked: [UInt64: Range<Int>] = [:]
    for (id, place) in placements {
      guard let display = result.displays[place.region], let value = regions.values[place.region] else { continue }
      let text = value.draft.string as NSString
      let start = display.lowerBound + text.substring(to: place.range.location).utf8.count
      let end = start + text.substring(with: place.range).utf8.count
      marked[id] = start..<end
    }
    return (result.projection, marked)
  }
}
