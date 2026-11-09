import CoreText
import XCTest
@testable import FreshKit

final class ComposeDocumentPresentationTests: XCTestCase {
  private let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
  private func fixture(_ text: String) -> DocumentUpdateFixture {
    var value = DocumentUpdateFixture()
    value.pane.compose.text = text; value.pane.compose.sourceEnd = UInt64(text.utf8.count)
    value.pane.compose.documentLen = value.pane.compose.sourceEnd; value.pane.compose.spans = []
    value.pane.compose.segments = [.with { $0.sourceEnd = UInt64(text.utf8.count); $0.displayEnd = $0.sourceEnd }]
    return value
  }
  private func context(_ text: String, start: Int = 0, units: Int = 0, length: Int? = nil) throws -> ComposeTextContext {
    try XCTUnwrap(ComposeTextContext(.with {
      $0.text = text; $0.sourceStart = UInt64(start); $0.utf16Start = UInt64(units)
    }, documentLength: UInt64(length ?? text.utf8.count)))
  }
  private func draft(_ context: ComposeTextContext, range: NSRange, text: String, selected: NSRange? = nil) throws -> ComposeMarkedText {
    try XCTUnwrap(ComposeMarkedText(context: context, range: range,
      source: try XCTUnwrap(context.sourceRange(forUTF16: range)), text: NSAttributedString(string: text),
      selected: selected ?? NSRange(location: text.utf16.count,length: 0)))
  }
  private func overlay(_ pane: WirePane, _ composition: ComposeComposition? = nil,
                       insertion: ComposeVirtualInsertion? = nil, selections: ComposeVirtualSelections? = nil) throws -> ComposeDocumentOverlay {
    try XCTUnwrap(ComposeDocumentOverlay(window: 1,pane: pane,composition: composition,
      virtualInsertion: insertion,virtualSelections: selections))
  }

  func testCompleteDraftKeepsAnOffscreenSecondaryAndCertifiesTheSameCroppedProjection() throws {
    let head = "café 👩🏽‍💻 first\r\n", middle = String(repeating: "middle e\u{301} 東京\r\n",count: 4000), tail = "Final text\r\n"
    let source = head+middle+tail
    var fixture = fixture(source)
    fixture.pane.compose.cursors = [.with { $0.id = 10; $0.primary = true; $0.position = 0 },
      .with { $0.id = 20; $0.position = UInt64((head+middle).utf8.count); $0.anchor = UInt64(source.utf8.count) }]
    let composition = try XCTUnwrap(ComposeComposition(primary: 10,values: [10: try draft(context(head,length: source.utf8.count),
      range: NSRange(location: 0,length: 0),text: "日本 👩🏽‍💻\r\n",selected: NSRange(location: 0,length: 2))]))
    let snapshot = try fixture.snapshot(), captured = try overlay(fixture.pane,composition)
    let presentation = try XCTUnwrap(ComposeDocumentPresentation(snapshot,overlay: captured))
    XCTAssertTrue(presentation.text.utf8.elementsEqual(("日本 👩🏽‍💻\r\n"+source).utf8))
    XCTAssertEqual(presentation.selectedRanges,[NSRange(location: 0,length: 2),
      NSRange(location: ("日本 👩🏽‍💻\r\n"+head+middle).utf16.count,length: tail.utf16.count)])
    XCTAssertEqual(snapshot.document.text,source,"the verified source baseline is never rewritten by a draft")
    let environment = ComposeFlowMeasurement.Environment(body: font,monospace: font,width: 420)
    let flow = try ComposeFlowMeasurement.measure(snapshot,environment: environment,overlay: captured)
    var crop = fixture.pane
    crop.compose.sourceStart = UInt64((head+middle).utf8.count); crop.compose.text = tail
    crop.compose.segments = [.with { $0.sourceStart = crop.compose.sourceStart; $0.sourceEnd = crop.compose.sourceEnd; $0.displayEnd = UInt64(tail.utf8.count) }]
    let drawing = try XCTUnwrap(ComposePaneLayout(pane: crop.compose,body: font,monospace: font,width: 420,composition: composition))
    let range = try XCTUnwrap(flow.presentation.range(window: 1,pane: crop,projection: drawing.text.projection))
    XCTAssertEqual(range.location,("日本 👩🏽‍💻\r\n"+head+middle).utf16.count)
    XCTAssertNotNil(flow.correspondence(window: 1,pane: crop,layout: drawing))
    XCTAssertNotNil(flow.bounds(for: NSRange(location: range.location,length: 5)))
  }

