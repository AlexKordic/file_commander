import Foundation

/// Immutable interval queries for parser-owned layout spans. A long enclosing
/// quote/list must not force a scan of every preceding paragraph on each line.
/// Results retain original identities; callers choose their own precedence.
struct ComposeIntervalIndex {
  private struct Entry { let id: Int; let range: Range<Int> }
  private let entries: [Entry]
  private let maximumEnds: [Int]

  init(_ ranges: [Range<Int>]) {
    var entries: [Entry] = []
    for (id, range) in ranges.enumerated() where !range.isEmpty { entries.append(Entry(id: id, range: range)) }
    entries.sort {
      $0.range.lowerBound == $1.range.lowerBound ? $0.id < $1.id : $0.range.lowerBound < $1.range.lowerBound
    }
    var ends = [Int](repeating: Int.min, count: entries.count)
    func build(_ lower: Int, _ upper: Int) -> Int {
      guard lower < upper else { return Int.min }
      let middle = lower + (upper - lower) / 2
      let left = build(lower, middle), right = build(middle + 1, upper)
      ends[middle] = max(entries[middle].range.upperBound, left, right)
      return ends[middle]
    }
    _ = build(0, entries.count)
    self.entries = entries; maximumEnds = ends
  }

  func matches(at position: Int) -> [Int] {
    var result: [Int] = []
    func visit(_ lower: Int, _ upper: Int) {
      guard lower < upper else { return }
      let middle = lower + (upper - lower) / 2
      guard maximumEnds[middle] > position, entries[lower].range.lowerBound <= position else { return }
      visit(lower, middle)
      if entries[middle].range.contains(position) { result.append(entries[middle].id) }
      if entries[middle].range.lowerBound <= position { visit(middle + 1, upper) }
    }
    visit(0, entries.count)
    return result
  }
}
