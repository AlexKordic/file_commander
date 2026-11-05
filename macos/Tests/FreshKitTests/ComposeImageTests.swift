import XCTest
import CoreGraphics
import CoreText
import ImageIO
@testable import FreshKit

final class ComposeImageTests: XCTestCase {
  private func bitmap(_ width: Int = 96, _ height: Int = 48) throws -> CGImage {
    let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0.1, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    return try XCTUnwrap(context.makeImage())
  }

  private func encode(_ image: CGImage, type: String = "public.png", orientation: Int = 1) throws -> Data {
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
  }

  private func pane(_ text: String) -> WireComposePane {
    .with {
      $0.text = text; $0.sourceEnd = UInt64(text.utf8.count); $0.documentLen = $0.sourceEnd
      $0.projectionRevision = 1
      $0.segments = [.with { $0.sourceEnd = UInt64(text.utf8.count); $0.displayEnd = $0.sourceEnd }]
    }
  }
  private func image(_ source: String, _ markup: String, block: Bool = false) -> WireComposeImage {
    let range = source.range(of: markup)!
    return .with {
      $0.start = UInt64(source[..<range.lowerBound].utf8.count); $0.end = UInt64(source[..<range.upperBound].utf8.count)
      $0.target = "x.png"; $0.alt = "A red and blue test image"; $0.block = block; $0.rendered = true
    }
  }

  func testObjectsPreserveSurroundingUnicodeAndRefuseInventedAtomicBoundaries() throws {
    let source = "é ![pic](x.png) 👩🏽‍💻"
    let annotation = image(source, "![pic](x.png)")
    let base = try XCTUnwrap(ComposeProjection(pane(source)))
    let range = Int(annotation.start)..<Int(annotation.end)
    let replaced = try XCTUnwrap(base.replacingObjects([range]))
    XCTAssertEqual(replaced.projection.text, "é \u{fffc} 👩🏽‍💻")
    let object = replaced.objects[0]
    XCTAssertEqual(replaced.projection.sourcePosition(at: object.display.lowerBound), range.lowerBound)
    XCTAssertEqual(replaced.projection.sourcePosition(at: object.display.upperBound), range.upperBound)
    XCTAssertEqual(replaced.projection.displayPosition(for: range.lowerBound + 3), object.display.upperBound)
    let atomic = try XCTUnwrap(ComposeProjection(source: 0..<10, text: "x", segments: [
      .init(source: 0..<10, display: 0..<1, kind: .replacement),
    ]))
    XCTAssertNil(atomic.replacingObjects([2..<5]))
    XCTAssertNil(base.replacingObjects([range, range]))
  }

  func testRealFreshComposeImageProjectionUsesTheSameSourceRangesInNativeLayout() throws {
    // Recorded by scene_socket's real markdown_compose plugin contract; only
    // opaque authority/document ids are normalized when writing the fixture.
    let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/compose-images", withExtension: "pb"))
    let input = try WireComposePane(serializedBytes: Data(contentsOf: url))
    XCTAssertEqual(input.images.count, 3)
    XCTAssertEqual(input.images.map(\.block), [false, true, true])
    XCTAssertEqual(input.images[2].target, "a b.png")
    let asset = try ComposeImageAsset.decode(encode(bitmap()))
    let states = Dictionary(uniqueKeysWithValues: input.images.map { ($0.start, ComposeImageState.ready(asset)) })
    let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
    let layout = try XCTUnwrap(ComposePaneLayout(pane: input, body: font, monospace: font, width: 480, images: states))
    XCTAssertEqual(layout.text.attachments.count, 3)
    for image in input.images {
      let placed = try XCTUnwrap(layout.text.attachments.first { UInt64($0.attachment.source.lowerBound) == image.start })
      XCTAssertEqual(placed.attachment.source.upperBound, Int(image.end))
      let click = try XCTUnwrap(layout.text.hit(at: CGPoint(x: placed.rect.maxX - 1, y: placed.rect.midY)))
      XCTAssertEqual(click.source, Int(image.end))
      XCTAssertEqual(click.attachment, Int(image.start)..<Int(image.end))
    }
  }

