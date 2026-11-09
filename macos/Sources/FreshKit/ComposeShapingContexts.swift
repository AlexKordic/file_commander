import Foundation
import CoreText

/// A Core Text line uses indices in its paragraph context. Projection APIs
/// use global UTF-16; this offset is applied everywhere those spaces meet.
public struct ComposeShapedLine {
  public let line: CTLine
  public let origin: Int
  public let context: NSString?
  init(line:CTLine,origin:Int,context:NSString?=nil) {self.line=line;self.origin=origin;self.context=context}
  public func offset(for index: Int) -> CGFloat { CTLineGetOffsetForStringIndex(line,index-origin,nil) }
  public func index(at point: CGPoint) -> Int {
    let value=CTLineGetStringIndexForPosition(line,point)
    return value == kCFNotFound ? value : value+origin
  }
  public func range(of run: CTRun) -> NSRange {
    let range=CTRunGetStringRange(run)
    guard range.location != kCFNotFound else {return NSRange(location:NSNotFound,length:0)}
    return NSRange(location:range.location+origin,length:range.length)
  }
  public func indices(of run: CTRun) -> [Int] {
    var indices=[CFIndex](repeating:0,count:CTRunGetGlyphCount(run))
    CTRunGetStringIndices(run,CFRange(),&indices)
    return indices.map {$0 == kCFNotFound ? $0 : $0+origin}
  }
}

/// Cache one contextual typesetter. Boundaries follow CR/LF and paragraph
/// separators, never a byte/column cutoff inside a bidi paragraph. A long
/// single paragraph retains its complete context unless explicit admission
/// rejects it; it is never simplified, clipped or split into different text.
/// Each request drains its temporary objects while retaining cached shaping
/// state and any returned line beyond that request's autorelease pool.
final class ComposeShapingContexts {
  struct Usage { var contexts=0;var maximumUnits=0 }
  private struct Context {
    let range: Range<Int>
    let typesetter: CTTypesetter
    let wrapping: ComposeWrappingBreaks?
    let string:NSString
  }
  private let text: NSAttributedString
  private let ranges: [Range<Int>]
  private let wrapping: Bool
  private let maximumUnits: Int?
  private var cached: Context?
  private(set) var usage=Usage()

  init(_ text: NSAttributedString, wrapping: Bool = false, targetUnits: Int = 16_384, maximumUnits: Int? = nil) {
    self.text=text;self.wrapping=wrapping;self.maximumUnits=maximumUnits
    let target=max(1,maximumUnits.map {min(targetUnits,$0)} ?? targetUnits)
    var ranges:[Range<Int>]=[],start=0,paragraph=0,units=0,pendingCR=false
    func end(_ at:Int) {
      if at-start > target,paragraph>start {ranges.append(start..<paragraph);start=paragraph}
      paragraph=at
      if at-start >= target {ranges.append(start..<at);start=at}
    }
    // U+2028 is a line separator, not a bidi paragraph boundary. Preserve its
    // surrounding context. Other controls also stay inside these safe groups.
    for scalar in text.string.unicodeScalars {
      if pendingCR && scalar.value != 10 {end(units);pendingCR=false}
      units += scalar.utf16.count
      if scalar.value == 13 {pendingCR=true}
      else if scalar.value == 10 || scalar.value == 0x2029 {end(units);pendingCR=false}
    }
    if paragraph != units {end(units)}
    if start<units {ranges.append(start..<units)}
    self.ranges=ranges
  }

  private init(text:NSAttributedString,ranges:[Range<Int>],wrapping:Bool,maximumUnits:Int?) {
    self.text=text;self.ranges=ranges;self.wrapping=wrapping;self.maximumUnits=maximumUnits
  }

  /// Immutable attributes and safe context ranges, with no retained typesetter
  /// or glyph lines. Every query gets its own bounded contextual cache.
  final class Plan: @unchecked Sendable {
    private let text:NSAttributedString
    private let ranges:[Range<Int>]
    private let wrapping:Bool
    private let maximumUnits:Int?
    fileprivate init(_ source:ComposeShapingContexts) {
      text=source.text.copy() as! NSAttributedString;ranges=source.ranges
      wrapping=source.wrapping;maximumUnits=source.maximumUnits
    }
    func line(_ range:NSRange) -> ComposeShapedLine? {
      ComposeShapingContexts(text:text,ranges:ranges,wrapping:wrapping,maximumUnits:maximumUnits).line(range)
    }
  }
  func plan() -> Plan { Plan(self) }

  private func context(_ request: Range<Int>) -> Context? {
    guard request.lowerBound>=0,request.upperBound<=text.length,!request.isEmpty else {return nil}
    if let cached,cached.range.lowerBound<=request.lowerBound,cached.range.upperBound>=request.upperBound {return cached}
    var low=0,high=ranges.count
    while low<high {let mid=low+(high-low)/2;if ranges[mid].upperBound<=request.lowerBound {low=mid+1}else{high=mid}}
    guard low<ranges.count else {return nil}
    let start=ranges[low].lowerBound
    var last=low
    while last+1<ranges.count && ranges[last].upperBound<request.upperBound {last+=1}
    let range=start..<ranges[last].upperBound
    guard maximumUnits.map({range.count<=$0}) ?? true else {return nil}
    let substring=text.attributedSubstring(from:NSRange(location:range.lowerBound,length:range.count))
    guard let typesetter=ComposeShaping.typesetter(substring) else {return nil}
    let local=NSString(string:substring.string)
    let value=Context(range:range,typesetter:typesetter,
      wrapping:wrapping ? ComposeWrappingBreaks(local) : nil,string:local)
    usage.contexts+=1;usage.maximumUnits=max(usage.maximumUnits,range.count)
    cached=value
    return value
  }

  func suggest(from:Int,width:Double) -> Int? {
    guard from>=0,from<text.length else {return nil}
    return autoreleasepool {
      guard let context=context(from..<(from+1)) else {return nil}
      let local=from-context.range.lowerBound
      return context.wrapping?.suggest(context.typesetter,from:local,width:width)
        ?? CTTypesetterSuggestLineBreak(context.typesetter,local,width)
    }
  }

  func line(_ range:NSRange) -> ComposeShapedLine? {
    guard range.location>=0,range.length>=0,range.location<=text.length,range.length<=text.length-range.location else {return nil}
    if range.length==0 {return .init(line:CTLineCreateWithAttributedString(NSAttributedString(string:"")),origin:range.location)}
    // Keep Core Text's temporary request objects out of the enclosing pane or
    // batch pool. The returned line and its immutable context remain retained.
    return autoreleasepool {
      guard let context=context(range.location..<NSMaxRange(range)) else {return nil}
      return .init(line:CTTypesetterCreateLine(context.typesetter,
        CFRange(location:range.location-context.range.lowerBound,length:range.length)),origin:context.range.lowerBound,context:context.string)
    }
  }
}
