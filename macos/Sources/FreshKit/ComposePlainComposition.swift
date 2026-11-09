import Foundation

/// A worker-safe capture of draft text. AppKit's arbitrary attributed values
/// never cross this boundary; draft fonts come from the source-owned layout.
struct ComposePlainComposition: Sendable {
  struct Value: Sendable {
    let context: ComposeTextContext
    let original: NSRange
    let source: Range<Int>
    let text: String
    let selected, marked: NSRange
  }
  let primary: UInt64
  let values: [UInt64: Value]

  init(_ composition: ComposeComposition) {
    primary = composition.primaryID
    var captured: [UInt64: Value] = [:], strings: [ObjectIdentifier: String] = [:]
    for (id, value) in composition.values {
      let key = ObjectIdentifier(value.draft)
      let text = strings[key] ?? value.draft.string
      strings[key] = text
      captured[id] = .init(context: value.context, original: value.originalRange, source: value.source,
        text: text, selected: value.selected, marked: value.marked)
    }
    values = captured
  }

  func restore() -> ComposeComposition? {
    var result: [UInt64: ComposeMarkedText] = [:]
    for (id, value) in values {
      guard let draft = ComposeMarkedText(context: value.context, range: value.original, source: value.source,
        text: NSAttributedString(string: value.text), selected: value.selected, marked: value.marked) else { return nil }
      result[id] = draft
    }
    return ComposeComposition(primary: primary, values: result)
  }

  func isEquivalent(to other: Self, includingSelection: Bool = true) -> Bool {
    guard primary == other.primary, values.keys == other.values.keys else { return false }
    return values.allSatisfy { id, a in
      let b = other.values[id]!
      return a.original == b.original && a.source == b.source && a.text.utf8.elementsEqual(b.text.utf8)
        && (!includingSelection || a.selected == b.selected && a.marked == b.marked)
        && a.context.source == b.context.source && a.context.range == b.context.range
        && a.context.documentLength == b.context.documentLength && a.context.text.utf8.elementsEqual(b.context.text.utf8)
    }
  }
}
