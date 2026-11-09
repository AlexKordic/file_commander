import Foundation

extension ComposeProjection {
  /// Locate a crop only after literal bytes and normalized source ownership
  /// agree. Frame/document lifetime is checked by the caller, separately from
  /// this pure map proof. Whole replacements cannot be split or guessed.
  public func certifiedRange(of part: ComposeProjection) -> NSRange? {
    guard part.source.lowerBound >= source.lowerBound,
          part.source.upperBound <= source.upperBound else { return nil }
    let starts = [ComposeProjection.Affinity.upstream, .downstream].compactMap {
      displayPosition(for: part.source.lowerBound, affinity: $0)
    }
    let ends = [ComposeProjection.Affinity.upstream, .downstream].compactMap {
      displayPosition(for: part.source.upperBound, affinity: $0)
    }
    for start in starts {
      for end in ends where start <= end {
        let range = start..<end
        guard textIndex.hasBytes(range, equalTo: part.textIndex),
              let segments = sliced(source: part.source, display: range),
              same(normalized(segments), normalized(part.segments)) else { continue }
        return textIndex.units(for: range)
      }
    }
    return nil
  }

  private func sliced(source: Range<Int>, display: Range<Int>) -> [ComposeProjection.Segment]? {
    var low = 0, high = segments.count
    while low < high {
      let mid = low + (high - low) / 2
      if segments[mid].source.upperBound < source.lowerBound { low = mid + 1 } else { high = mid }
    }
    var result: [ComposeProjection.Segment] = []
    for segment in segments[low...] {
      if segment.source.lowerBound > source.upperBound { break }
      if segment.kind == .insertion {
        if segment.display.upperBound <= display.lowerBound || segment.display.lowerBound >= display.upperBound { continue }
        guard segment.display.lowerBound >= display.lowerBound, segment.display.upperBound <= display.upperBound else { return nil }
        result.append(.init(source: segment.source, display: (segment.display.lowerBound-display.lowerBound)..<(segment.display.upperBound-display.lowerBound), kind: .insertion))
        continue
      }
      let start = max(source.lowerBound, segment.source.lowerBound), end = min(source.upperBound, segment.source.upperBound)
      guard start < end else { continue }
      let mapped: Range<Int>
      switch segment.kind {
      case .copy:
        let a = segment.display.lowerBound + start - segment.source.lowerBound
        mapped = a..<(a + end - start)
      case .hidden: mapped = segment.display
      case .replacement:
        guard start == segment.source.lowerBound, end == segment.source.upperBound else { return nil }
        mapped = segment.display
      case .insertion: return nil
      }
      guard mapped.lowerBound >= display.lowerBound, mapped.upperBound <= display.upperBound else { return nil }
      result.append(.init(source: start..<end, display: (mapped.lowerBound-display.lowerBound)..<(mapped.upperBound-display.lowerBound), kind: segment.kind))
    }
    return result
  }

  private func normalized(_ segments: [ComposeProjection.Segment]) -> [ComposeProjection.Segment] {
    var result: [ComposeProjection.Segment] = []
    for segment in segments {
      if let last = result.last, (last.kind == .copy || last.kind == .hidden), last.kind == segment.kind,
         last.source.upperBound == segment.source.lowerBound, last.display.upperBound == segment.display.lowerBound {
        result[result.count-1] = .init(source: last.source.lowerBound..<segment.source.upperBound,
          display: last.display.lowerBound..<segment.display.upperBound, kind: last.kind)
      } else { result.append(segment) }
    }
    return result
  }

  private func same(_ a: [ComposeProjection.Segment], _ b: [ComposeProjection.Segment]) -> Bool {
    a.count == b.count && zip(a,b).allSatisfy { $0.source == $1.source && $0.display == $1.display && $0.kind == $1.kind }
  }
}
