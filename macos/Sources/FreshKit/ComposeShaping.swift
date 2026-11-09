import Foundation
import CoreText

/// Keep contextual shaping when Core Text refuses its bounded work policy.
enum ComposeShaping {
  static func typesetter(_ text: NSAttributedString) -> CTTypesetter? {
    if let bounded = CTTypesetterCreateWithAttributedStringAndOptions(text, nil) { return bounded }
    // The legacy nonnullable factory can silently simplify long Unicode text
    // (including joined emoji). Retain full source/context and request proper
    // shaping explicitly instead.
    return CTTypesetterCreateWithAttributedStringAndOptions(text,
      [kCTTypesetterOptionAllowUnboundedLayout: true] as CFDictionary)
  }

  static func line(_ text: NSAttributedString) -> CTLine? {
    guard let typesetter = typesetter(text) else { return nil }
    return CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: text.length))
  }
}
