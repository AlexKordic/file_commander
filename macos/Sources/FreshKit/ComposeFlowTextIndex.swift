import Foundation

/// Text-query policy over measured fragments, in complete projection UTF-16.
/// Table cells retain source reading order. A fragment owns the following
/// separator characters up to the next fragment; empty cells remain lines.
/// This partitions the value without estimating wraps or inventing glyphs.
public struct ComposeFlowTextIndex: Sendable {
  public struct Style: Sendable, Equatable {
    public let range: NSRange
    public let font: Int
    public let attachment: Range<Int>?
  }
  public let length: Int
  public var lineCount: Int { fragments.count }
  public let styles: [Style]
  private let fragments: [ComposeFlowMeasurement.Line]

  init?(projection: ComposeProjection, fragments: [ComposeFlowMeasurement.Line],
        styles: [ComposeFlowMeasurement.Style], attachments: [ComposeTextLayout.PlacedAttachment]) {
    length = projection.textIndex.utf16Count
    guard !fragments.isEmpty else { return nil }
    var previousEnd = 0
    for fragment in fragments {
      guard fragment.range.location >= previousEnd, fragment.range.location <= length,
            fragment.range.length >= 0, fragment.range.length <= length - fragment.range.location,
            fragment.contentEnd >= fragment.range.location,
            fragment.contentEnd <= NSMaxRange(fragment.range) else { return nil }
      previousEnd = NSMaxRange(fragment.range)
    }
    self.fragments = fragments

    // Native glyph runs arrive in visual order. Sort their disjoint logical
    // ranges once on the measurement worker; gaps use the ordinary body font.
    var fonts: [(range: NSRange, id: Int)] = [], end = 0
    for style in styles.filter({ $0.range.length > 0 }).sorted(by: { $0.range.location < $1.range.location }) {
      let range = style.range
      guard range.location >= end, range.location <= length,
            range.length <= length - range.location, style.font >= 0 else { return nil }
      if end < range.location { fonts.append((NSRange(location: end, length: range.location - end), 0)) }
      fonts.append((range, style.font)); end = NSMaxRange(range)
    }
    if end < length { fonts.append((NSRange(location: end, length: length - end), 0)) }
    var objects: [(range: NSRange, source: Range<Int>)] = []
    for placed in attachments where !placed.attachment.preview {
      guard let range = projection.textIndex.units(for: placed.attachment.display), range.length > 0 else { return nil }
      objects.append((range, placed.attachment.source))
    }
    objects.sort { $0.range.location < $1.range.location }
    guard zip(objects, objects.dropFirst()).allSatisfy({ NSMaxRange($0.range) <= $1.range.location }) else { return nil }
    let boundaries = Set([0, length] + fonts.flatMap { [$0.range.location, NSMaxRange($0.range)] }
      + objects.flatMap { [$0.range.location, NSMaxRange($0.range)] }).sorted()
    var result: [Style] = [], font = 0, object = 0
    for (start, stop) in zip(boundaries, boundaries.dropFirst()) where start < stop {
      while font < fonts.count && NSMaxRange(fonts[font].range) <= start { font += 1 }
      while object < objects.count && NSMaxRange(objects[object].range) <= start { object += 1 }
      guard font < fonts.count, fonts[font].range.location <= start else { return nil }
      let source = object < objects.count && objects[object].range.location <= start ? objects[object].source : nil
      if let last = result.last, last.font == fonts[font].id, last.attachment == source {
        result[result.count - 1] = .init(range: NSRange(location: last.range.location, length: stop - last.range.location),
          font: last.font, attachment: source)
      } else {
        result.append(.init(range: NSRange(location: start, length: stop - start), font: fonts[font].id, attachment: source))
      }
    }
    self.styles = result
  }

  public func contains(_ range: NSRange) -> Bool {
    range.location >= 0 && range.location <= length && range.length >= 0 && range.length <= length - range.location
  }

  public func range(forLine line: Int) -> NSRange? {
    guard fragments.indices.contains(line) else { return nil }
    let start = line == 0 ? 0 : fragments[line].range.location
    let end = line + 1 < fragments.count ? fragments[line + 1].range.location : length
    return NSRange(location: start, length: end - start)
  }

  public func line(atUTF16 index: Int, affinity: ComposeProjection.Affinity = .downstream) -> Int? {
    guard index >= 0, index <= length else { return nil }
    // EOF always has a valid existing owner. A trailing empty renderer line
    // remains addressable; an unterminated line gets no phantom successor.
    if index == length { return fragments.count - 1 }
    var low = 0, high = fragments.count
    while low < high {
      let mid = low + (high - low) / 2
      if mid == 0 || fragments[mid].range.location <= index { low = mid + 1 } else { high = mid }
    }
    let line = max(0, low - 1)
    if affinity == .upstream, line > 0, index == fragments[line].range.location {
      let before = fragments[line - 1], after = fragments[line]
      if before.range.length > 0, after.range.length > 0, !before.endsInHardBreak,
         NSMaxRange(before.range) == index, before.contentEnd == index, before.table == after.table {
        return line - 1
      }
    }
    return line
  }

  /// Only lines whose owned text intersects a range. Empty EOF is returned
  /// for a collapsed EOF query, never appended to a nonempty preceding range.
  public func lines(intersecting range: NSRange) -> Range<Int>? {
    guard contains(range), let start = line(atUTF16: range.location) else { return nil }
    if range.length == 0 { return start..<(start + 1) }
    let end = NSMaxRange(range)
    var low = start, high = fragments.count
    while low < high {
      let mid = low + (high - low) / 2
      let location = mid == 0 ? 0 : fragments[mid].range.location
      if location < end { low = mid + 1 } else { high = mid }
    }
    return start..<low
  }

  public func style(atUTF16 index: Int) -> Style? {
    guard index >= 0, index < length else { return nil }
    var low = 0, high = styles.count
    while low < high {
      let mid = low + (high - low) / 2
      if NSMaxRange(styles[mid].range) <= index { low = mid + 1 } else { high = mid }
    }
    return low < styles.count ? styles[low] : nil
  }

  public func styles(intersecting range: NSRange) -> ArraySlice<Style>? {
    guard contains(range) else { return nil }
    if range.length == 0 { return styles[0..<0] }
    var low = 0, high = styles.count
    while low < high {
      let mid = low + (high - low) / 2
      if NSMaxRange(styles[mid].range) <= range.location { low = mid + 1 } else { high = mid }
    }
    let start = low, end = NSMaxRange(range)
    high = styles.count
    while low < high {
      let mid = low + (high - low) / 2
      if styles[mid].range.location < end { low = mid + 1 } else { high = mid }
    }
    return styles[start..<low]
  }
}