  func testInlineImageParticipatesInWrappingHitTestingAndMeasuredSourceNavigation() throws {
    let source = "Before ![pic](x.png) after text that wraps."
    var input = pane(source); let annotation = image(source, "![pic](x.png)"); input.images = [annotation]
    let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
    let asset = try ComposeImageAsset.decode(encode(bitmap()))
    let layout = try XCTUnwrap(ComposePaneLayout(pane: input, body: font, monospace: font, width: 400,
      images: [annotation.start: .ready(asset)]))
    let placed = try XCTUnwrap(layout.text.attachments.first)
    XCTAssertEqual(placed.rect.width, 96, accuracy: 0.1)
    XCTAssertEqual(placed.rect.height, 48, accuracy: 0.1)
    XCTAssertGreaterThan(layout.text.fragments[0].rect.height, 48)
    let before = try XCTUnwrap(layout.text.caret(for: Int(annotation.start)))
    let after = try XCTUnwrap(layout.text.caret(for: Int(annotation.end)))
    XCTAssertEqual(after.minX - before.minX, 96, accuracy: 0.1)
    let hit = try XCTUnwrap(layout.text.hit(at: CGPoint(x: placed.rect.maxX - 2, y: placed.rect.midY)))
    XCTAssertEqual(hit.source, Int(annotation.end)); XCTAssertEqual(hit.attachment, Int(annotation.start)..<Int(annotation.end))
    let feedback = try XCTUnwrap(layout.text.navigation(id: 1, pageHeight: 200, documentLength: input.documentLen, positions: [0]))
    XCTAssertTrue(feedback.lines.flatMap(\.stops).allSatisfy { $0.source <= annotation.start || $0.source >= annotation.end })
    let narrow = try XCTUnwrap(ComposePaneLayout(pane: input, body: font, monospace: font, width: 100,
      images: [annotation.start: .ready(asset)]))
    XCTAssertGreaterThan(narrow.text.fragments.count, layout.text.fragments.count)
    XCTAssertLessThanOrEqual(narrow.text.attachments[0].rect.maxX, 100)
  }

  func testBlockImageAndPlaceholderFitTheIndentedQuoteAndListMeasure() throws {
    let source = "![pic](x.png)\n"
    var input = pane(source)
    let annotation = image(source, "![pic](x.png)", block: true)
    input.images = [annotation]
    input.spans = [9, 10, 11].map { role in .with { $0.end = input.sourceEnd; $0.role = UInt32(role) } }
    let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
    let asset = try ComposeImageAsset.decode(encode(bitmap(600, 300)))
    for state: ComposeImageState in [.loading, .ready(asset), .failed("Unavailable")] {
      let layout = try XCTUnwrap(ComposePaneLayout(pane: input, body: font, monospace: font, width: 260,
        images: [annotation.start: state]))
      let placed = try XCTUnwrap(layout.text.attachments.first)
      XCTAssertEqual(placed.rect.minX, 48, accuracy: 0.001)
      XCTAssertLessThanOrEqual(placed.rect.maxX, 260)
      let hit = try XCTUnwrap(layout.text.hit(at: CGPoint(x: placed.rect.maxX - 1, y: placed.rect.midY)))
      XCTAssertEqual(hit.attachment, Int(annotation.start)..<Int(annotation.end))
      XCTAssertEqual(hit.source, Int(annotation.end))
      let caret = try XCTUnwrap(layout.text.caret(for: Int(annotation.end), affinity: .upstream))
      XCTAssertEqual(caret.minX, placed.rect.maxX, accuracy: 0.001)
    }
  }

