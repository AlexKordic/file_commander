import XCTest
import FreshKit

final class SceneValidationTests: XCTestCase {
  func testRejectsUnadmittedGridPaneAndCopyCountsBeforePublishingFramesOrHellos() throws {
    let mutations: [(inout WireFrame) -> Void] = [
      { $0.gridLen = UInt32.max }, { $0.paneLen = UInt32.max },
      { $0.copies = [0] }, { $0.copies = [0, 0] },
      { $0.gridLen = UInt32(SceneMessage.maximumGridRows + 1) },
      { $0.paneLen = UInt32(SceneMessage.maximumPanes + 1) },
      { $0.copies = [0, 0, UInt32.max] },
      { $0.copies = [0, 0, UInt32(SceneMessage.maximumGridRows), 0, 0, 1] },
    ]
    for hello in [false, true] {
      for mutate in mutations {
        var frame = WireFrame(); mutate(&frame)
        XCTAssertNil(try decode(frame, hello: hello))
      }
    }
  }

  func testRejectsOversizedUpdateListsWithoutDeclaredCollectionCounts() throws {
    let mutations: [(inout WireFrame) -> Void] = [
      { $0.rows = Array(repeating: .init(), count: SceneMessage.maximumGridRows + 1) },
      { $0.panes = Array(repeating: .init(), count: SceneMessage.maximumPanes + 1) },
      { $0.copies = Array(repeating: [UInt32(0), 0, 0], count: SceneMessage.maximumGridRows + 1).flatMap { $0 } },
    ]
    for hello in [false, true] {
      for mutate in mutations {
        var frame = WireFrame(); mutate(&frame)
        XCTAssertNil(try decode(frame, hello: hello))
      }
    }
  }

  @MainActor
  func testAdmittedCollectionBoundariesRemainCompleteAndCanShrink() throws {
    let frame = WireFrame.with {
      $0.seq = 1; $0.gridLen = UInt32(SceneMessage.maximumGridRows); $0.paneLen = UInt32(SceneMessage.maximumPanes)
      $0.rows = [.with { $0.index = UInt32(SceneMessage.maximumGridRows - 1); $0.text = "last"; $0.runBytes = [4]; $0.runStyles = [0] }]
      $0.panes = [.with { $0.index = UInt32(SceneMessage.maximumPanes - 1); $0.pane.leaf = 7; $0.pane.buffer = 8 }]
    }
    let store = SceneStore(); store.apply(try XCTUnwrap(decode(frame, hello: true)))
    XCTAssertEqual(store.grid.count, SceneMessage.maximumGridRows)
    XCTAssertEqual(store.grid.last?.map(\.text).joined(), "last")
    XCTAssertEqual(store.panes.count, SceneMessage.maximumPanes); XCTAssertEqual(store.panes.last?.leaf, 7)
    store.apply(try XCTUnwrap(decode(.with { $0.seq = 2; $0.gridLen = 0; $0.paneLen = 0 }, hello: false)))
    XCTAssertTrue(store.grid.isEmpty); XCTAssertTrue(store.panes.isEmpty)
  }

  @MainActor
  func testGridCopiesUseExistingRowsAndReadTheOriginalFrame() throws {
    let initial = WireFrame.with {
      $0.gridLen = 3
      $0.rows = ["A", "B", "C"].enumerated().map { index, text in
        .with { $0.index = UInt32(index); $0.text = text; $0.runBytes = [1]; $0.runStyles = [0] }
      }
    }
    let store = SceneStore(); store.apply(try XCTUnwrap(decode(initial, hello: true)))
    let copies = WireFrame.with { $0.copies = [0, 1, UInt32(SceneMessage.maximumGridRows - 1), 2, 0, 1] }
    store.apply(try XCTUnwrap(decode(copies, hello: false)))
    XCTAssertEqual(store.grid.map { $0.map(\.text).joined() }, ["B", "C", "A"])
    let outside = WireFrame.with { $0.copies = [UInt32.max, UInt32.max, 1] }
    store.apply(try XCTUnwrap(decode(outside, hello: false)))
    XCTAssertEqual(store.grid.map { $0.map(\.text).joined() }, ["B", "C", "A"])
  }

  private func decode(_ frame: WireFrame, hello: Bool) throws -> SceneMessage? {
    let bytes: [UInt8]
    let kind: SceneWire.Kind
    if hello {
      kind = .serverHello
      bytes = try WireServerHello.with { $0.version = SceneWire.version; $0.scene = frame }.serializedBytes()
    } else {
      kind = .frame
      bytes = try frame.serializedBytes()
    }
    return SceneMessage(kind: kind.rawValue, payload: bytes[...])
  }

  func testRejectsUnrepresentableSceneCountersBeforePublishingFramesOrHellos() throws {
    for value in [UInt64(Int.max) + 1, UInt64.max] {
      let mutations: [(inout WireFrame) -> Void] = [
        { $0.seq = value }, { $0.windowID = value }, { $0.clipboard.seq = value },
      ]
      for hello in [false, true] {
        for mutate in mutations {
          var frame = WireFrame(); mutate(&frame)
          XCTAssertNil(try decode(frame, hello: hello))
        }
      }
    }
  }

  func testRejectsUnrepresentableTimingCountersBeforePublishingFramesOrHellos() throws {
    for value in [UInt64(Int.max) + 1, UInt64.max] {
      let mutations: [(inout WireTiming) -> Void] = [
        { $0.ack = value }, { $0.queued = value }, { $0.ahead = value },
        { $0.top = value }, { $0.prevAllocs = value }, { $0.prevAllocBytes = value },
      ]
      for hello in [false, true] {
        for mutate in mutations {
          var timing = WireTiming(); mutate(&timing)
          let frame = WireFrame.with { $0.timing = timing }
          XCTAssertNil(try decode(frame, hello: hello))
        }
      }
    }
  }

  @MainActor
  func testLargestRepresentableCountersAndOptionalZeroTimingRemainExact() throws {
    let limit = UInt64(Int.max)
    for hello in [false, true] {
      let frame = WireFrame.with {
        $0.seq = limit; $0.windowID = limit; $0.clipboard.seq = limit
        $0.timing = .with {
          $0.ack = limit; $0.queued = limit; $0.ahead = limit; $0.top = limit
          $0.prevAllocs = limit; $0.prevAllocBytes = limit
        }
      }
      let message = try XCTUnwrap(decode(frame, hello: hello))
      XCTAssertEqual(message.sequence, Int.max)
      let timing = try XCTUnwrap(message.timing)
      XCTAssertEqual([timing.ack, timing.queued, timing.ahead, timing.top], Array(repeating: Int.max, count: 4))
      XCTAssertEqual(timing.prevAllocs, Int.max); XCTAssertEqual(timing.prevAllocBytes, Int.max)
      let store = SceneStore(); store.apply(message)
      XCTAssertEqual(store.windowID, Int.max); XCTAssertEqual(store.clipboard?.sequence, Int.max)
      let absent = try XCTUnwrap(decode(.with { $0.timing = .init() }, hello: hello))
      XCTAssertNil(absent.timing?.prevAllocs); XCTAssertNil(absent.timing?.prevAllocBytes)
      let zero = try XCTUnwrap(decode(.with { $0.timing = .with { $0.prevAllocs = 0; $0.prevAllocBytes = 0 } }, hello: hello))
      XCTAssertEqual(zero.timing?.prevAllocs, 0); XCTAssertEqual(zero.timing?.prevAllocBytes, 0)
    }
  }
}
