import AppKit
import CoreText
import FreshKit

/// Accessibility indexes the displayed projection. AppKit text input instead
/// indexes raw source context; keeping the two spaces separate avoids reading
/// concealed Markdown or addressing a different character after a source crop.
@MainActor
struct ComposeAccessibilityText {
  let pane: ComposePresentation
  let text: NSString
  static let missing = NSRange(location: NSNotFound, length: 0)

  init(pane: ComposePresentation) { self.pane = pane; text = pane.layout.text.projection.text as NSString }

  func contains(_ range: NSRange) -> Bool {
    range.location >= 0 && range.location <= text.length && range.length >= 0 && range.length <= text.length - range.location
  }

  func character(at index: Int) -> NSRange {
    guard index >= 0, index <= text.length else { return Self.missing }
    return index == text.length ? NSRange(location: index, length: 0) : text.rangeOfComposedCharacterSequence(at: index)
  }

  func line(at index: Int) -> Int {
    guard index >= 0, index <= text.length else { return NSNotFound }
    // The next visual line owns a soft-wrap boundary. Empty EOF lines retain
    // their index; table fragments retain source order rather than cell rows.
    return pane.layout.text.fragments.lastIndex { fragment in
      fragment.range.location <= index && (index < NSMaxRange(fragment.range) || index == text.length)
    } ?? NSNotFound
  }

  var visibleRange: NSRange {
    let visible = pane.layout.text.fragments.filter { $0.rect.offsetBy(dx: pane.origin.x, dy: pane.origin.y).intersects(pane.bounds) }
    guard let start = visible.map(\.range.location).min(), let end = visible.map({ NSMaxRange($0.range) }).max() else { return Self.missing }
    return NSRange(location: start, length: end - start)
  }

  func character(at point: CGPoint) -> NSRange {
    // Pointer editing chooses a nearest caret. AX asks for the character
    // under the point, including the right half of a glyph and RTL runs.
    for fragment in pane.layout.text.fragments where point.y >= fragment.rect.minY && point.y < fragment.rect.maxY {
      if let glyph = glyphs(in: fragment).first(where: { $0.rect.contains(point) }) { return glyph.range }
    }
    return pane.layout.text.hitUTF16(at: point).map { character(at: $0) } ?? Self.missing
  }

  private func glyphs(in fragment: ComposeTextLayout.Fragment) -> [(range: NSRange, rect: CGRect)] {
    ComposeGlyphGeometry.glyphs(in:fragment,text:text).map {($0.range,$0.rect)}
  }

  func bounds(for range: NSRange) -> CGRect? {
    guard contains(range) else { return nil }
    if range.length == 0 {
      if range == pane.selectedRange, let caret = pane.caret { return caret }
      return pane.layout.text.caret(atUTF16: range.location)?.offsetBy(dx: pane.origin.x, dy: pane.origin.y)
    }
    var rects = pane.layout.text.selectionRects(forUTF16: range)
    for fragment in pane.layout.text.fragments where NSIntersectionRange(fragment.range, range).length > 0 {
      // Endpoint offsets alone can miss the middle of a bidirectional run.
      // Add the actual selected glyph advances from the same Core Text line.
      for glyph in glyphs(in: fragment) where NSIntersectionRange(glyph.range, range).length > 0 { rects.append(glyph.rect) }
    }
    // Source-edit previews occupy measured flow without adding a character.
    // Their bounds still belong to the range of their visible source markup.
    for placed in pane.layout.text.attachments {
      guard let start = pane.layout.text.utf16Position(for: placed.attachment.source.lowerBound),
            let end = pane.layout.text.utf16Position(for: placed.attachment.source.upperBound, affinity: .upstream),
            start < NSMaxRange(range), range.location < end else { continue }
      rects.append(placed.rect)
    }
    let bounds = rects.reduce(CGRect.null) { $0.union($1) }
    return bounds.isNull ? nil : bounds.offsetBy(dx: pane.origin.x, dy: pane.origin.y)
  }

