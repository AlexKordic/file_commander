import Foundation
import CoreText
import CryptoKit

/// A correspondence proof over actual shaped runs, not estimated widths.
/// Normalize only index origin and signed zero; no coordinate rounding occurs.
enum ComposeGlyphSignature {
  static func digest(_ fragment:ComposeTextLayout.Fragment,offset:Int=0) -> Data {
    var bytes=Data()
    func uint(_ value:UInt64) {var v=value.littleEndian;withUnsafeBytes(of:&v) {bytes.append(contentsOf:$0)}}
    func index(_ value:Int) {uint(UInt64(bitPattern:Int64(value)))}
    func number(_ value:CGFloat) {uint(Double(value==0 ? 0:value).bitPattern)}
    func string(_ value:String) {let value=Data(value.utf8);uint(UInt64(value.count));bytes.append(value)}
    for run in CTLineGetGlyphRuns(fragment.line) as! [CTRun] {
      let count=CTRunGetGlyphCount(run),range=fragment.shaped.range(of:run),indices=fragment.shaped.indices(of:run)
      index(range.location == NSNotFound ? -1:range.location+offset);index(range.length);index(count)
      let attributes=CTRunGetAttributes(run) as NSDictionary
      let font=attributes[kCTFontAttributeName] as! CTFont
      string(CTFontCopyPostScriptName(font) as String);string(CTFontCopyFamilyName(font) as String)
      number(CTFontGetSize(font));uint(UInt64(CTFontGetSymbolicTraits(font).rawValue))
      let matrix=CTFontGetMatrix(font)
      for value in [matrix.a,matrix.b,matrix.c,matrix.d,matrix.tx,matrix.ty] {number(value)}
      if let variation=CTFontCopyVariation(font) as? [NSNumber:NSNumber] {
        let axes=variation.keys.sorted {$0.uint64Value<$1.uint64Value};index(axes.count)
        for axis in axes {uint(axis.uint64Value);number(CGFloat(variation[axis]!.doubleValue))}
      } else {index(0)}
      uint(UInt64((attributes[ComposeTextLayout.roleKey] as? UInt32) ?? 0))
      uint(UInt64((attributes[ComposeTextLayout.flagsKey] as? UInt32) ?? 0))
      var glyphs=[CGGlyph](repeating:0,count:count),positions=[CGPoint](repeating:.zero,count:count),advances=[CGSize](repeating:.zero,count:count)
      CTRunGetGlyphs(run,CFRange(),&glyphs);CTRunGetPositions(run,CFRange(),&positions);CTRunGetAdvances(run,CFRange(),&advances)
      for i in 0..<count {
        index(indices[i] == kCFNotFound ? -1:indices[i]+offset);uint(UInt64(glyphs[i]))
        number(positions[i].x);number(positions[i].y);number(advances[i].width);number(advances[i].height)
      }
    }
    return Data(SHA256.hash(data:bytes))
  }
}