  func testLayeredInsertionRetainsGenuineCaretsWhileEndpointsUseOnlyLocalRegionKeys() throws {
    var fixture = fixture("aa BB cc")
    fixture.pane.compose.cursors = [.with { $0.id = 30; $0.primary = true },.with { $0.id = 40; $0.position = 3 }]
    let context = try context(fixture.pane.compose.text)
    let prefix = try XCTUnwrap(ComposeComposition(primary: 30,values: [
      30: try draft(context,range: NSRange(location: 0,length: 0),text: "日本"),
      40: try draft(context,range: NSRange(location: 3,length: 0),text: "日本")]))
    let moved = try XCTUnwrap(ComposeVirtualSelections(prefix: prefix)?.movingPrimary(to: 6,extend: false))
    let snapshot = try fixture.snapshot()
    let selected = try XCTUnwrap(ComposeDocumentPresentation(snapshot,overlay: overlay(fixture.pane,prefix,selections: moved)))
    XCTAssertEqual(selected.text,"日本aa 日本BB cc")
    XCTAssertEqual(selected.selectedRanges,[NSRange(location: 6,length: 0),NSRange(location: 7,length: 0)])
    let insertion = try XCTUnwrap(ComposeVirtualInsertion(selections: moved,text: NSAttributedString(string: "X"),selected: NSRange(location: 1,length: 0)))
    let captured = try overlay(fixture.pane,insertion: insertion)
    let flow = try ComposeFlowMeasurement.measure(snapshot,environment: .init(body: font,monospace: font,width: 140),overlay: captured)
    XCTAssertEqual(flow.presentation.text,"日本aa 日X本XBB cc")
    XCTAssertEqual(flow.presentation.selectedRanges,[NSRange(location: 7,length: 0),NSRange(location: 9,length: 0)])
    let point = try XCTUnwrap(flow.presentation.endpoint(atUTF16: 7))
    guard case .draft(let region,let offset) = point.location else { return XCTFail("an inserted point cannot be a source byte") }
    XCTAssertFalse([30,40].contains(region)); XCTAssertEqual(offset,2)
    let drawing = try XCTUnwrap(ComposePaneLayout(pane: snapshot.pane,body: font,monospace: font,width: 140,virtualInsertion: insertion))
    XCTAssertEqual(flow.correspondence(window: 1,pane: fixture.pane,layout: drawing),.zero)
    XCTAssertEqual(flow.presentation.characterCount,drawing.text.projection.text.utf16.count)
  }

  func testProposedGroupCanAddAndDropCaretsWithoutRekeyingSourceRegions() throws {
    var fixture = fixture("aa BB cc")
    fixture.pane.compose.cursors = [.with { $0.id = 30; $0.primary = true }, .with { $0.id = 40; $0.position = 3 }]
    let raw = try context(fixture.pane.compose.text)
    let prefix = try XCTUnwrap(ComposeComposition(primary: 30, values: [
      30: try draft(raw, range: NSRange(location: 0, length: 0), text: "日本"),
      40: try draft(raw, range: NSRange(location: 3, length: 0), text: "日本")]))
    let group = try XCTUnwrap(ComposeVirtualSelections(prefix: prefix)?.replacingGroup(with: [
      NSRange(location: 1, length: 0), NSRange(location: 5, length: 0), NSRange(location: 10, length: 0)]))
    let snapshot = try fixture.snapshot()
    let selected = try XCTUnwrap(ComposeDocumentPresentation(snapshot, overlay: overlay(fixture.pane, prefix, selections: group)))
    XCTAssertEqual(selected.selectedRanges, [NSRange(location: 1, length: 0), NSRange(location: 5, length: 0), NSRange(location: 10, length: 0)])
    XCTAssertEqual(selected.text, "日本aa 日本BB cc")
    let insertion = try XCTUnwrap(ComposeVirtualInsertion(selections: group, text: NSAttributedString(string: "X"), selected: NSRange(location: 1, length: 0)))
    let full = try XCTUnwrap(ComposeDocumentPresentation(snapshot, overlay: overlay(fixture.pane, insertion: insertion)))
    XCTAssertEqual(full.text, "日X本aa X日本BB Xcc")
    XCTAssertEqual(full.selectedRanges, [NSRange(location: 2, length: 0), NSRange(location: 7, length: 0), NSRange(location: 13, length: 0)])
    XCTAssertEqual(snapshot.document.text, "aa BB cc")
    let one = try XCTUnwrap(group.replacingGroup(with: [NSRange(location: 1, length: 0)]))
    let reduced = try XCTUnwrap(ComposeDocumentPresentation(snapshot, overlay: overlay(fixture.pane, prefix, selections: one)))
    XCTAssertEqual(reduced.selectedRanges, [NSRange(location: 1, length: 0)])
  }

