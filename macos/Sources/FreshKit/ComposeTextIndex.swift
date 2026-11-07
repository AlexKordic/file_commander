import Foundation

/// Scalar-boundary coordinates without one hash entry per character. A lookup
/// scans at most one sparse interval; an extended grapheme may span intervals.
/// UTF-16 positions inside surrogate pairs are never source positions.
final class ComposeTextIndex: Sendable {
  private struct Checkpoint: Sendable { let byte, unit: Int }
  private let bytes: [UInt8]
  private let checkpoints: [Checkpoint]
  let utf16Count: Int
  var byteCount: Int { bytes.count }
  var checkpointCount: Int { checkpoints.count }
  static let stride = 1024

  init(_ text: String) {
    let bytes = Array(text.utf8)
    var points = [Checkpoint(byte: 0, unit: 0)], byte = 0, unit = 0
    while byte < bytes.count {
      if byte - points.last!.byte >= Self.stride { points.append(.init(byte: byte, unit: unit)) }
      let length = Self.length(bytes[byte])
      byte += length; unit += length == 4 ? 2 : 1
    }
    if points.last!.byte != byte { points.append(.init(byte: byte, unit: unit)) }
    self.bytes = bytes; checkpoints = points; utf16Count = unit
  }

  private static func length(_ byte: UInt8) -> Int { byte < 0x80 ? 1 : byte < 0xe0 ? 2 : byte < 0xf0 ? 3 : 4 }

  func contains(byte: Int) -> Bool {
    byte >= 0 && byte <= bytes.count && (byte == bytes.count || bytes[byte] & 0xc0 != 0x80)
  }

  private func checkpoint(before value: Int, by coordinate: (Checkpoint) -> Int) -> Checkpoint {
    var low = 0, high = checkpoints.count
    while low < high {
      let mid = low + (high - low) / 2
      if coordinate(checkpoints[mid]) <= value { low = mid + 1 } else { high = mid }
    }
    return checkpoints[max(0, low - 1)]
  }

  func unit(forByte target: Int) -> Int? {
    guard contains(byte: target) else { return nil }
    let point = checkpoint(before: target, by: \.byte)
    var byte = point.byte, unit = point.unit
    while byte < target {
      let length = Self.length(bytes[byte]); byte += length; unit += length == 4 ? 2 : 1
    }
    return unit
  }

  func byte(forUnit target: Int) -> Int? {
    guard target >= 0, target <= utf16Count else { return nil }
    let point = checkpoint(before: target, by: \.unit)
    var byte = point.byte, unit = point.unit
    while unit < target {
      let length = Self.length(bytes[byte]); byte += length; unit += length == 4 ? 2 : 1
    }
    return unit == target ? byte : nil
  }

  func bytes(for range: NSRange) -> Range<Int>? {
    guard range.location >= 0, range.location <= utf16Count, range.length >= 0,
          range.length <= utf16Count - range.location,
          let start = byte(forUnit: range.location), let end = byte(forUnit: range.location + range.length) else { return nil }
    return start..<end
  }

  func units(for range: Range<Int>) -> NSRange? {
    guard let start = unit(forByte: range.lowerBound), let end = unit(forByte: range.upperBound) else { return nil }
    return NSRange(location: start, length: end - start)
  }

  func hasBytes(_ range: Range<Int>, equalTo other: ComposeTextIndex) -> Bool {
    guard contains(byte: range.lowerBound), contains(byte: range.upperBound), range.count == other.byteCount else { return false }
    return bytes[range].elementsEqual(other.bytes)
  }
}
