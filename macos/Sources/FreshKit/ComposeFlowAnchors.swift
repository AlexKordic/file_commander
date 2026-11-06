import Foundation
import CoreGraphics

extension ComposeTextLayout {
  /// Physical text starts and complete table rows are repeatable flow points.
  /// Soft wraps are deliberately excluded: extending a paragraph can reshape
  /// its last wrapped line, while preserving its physical beginning.
  func flowAnchors(documentLength: UInt64, nearby: (CGRect) -> Bool) -> [WireComposeFlowAnchor]? {
    let mapped = projection.segments.filter { !$0.display.isEmpty && !$0.source.isEmpty }
    var segmentIndex = 0, anchors: [(WireComposeFlowAnchor, CGRect)] = []
    for fragment in fragments where fragment.table == nil {
      let start = fragment.range.location
      guard start == 0 || [10, 13].contains(string.character(at: start - 1)),
            let display = utf16ToByte[start] else { continue }
      if fragment.range.length == 0 {
        guard UInt64(projection.source.upperBound) == documentLength,
              let source = projection.sourcePosition(at: display, affinity: .upstream) else { continue }
        anchors.append((.with {
          $0.source = UInt64(source); $0.y = Double(fragment.rect.minY); $0.kind = 2
          $0.contextStart = UInt64(source); $0.contextEnd = documentLength
        }, fragment.rect))
        continue
      }
      while segmentIndex < mapped.count && mapped[segmentIndex].display.upperBound <= display { segmentIndex += 1 }
      guard segmentIndex < mapped.count else { continue }
      let segment = mapped[segmentIndex], mappedDisplay = max(display, segment.display.lowerBound)
      guard let unit = byteToUTF16[mappedDisplay], unit < NSMaxRange(fragment.range) else { continue }
      let source: Int, end: Int
      if segment.kind == .copy {
        source = segment.source.lowerBound + mappedDisplay - segment.display.lowerBound
        let next = NSMaxRange(string.rangeOfComposedCharacterSequence(at: unit))
        guard let boundary = utf16ToByte[next] else { return nil }
        end = min(segment.source.upperBound, source + boundary - mappedDisplay)
      } else {
        source = segment.source.lowerBound; end = segment.source.upperBound
      }
      anchors.append((.with {
        $0.source = UInt64(source); $0.y = Double(fragment.rect.minY)
        $0.contextStart = UInt64(source); $0.contextEnd = UInt64(end)
      }, fragment.rect))
    }
    for table in tables {
      for row in table.rows {
        anchors.append((.with {
          $0.source = UInt64(row.source.lowerBound); $0.y = Double(row.rect.minY); $0.kind = 1
          $0.contextStart = UInt64(row.source.lowerBound); $0.contextEnd = UInt64(row.source.upperBound)
        }, row.rect))
      }
    }
    anchors.sort { $0.0.source < $1.0.source || ($0.0.source == $1.0.source && $0.0.kind < $1.0.kind) }
    let selected = anchors.enumerated().filter { $0.offset == 0 || $0.offset + 1 == anchors.count || nearby($0.element.1) }.map { $0.element.0 }
    guard selected.count <= 16_384 else { return nil }
    return selected
  }
}
