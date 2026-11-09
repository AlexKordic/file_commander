import Foundation
import CoreFoundation

/// Native line-break units for a table's preferred minimum. Reuse one
/// tokenizer across its samples instead of initializing a linguistic word
/// analyzer for every cell. This supplies no Markdown or column decisions.
struct ComposeLineBreaks {
  private let tokenizer = CFStringTokenizerCreate(nil, "" as CFString,
    CFRange(location: 0, length: 0), kCFStringTokenizerUnitLineBreak, nil)!
  private let content = CharacterSet.whitespacesAndNewlines.inverted

  func forEach(in text: NSString, range: NSRange, _ visit: (NSRange) -> Bool) {
    CFStringTokenizerSetString(tokenizer, text as CFString,
      CFRange(location: range.location, length: range.length))
    while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
      let token = CFStringTokenizerGetCurrentTokenRange(tokenizer)
      let unit = NSIntersectionRange(range, NSRange(location: token.location, length: token.length))
      guard unit.length > 0 else { continue }
      // A line-break unit includes its trailing spaces/EOL. They still draw
      // and retain source positions, but do not enlarge the word preference.
      let first = text.rangeOfCharacter(from: content, range: unit)
      guard first.location != NSNotFound else { continue }
      let last = text.rangeOfCharacter(from: content, options: .backwards, range: unit)
      guard visit(NSRange(location: first.location, length: NSMaxRange(last) - first.location)) else { break }
    }
  }
}
