import Foundation
import SwiftProtobuf

/// The scene channel on the wire: protobuf messages (Fresh's `scene.proto`,
/// generated as the `Wire…` types in `Generated/`) in a type-length-value
/// stream over the session's Unix socket:
///
///     message := type:varint  length:varint  payload:length bytes
///
/// Varints are protobuf's: unsigned LEB128, at most ten bytes, minimal.
public enum SceneWire {
  /// What a message is, its type on the wire.
  public enum Kind: UInt64, Sendable {
    case serverHello = 1
    case frame = 2
    case error = 3
    case clientHello = 16
    case key = 17
    case mouse = 18
    case resize = 19
    case paste = 20
    case action = 21
    case widget = 22
    case settingsClick = 23
    case kbEditClick = 24
    case configure = 25
    case applied = 26
    case composeInput = 27
    case composeAsset = 28
    case composeViewport = 29
  }

  /// The protocol version the app speaks; Fresh refuses another.
  public static let version: UInt32 = 1
  /// The longest payload either side accepts.
  public static let maxPayload = 16 << 20

  /// Why bytes off the wire were refused.
  public enum Failure: Error, Equatable, CustomStringConvertible {
    case longVarint
    case notMinimal
    case tooLong(UInt64)

    public var description: String {
      switch self {
      case .longVarint: return "varint longer than ten bytes"
      case .notMinimal: return "varint not minimally encoded"
      case .tooLong(let n): return "payload of \(n) bytes, more than \(SceneWire.maxPayload)"
      }
    }
  }

  public static func appendVarint(_ value: UInt64, to bytes: inout [UInt8]) {
    var v = value
    while v >= 0x80 {
      bytes.append(UInt8(truncatingIfNeeded: v) | 0x80)
      v >>= 7
    }
    bytes.append(UInt8(v))
  }

  /// The varint at `start` and the bytes it took; nil while it hasn't all arrived.
  public static func varint(_ bytes: [UInt8], at start: Int) throws -> (value: UInt64, length: Int)? {
    var value: UInt64 = 0
    var i = 0
    while start + i < bytes.count {
      let b = bytes[start + i]
      // The tenth byte holds the 64th bit and nothing else.
      if i == 9 && b > 1 { throw Failure.longVarint }
      value |= UInt64(b & 0x7F) << (7 * UInt64(i))
      if b & 0x80 == 0 {
        if i > 0 && b == 0 { throw Failure.notMinimal }
        return (value, i + 1)
      }
      i += 1
    }
    return nil
  }

  /// One message: its header and payload.
  public static func message(_ kind: Kind, payload: [UInt8]) -> [UInt8] {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(payload.count + 6)
    appendVarint(kind.rawValue, to: &bytes)
    appendVarint(UInt64(payload.count), to: &bytes)
    bytes.append(contentsOf: payload)
    return bytes
  }

  /// The message starting at `start`: its type, where its payload is, and the
  /// bytes it took; nil while it hasn't all arrived.
  public static func readMessage(_ bytes: [UInt8], at start: Int) throws -> (kind: UInt64, payload: Range<Int>, length: Int)? {
    guard let (kind, a) = try varint(bytes, at: start), let (length, b) = try varint(bytes, at: start + a) else { return nil }
    guard length <= UInt64(maxPayload) else { throw Failure.tooLong(length) }
    let payloadStart = start + a + b
    let end = payloadStart + Int(length)
    guard end <= bytes.count else { return nil }
    return (kind, payloadStart..<end, end - start)
  }
}

