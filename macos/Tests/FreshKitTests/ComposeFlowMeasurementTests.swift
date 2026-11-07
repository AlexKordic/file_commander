import CryptoKit
import CoreText
import XCTest
@testable import FreshKit

final class ComposeFlowMeasurementTests: XCTestCase {
  private let body=CTFontCreateWithName("Helvetica" as CFString,18,nil),code=CTFontCreateWithName("Menlo" as CFString,18,nil)
  private func snapshot(_ input:WireComposePane) throws -> ComposeDocumentSnapshot {
    var value=input;value.bufferRevision=1;value.selectionRevision=2;value.decorationRevision=3
    value.viewport.epoch=4;value.assetAuthority=5;value.assetDocument=6;value.ready=true;value.currentProjection=true
    let pane=WirePane.with {$0.leaf=2;$0.buffer=3;$0.compose=value}
    let document=try XCTUnwrap(ComposeAccessibleDocument(window:1,pane:pane)),data=try value.serializedData()
    return .init(document:document,pane:value,baseline:.init(id:1,owner:document.owner,data:data,digest:Data(SHA256.hash(data:data))))
  }
  private func plain(_ text:String) throws -> ComposeDocumentSnapshot {
    try snapshot(.with {
      $0.text=text;$0.sourceEnd=UInt64(text.utf8.count);$0.documentLen=$0.sourceEnd
      $0.segments=[.with {$0.sourceEnd=UInt64(text.utf8.count);$0.displayEnd=$0.sourceEnd}]
    })
  }
  private func tableFixture() throws -> ComposeDocumentSnapshot {
    let url=try XCTUnwrap(Bundle.module.url(forResource:"compose-tables",withExtension:"pb",subdirectory:"Fixtures"))
    return try snapshot(WireComposePane(serializedBytes:Data(contentsOf:url)))
  }

  func testWholeTableImageAndUnicodeFlowMatchesTheRendererWithoutRetainedGlyphLines() throws {
    let snapshot=try tableFixture()
    for width:CGFloat in [320,620] {
      let draw=try XCTUnwrap(ComposePaneLayout(pane:snapshot.pane,body:body,monospace:code,width:width))
      let flow=try ComposeFlowMeasurement.measure(snapshot,environment:draw.measurementEnvironment())
      XCTAssertFalse(flow.usage.retainedGlyphs);XCTAssertEqual(flow.lines.count,draw.text.fragments.count)
      XCTAssertEqual(flow.size,draw.text.size);XCTAssertEqual(flow.tables.count,draw.text.tables.count)
      XCTAssertEqual(flow.attachments.map(\.rect),draw.text.attachments.map(\.rect))
      for (line,fragment) in zip(flow.lines,draw.text.fragments) {
        XCTAssertEqual(line.range,fragment.range);XCTAssertEqual(line.rect,fragment.rect);XCTAssertEqual(line.baseline,fragment.baseline)
        XCTAssertEqual(line.signature,ComposeGlyphSignature.digest(fragment))
        XCTAssertEqual(line.table,fragment.table)
      }
      let pane=WirePane.with {$0.leaf=2;$0.buffer=3;$0.compose=snapshot.pane}
      XCTAssertEqual(flow.correspondence(window:1,pane:pane,layout:draw),.zero)
      let text=draw.text.projection.text as NSString
      for range in [NSRange(location:0,length:min(12,text.length)),NSRange(location:0,length:text.length),
                    text.range(of:"café",options:.literal)] where range.location != NSNotFound {
        var expected=CGRect.null
        for fragment in draw.text.fragments where NSIntersectionRange(fragment.range,range).length>0 {
          if let rect=ComposeGlyphGeometry.bounds(in:fragment,text:text,for:range) {expected=expected.union(rect)}
        }
        XCTAssertEqual(flow.bounds(for:range),expected.isNull ? nil:expected)
      }
      XCTAssertTrue(flow.fonts.contains(where:{$0.traits & CTFontSymbolicTraits.traitBold.rawValue != 0}))
      XCTAssertFalse(flow.styles.isEmpty)
    }
  }

  func testLargeMultilingualFlowUsesSparseCoordinatesAndBoundedContexts() async throws {
    let text=String(repeating:"café e\u{301} 👩🏽‍💻 東京 العربية abc.\r\n",count:14_000)
    let snapshot=try plain(text),environment=ComposeFlowMeasurement.Environment(body:body,monospace:code,width:700)
    let flow=try await Task.detached {try ComposeFlowMeasurement.measure(snapshot,environment:environment)}.value
    XCTAssertGreaterThan(text.utf8.count,500_000)
    XCTAssertGreaterThan(flow.lines.count,10_000);XCTAssertLessThanOrEqual(flow.usage.maximumContextUnits,16_384)
    XCTAssertLessThan(flow.usage.coordinateEntries,16);XCTAssertFalse(flow.usage.retainedGlyphs)
    let end=text.utf16.count
    XCTAssertNotNil(flow.bounds(for:NSRange(location:end-10,length:5)))
    XCTAssertNotNil(flow.bounds(for:NSRange(location:end,length:0)))
    XCTAssertEqual(flow.document.text.utf8.count,text.utf8.count)
  }

