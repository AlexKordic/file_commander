import Foundation
import CoreText
import CoreGraphics

/// Complete measured flow from the renderer's own layout path. Retained lines
/// contain numeric metadata and glyph signatures; Core Text lines are transient.
/// This is a geometry primitive, not yet the public accessibility line policy.
public struct ComposeFlowMeasurement: Sendable {
  public enum Failure: Error {case unavailable}

  /// Fonts are immutable Core Text values. Pixels are never retained: only
  /// intrinsic image dimensions are copied from the current presentation.
  public struct Environment: @unchecked Sendable {
    let body,monospace:CTFont
    public let width:CGFloat
    public let typography:ComposeTypography
    let imageSizes:[UInt64:CGSize]
    public init(body:CTFont,monospace:CTFont,width:CGFloat,typography:ComposeTypography = .init(),images:[UInt64:ComposeImageState]=[:]) {
      self.body=body;self.monospace=monospace;self.width=width;self.typography=typography
      imageSizes=images.compactMapValues {state in
        if case .deferred(let size)=state {return size}
        return state.asset?.originalSize
      }
    }
    public func isEquivalent(to other:Self) -> Bool {
      width==other.width && typography==other.typography && imageSizes==other.imageSizes
        && CFEqual(body,other.body) && CFEqual(monospace,other.monospace)
    }
  }
  public struct Font: Hashable,Sendable {
    public let name,family:String
    public let size:CGFloat
    public let traits:UInt32
    init(_ font:CTFont) {
      name=CTFontCopyPostScriptName(font) as String;family=CTFontCopyFamilyName(font) as String
      size=CTFontGetSize(font);traits=CTFontGetSymbolicTraits(font).rawValue
    }
  }
  public struct Style: Sendable {
    public let range:NSRange
    public let font:Int
    public let role,flags:UInt32
  }
  public struct Line: Sendable {
    public let range:NSRange
    public let rect:CGRect
    public let baseline:CGFloat
    public let contentEnd:Int
    public let table:ComposeTextLayout.TablePosition?
    public let glyphBounds:CGRect?
    let signature:Data
  }
  public let document:ComposeAccessibleDocument
  public let environment:Environment
  public let lines:[Line]
  public let fonts:[Font]
  public let styles:[Style]
  public let tables:[ComposeTextLayout.Table]
  public let attachments:[ComposeTextLayout.PlacedAttachment]
  public let size:CGSize
  public let usage:ComposeTextLayout.MeasurementUsage
  private let plan:ComposeShapingContexts.Plan

  public static func measure(_ snapshot:ComposeDocumentSnapshot,environment:Environment,
                             options:ComposeTextLayout.MeasurementOptions = .init()) throws -> Self {
    try Task.checkCancellation()
    let text=snapshot.document.text as NSString
    var lines:[Line]=[],fonts:[Font]=[Font(environment.body)],styles:[Style]=[]
    var fontIDs:[Font:Int]=[fonts[0]:0],lastEnd=0
    let images=environment.imageSizes.mapValues {ComposeImageState.deferred(originalSize:$0)}
    let layout=ComposePaneLayout(pane:snapshot.pane,body:environment.body,monospace:environment.monospace,
      width:environment.width,typography:environment.typography,images:images,measurement:options) {fragment in
      guard !Task.isCancelled,fragment.range.location>=lastEnd,
            [fragment.rect.minX,fragment.rect.minY,fragment.rect.width,fragment.rect.height,fragment.baseline].allSatisfy(\.isFinite),
            fragment.rect.width>0,fragment.rect.height>0 else {return false}
      lastEnd=NSMaxRange(fragment.range)
      lines.append(.init(range:fragment.range,rect:fragment.rect,baseline:fragment.baseline,contentEnd:fragment.contentEnd,table:fragment.table,
        glyphBounds:ComposeGlyphGeometry.bounds(in:fragment,text:text,for:fragment.range),signature:ComposeGlyphSignature.digest(fragment)))
      for run in CTLineGetGlyphRuns(fragment.line) as! [CTRun] {
        guard styles.count<options.maximumFragments else {return false}
        let attributes=CTRunGetAttributes(run) as NSDictionary,font=Font(attributes[kCTFontAttributeName] as! CTFont)
        guard font.size.isFinite,font.size>0 else {return false}
        let id:Int
        if let known=fontIDs[font] {id=known} else {
          guard fonts.count<1024 else {return false};id=fonts.count;fontIDs[font]=id;fonts.append(font)
        }
        let range=fragment.shaped.range(of:run)
        guard range.location != NSNotFound,range.location>=0,NSMaxRange(range)<=text.length else {return false}
        styles.append(.init(range:range,font:id,role:(attributes[ComposeTextLayout.roleKey] as? UInt32) ?? 0,
          flags:(attributes[ComposeTextLayout.flagsKey] as? UInt32) ?? 0))
      }
      return true
    }
    try Task.checkCancellation()
    guard let layout,let plan=layout.text.measurementPlan,layout.text.fragments.isEmpty,
          layout.text.projection.text.utf8.elementsEqual(snapshot.document.text.utf8) else {throw Failure.unavailable}
    let measured=layout.text.measurementUsage
    let usage=ComposeTextLayout.MeasurementUsage(
      maximumContextUnits:max(measured.maximumContextUnits,layout.maximumAuxiliaryContextUnits),
      contexts:measured.contexts,coordinateEntries:measured.coordinateEntries,fragments:measured.fragments,retainedGlyphs:false)
    return .init(document:snapshot.document,environment:environment,lines:lines,fonts:fonts,styles:styles,
      tables:layout.text.tables,attachments:layout.text.attachments,size:layout.text.size,usage:usage,plan:plan)
  }