/// A message the app sends.
public enum SceneInput: Sendable {
  case hello(telemetry: Bool, richCompose: Bool = false, measuredTables: Bool = false)
  case key(WireKey)
  case mouse(WireMouse)
  case resize(cols: Int, rows: Int)
  case paste(String)
  /// A committed input-method phrase. Rich input inserts it at every caret
  /// without clipboard column-paste distribution.
  case text(String)
  /// An action by name, with the arguments its menu item gave it (JSON, as
  /// Fresh sent them, or empty).
  case action(name: String, argsJson: String)
  case widget(surface: String, key: String?)
  case settingsClick(WireSettingsClick)
  case kbEditClick(row: Int?)
  case configure(telemetry: Bool)
  case applied(seq: UInt64)
  case composeInput(WireComposeInput)
  case composeAsset(WireComposeAssetRequest)
  case composeViewport(WireComposeViewportRequest)

  public var kind: SceneWire.Kind {
    switch self {
    case .hello: return .clientHello
    case .key: return .key
    case .mouse: return .mouse
    case .resize: return .resize
    case .paste, .text: return .paste
    case .action: return .action
    case .widget: return .widget
    case .settingsClick: return .settingsClick
    case .kbEditClick: return .kbEditClick
    case .configure: return .configure
    case .applied: return .applied
    case .composeInput: return .composeInput
    case .composeAsset: return .composeAsset
    case .composeViewport: return .composeViewport
    }
  }

  /// The message's protobuf payload.
  public func payload() -> [UInt8] {
    let message: any SwiftProtobuf.Message
    switch self {
    case .hello(let telemetry, let richCompose, let measuredTables):
      message = WireClientHello.with {
        $0.version = SceneWire.version
        $0.telemetry = telemetry
        $0.richCompose = richCompose
        $0.measuredTables = measuredTables
      }
    case .key(let key): message = key
    case .mouse(let mouse): message = mouse
    case .resize(let cols, let rows):
      message = WireResize.with {
        $0.cols = UInt32(clamping: cols)
        $0.rows = UInt32(clamping: rows)
      }
    case .paste(let text), .text(let text): message = WirePaste.with { $0.text = text }
    case .action(let name, let argsJson):
      message = WireAction.with {
        $0.name = name
        $0.argsJson = argsJson
      }
    case .widget(let surface, let key):
      message = WireWidget.with {
        $0.surface = surface
        if let key { $0.key = key }
      }
    case .settingsClick(let click): message = click
    case .kbEditClick(let row): message = WireKbEditClick.with { if let row { $0.row = UInt64(clamping: row) } }
    case .configure(let telemetry): message = WireConfigure.with { $0.telemetry = telemetry }
    case .applied(let seq): message = WireApplied.with { $0.seq = seq }
    case .composeInput(let input): message = input
    case .composeAsset(let request): message = request
    case .composeViewport(let request): message = request
    }
    // A message built from these types always serializes.
    return (try? message.serializedBytes()) ?? []
  }

  /// The message's type and kind as the editor's telemetry names them.
  public var telemetryName: (type: String, kind: String?) {
    switch self {
    case .hello: return ("hello", nil)
    case .key: return ("key", nil)
    case .mouse(let mouse): return ("mouse", SceneInput.mouseKindName(mouse.kind))
    case .resize: return ("resize", nil)
    case .paste: return ("paste", nil)
    case .text: return ("text", nil)
    case .action: return ("action", nil)
    case .widget: return ("widget", nil)
    case .settingsClick: return ("settings", nil)
    case .kbEditClick: return ("kbedit", nil)
    case .configure: return ("configure", nil)
    case .applied: return ("applied", nil)
    case .composeInput: return ("composeInput", nil)
    case .composeAsset: return ("composeAsset", nil)
    case .composeViewport: return ("composeViewport", nil)
    }
  }

  static func mouseKindName(_ kind: WireMouseKind) -> String {
    switch kind {
    case .down: return "down"
    case .up: return "up"
    case .drag: return "drag"
    case .moved: return "moved"
    case .scrollUp: return "scrollup"
    case .scrollDown: return "scrolldown"
    case .scrollLeft: return "scrollleft"
    case .scrollRight: return "scrollright"
    default: return "unknown"
    }
  }
}