  func attributed(_ range: NSRange) -> NSAttributedString? {
    guard contains(range) else { return nil }
    let result = NSMutableAttributedString(string: text.substring(with: range))
    for fragment in pane.layout.text.fragments {
      for run in CTLineGetGlyphRuns(fragment.line) as! [CTRun] {
        let overlap = NSIntersectionRange(range,fragment.shaped.range(of:run))
        guard overlap.length > 0, let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont? else { continue }
        let attributes: [NSAccessibility.FontAttributeKey: Any] = [
          .fontName: CTFontCopyPostScriptName(font) as String,
          .fontFamily: CTFontCopyFamilyName(font) as String,
          .fontSize: CTFontGetSize(font),
        ]
        result.addAttribute(.accessibilityFont, value: attributes,
          range: NSRange(location: overlap.location - range.location, length: overlap.length))
      }
    }
    return result
  }
}

/// The object keeps only source ownership and a weak parent. Every read/action
/// resolves the current placement; retained objects cannot act after a source,
/// buffer, client or focus change and never retain an old image bitmap.
@MainActor
final class ComposeAccessibilityImage: NSAccessibilityElement {
  struct ID: Hashable {
    let window, leaf, buffer, epoch, revision, authority, document, start, end: UInt64
    init(_ pane: ComposePresentation, source: Range<Int>) {
      window = pane.identity.window; leaf = pane.identity.leaf; buffer = pane.identity.buffer
      epoch = pane.pane.compose.viewport.epoch; revision = pane.pane.compose.bufferRevision
      authority = pane.pane.compose.assetAuthority
      document = pane.pane.compose.assetDocument; start = UInt64(source.lowerBound); end = UInt64(source.upperBound)
    }
    init(owner: WireComposeIndexOwner, source: Range<Int>) {
      window = owner.window; leaf = owner.leaf; buffer = owner.buffer; epoch = owner.epoch; revision = owner.revision
      authority = owner.authority; document = owner.document; start = UInt64(source.lowerBound); end = UInt64(source.upperBound)
    }
  }
  let id: ID
  weak var grid: CellGridView?

  init(id: ID, grid: CellGridView) { self.id = id; self.grid = grid; super.init() }
  override func accessibilityParent() -> Any? { grid }
  override func accessibilityRole() -> NSAccessibility.Role? { .image }
  override func accessibilityLabel() -> String? {
    if let complete { return grid?.completeImageDescription(complete.image, in: complete.value.basis) }
    return current.map { $0.pane.layout.imageDescription($0.image) }
  }
  override func accessibilityHelp() -> String? { isAccessibilityElement() ? "Select image Markdown source" : nil }
  override func accessibilityFrame() -> NSRect {
    if let complete, let grid {
      guard let rect = complete.value.imageRect(Int(id.start)..<Int(id.end)) else { return .zero }
      return grid.accessibilityScreenRect(rect)
    }
    guard let current, let grid else { return .zero }
    return grid.accessibilityScreenRect(current.rect)
  }
  override func isAccessibilityElement() -> Bool { complete != nil || current != nil }

  private var complete: (value: ComposeCompleteAccessibility, image: WireComposeImage)? {
    guard let grid, grid.usesCompleteAccessibility, grid.isCurrentAccessibilityImage(self),
          let value = grid.completeAccessibility,
          let image = value.model.image(source: Int(id.start)..<Int(id.end)) else { return nil }
    return (value, image)
  }

  private var current: (pane: ComposePresentation, image: WireComposeImage, rect: CGRect)? {
    guard let grid, !grid.usesCompleteAccessibility, grid.isCurrentAccessibilityImage(self), let pane = grid.focusedCompose,
          let placed = pane.attachment(start: id.start, end: id.end), ID(pane, source: placed.attachment.source) == id,
          let image = pane.image(start: id.start, end: id.end) else { return nil }
    return (pane, image, placed.rect.offsetBy(dx: pane.origin.x, dy: pane.origin.y))
  }

  override func accessibilityPerformPress() -> Bool {
    if let complete, let grid, let delegate = grid.delegate {
      guard let range = complete.value.model.displayedRange(for: Int(id.start)..<Int(id.end)) else { return false }
      return delegate.grid(grid, selectDocument: [range], in: complete.value.model)
    }
    guard let grid, current != nil, let delegate = grid.delegate else { return false }
    if grid.hasMarkedText() { grid.unmarkText() }
    guard let current else { return false }
    delegate.grid(grid, point: CGPoint(x: current.rect.midX, y: current.rect.midY), in: current.pane, extend: false, count: 1)
    return true
  }
}
