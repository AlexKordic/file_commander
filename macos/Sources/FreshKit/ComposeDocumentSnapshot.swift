import CryptoKit
import Foundation

/// An immutable, verified transport baseline. It is distinct from the current
/// accessibility generation: a newer source may use these old binary bytes as
/// a delta base, but cannot publish their old text or selection as current.
public struct ComposeDocumentBaseline: Sendable {
  public let id: UInt64
  public let owner: WireComposeIndexOwner
  public let data: Data
  public let digest: Data
}

/// Full Fresh metadata accompanies the text/map model for subsequent global
/// style, image, table and measured-flow integration. No Core Text is built.
public struct ComposeDocumentSnapshot: Sendable {
  public let document: ComposeAccessibleDocument
  public let pane: WireComposePane
  public let baseline: ComposeDocumentBaseline
}

extension WireComposeIndexOwner {
  public func isSameDocument(as other: Self) -> Bool {
    window == other.window && leaf == other.leaf && buffer == other.buffer && epoch == other.epoch
      && authority == other.authority && document == other.document
  }
}

/// A complete binary message plus its captured header. Reconstruction, hashes
/// and protobuf/model decoding belong on a worker, never in a scene callback.
public struct ComposeDocumentDecode: Sendable {
  let id: UInt64
  let owner: WireComposeIndexOwner
  let selection, decoration: UInt64
  let header: ComposeDocumentUpdateReceiver.Header
  let bytes: Data
  let base: ComposeDocumentBaseline?
  var prior: ComposeAccessibleDocument?

  func reusing(_ document: ComposeAccessibleDocument?) -> Self { var copy=self;copy.prior=document;return copy }

  public func decode() throws -> ComposeDocumentSnapshot {
    try Task.checkCancellation()
    let body: Data
    if header.encoding == 0 {
      body = bytes
    } else {
      guard let base, base.id == header.baseID, base.digest == header.baseDigest,
            base.owner.isSameDocument(as: owner) else { throw ComposeDocumentReceiver.Failure.invalidProjection }
      body = try BinaryProjectionDelta.apply(bytes, to: base.data, length: header.resultLength)
    }
    try Task.checkCancellation()
    guard body.count == header.resultLength, Data(SHA256.hash(data: body)) == header.resultDigest else {
      throw ComposeDocumentReceiver.Failure.invalidProjection
    }
    var pane = try WireComposePane(serializedBytes: body)
    guard pane.hasDecorationRevision, pane.decorationRevision == decoration,
          pane.selectionRevision == selection, pane.bufferRevision == owner.revision,
          pane.documentLen == owner.length, pane.viewport.epoch == owner.epoch,
          pane.assetAuthority == owner.authority, pane.assetDocument == owner.document else {
      throw ComposeDocumentReceiver.Failure.invalidProjection
    }
    let wire = WirePane.with { $0.leaf = owner.leaf; $0.buffer = owner.buffer; $0.compose = pane }
    let shared = prior?.reusingCoordinates(window:owner.window,pane:wire)
    guard let document = shared ?? ComposeAccessibleDocument(window: owner.window, pane: wire), document.owner == owner else {
      throw ComposeDocumentReceiver.Failure.invalidProjection
    }
    if shared != nil { pane.text = document.text }
    try Task.checkCancellation()
    return .init(document: document, pane: pane,
      baseline: .init(id: id, owner: owner, data: body, digest: header.resultDigest))
  }
}

/// The existing bounded accumulator validates the ordinary stream envelope.
/// This layer additionally binds the binary encoding, baseline and body hash.
public struct ComposeDocumentUpdateReceiver {
  struct Header: Equatable, Sendable {
    let baseID: UInt64
    let resultLength: Int
    let resultDigest, baseDigest: Data
    let encoding: UInt32
  }
  public let id: UInt64
  public let owner: WireComposeIndexOwner
  public let selection: UInt64
  private var receiver: ComposeDocumentReceiver
  private var header: Header?
  private var base: ComposeDocumentBaseline?
  private var failed = false

  public init(id: UInt64, owner: WireComposeIndexOwner, selection: UInt64, base: ComposeDocumentBaseline?) {
    self.id = id; self.owner = owner; self.selection = selection; self.base = base
    receiver = .init(id: id, owner: owner, selection: selection)
  }

  public mutating func receive(_ chunk: WireComposeDocumentChunk) throws -> ComposeDocumentDecode? {
    do {
      guard !failed, chunk.resultLength > 0,
            chunk.resultLength <= UInt64(ComposeDocumentReceiver.maximumEncoded), chunk.resultDigest.count == 32,
            chunk.encoding <= 1 else { throw ComposeDocumentReceiver.Failure.invalidChunk }
      let next = Header(baseID: chunk.baseID, resultLength: Int(chunk.resultLength), resultDigest: chunk.resultDigest,
        baseDigest: chunk.baseDigest, encoding: chunk.encoding)
      if let header { guard header == next else { throw ComposeDocumentReceiver.Failure.invalidChunk } }
      else { header = next }
      if next.encoding == 0 {
        guard next.baseID == 0, next.baseDigest.isEmpty, chunk.resultLength == chunk.length else {
          throw ComposeDocumentReceiver.Failure.invalidChunk
        }
      } else {
        guard let base, base.digest.count == 32, next.baseID != 0, next.baseID == base.id, next.baseDigest == base.digest,
              base.owner.isSameDocument(as: owner) else { throw ComposeDocumentReceiver.Failure.invalidChunk }
      }
      guard let bytes = try receiver.receive(chunk) else { return nil }
      failed = true // A completed stream cannot be appended to or replayed.
      let job = ComposeDocumentDecode(id: id, owner: owner, selection: selection,
        decoration: receiver.decorationRevision!, header: next, bytes: bytes, base: base, prior: nil)
      base = nil
      return job
    } catch { failed = true; base = nil; throw error }
  }
}

