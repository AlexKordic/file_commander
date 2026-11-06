import XCTest
import SwiftProtobuf
@testable import FreshKit

final class ComposeAcceptanceTests: XCTestCase {
  private func pane(_ text: String, revision: UInt64) -> WirePane {
    .with {
      $0.leaf = 2; $0.buffer = 3
      $0.compose = .with {
        $0.bufferRevision = revision; $0.selectionRevision = revision
        $0.text = text; $0.sourceEnd = UInt64(text.utf8.count); $0.documentLen = $0.sourceEnd
        $0.viewport.epoch = 7
      }
    }
  }

  private func message(_ pane: WirePane? = nil, hello: Bool = false) throws -> SceneMessage {
    let frame = WireFrame.with {
      $0.windowID = 1
      if let pane { $0.paneLen = 1; $0.panes = [.with { $0.index = 0; $0.pane = pane }] }
    }
    let bytes: [UInt8] = hello
      ? try WireServerHello.with { $0.version = SceneWire.version; $0.scene = frame }.serializedBytes()
      : try frame.serializedBytes()
    return try XCTUnwrap(SceneMessage(kind: (hello ? SceneWire.Kind.serverHello : .frame).rawValue, payload: bytes[...]))
  }

  private func receipt(_ pane: WirePane) -> WireComposeEditReceipt {
    .with { $0.window = 1; $0.leaf = 2; $0.buffer = 3; $0.epoch = 7; $0.pane = pane.compose }
  }

  @MainActor
  func testNewServerHelloRetiresAcceptanceEvenWhenEveryNumericOwnerIDIsReused() throws {
    let store = SceneStore()
    try store.apply(message(pane("old", revision: 4), hello: true))
    try store.apply(message(), acceptedCompose: receipt(pane("accepted", revision: 5)))
    XCTAssertEqual(store.panes.first?.compose.text, "accepted")
    XCTAssertEqual(store.composeAcceptances[2]?.revision, 5)
    try store.apply(message(pane("new", revision: 0), hello: true))
    XCTAssertTrue(store.composeAcceptances.isEmpty, "a restarted backend can reuse marker epochs and view/buffer IDs")
    try store.apply(message(), acceptedCompose: receipt(pane("new accepted", revision: 1)))
    XCTAssertEqual(store.panes.first?.compose.text, "new accepted")
    XCTAssertEqual(store.composeAcceptances[2]?.revision, 1, "the old server's higher source revision must not constrain new input")
  }
}