  func testImageReplacementAndDraftingInsideItsMarkdownShareTheRendererPlan() throws {
    var fixture = fixture("before ![alt](image.png) after")
    let raw = fixture.pane.compose.text, image = (raw as NSString).range(of: "![alt](image.png)")
    fixture.pane.compose.images = [.with {
      $0.start = UInt64(image.location); $0.end = UInt64(NSMaxRange(image)); $0.rendered = true; $0.alt = "alt"
    }]
    let snapshot = try fixture.snapshot(), baseline = try XCTUnwrap(ComposeDocumentPresentation(snapshot))
    XCTAssertEqual(baseline.text,"before \u{fffc} after")
    let start = image.location+2
    fixture.pane.compose.cursors[0].position = UInt64(start)
    let composition = try XCTUnwrap(ComposeComposition(primary: 1,values: [1: try draft(context(raw),
      range: NSRange(location: start,length: 0),text: "X")]))
    let captured = try overlay(fixture.pane,composition), presentation = try XCTUnwrap(ComposeDocumentPresentation(snapshot,overlay: captured))
    XCTAssertEqual(presentation.text,"before ![Xalt](image.png) after")
    let drawing = try XCTUnwrap(ComposePaneLayout(pane: snapshot.pane,body: font,monospace: font,width: 300,composition: composition))
    XCTAssertEqual(presentation.text,drawing.text.projection.text); XCTAssertTrue(presentation.plan.images.isEmpty)
    let flow = try ComposeFlowMeasurement.measure(snapshot,environment: .init(body: font,monospace: font,width: 300),overlay: captured)
    XCTAssertEqual(flow.presentation.text,presentation.text); XCTAssertTrue(flow.attachments.isEmpty)
  }

