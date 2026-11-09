import XCTest
import CoreText
@testable import FreshKit

final class ComposeShapingContextTests: XCTestCase {
  private let font=CTFontCreateWithName("Helvetica" as CFString,16,nil)
  private func attributes(_ value:String) -> NSAttributedString {
    NSAttributedString(string:value,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,
      NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String):true])
  }

  func testParagraphWindowsHaveTheExactFullTypesetterGlyphsBreaksAndGlobalIndices() throws {
    let unit="Latin café 👩🏽‍💻 e\u{301}.\r\nאבג 123 العربية!\n東京、漢字。\u{2029}123 \u{2028}אבג suffix\r\u{2067}abc 456\u{2069} END.\n"
    let source=String(repeating:unit,count:550),string=NSString(string:source),value=attributes(source)
    XCTAssertGreaterThan(string.length,32_768)
    let full=try XCTUnwrap(ComposeShaping.typesetter(value))
    for width:CGFloat in [95,420] {
      let projection=try XCTUnwrap(ComposeProjection(source:0..<source.utf8.count,text:source,
        segments:[.init(source:0..<source.utf8.count,display:0..<source.utf8.count,kind:.copy)]))
      let result=try XCTUnwrap(ComposeTextLayout(projection:projection,font:font,width:width))
      XCTAssertTrue(result.fragments.contains(where:{$0.indexOrigin>0}))
      var from=0
      for fragment in result.fragments where fragment.range.length>0 {
        let suggestion=CTTypesetterSuggestLineBreak(full,from,Double(width))
        var count=suggestion>0 ? suggestion:string.rangeOfComposedCharacterSequence(at:from).length
        if from+count<string.length {
          let cluster=string.rangeOfComposedCharacterSequence(at:from+count)
          if cluster.location<from+count {count=NSMaxRange(cluster)-from}
        }
        XCTAssertEqual(fragment.range,NSRange(location:from,length:count))
        let reference=ComposeTextLayout.Fragment(line:CTTypesetterCreateLine(full,CFRange(location:from,length:count)),
          range:fragment.range,rect:fragment.rect,baseline:fragment.baseline,contentEnd:fragment.contentEnd,table:nil)
        XCTAssertEqual(ComposeGlyphSignature.digest(fragment),ComposeGlyphSignature.digest(reference))
        from+=count
      }
      XCTAssertEqual(from,string.length)
      XCTAssertLessThanOrEqual(result.measurementUsage.maximumContextUnits,16_384)
    }
  }

  func testLineSeparatorsDoNotCutBidiParagraphContextAndLongContextIsNeverTruncated() throws {
    let source="12345678 \u{2028}אבג العربية trailing context and 👩🏽‍💻.\n"
    let value=attributes(source),full=try XCTUnwrap(ComposeShaping.typesetter(value))
    let context=ComposeShapingContexts(value,targetUnits:8,maximumUnits:128)
    for from in [0,9,12] {
      let range=NSRange(location:from,length:3)
      let line=try XCTUnwrap(context.line(range))
      XCTAssertEqual(line.origin,0)
      let reference=ComposeTextLayout.Fragment(line:CTTypesetterCreateLine(full,CFRange(location:from,length:3)),range:range,
        rect:.zero,baseline:0,contentEnd:from+3,table:nil)
      let actual=ComposeTextLayout.Fragment(line:line.line,range:range,rect:.zero,baseline:0,contentEnd:from+3,table:nil,
        indexOrigin:line.origin,context:line.context)
      XCTAssertEqual(ComposeGlyphSignature.digest(actual),ComposeGlyphSignature.digest(reference))
    }
    XCTAssertEqual(context.usage.maximumUnits,value.length)
    let denied=ComposeShapingContexts(value,targetUnits:8,maximumUnits:16)
    XCTAssertNil(denied.line(NSRange(location:0,length:1)))
    XCTAssertNil(denied.suggest(from:Int.max,width:50));XCTAssertEqual(denied.usage.contexts,0)
    let long=attributes(String(repeating:"👩🏽‍💻 ",count:2000))
    let allowed=ComposeShapingContexts(long)
    XCTAssertNotNil(allowed.line(NSRange(location:0,length:long.length)))
    XCTAssertEqual(allowed.usage.maximumUnits,long.length)
  }

  func testAnImmutablePlanCanShapeNonzeroGlobalRangesAfterItsConstructionCacheIsGone() throws {
    let text=attributes(String(repeating:"Latin café 👩🏽‍💻 אבג\r\n",count:3000))
    let contexts=ComposeShapingContexts(text,targetUnits:128,maximumUnits:256),plan=contexts.plan()
    let range=NSRange(location:40_000,length:8)
    let before=try XCTUnwrap(contexts.line(range)),after=try XCTUnwrap(plan.line(range))
    XCTAssertEqual(before.origin,after.origin);XCTAssertGreaterThan(after.origin,0)
    let make: (ComposeShapedLine)->ComposeTextLayout.Fragment = {.init(line:$0.line,range:range,rect:.zero,baseline:0,contentEnd:NSMaxRange(range),
      table:nil,indexOrigin:$0.origin,context:$0.context)}
    XCTAssertEqual(ComposeGlyphSignature.digest(make(before)),ComposeGlyphSignature.digest(make(after)))
    for index in range.location...NSMaxRange(range) {XCTAssertEqual(before.offset(for:index),after.offset(for:index),accuracy:0.0001)}
  }
}
