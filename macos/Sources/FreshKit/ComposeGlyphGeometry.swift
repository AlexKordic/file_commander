import Foundation
import CoreText
import CoreGraphics

/// Glyph advances from the same shaped lines used by drawing. Projection
/// UTF-16 ranges stay global even when Core Text used a paragraph substring.
public enum ComposeGlyphGeometry {
  public struct Glyph { public let range:NSRange;public let rect:CGRect }

  public static func glyphs(in fragment:ComposeTextLayout.Fragment,text:NSString) -> [Glyph] {
    var result:[Glyph]=[]
    for run in CTLineGetGlyphRuns(fragment.line) as! [CTRun] {
      let count=CTRunGetGlyphCount(run),indices=fragment.shaped.indices(of:run)
      var positions=[CGPoint](repeating:.zero,count:count),advances=[CGSize](repeating:.zero,count:count)
      CTRunGetPositions(run,CFRange(),&positions);CTRunGetAdvances(run,CFRange(),&advances)
      let source=fragment.shaped.range(of:run)
      guard source.location != NSNotFound,source.location>=0,source.location<=text.length,source.length<=text.length-source.location else {continue}
      let boundaries=Array(Set(indices+[NSMaxRange(source)])).sorted()
      let ends=Dictionary(uniqueKeysWithValues:zip(boundaries,boundaries.dropFirst()))
      for index in 0..<count {
        guard let end=ends[indices[index]],indices[index]>=0,end<=text.length,indices[index]<end else {continue}
        let range:NSRange
        if let context=fragment.shaped.context {
          let local=context.rangeOfComposedCharacterSequences(for:NSRange(location:indices[index]-fragment.indexOrigin,length:end-indices[index]))
          range=NSRange(location:local.location+fragment.indexOrigin,length:local.length)
        } else {range=text.rangeOfComposedCharacterSequences(for:NSRange(location:indices[index],length:end-indices[index]))}
        let a=positions[index].x+fragment.rect.minX,b=a+advances[index].width
        result.append(.init(range:range,rect:CGRect(x:min(a,b),y:fragment.rect.minY,width:max(1,abs(b-a)),height:fragment.rect.height)))
      }
    }
    return result
  }

  public static func bounds(in fragment:ComposeTextLayout.Fragment,text:NSString,for range:NSRange) -> CGRect? {
    guard range.location>=0,range.location<=text.length,range.length>=0,range.length<=text.length-range.location else {return nil}
    let from=max(range.location,fragment.range.location),to=min(NSMaxRange(range),fragment.contentEnd)
    let newline=NSMaxRange(range)>fragment.contentEnd && NSMaxRange(range)>=NSMaxRange(fragment.range)
    var result=CGRect.null
    if from<to || (newline && from<=fragment.contentEnd) {
      let a=fragment.rect.minX+fragment.shaped.offset(for:from)
      let b=newline ? fragment.rect.maxX : fragment.rect.minX+fragment.shaped.offset(for:to)
      result=result.union(CGRect(x:min(a,b),y:fragment.rect.minY,width:max(1,abs(b-a)),height:fragment.rect.height))
    }
    for glyph in glyphs(in:fragment,text:text) where NSIntersectionRange(glyph.range,range).length>0 {result=result.union(glyph.rect)}
    return result.isNull ? nil : result
  }
}