  func testProvisionalTableCellsUseTheSameCompleteLineStyleAndGlyphCoordinates() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "compose-tables",withExtension: "pb",subdirectory: "Fixtures"))
    var fixture = fixture("")
    fixture.pane.compose = try WireComposePane(serializedBytes: Data(contentsOf: url))
    fixture.pane.compose.bufferRevision = 5; fixture.pane.compose.selectionRevision = 6; fixture.pane.compose.decorationRevision = 7
    fixture.pane.compose.viewport.epoch = 9; fixture.pane.compose.assetAuthority = 10; fixture.pane.compose.assetDocument = 11
    fixture.pane.compose.ready = true; fixture.pane.compose.currentProjection = true
    let context = try XCTUnwrap(ComposeTextContext(fixture.pane.compose.textContext,documentLength: fixture.pane.compose.documentLen))
    var range = (context.text as NSString).range(of: "café")
    XCTAssertNotEqual(range.location,NSNotFound); range.location += context.range.location
    let value = try draft(context,range: range,text: String(repeating: "extended 👩🏽‍💻 日本 ",count: 20),selected: NSRange(location: 0,length: 8))
    fixture.pane.compose.cursors = [.with {
      $0.id = 30; $0.primary = true; $0.position = UInt64(value.source.upperBound); $0.anchor = UInt64(value.source.lowerBound)
    }]
    let composition = try XCTUnwrap(ComposeComposition(primary: 30,values: [30:value]))
    let snapshot = try fixture.snapshot(), captured = try overlay(fixture.pane,composition)
    for width: CGFloat in [320,620] {
      let drawing = try XCTUnwrap(ComposePaneLayout(pane: snapshot.pane,body: font,monospace: font,width: width,composition: composition))
      let flow = try ComposeFlowMeasurement.measure(snapshot,environment: .init(body: font,monospace: font,width: width),overlay: captured)
      XCTAssertEqual(flow.presentation.text,drawing.text.projection.text)
      XCTAssertEqual(flow.lines.map(\.range),drawing.text.fragments.map(\.range))
      XCTAssertEqual(flow.lines.map(\.rect),drawing.text.fragments.map(\.rect))
      XCTAssertEqual(flow.tables.count,2); XCTAssertEqual(flow.correspondence(window: 1,pane: fixture.pane,layout: drawing),.zero)
      let selection = try XCTUnwrap(flow.presentation.selectedRanges?.first)
      XCTAssertEqual(flow.presentation.string(for: selection),"extended")
      XCTAssertNotNil(flow.bounds(for: selection)); XCTAssertNotNil(flow.textIndex.style(atUTF16: selection.location))
    }
  }

  func testClauseSelectionReusesGlyphsButNewTextRebuildsAndEndpointsNeverRegainRetiredIdentity() throws {
    let fixture = fixture("abc 👩🏽‍💻 tail"), snapshot = try fixture.snapshot()
    var composition = try XCTUnwrap(ComposeComposition(primary: 1,values: [1: try draft(context(fixture.pane.compose.text),
      range: NSRange(location: 0,length: 3),text: "日本 👩🏽‍💻",selected: NSRange(location: 0,length: 2))]))
    let environment = ComposeFlowMeasurement.Environment(body: font,monospace: font,width: 160)
    let first = try ComposeFlowMeasurement.measure(snapshot,environment: environment,overlay: overlay(fixture.pane,composition))
    let oldPoint = try XCTUnwrap(first.presentation.endpoint(atUTF16: 1))
    XCTAssertTrue(composition.select(NSRange(location: 2,length: 0)))
    let second = try ComposeFlowMeasurement.measure(snapshot,environment: environment,overlay: overlay(fixture.pane,composition),reusing: first)
    XCTAssertEqual(second.geometryGeneration,first.geometryGeneration)
    XCTAssertEqual(second.presentation.selectedRanges,[NSRange(location: 2,length: 0)])
    XCTAssertNotEqual(second.presentation.endpoint(atUTF16: 1)?.presentation,oldPoint.presentation)
    XCTAssertTrue(composition.update(NSAttributedString(string: "語"),selected: NSRange(location: 1,length: 0),replacement: NSRange(location: NSNotFound,length: 0)))
    let third = try ComposeFlowMeasurement.measure(snapshot,environment: environment,overlay: overlay(fixture.pane,composition),reusing: second)
    XCTAssertNotEqual(third.geometryGeneration,second.geometryGeneration)
    XCTAssertNotEqual(third.presentation.text,second.presentation.text)
  }

  func testDeletionAndUnicodeEndpointsAreProvisionalAndSourceOwnershipCannotBeRelabelled() throws {
    let fixture = fixture("Aé👩‍💻Z"), snapshot = try fixture.snapshot()
    let composition = try XCTUnwrap(ComposeComposition(primary: 1,values: [1: try draft(context(fixture.pane.compose.text),
      range: NSRange(location: 1,length: 1),text: "")]))
    let captured = try overlay(fixture.pane,composition), presentation = try XCTUnwrap(ComposeDocumentPresentation(snapshot,overlay: captured))
    XCTAssertEqual(presentation.text,"A👩‍💻Z")
    XCTAssertEqual(presentation.endpoint(atUTF16: 1)?.location,.draft(region: 1,offsetUTF16: 0),"a deletion still owns a pending boundary")
    XCTAssertNil(presentation.endpoint(atUTF16: 2)); XCTAssertNil(presentation.string(for: NSRange(location: 2,length: 1)))
    XCTAssertEqual(presentation.character(at: 2),NSRange(location: 1,length: 5))
    var changed = fixture; changed.pane.compose.bufferRevision += 1
    XCTAssertNil(ComposeDocumentPresentation(try changed.snapshot(),overlay: captured))
    changed = fixture; changed.pane.compose.selectionRevision += 1
    XCTAssertNil(ComposeDocumentPresentation(try changed.snapshot(),overlay: captured))
    changed = fixture; changed.pane.compose.decorationRevision += 1
    XCTAssertNil(ComposeDocumentPresentation(try changed.snapshot(),overlay: captured))
    changed = fixture; changed.pane.compose.cursors[0].primary = false
    XCTAssertNil(ComposeDocumentOverlay(window: 1,pane: changed.pane,composition: composition))
  }

  func testAttributedObjectsStayOutsideTheWorkerCaptureAndNormalizedCommittedTextStaysExact() async throws {
    var fixture = fixture("before\r\nafter")
    fixture.pane.compose.textContext.text = fixture.pane.compose.text
    fixture.pane.compose.textContext.selectionStart = 0; fixture.pane.compose.textContext.selectionEnd = 0
    let mutable = NSMutableString(string: "mutable attribute")
    let text = NSAttributedString(string: "é\n👩🏽‍💻",attributes: [NSAttributedString.Key("custom.mutable"):mutable])
    let pending = try XCTUnwrap(ComposePendingText(pane: fixture.pane.compose,text: text,selected: NSRange(location: text.length,length: 0),
      replacement: NSRange(location: NSNotFound,length: 0)))
    let committed = try XCTUnwrap(pending.committed(nativeNewline: 2))
    let captured = try overlay(fixture.pane,committed.presentation), snapshot = try fixture.snapshot()
    mutable.setString("changed after capture")
    let result = try await Task.detached {
      let restored = try XCTUnwrap(captured.composition?.restore())
      XCTAssertTrue(restored.primary.draft.attributes(at: 0,effectiveRange: nil).isEmpty)
      return try XCTUnwrap(ComposeDocumentPresentation(snapshot,overlay: captured))
    }.value
    XCTAssertTrue(result.text.utf8.elementsEqual(("é\r\n👩🏽‍💻"+fixture.pane.compose.text).utf8))
    XCTAssertEqual(result.selectedRanges,[NSRange(location: "é\r\n👩🏽‍💻".utf16.count,length: 0)])
  }
}