  func testSourceEditingKeepsExactWrappedMarkupAndAddsOnlyPreviewGeometry() throws {
    let markup = "![**café 👩🏽‍💻**](<images/a very long path.png> \"caption\")"
    let source = "Before \(markup) after.\r\n\r\nFollowing paragraph.\r\n"
    var input = pane(source)
    var annotation = image(source, markup)
    annotation.rendered = false; annotation.sourcePreview = true
    input.images = [annotation]
    let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
    let mono = CTFontCreateWithName("Menlo" as CFString, 16, nil)
    let asset = try ComposeImageAsset.decode(encode(bitmap(600, 300)))
    for width: CGFloat in [180, 480] {
      let layout = try XCTUnwrap(ComposePaneLayout(pane: input, body: font, monospace: mono, width: width,
        images: [annotation.start: .ready(asset)]))
      XCTAssertEqual(layout.text.projection.text, source)
      XCTAssertTrue(layout.text.projection.segments.allSatisfy { $0.kind == .copy })
      let placed = try XCTUnwrap(layout.text.attachments.first)
      XCTAssertTrue(placed.attachment.preview)
      XCTAssertEqual(placed.attachment.display, Int(annotation.start)..<Int(annotation.end))
      XCTAssertLessThanOrEqual(placed.rect.width, min(width, 360))
      XCTAssertLessThanOrEqual(placed.rect.height, 240)
      let end = try XCTUnwrap(layout.text.caret(for: Int(annotation.end), affinity: .upstream))
      XCTAssertLessThanOrEqual(end.maxY + 18, placed.rect.minY + 0.001)
      let following = source[..<source.range(of: "Following")!.lowerBound].utf8.count
      let after = try XCTUnwrap(layout.text.caret(for: following))
      XCTAssertGreaterThanOrEqual(after.minY, placed.rect.maxY + 8)
      let hit = try XCTUnwrap(layout.text.hit(at: CGPoint(x: placed.rect.maxX - 1, y: placed.rect.midY)))
      XCTAssertEqual(hit.attachment, Int(annotation.start)..<Int(annotation.end))
      let feedback = try XCTUnwrap(layout.text.navigation(id: 1, pageHeight: 900,
        documentLength: input.documentLen, positions: [annotation.start]))
      XCTAssertTrue(feedback.lines.flatMap(\.stops).contains { annotation.start < $0.source && $0.source < annotation.end },
        "markup has real caret stops; the preview adds none")
      XCTAssertEqual(feedback.lines.count, layout.text.fragments.count)
      if width == 480 {
        let w = 528, h = Int(ceil(layout.text.size.height)) + 48
        let context = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(h)); context.scaleBy(x: 1, y: -1)
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        layout.draw(in: context, origin: CGPoint(x: 24, y: 24), clip: bounds, dirty: bounds,
          foreground: CGColor(gray: 0.1, alpha: 1), background: CGColor(gray: 1, alpha: 1), selection: CGColor(gray: 0.5, alpha: 1))
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        let red = (0..<(w * h)).filter { pixels[$0 * 4] > 200 && pixels[$0 * 4 + 2] < 70 }.count
        XCTAssertGreaterThan(red, 1000, "the source-edit preview uses the native image draw path")
        if let path = ProcessInfo.processInfo.environment["FC_COMPOSE_SOURCE_PREVIEW_FILE"] {
          try encode(XCTUnwrap(context.makeImage())).write(to: URL(fileURLWithPath: path))
        }
      }
    }
    // Pending/fallback source has neither native attachment nor asset demand.
    input.images[0].sourcePreview = false
    let sourceOnly = try XCTUnwrap(ComposePaneLayout(pane: input, body: font, monospace: mono, width: 480))
    XCTAssertTrue(sourceOnly.text.attachments.isEmpty)
    input.images[0].sourcePreview = true; input.images[0].rendered = true
    XCTAssertNil(ComposePaneLayout(pane: input, body: font, monospace: mono, width: 480))
    input.images[0].rendered = false
    let replaced = try XCTUnwrap(ComposeProjection(input)?.replacingObjects([Int(annotation.start)..<Int(annotation.end)]))
    input.text = replaced.projection.text
    input.segments = replaced.projection.segments.map { segment in .with {
      $0.sourceStart = UInt64(segment.source.lowerBound); $0.sourceEnd = UInt64(segment.source.upperBound)
      $0.displayStart = UInt64(segment.display.lowerBound); $0.displayEnd = UInt64(segment.display.upperBound)
      $0.kind = segment.kind == .copy ? 0 : 2
    } }
    XCTAssertNil(ComposePaneLayout(pane: input, body: font, monospace: mono, width: 480),
      "a source-edit preview must not accept a concealed or atomic source map")
  }

  func testSourcePreviewFitsNestedIndentAndAnchorsFollowingTextThroughLateSizing() throws {
    let source = "![pic](x.png)\n\nFollowing\n"
    var input = pane(source)
    var annotation = image(source, "![pic](x.png)", block: true)
    annotation.rendered = false; annotation.sourcePreview = true; input.images = [annotation]
    input.spans = [9, 10, 11].map { role in .with { $0.end = annotation.end; $0.role = UInt32(role) } }
    let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
    let asset = try ComposeImageAsset.decode(encode(bitmap(600, 300)))
    let following = source[..<source.range(of: "Following")!.lowerBound].utf8.count
    for state: ComposeImageState in [.loading, .ready(asset), .failed("Unavailable")] {
      let layout = try XCTUnwrap(ComposePaneLayout(pane: input, body: font, monospace: font, width: 200,
        images: [annotation.start: state]))
      let rect = try XCTUnwrap(layout.text.attachments.first?.rect)
      XCTAssertEqual(rect.minX, 48, accuracy: 0.001)
      XCTAssertLessThanOrEqual(rect.maxX, 200)
      let viewport = ComposeViewport(text: layout.text, documentLength: input.documentLen, height: 80)
      let anchor = WireComposeViewport.with { $0.position = UInt64(following); $0.offset = 12; $0.epoch = 1 }
      let top = try XCTUnwrap(viewport.requestedTop(anchor))
      XCTAssertEqual(try XCTUnwrap(layout.text.caret(for: following)).minY - top, 12, accuracy: 0.001)
    }
  }

  func testImagesDrawInsideTextAndAsBlocksThroughTheNativePath() throws {
    let source = "Compose images\n\nBefore ![inline](x.png) after text.\n\n![block](x.png)\n\nEnd."
    var input = pane(source)
    let inline = image(source, "![inline](x.png)"), block = image(source, "![block](x.png)", block: true)
    input.images = [inline, block]
    input.spans = [.with { $0.start = 0; $0.end = 14; $0.role = 1 }]
    let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
    let asset = try ComposeImageAsset.decode(encode(bitmap()))
    let layout = try XCTUnwrap(ComposePaneLayout(pane: input, body: font, monospace: font, width: 480,
      images: [inline.start: .ready(asset), block.start: .ready(asset)]))
    XCTAssertEqual(layout.text.attachments.count, 2)
    XCTAssertGreaterThan(layout.text.attachments[1].rect.minY, layout.text.attachments[0].rect.maxY)
    let width = 528, height = Int(ceil(layout.text.size.height)) + 48
    let context = try XCTUnwrap(CGContext(data: nil, width: width * 2, height: height * 2, bitsPerComponent: 8,
      bytesPerRow: width * 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.scaleBy(x: 2, y: 2); context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    layout.draw(in: context, origin: CGPoint(x: 24, y: 24), clip: bounds, dirty: bounds,
      foreground: CGColor(gray: 0.1, alpha: 1), background: CGColor(gray: 1, alpha: 1), selection: CGColor(gray: 0.5, alpha: 1))
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    let red = (0..<(width * height * 4)).filter { pixels[$0 * 4] > 200 && pixels[$0 * 4 + 2] < 70 }.count
    let blue = (0..<(width * height * 4)).filter { pixels[$0 * 4] < 70 && pixels[$0 * 4 + 2] > 200 }.count
    XCTAssertGreaterThan(red, 1000); XCTAssertGreaterThan(blue, 1000)
    func blackInk(_ rect: CGRect) -> Int {
      var count = 0
      for y in max(0, Int(rect.minY * 2))..<min(height * 2, Int(ceil(rect.maxY * 2))) {
        for x in max(0, Int(rect.minX * 2))..<min(width * 2, Int(ceil(rect.maxX * 2))) {
          let i = (y * width * 2 + x) * 4
          if pixels[i] < 128 && pixels[i + 1] < 128 && pixels[i + 2] < 128 { count += 1 }
        }
      }
      return count
    }
    let inlineRect = layout.text.attachments[0].rect
    let row = try XCTUnwrap(layout.text.fragments.first { $0.rect.contains(CGPoint(x: 0, y: inlineRect.midY)) })
    XCTAssertGreaterThan(blackInk(CGRect(x: inlineRect.maxX + 24, y: row.rect.minY + 24,
      width: 480 - inlineRect.maxX, height: row.rect.height)), 20, "text after the inline image remains visible")
    let end = try XCTUnwrap(layout.text.caret(for: source.utf8.count - 4))
    XCTAssertGreaterThan(blackInk(CGRect(x: 24, y: end.minY + 24, width: 100, height: end.height)), 20,
      "text after the block image remains visible")
    if let path = ProcessInfo.processInfo.environment["FC_COMPOSE_IMAGE_PREVIEW_FILE"] {
      let data = try encode(XCTUnwrap(context.makeImage()))
      try data.write(to: URL(fileURLWithPath: path))
    }
  }

  func testImageDecoderDownsamplesAppliesOrientationAndChecksSourceDimensions() throws {
    let source = try bitmap(80, 40)
    let thumbnail = try ComposeImageAsset.decode(encode(source), maximumDimension: 20)
    XCTAssertEqual(thumbnail.originalSize, CGSize(width: 80, height: 40))
    XCTAssertEqual(thumbnail.image.width, 20); XCTAssertEqual(thumbnail.image.height, 10)
    let oriented = try ComposeImageAsset.decode(encode(source, type: "public.jpeg", orientation: 6))
    XCTAssertEqual(oriented.originalSize, CGSize(width: 40, height: 80))
    XCTAssertEqual(oriented.image.width, 40); XCTAssertEqual(oriented.image.height, 80)
    XCTAssertThrowsError(try ComposeImageAsset.decode(Data([0, 1, 2, 3])))
    XCTAssertThrowsError(try ComposeImageAsset.decode(encode(bitmap(32_769, 1))))
  }
}