  /// Exact range bounds use stored whole-line geometry and shape only partial
  /// boundary lines, with their original bounded paragraph context.
  public func bounds(for range:NSRange,affinity:ComposeProjection.Affinity = .downstream) -> CGRect? {
    guard document.projection.textIndex.bytes(for:range) != nil else {return nil}
    if range.length==0 {
      var position=range.location
      var candidates=lines.indices.filter {position>=lines[$0].range.location && position<=lines[$0].contentEnd}
      if candidates.isEmpty,let ending=lines.firstIndex(where:{position > $0.contentEnd && position<NSMaxRange($0.range)}) {
        position=lines[ending].contentEnd;candidates=[ending]
      }
      guard let i=affinity == .upstream ? candidates.first:candidates.last,let shaped=plan.line(lines[i].range) else {return nil}
      return CGRect(x:lines[i].rect.minX+shaped.offset(for:position),y:lines[i].rect.minY,width:1,height:lines[i].rect.height)
    }
    var result=CGRect.null
    let text=document.text as NSString
    for line in lines where NSIntersectionRange(line.range,range).length>0 {
      if range.location<=line.range.location,NSMaxRange(range)>=NSMaxRange(line.range) {
        if let bounds=line.glyphBounds {result=result.union(bounds)}
      } else {
        guard let shaped=plan.line(line.range) else {return nil}
        let fragment=ComposeTextLayout.Fragment(line:shaped.line,range:line.range,rect:line.rect,baseline:line.baseline,
          contentEnd:line.contentEnd,table:line.table,indexOrigin:shaped.origin,context:shaped.context)
        if let bounds=ComposeGlyphGeometry.bounds(in:fragment,text:text,for:range) {result=result.union(bounds)}
      }
    }
    for placed in attachments where placed.attachment.preview {
      if let own=document.displayedRange(for:placed.attachment.source),NSIntersectionRange(own,range).length>0 {result=result.union(placed.rect)}
    }
    return result.isNull ? nil:result
  }

  /// A drawing crop gets a translation only when actual glyphs, fonts and line
  /// geometry match the complete flow. A guessed prefix height is never used.
  public func correspondence(window:UInt64,pane:WirePane,layout:ComposePaneLayout) -> CGPoint? {
    guard layout.composition==nil,layout.virtualInsertion==nil,
          layout.matchesMeasurement(body:environment.body,monospace:environment.monospace,width:environment.width,
            typography:environment.typography,imageSizes:environment.imageSizes),
          let range=document.range(of:window,pane:pane) else {return nil}
    var translation:CGPoint?
    for fragment in layout.text.fragments {
      if fragment.range.length==0,fragment.table==nil,fragment.range.location==layout.text.projection.textIndex.utf16Count,
         pane.compose.sourceEnd<document.owner.length {continue}
      let global=NSRange(location:fragment.range.location+range.location,length:fragment.range.length)
      var low=0,high=lines.count
      while low<high {let mid=low+(high-low)/2;if lines[mid].range.location<global.location {low=mid+1}else{high=mid}}
      var found:Line?
      while low<lines.count,lines[low].range.location==global.location {
        if lines[low].range==global && lines[low].table==fragment.table {found=lines[low];break};low+=1
      }
      guard let line=found,
            line.signature==ComposeGlyphSignature.digest(fragment,offset:range.location),
            abs(line.rect.width-fragment.rect.width)<0.0001,abs(line.rect.height-fragment.rect.height)<0.0001,
            abs((line.baseline-line.rect.minY)-(fragment.baseline-fragment.rect.minY))<0.0001 else {return nil}
      let offset=CGPoint(x:fragment.rect.minX-line.rect.minX,y:fragment.rect.minY-line.rect.minY)
      if let translation {guard abs(translation.x-offset.x)<0.0001,abs(translation.y-offset.y)<0.0001 else {return nil}}
      else {translation=offset}
    }
    return translation
  }
}
