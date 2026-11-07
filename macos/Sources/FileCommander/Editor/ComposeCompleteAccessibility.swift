import AppKit
import FreshKit

/// One captured logical generation for every AX query family. Geometry can be
/// absent without substituting the drawing crop for the document's text.
@MainActor
final class ComposeCompleteAccessibility {
  let model: ComposeDocumentPresentation
  let basis: any ComposeInputBasis
  let pane: ComposePresentation?
  let flow: ComposeFlowMeasurement?

  convenience init(model: ComposeDocumentPresentation, pane: ComposePresentation, flow: ComposeFlowMeasurement?) {
    self.init(model: model, basis: pane, pane: pane, flow: flow)
  }

  init(model: ComposeDocumentPresentation, basis: any ComposeInputBasis, pane: ComposePresentation?, flow: ComposeFlowMeasurement?) {
    self.model = model; self.basis = basis; self.pane = pane
    self.flow = flow?.presentation === model ? flow : nil
  }

  private lazy var crop: NSRange? = {
    guard let pane else { return nil }
    return model.range(window: pane.identity.window, pane: pane.pane, projection: pane.layout.text.projection)
  }()
  private lazy var translation: CGPoint? = {
    guard let pane else { return nil }
    return flow?.correspondence(window: pane.identity.window, pane: pane.pane, layout: pane.layout)
  }()

  var visibleRange: NSRange {
    guard let pane, let crop else { return ComposeAccessibilityText.missing }
    let visible = ComposeAccessibilityText(pane: pane).visibleRange
    guard visible.location != NSNotFound else { return visible }
    return NSRange(location: crop.location + visible.location, length: visible.length)
  }

  func bounds(for range: NSRange) -> CGRect? {
    guard let pane, model.contains(range), let crop else { return nil }
    if range.location >= crop.location, NSMaxRange(range) <= NSMaxRange(crop) {
      return ComposeAccessibilityText(pane: pane).bounds(for:
        NSRange(location: range.location - crop.location, length: range.length))
    }
    guard let flow, let offset = translation,
          let rect = flow.bounds(for: range) else { return nil }
    return rect.offsetBy(dx: pane.origin.x + offset.x, dy: pane.origin.y + offset.y)
  }

  func character(at point: CGPoint) -> NSRange {
    guard let pane, let crop, pane.bounds.contains(point) else { return ComposeAccessibilityText.missing }
    let local = CGPoint(x: point.x - pane.origin.x, y: point.y - pane.origin.y)
    let range: NSRange
    if let placed = pane.layout.text.attachments.first(where: { $0.rect.contains(local) }),
       let start = pane.layout.text.utf16Position(for: placed.attachment.source.lowerBound),
       let end = pane.layout.text.utf16Position(for: placed.attachment.source.upperBound, affinity: .upstream) {
      range = NSRange(location: start, length: end - start)
    } else { range = ComposeAccessibilityText(pane: pane).character(at: local) }
    guard range.location != NSNotFound else { return range }
    return NSRange(location: crop.location + range.location, length: range.length)
  }

  func attributed(_ range: NSRange, attachment: (Range<Int>) -> Any?) -> NSAttributedString? {
    guard let text = model.string(for: range) else { return nil }
    let result = NSMutableAttributedString(string: text)
    for style in flow?.textIndex.styles(intersecting: range) ?? [] {
      let overlap = NSIntersectionRange(style.range, range)
      guard overlap.length > 0 else { continue }
      let relative = NSRange(location: overlap.location - range.location, length: overlap.length)
      if let flow, flow.fonts.indices.contains(style.font) {
        let font = flow.fonts[style.font]
        let attributes: [NSAccessibility.FontAttributeKey: Any] = [
          .fontName: font.name, .fontFamily: font.family, .fontSize: font.size,
        ]
        result.addAttribute(.accessibilityFont, value: attributes, range: relative)
      }
    }
    // Attachment ownership is known before shaping. Expose the same complete
    // inventory while fonts/lines are pending, without demanding image bytes.
    for image in model.imageRanges(intersecting: range) {
      guard let element = attachment(image.source) else { continue }
      let overlap = NSIntersectionRange(image.range, range)
      if overlap.length > 0 {
        result.addAttribute(.accessibilityAttachment, value: element,
          range: NSRange(location: overlap.location - range.location, length: overlap.length))
      }
    }
    return result
  }

  func imageRect(_ source: Range<Int>) -> CGRect? {
    guard let pane else { return nil }
    if let placed = pane.attachment(start: UInt64(source.lowerBound), end: UInt64(source.upperBound)), crop != nil {
      return placed.rect.offsetBy(dx: pane.origin.x, dy: pane.origin.y)
    }
    guard let flow, let offset = translation, let placed = flow.attachment(source: source) else { return nil }
    return placed.rect.offsetBy(dx: pane.origin.x + offset.x, dy: pane.origin.y + offset.y)
  }
}
