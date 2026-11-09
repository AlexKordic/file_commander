import Foundation

/// One complete binary projection, independently acknowledged from frames.
/// A prefix is never decoded or exposed as a document. Decode/model validation
/// belongs off the scene/UI thread after the complete payload has arrived.
public struct ComposeDocumentReceiver {
  public static let maximumSource = 16 << 20
  public static let maximumEncoded = 32 << 20
  public static let maximumChunk = 64 << 10
  public enum Failure: Error { case invalidChunk, invalidProjection }
  public let id: UInt64
  public let owner: WireComposeIndexOwner
  public let selection: UInt64
  private var nextSequence: UInt64 = 0
  private var declaredLength: Int?
  public private(set) var decorationRevision: UInt64?
  private var data = Data()
  private var finished = false

  public init(id: UInt64, owner: WireComposeIndexOwner, selection: UInt64) {
    self.id = id; self.owner = owner; self.selection = selection
  }

  public mutating func receive(_ chunk: WireComposeDocumentChunk) throws -> Data? {
    do { return try accept(chunk) }
    catch { data = Data(); finished = true; throw error }
  }

  private mutating func accept(_ chunk: WireComposeDocumentChunk) throws -> Data? {
    guard !finished, id != 0, chunk.id == id, chunk.hasOwner, chunk.owner == owner,
          owner.epoch != 0, owner.length <= UInt64(Self.maximumSource),
          chunk.selection == selection, chunk.sequence == nextSequence, chunk.error.isEmpty,
          chunk.length > 0, chunk.length <= UInt64(Self.maximumEncoded),
          !chunk.data.isEmpty, chunk.data.count <= Self.maximumChunk else { throw Failure.invalidChunk }
    let length = Int(chunk.length)
    if let declaredLength {
      guard declaredLength == length, decorationRevision == chunk.decorationRevision else { throw Failure.invalidChunk }
    } else {
      declaredLength = length
      decorationRevision = chunk.decorationRevision
      data.reserveCapacity(length)
    }
    guard data.count <= length, chunk.data.count <= length - data.count else { throw Failure.invalidChunk }
    data.append(chunk.data)
    guard chunk.done == (data.count == length) else { throw Failure.invalidChunk }
    if chunk.done {
      finished = true
      let result = data; data = Data()
      return result
    }
    nextSequence += 1
    return nil
  }

  /// The complete body and its header must prove the same source ownership.
  /// This does not measure the document or move the editor's viewport.
  public static func decode(_ data: Data, owner: WireComposeIndexOwner, selection: UInt64, decoration: UInt64) throws -> ComposeAccessibleDocument {
    guard !data.isEmpty, data.count <= maximumEncoded, owner.epoch != 0,
          owner.length <= UInt64(maximumSource) else { throw Failure.invalidProjection }
    let compose = try WireComposePane(serializedBytes: data)
    guard compose.hasDecorationRevision, compose.decorationRevision == decoration,
          compose.selectionRevision == selection, compose.bufferRevision == owner.revision,
          compose.documentLen == owner.length, compose.viewport.epoch == owner.epoch,
          compose.assetAuthority == owner.authority, compose.assetDocument == owner.document else { throw Failure.invalidProjection }
    let pane = WirePane.with { $0.leaf = owner.leaf; $0.buffer = owner.buffer; $0.compose = compose }
    guard let document = ComposeAccessibleDocument(window: owner.window, pane: pane), document.owner == owner else { throw Failure.invalidProjection }
    return document
  }
}
