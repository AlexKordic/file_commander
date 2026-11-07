import Foundation
import CoreText
import CryptoKit

/// Immutable input for retained preview construction. Core Text fonts and
/// decoded image assets are immutable; arbitrary attributed IME values stay on
/// the main actor. Drafts cross the boundary through the existing plain capture.
public struct ComposePreviewRequest: @unchecked Sendable {
  let pane: WireComposePane
  let body, monospace: CTFont
  let width: CGFloat
  let typography: ComposeTypography
  let images: [UInt64: ComposeImageState]
  private let composition: ComposePlainComposition?
  private let insertion: ComposeVirtualInsertion.Plain?
  private let wireDigest, geometryDigest: Data
  private let tableMeasurements: [ComposeTableMeasurements]

  @MainActor
  public init?(pane: WireComposePane, body: CTFont, monospace: CTFont, width: CGFloat,
               typography: ComposeTypography = .init(), images: [UInt64: ComposeImageState] = [:],
               composition: ComposeComposition? = nil, virtualInsertion: ComposeVirtualInsertion? = nil,
               tableMeasurements: [ComposeTableMeasurements] = []) {
    guard width.isFinite, width > 0, typography.isValid else { return nil }
    self.pane = pane; self.body = body; self.monospace = monospace
    self.width = width; self.typography = typography; self.images = images
    self.tableMeasurements = tableMeasurements
    self.composition = composition.map(ComposePlainComposition.init)
    insertion = virtualInsertion.map(ComposeVirtualInsertion.Plain.init)
    // Complete column samples can dominate the pane. Keep their presence in
    // the digests, but compare their full values/literal text independently;
    // do not encode the same large inputs twice on each main-actor capture.
    var identity = pane
    for index in identity.tables.indices where identity.tables[index].hasMeasurement {
      identity.tables[index].measurement = .init()
    }
    guard let wire = try? identity.serializedData() else { return nil }
    wireDigest = Data(SHA256.hash(data: wire))
    let geometry = WireComposePane.with {
      $0.sourceStart = pane.sourceStart; $0.sourceEnd = pane.sourceEnd; $0.documentLen = pane.documentLen
      $0.text = pane.text; $0.segments = pane.segments; $0.spans = pane.spans
      $0.images = pane.images; $0.tables = identity.tables; $0.hangingContexts = pane.hangingContexts
      $0.assetAuthority = pane.assetAuthority; $0.assetDocument = pane.assetDocument
    }
    guard let bytes = try? geometry.serializedData() else { return nil }
    geometryDigest = Data(SHA256.hash(data: bytes))
  }

  private func sameDraft(as other: Self, selection: Bool) -> Bool {
    switch (composition, other.composition) {
    case (nil, nil): break
    case (let a?, let b?): guard a.isEquivalent(to: b, includingSelection: selection) else { return false }
    default: return false
    }
    switch (insertion, other.insertion) {
    case (nil, nil): return true
    case (let a?, let b?): return a.isEquivalent(to: b)
    default: return false
    }
  }

  private func sameEnvironment(as other: Self) -> Bool {
    width == other.width && typography == other.typography
      && CFEqual(body, other.body) && CFEqual(monospace, other.monospace)
  }

  private func sameImages(as other: Self) -> Bool {
    guard images.keys == other.images.keys else { return false }
    return images.allSatisfy { key, a in
      let b = other.images[key]!
      switch (a,b) {
      case (.loading,.loading): return true
      case (.ready(let a),.ready(let b)): return a.id == b.id
      case (.stale(let a,let x),.stale(let b,let y)): return a.id == b.id && x.utf8.elementsEqual(y.utf8)
      case (.failed(let x),.failed(let y)): return x.utf8.elementsEqual(y.utf8)
      case (.deferred(let x),.deferred(let y)): return x == y
      default: return false
      }
    }
  }

  private func sameTableInputs(as other: Self) -> Bool {
    guard pane.tables.count == other.pane.tables.count else { return false }
    return zip(pane.tables, other.pane.tables).allSatisfy { a, b in
      a.hasMeasurement == b.hasMeasurement
        && (!a.hasMeasurement || ComposeTableMeasurement.sameInputs(a.measurement, b.measurement))
    }
  }

  public func isEquivalent(to other: Self) -> Bool {
    // Measurement hints affect only cost, never request identity. The worker
    // validates each hint against this request's complete delivered inputs.
    wireDigest == other.wireDigest && sameEnvironment(as: other)
      && sameDraft(as: other, selection: true) && sameImages(as: other) && sameTableInputs(as: other)
  }

  /// A hint for a main-actor reuse-only constructor, never permission to attach
  /// an old source map to a new pane. That constructor still validates inputs.
  public func hasSameGeometry(as other: Self) -> Bool {
    guard geometryDigest == other.geometryDigest, sameEnvironment(as: other), sameDraft(as: other, selection: false),
          images.keys == other.images.keys, sameTableInputs(as: other) else { return false }
    func intrinsic(_ state: ComposeImageState) -> CGSize? {
      if case .deferred(let size) = state { return size }
      return state.asset?.originalSize
    }
    return images.allSatisfy { key, state in intrinsic(state) == intrinsic(other.images[key]!) }
  }

  public enum Failure: Error { case unavailable }

  /// Construction and all lazy ornaments finish on this worker. No previously
  /// published pane or mutable AppKit value is read or mutated here.
  public func prepare() throws -> ComposePreviewResult {
    try Task.checkCancellation()
    return try autoreleasepool {
      let draft = composition?.restore(), insertion = self.insertion?.restore()
      guard composition == nil || draft != nil, self.insertion == nil || insertion != nil,
            let layout = ComposePaneLayout(pane: pane, body: body, monospace: monospace, width: width,
              typography: typography, images: images, tableMeasurements: tableMeasurements,
              composition: draft, virtualInsertion: insertion,
              record: { _ in !Task.isCancelled }) else { throw Failure.unavailable }
      try Task.checkCancellation()
      _ = layout.codeFrames; _ = layout.quoteRails; _ = layout.thematicRules
      try Task.checkCancellation()
      return ComposePreviewResult(request: self, layout: layout)
    }
  }
}

/// One-way handoff: the worker stops accessing the fully prepared layout before
/// the main actor can obtain it. Later reuse/drawing stays on that actor.
public final class ComposePreviewResult: @unchecked Sendable {
  private let request: ComposePreviewRequest
  private let layout: ComposePaneLayout
  fileprivate init(request: ComposePreviewRequest, layout: ComposePaneLayout) {
    self.request = request; self.layout = layout
  }
  @MainActor
  public func layout(matching request: ComposePreviewRequest) -> ComposePaneLayout? {
    self.request.isEquivalent(to: request) ? layout : nil
  }
}
