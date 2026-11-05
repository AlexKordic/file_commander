import XCTest
@testable import FreshKit

final class SceneWireTests: XCTestCase {
  private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

  func testVarintsRoundTripAndBadOnesAreRefused() throws {
    for value: UInt64 in [0, 1, 127, 128, 300, 16_383, 16_384, UInt64(UInt32.max), .max] {
      var bytes: [UInt8] = []
      SceneWire.appendVarint(value, to: &bytes)
      let read = try XCTUnwrap(try SceneWire.varint(bytes, at: 0))
      XCTAssertEqual(read.value, value)
      XCTAssertEqual(read.length, bytes.count)
      for n in 0..<bytes.count {
        XCTAssertNil(try SceneWire.varint(Array(bytes.prefix(n)), at: 0), "\(value) cut at \(n) is incomplete, not wrong")
      }
    }
    XCTAssertThrowsError(try SceneWire.varint([0x80, 0x00], at: 0)) { XCTAssertEqual($0 as? SceneWire.Failure, .notMinimal) }
    XCTAssertThrowsError(try SceneWire.varint([UInt8](repeating: 0xFF, count: 10), at: 0)) {
      XCTAssertEqual($0 as? SceneWire.Failure, .longVarint)
    }
  }

  func testMessagesAreFramedByTypeAndLength() throws {
    let stream = SceneWire.message(.frame, payload: Array("abc".utf8)) + SceneWire.message(.applied, payload: [])
    let first = try XCTUnwrap(try SceneWire.readMessage(stream, at: 0))
    XCTAssertEqual(first.kind, SceneWire.Kind.frame.rawValue)
    XCTAssertEqual(Array(stream[first.payload]), Array("abc".utf8))
    let second = try XCTUnwrap(try SceneWire.readMessage(stream, at: first.length))
    XCTAssertEqual(second.kind, SceneWire.Kind.applied.rawValue)
    XCTAssertEqual(second.payload.count, 0)
    XCTAssertNil(try SceneWire.readMessage(Array(stream.prefix(4)), at: 0), "a payload still arriving")
    var huge: [UInt8] = []
    SceneWire.appendVarint(2, to: &huge)
    SceneWire.appendVarint(UInt64(SceneWire.maxPayload + 1), to: &huge)
    XCTAssertThrowsError(try SceneWire.readMessage(huge, at: 0))
  }

