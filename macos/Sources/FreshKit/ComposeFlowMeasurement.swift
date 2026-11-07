import Foundation
import CoreText
import CoreGraphics
import CryptoKit

/// Complete measured flow from the renderer's own layout path. Retained lines
/// contain numeric metadata and glyph signatures; Core Text lines are transient.
/// Text ownership and styles share the measured geometry through textIndex.
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
    public let endsInHardBreak:Bool
    public let table:ComposeTextLayout.TablePosition?
    public let glyphBounds:CGRect?
    let signature:Data
  }
  public let document:ComposeAccessibleDocument
  public let presentation:ComposeDocumentPresentation
  public let environment:Environment
  public let lines:[Line]
  public let fonts:[Font]
  public let styles:[Style]
  public let tables:[ComposeTextLayout.Table]
  public let attachments:[ComposeTextLayout.PlacedAttachment]
  public let size:CGSize
  public let usage:ComposeTextLayout.MeasurementUsage
  public let textIndex:ComposeFlowTextIndex
  public let geometryGeneration:UUID
  private let plan:ComposeShapingContexts.Plan
  private let inputDigest:Data
  private let admission:ComposeTextLayout.MeasurementOptions
  private let attachmentIndices:[Range<Int>:Int]

  public func attachment(source:Range<Int>) -> ComposeTextLayout.PlacedAttachment? {
    attachmentIndices[source].map {attachments[$0]}
  }

  func selecting(_ value:ComposeDocumentPresentation) -> Self? {
    guard value.sharesLayout(with:presentation) else {return nil}
    return .init(document:document,presentation:value,environment:environment,lines:lines,fonts:fonts,styles:styles,
      tables:tables,attachments:attachments,size:size,usage:usage,textIndex:textIndex,geometryGeneration:geometryGeneration,
      plan:plan,inputDigest:inputDigest,admission:admission,attachmentIndices:attachmentIndices)
  }

  /// Serialize only layout inputs, with literal protobuf string bytes. Swift
  /// String equality can equate differently encoded marker/table samples.
  /// This temporary encoding is hashed on the worker and is never retained.
  private static func layoutDigest(_ pane:WireComposePane) throws -> Data {
    let inputs=WireComposePane.with {
      $0.sourceStart=pane.sourceStart;$0.sourceEnd=pane.sourceEnd;$0.documentLen=pane.documentLen
      $0.text=pane.text;$0.segments=pane.segments;$0.spans=pane.spans
      $0.images=pane.images;$0.tables=pane.tables;$0.hangingContexts=pane.hangingContexts
    }
    return try autoreleasepool {Data(SHA256.hash(data:try inputs.serializedData()))}
  }

  public static func measure(_ snapshot:ComposeDocumentSnapshot,environment:Environment,overlay:ComposeDocumentOverlay? = nil,
                             options:ComposeTextLayout.MeasurementOptions = .init(),reusing previous:Self?=nil,
                             presentation prepared:ComposeDocumentPresentation?=nil) throws -> Self {
    try Task.checkCancellation()
    let inputDigest=try layoutDigest(snapshot.pane)
    try Task.checkCancellation()
    guard overlay?.owns(snapshot.document) ?? true else {throw Failure.unavailable}
    guard prepared == nil || prepared!.document === snapshot.document && prepared!.overlay?.id == overlay?.id else {throw Failure.unavailable}
    func sameOverlayLayout(_ old:ComposeDocumentOverlay?) -> Bool {
      switch (old,overlay) {
      case (nil,nil): return true
      case (let a?,let b?): return a.hasSameLayout(as:b)
      case (nil,let b?): return b.sourceComposition == nil
      case (let a?,nil): return a.sourceComposition == nil
      }
    }
    if let previous,previous.document.owner.isSameDocument(as:snapshot.document.owner),
       previous.environment.isEquivalent(to:environment),previous.inputDigest==inputDigest,previous.admission==options,
       sameOverlayLayout(previous.presentation.overlay) {
      // Coordinates can survive a caret/selection header update. Ownership
      // cannot: every returned model contains the new complete document.
      let presentation=prepared ?? ComposeDocumentPresentation(snapshot,overlay:overlay,prepared:previous.presentation.plan)
      return .init(document:snapshot.document,presentation:presentation,environment:environment,lines:previous.lines,fonts:previous.fonts,
        styles:previous.styles,tables:previous.tables,attachments:previous.attachments,size:previous.size,
        usage:previous.usage,textIndex:previous.textIndex,geometryGeneration:previous.geometryGeneration,
        plan:previous.plan,inputDigest:inputDigest,admission:options,attachmentIndices:previous.attachmentIndices)
    }
    guard let presentation=prepared ?? ComposeDocumentPresentation(snapshot,overlay:overlay) else {throw Failure.unavailable}
    let text=presentation.text as NSString
    var lines:[Line]=[],fonts:[Font]=[Font(environment.body)],styles:[Style]=[]
    var fontIDs:[Font:Int]=[fonts[0]:0],lastEnd=0
    let images=environment.imageSizes.mapValues {ComposeImageState.deferred(originalSize:$0)}
    let layout=ComposePaneLayout(pane:snapshot.pane,body:environment.body,monospace:environment.monospace,
      width:environment.width,typography:environment.typography,images:images,
      composition:overlay?.composition?.restore(),virtualInsertion:overlay?.insertion?.restore(),measurement:options,record: {fragment in
      guard !Task.isCancelled,fragment.range.location>=lastEnd,
            [fragment.rect.minX,fragment.rect.minY,fragment.rect.width,fragment.rect.height,fragment.baseline].allSatisfy(\.isFinite),
            fragment.rect.width>0,fragment.rect.height>0 else {return false}
      lastEnd=NSMaxRange(fragment.range)
      let context=fragment.shaped.context ?? text
      let end=NSMaxRange(fragment.range)-(fragment.shaped.context == nil ? 0:fragment.indexOrigin)
      let hardBreak=fragment.range.length>0 && [10,11,12,13,0x85,0x2028,0x2029].contains(Int(context.character(at:end-1)))
      lines.append(.init(range:fragment.range,rect:fragment.rect,baseline:fragment.baseline,contentEnd:fragment.contentEnd,
        endsInHardBreak:hardBreak,table:fragment.table,
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
    },prepared:presentation.plan)
    try Task.checkCancellation()
    guard let layout,let plan=layout.text.measurementPlan,layout.text.fragments.isEmpty,
          layout.text.projection.text.utf8.elementsEqual(presentation.text.utf8),
          let textIndex=ComposeFlowTextIndex(projection:layout.text.projection,fragments:lines,styles:styles,attachments:layout.text.attachments) else {throw Failure.unavailable}
    let measured=layout.text.measurementUsage
    let usage=ComposeTextLayout.MeasurementUsage(
      maximumContextUnits:max(measured.maximumContextUnits,layout.maximumAuxiliaryContextUnits),
      contexts:measured.contexts,coordinateEntries:measured.coordinateEntries,fragments:measured.fragments,retainedGlyphs:false)
    var attachmentIndices:[Range<Int>:Int]=[:]
    attachmentIndices.reserveCapacity(layout.text.attachments.count)
    for (index,placed) in layout.text.attachments.enumerated() where attachmentIndices[placed.attachment.source] == nil {
      attachmentIndices[placed.attachment.source]=index
    }
    return .init(document:snapshot.document,presentation:presentation,environment:environment,lines:lines,fonts:fonts,styles:styles,
      tables:layout.text.tables,attachments:layout.text.attachments,size:layout.text.size,usage:usage,textIndex:textIndex,
      geometryGeneration:UUID(),plan:plan,inputDigest:inputDigest,admission:options,attachmentIndices:attachmentIndices)
  }

  /// Exact range bounds use stored whole-line geometry and shape only partial
  /// boundary lines, with their original bounded paragraph context.
  public func bounds(for range:NSRange,affinity:ComposeProjection.Affinity = .downstream) -> CGRect? {
    guard presentation.projection.textIndex.bytes(for:range) != nil else {return nil}
    func caret(_ line:Line,at position:Int) -> CGRect? {
      guard let shaped=plan.line(line.range) else {return nil}
      let position=min(line.contentEnd,max(line.range.location,position))
      return CGRect(x:line.rect.minX+shaped.offset(for:position),y:line.rect.minY,width:1,height:line.rect.height)
    }
    if range.length==0 {
      guard let i=textIndex.line(atUTF16:range.location,affinity:affinity) else {return nil}
      return caret(lines[i],at:range.location)
    }
    var result=CGRect.null
    let text=presentation.text as NSString
    guard let indices=textIndex.lines(intersecting:range) else {return nil}
    for i in indices {
      let line=lines[i]
      if NSIntersectionRange(line.range,range).length>0 {
        if range.location<=line.range.location,NSMaxRange(range)>=NSMaxRange(line.range) {
          if let bounds=line.glyphBounds {result=result.union(bounds)}
        } else {
          guard let shaped=plan.line(line.range) else {return nil}
          let fragment=ComposeTextLayout.Fragment(line:shaped.line,range:line.range,rect:line.rect,baseline:line.baseline,
            contentEnd:line.contentEnd,table:line.table,indexOrigin:shaped.origin,context:shaped.context)
          if let bounds=ComposeGlyphGeometry.bounds(in:fragment,text:text,for:range) {result=result.union(bounds)}
        }
      }
      // Structural tabs/row endings have a text owner but no painted glyph.
      // Their bounds use that fragment's measured edge caret, not a guessed
      // tab width or line/row height. Empty cells retain the same anchor.
      let own=NSIntersectionRange(textIndex.range(forLine:i)!,range)
      if own.length>0 {
        if own.location<line.range.location,let bounds=caret(line,at:line.range.location) {result=result.union(bounds)}
        if NSMaxRange(own)>NSMaxRange(line.range),let bounds=caret(line,at:line.contentEnd) {result=result.union(bounds)}
      }
    }
    for placed in attachments where placed.attachment.preview {
      if let own=presentation.displayedRange(for:placed.attachment.source),NSIntersectionRange(own,range).length>0 {result=result.union(placed.rect)}
    }
    return result.isNull ? nil:result
  }

  /// A drawing crop gets a translation only when actual glyphs, fonts and line
  /// geometry match the complete flow. A guessed prefix height is never used.
  public func correspondence(window:UInt64,pane:WirePane,layout:ComposePaneLayout) -> CGPoint? {
    guard layout.matchesMeasurement(body:environment.body,monospace:environment.monospace,width:environment.width,
            typography:environment.typography,imageSizes:environment.imageSizes),
          let range=presentation.range(window:window,pane:pane,projection:layout.text.projection) else {return nil}
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