  func testAdmissionFailureDoesNotPublishAPrefixAndDoesNotAffectDrawing() throws {
    let source=String(repeating:"long café 👩🏽‍💻 paragraph ",count:2000),snapshot=try plain(source)
    let env=ComposeFlowMeasurement.Environment(body:body,monospace:code,width:180)
    XCTAssertThrowsError(try ComposeFlowMeasurement.measure(snapshot,environment:env,options:.init(maximumContextUnits:1024)))
    XCTAssertThrowsError(try ComposeFlowMeasurement.measure(plain("one\ntwo\nthree"),environment:env,options:.init(maximumFragments:2)))
    let drawing=try XCTUnwrap(ComposePaneLayout(pane:snapshot.pane,body:body,monospace:code,width:180))
    XCTAssertTrue(drawing.text.measurementUsage.retainedGlyphs);XCTAssertFalse(drawing.text.fragments.isEmpty)
    XCTAssertEqual(drawing.text.projection.text.utf8.count,source.utf8.count)
  }

  func testBoundsUseTheSameBidiAndCRLFAffinitiesAndEnvironmentChangesRetireCorrespondence() throws {
    let snapshot=try plain("abc אבג العربية 👩🏽‍💻\r\nsecond line\r\n")
    let draw=try XCTUnwrap(ComposePaneLayout(pane:snapshot.pane,body:body,monospace:code,width:160))
    let flow=try ComposeFlowMeasurement.measure(snapshot,environment:draw.measurementEnvironment())
    let string=snapshot.document.text as NSString
    for at in [0,4,string.range(of:"\r\n").location+1,string.length] {
      XCTAssertEqual(flow.bounds(for:NSRange(location:at,length:0)),draw.text.caret(atUTF16:at))
    }
    let pane=WirePane.with {$0.leaf=2;$0.buffer=3;$0.compose=snapshot.pane}
    let narrow=try XCTUnwrap(ComposePaneLayout(pane:snapshot.pane,body:body,monospace:code,width:140))
    XCTAssertNil(flow.correspondence(window:1,pane:pane,layout:narrow))
    var stale=pane;stale.compose.selectionRevision += 1
    XCTAssertNil(flow.correspondence(window:1,pane:stale,layout:draw))
    let before=ComposeFlowMeasurement.Environment(body:body,monospace:code,width:160,images:[1:.deferred(originalSize:CGSize(width:40,height:80))])
    let after=ComposeFlowMeasurement.Environment(body:body,monospace:code,width:160,images:[1:.deferred(originalSize:CGSize(width:80,height:40))])
    XCTAssertFalse(before.isEquivalent(to:after))
  }

  func testCompleteTableSamplesAndOffscreenMarkersCannotBypassContextAdmission() throws {
    let snapshot=try tableFixture(),environment=ComposeFlowMeasurement.Environment(body:body,monospace:code,width:320)
    var table=snapshot.pane
    XCTAssertFalse(table.tables.isEmpty)
    table.tables[0].measurement.columns[0].samples=[.with {$0.text=String(repeating:"sample ",count:10_000)}]
    XCTAssertThrowsError(try ComposeFlowMeasurement.measure(self.snapshot(table),environment:environment))
    // Drawing still accepts the exact sample. Measurement must reject it even
    // after its intrinsic font cache has been populated by another layout.
    let drawn=try XCTUnwrap(ComposePaneLayout(pane:table,body:body,monospace:code,width:320))
    XCTAssertNil(ComposePaneLayout(pane:table,body:body,monospace:code,width:320,reuse:drawn,measurement:.init()))
    let prefix=String(repeating:" ",count:80)+"1) ",tail="body words\n",start=prefix.utf8.count+1
    let marker=WireComposePane.with {
      $0.text=tail;$0.sourceStart=UInt64(start);$0.sourceEnd=UInt64(start+tail.utf8.count);$0.documentLen=$0.sourceEnd
      $0.segments=[.with {$0.sourceStart=UInt64(start);$0.sourceEnd=UInt64(start+tail.utf8.count);$0.displayEnd=UInt64(tail.utf8.count)}]
      $0.spans=[.with {$0.role=13;$0.contentStart=UInt64(prefix.utf8.count);$0.end=UInt64(start+tail.utf8.count)}]
      $0.hangingContexts=[.with {$0.contentStart=UInt64(prefix.utf8.count);$0.prefixEnd=UInt64(prefix.utf8.count);$0.text=prefix+"A"}]
    }
    XCTAssertNotNil(ComposePaneLayout(pane:marker,body:body,monospace:code,width:320))
    XCTAssertNil(ComposePaneLayout(pane:marker,body:body,monospace:code,width:320,measurement:.init(maximumContextUnits:64)))
  }
}