  /// The app's messages, byte for byte as protoc encodes them from scene.proto
  /// (`protoc --encode=fresh.scene.v1.<Message>`), so the generated types and
  /// the schema Fresh decodes agree on every field number.
  func testMessagesMatchTheSchema() {
    XCTAssertEqual(hex(SceneInput.hello(telemetry: true).payload()), "08011001")
    XCTAssertEqual(hex(SceneInput.hello(telemetry: false, richCompose: true).payload()), "08011801")
    XCTAssertEqual(hex(SceneInput.key(WireKey.with { $0.key = "x"; $0.ctrl = true; $0.shift = true }).payload()), "0a017818013001")
    let wheel = WireMouse.with { $0.kind = .scrollDown; $0.col = 10; $0.row = 5; $0.n = 1 }
    XCTAssertEqual(hex(SceneInput.mouse(wheel).payload()), "0806180a20052801")
    XCTAssertEqual(hex(SceneInput.resize(cols: 200, rows: 61).payload()), "08c801103d")
    XCTAssertEqual(hex(SceneInput.action(name: "menu_open", argsJson: #"{"name":"File"}"#).payload()),
                   "0a096d656e755f6f70656e120f7b226e616d65223a2246696c65227d")
    XCTAssertEqual(hex(SceneInput.applied(seq: 300).payload()), "08ac02")
    XCTAssertEqual(SceneInput.mouse(wheel).telemetryName.kind, "scrolldown")
  }
}

final class SceneTests: XCTestCase {
  /// A run's style as Fresh packs it: fg | bg << 25 | flags << 50, a color
  /// 0x1RRGGBB (0 for the default), flags bold 1, italic 2, underline 4, reverse 8.
  private func style(fg: UInt64? = nil, bg: UInt64? = nil, flags: UInt64 = 0) -> UInt64 {
    (fg.map { 1 << 24 | $0 } ?? 0) | (bg.map { 1 << 24 | $0 } ?? 0) << 25 | flags << 50
  }

  private func row(_ index: Int, _ runs: [(String, UInt64)]) -> WireGridRow {
    WireGridRow.with {
      $0.index = UInt32(index)
      $0.text = runs.map(\.0).joined()
      $0.runBytes = runs.map { UInt32($0.0.utf8.count) }
      $0.runStyles = runs.map(\.1)
    }
  }

  private func rows(_ texts: [String]) -> [WireGridRow] {
    texts.enumerated().map { row($0.offset, [($0.element, 0)]) }
  }

  private func hello(_ build: (inout WireFrame) -> Void) throws -> SceneMessage {
    let bytes: [UInt8] = try WireServerHello.with {
      $0.version = SceneWire.version
      $0.scene = WireFrame.with(build)
    }.serializedBytes()
    return try XCTUnwrap(SceneMessage(kind: SceneWire.Kind.serverHello.rawValue, payload: bytes[...]))
  }

  private func frame(_ build: (inout WireFrame) -> Void) throws -> SceneMessage {
    let bytes: [UInt8] = try WireFrame.with(build).serializedBytes()
    return try XCTUnwrap(SceneMessage(kind: SceneWire.Kind.frame.rawValue, payload: bytes[...]))
  }

  func testHelloFillsTheStore() throws {
    let message = try hello {
      $0.width = 4
      $0.height = 2
      $0.windowID = 1
      $0.theme = WireTheme.with { $0.name = "dark"; $0.bg = 0x1e1e1e; $0.fg = 0xd4d4d4; $0.accent = 0xff0000 }
      $0.gridLen = 2
      $0.rows = [row(0, [("ab", style(fg: 0xffffff, flags: 1)), ("cd", 0)]), row(1, [("ef  ", 0)])]
      $0.paneLen = 1
      $0.panes = [WirePaneUpdate.with {
        $0.pane.tabBar.tabs = [WireTabView.with { $0.label = "a.txt"; $0.active = true }]
      }]
      $0.cursor = WireCursor.with { $0.x = 1 }
      $0.statusBar.value.rect = WireRect.with { $0.y = 1; $0.w = 4; $0.h = 1 }
    }
    let store = MainActor.assumeIsolated { SceneStore() }
    MainActor.assumeIsolated {
      var seen: SceneChange?
      store.onChange = { seen = $0 }
      store.apply(message)
      XCTAssertEqual(store.width, 4)
      XCTAssertEqual(store.height, 2)
      XCTAssertEqual(store.lines, ["abcd", "ef  "])
      XCTAssertEqual(store.grid[0][0], CellRun(text: "ab", foreground: SceneColor(red: 255, green: 255, blue: 255), bold: true))
      XCTAssertEqual(store.cursor?.column, 1)
      XCTAssertEqual(store.theme.background, SceneColor(red: 0x1e, green: 0x1e, blue: 0x1e))
      XCTAssertNil(store.theme.muted, "a color left out is the default")
      XCTAssertTrue(store.theme.isDark)
      XCTAssertEqual(store.panes.first?.tabBar.tabs.first?.label, "a.txt")
      XCTAssertEqual(store.statusBar.map { CellRect($0.rect) }, CellRect(x: 0, y: 1, width: 4, height: 1))
      XCTAssertEqual(seen?.isHello, true)
    }
  }

  func testFramesReplaceRowsAndRegions() throws {
    let store = MainActor.assumeIsolated { SceneStore() }
    let first = try hello {
      $0.width = 3
      $0.height = 3
      $0.gridLen = 3
      $0.rows = rows(["aaa", "bbb", "ccc"])
      $0.cursor = WireCursor()
      $0.statusBar.value.rect = WireRect.with { $0.w = 3; $0.h = 1 }
    }
    let typed = try frame {
      $0.seq = 1
      $0.rows = [row(1, [("xyz", 0)])]
      $0.cursor = WireCursor.with { $0.x = 2; $0.y = 1 }
    }
    let shrunk = try frame {
      $0.seq = 2
      $0.height = 2
      $0.gridLen = 2
      $0.paneLen = 1
      $0.panes = [WirePaneUpdate.with { $0.pane.leaf = 3 }]
      $0.statusBar = WireStatusBarUpdate()
    }
    MainActor.assumeIsolated {
      store.apply(first)
      var seen = SceneChange()
      store.onChange = { seen = $0 }
      store.apply(typed)
      XCTAssertEqual(store.lines, ["aaa", "xyz", "ccc"])
      XCTAssertEqual(seen.rows, IndexSet([0, 1]), "the changed row and both cursor rows redraw")
      XCTAssertTrue(seen.cursorChanged)
      XCTAssertNotNil(store.statusBar, "a region left out of a frame stays")
      store.apply(shrunk)
      XCTAssertEqual(store.grid.count, 2)
      XCTAssertEqual(store.height, 2)
      XCTAssertEqual(store.panes.first?.leaf, 3)
      XCTAssertNil(store.statusBar, "a region's update without a value: it's gone")
      XCTAssertTrue(seen.regions.isSuperset(of: ["panes", "statusbar"]))
    }
  }

  func testCopiedRowsComeFromThePreviousFrame() throws {
    let store = MainActor.assumeIsolated { SceneStore() }
    let first = try hello {
      $0.width = 1
      $0.height = 4
      $0.gridLen = 4
      $0.rows = rows(["a", "b", "c", "d"])
    }
    // Scrolled by two: rows 0-1 are the previous 2-3, rows 2-3 came into view.
    let down = try frame {
      $0.seq = 1
      $0.copies = [0, 2, 2]
      $0.rows = [row(2, [("e", 0)]), row(3, [("f", 0)])]
    }
    // Back up by one, with a row the grid grows by: copies read the rows as they were.
    let up = try frame {
      $0.seq = 2
      $0.gridLen = 5
      $0.copies = [1, 0, 4]
      $0.rows = [row(0, [("b", 0)])]
    }
    MainActor.assumeIsolated {
      store.apply(first)
      var seen = SceneChange()
      store.onChange = { seen = $0 }
      store.apply(down)
      XCTAssertEqual(store.lines, ["c", "d", "e", "f"])
      XCTAssertEqual(seen.rows, IndexSet(0..<4))
      store.apply(up)
      XCTAssertEqual(store.lines, ["b", "c", "d", "e", "f"])
    }
  }

  func testRunsAreCutByBytesAndCarryTheirStyle() {
    let packed = row(0, [("hé", style(fg: 0x102030, bg: 0x405060, flags: 2 | 4 | 8)), ("llo", 0)])
    let runs = CellRun.runs(packed)
    XCTAssertEqual(runs.map(\.text), ["hé", "llo"])
    XCTAssertEqual(runs[0], CellRun(text: "hé", foreground: SceneColor(red: 0x10, green: 0x20, blue: 0x30),
                                    background: SceneColor(red: 0x40, green: 0x50, blue: 0x60),
                                    italic: true, underline: true, reverse: true))
    XCTAssertEqual(runs[1], CellRun(text: "llo"), "style 0 is the terminal's default")
  }

  func testTimingComesWithFramesThatCarryIt() throws {
    let timed = try frame {
      $0.seq = 3
      $0.timing = WireTiming.with { $0.ack = 7; $0.ahead = 2; $0.encodeMs = 0.5 }
    }
    XCTAssertEqual(timed.timing?.ack, 7)
    XCTAssertEqual(timed.timing?.ahead, 2)
    XCTAssertEqual(timed.timing?.diffMs, 0.5)
    XCTAssertNil(try frame { $0.seq = 4 }.timing)
    XCTAssertNil(SceneMessage(kind: SceneWire.Kind.applied.rawValue, payload: []), "not a message Fresh sends")
  }

  func testRunsCountCellsByCharacter() {
    let run = CellRun(text: "日 👨‍👩‍👧 a")
    XCTAssertEqual(run.cells, 5, "one cell per character, the wide one followed by its blank")
  }
}

final class SceneKeysTests: XCTestCase {
  func testNamedKeysAndModifiers() {
    let enter = SceneKeys.message(keyCode: 36, charactersIgnoringModifiers: "\r", command: false, control: false, option: false,
                                  shift: false, optionAsAlt: false)
    XCTAssertEqual(enter?.key, "Enter")
    let f10 = SceneKeys.message(keyCode: 109, charactersIgnoringModifiers: nil, command: false, control: false, option: false,
                                shift: false, optionAsAlt: false)
    XCTAssertEqual(f10?.key, "F10")
    let save = SceneKeys.message(keyCode: 1, charactersIgnoringModifiers: "s", command: true, control: false, option: false,
                                 shift: false, optionAsAlt: false)
    XCTAssertEqual(save?.key, "s")
    XCTAssertEqual(save?.meta, true)
    let redo = SceneKeys.message(keyCode: 6, charactersIgnoringModifiers: "Z", command: true, control: false, option: false,
                                 shift: true, optionAsAlt: false)
    XCTAssertEqual(redo?.key, "Z")
    XCTAssertEqual(redo?.shift, true)
    let bookmark = SceneKeys.message(keyCode: 18, charactersIgnoringModifiers: "!", command: false, control: true, option: false,
                                     shift: true, optionAsAlt: false)
    XCTAssertEqual(bookmark?.code, "Digit1", "the digit row names its digit")
  }

  func testTypingGoesToTextInput() {
    XCTAssertNil(SceneKeys.message(keyCode: 0, charactersIgnoringModifiers: "a", command: false, control: false, option: false,
                                   shift: false, optionAsAlt: false))
    XCTAssertNil(SceneKeys.message(keyCode: 14, charactersIgnoringModifiers: "e", command: false, control: false, option: true,
                                   shift: false, optionAsAlt: false), "Option types its character, so dead keys work")
    let alt = SceneKeys.message(keyCode: 3, charactersIgnoringModifiers: "f", command: false, control: false, option: true,
                                shift: false, optionAsAlt: true)
    XCTAssertEqual(alt?.alt, true)
    XCTAssertEqual(SceneKeys.typing("a\nb").map(\.key), ["a", "Enter", "b"])
  }
}

/// Messages recorded from a real Fresh session by macos/tools/record_scene.py,
/// as they came off the socket. Rerun the recorder after bumping the Fresh pin:
/// if Fresh changed what it sends, this fails here instead of in the app.
final class RecordedSceneTests: XCTestCase {
  private func recorded() throws -> [SceneMessage] {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/scene", withExtension: "tlv"))
    let bytes = try [UInt8](Data(contentsOf: url))
    var messages: [SceneMessage] = []
    var start = 0
    while start < bytes.count {
      let (kind, payload, length) = try XCTUnwrap(try SceneWire.readMessage(bytes, at: start), "a message cut short")
      messages.append(try XCTUnwrap(SceneMessage(kind: kind, payload: bytes[payload]), "a recorded message didn't decode"))
      start += length
    }
    return messages
  }

  func testRecordedSessionReplays() throws {
    var messages = try recorded()
    XCTAssertTrue(messages.first?.isHello == true)
    // The last message is the hello a second connection got at the end.
    let reference = try XCTUnwrap(messages.popLast())
    XCTAssertTrue(reference.isHello)
    XCTAssertTrue(messages.contains { !$0.gridCopies.isEmpty }, "scrolling sent rows that moved as copies")
    MainActor.assumeIsolated {
      let store = SceneStore()
      var sawPalette = false
      for message in messages {
        store.apply(message)
        if store.palette != nil { sawPalette = true }
      }
      XCTAssertEqual(store.width, 80)
      XCTAssertEqual(store.height, 24)
      XCTAssertEqual(store.grid.count, 24, "one row of runs per terminal row")
      XCTAssertTrue(store.lines.allSatisfy { $0.count == 80 }, "every row covers the frame's width in cells")
      XCTAssertTrue(store.lines.contains { $0.contains("First line. (recorded)") }, "typed keys reached the buffer")
      XCTAssertNotNil(store.cursor)
      XCTAssertNotNil(store.theme.background)
      let tab = store.panes.first?.tabBar.tabs.first
      XCTAssertEqual(tab?.label, "notes.md*", "the edited file's tab says it is modified")
      XCTAssertEqual(tab?.modified, true)
      XCTAssertEqual(store.statusBar.map { CellRect($0.rect).width }, 80, "the status bar has its rectangle")
      XCTAssertTrue(store.menus.contains { $0.label == "File" }, "the menu model is in the scene")
      XCTAssertTrue(sawPalette, "the command palette appeared as a region")
      XCTAssertNil(store.palette, "and closed again")
      let fresh = SceneStore()
      fresh.apply(reference)
      XCTAssertEqual(store.grid, fresh.grid, "the frames, copies and all, rebuilt the scene a new connection gets")
      XCTAssertEqual(store.panes, fresh.panes)
      XCTAssertEqual(store.menus, fresh.menus)
    }
  }
}