/// Strict, bounded decoding of the binary splice protocol, not Markdown.
/// Inspect counts and field types before allocating repeated protobuf objects.
enum BinaryProjectionDelta {
  private struct Cursor {
    let bytes: UnsafeRawBufferPointer
    var at: Int
    let end: Int
    mutating func uint() throws -> UInt64 {
      var value: UInt64 = 0
      for i in 0..<10 {
        guard at < end else { throw ComposeDocumentReceiver.Failure.invalidProjection }
        let b = bytes[at]; at += 1
        guard i != 9 || b <= 1 else { throw ComposeDocumentReceiver.Failure.invalidProjection }
        value |= UInt64(b & 127) << (7*i)
        if b & 128 == 0 {
          guard i == 0 || b != 0 else { throw ComposeDocumentReceiver.Failure.invalidProjection }
          return value
        }
      }
      throw ComposeDocumentReceiver.Failure.invalidProjection
    }
    mutating func range() throws -> Range<Int> {
      guard let count = Int(exactly: try uint()), count <= end-at else { throw ComposeDocumentReceiver.Failure.invalidProjection }
      let start = at; at += count; return start..<at
    }
  }
  private struct Edit { let offset, remove: Int; let insert: Range<Int> }

  static func apply(_ delta: Data, to base: Data, length: Int) throws -> Data {
    guard !delta.isEmpty, delta.count <= ComposeDocumentReceiver.maximumEncoded,
          length > 0, length <= ComposeDocumentReceiver.maximumEncoded,
          base.count <= ComposeDocumentReceiver.maximumEncoded else { throw ComposeDocumentReceiver.Failure.invalidProjection }
    return try delta.withUnsafeBytes { raw in
      var cursor = Cursor(bytes: raw, at: 0, end: raw.count), edits: [Edit] = [], baseLength: UInt64?
      while cursor.at < cursor.end {
        switch try cursor.uint() {
        case 10:
          guard edits.count < 64 else { throw ComposeDocumentReceiver.Failure.invalidProjection }
          let range = try cursor.range()
          var item = Cursor(bytes: raw, at: range.lowerBound, end: range.upperBound)
          var offset: UInt64 = 0, remove: UInt64 = 0, insert = 0..<0, seen: Set<UInt64> = []
          while item.at < item.end {
            let key = try item.uint()
            guard seen.insert(key).inserted else { throw ComposeDocumentReceiver.Failure.invalidProjection }
            switch key {
            case 8: offset = try item.uint()
            case 16: remove = try item.uint()
            case 26: insert = try item.range()
            default: throw ComposeDocumentReceiver.Failure.invalidProjection
            }
          }
          guard offset <= UInt64(base.count), remove <= UInt64(base.count)-offset else {
            throw ComposeDocumentReceiver.Failure.invalidProjection
          }
          edits.append(.init(offset: Int(offset), remove: Int(remove), insert: insert))
        case 16:
          guard baseLength == nil else { throw ComposeDocumentReceiver.Failure.invalidProjection }
          baseLength = try cursor.uint()
        default: throw ComposeDocumentReceiver.Failure.invalidProjection
        }
      }
      guard baseLength == UInt64(base.count) else { throw ComposeDocumentReceiver.Failure.invalidProjection }
      var count = 0, at = 0
      for edit in edits {
        guard edit.offset >= at, edit.offset-at <= ComposeDocumentReceiver.maximumEncoded-count else {
          throw ComposeDocumentReceiver.Failure.invalidProjection
        }
        count += edit.offset-at
        guard edit.insert.count <= ComposeDocumentReceiver.maximumEncoded-count else { throw ComposeDocumentReceiver.Failure.invalidProjection }
        count += edit.insert.count; at = edit.offset+edit.remove
      }
      guard base.count-at <= ComposeDocumentReceiver.maximumEncoded-count else { throw ComposeDocumentReceiver.Failure.invalidProjection }
      count += base.count-at
      guard count == length else { throw ComposeDocumentReceiver.Failure.invalidProjection }
      if edits.isEmpty { return base }
      var result = Data(); result.reserveCapacity(length); at = 0
      try base.withUnsafeBytes { (before: UnsafeRawBufferPointer) in
        for edit in edits {
          try Task.checkCancellation()
          result.append(contentsOf: before.bindMemory(to: UInt8.self)[at..<edit.offset])
          result.append(contentsOf: raw.bindMemory(to: UInt8.self)[edit.insert])
          at = edit.offset+edit.remove
        }
        result.append(contentsOf: before.bindMemory(to: UInt8.self)[at..<before.count])
      }
      return result
    }
  }
}
