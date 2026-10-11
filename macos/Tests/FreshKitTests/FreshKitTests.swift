import XCTest
@testable import FreshKit

final class SceneSocketTests: XCTestCase {
  func testClientFramesAreMaskedAndDecode() {
    for size in [5, 200, 70_000] {
      let payload = (0..<size).map { UInt8($0 % 251) }
      let frame = SceneSocket.encode(opcode: 0x1, payload: payload)
      XCTAssertEqual(frame[0], 0x81)
      XCTAssertNotEqual(frame[1] & 0x80, 0, "client frames are masked")
      guard let decoded = SceneSocket.decode(frame) else { return XCTFail("frame of \(size) bytes didn't decode") }
      XCTAssertEqual(decoded.opcode, 0x1)
      XCTAssertEqual(decoded.payload, payload)
      XCTAssertEqual(decoded.used, frame.count)
    }
  }

  func testPartialFramesWait() {
    let frame = SceneSocket.encode(opcode: 0x1, payload: Array("hello".utf8))
    XCTAssertNil(SceneSocket.decode(Array(frame.prefix(frame.count - 1))))
  }

  func testHeaderEnd() {
    let head = Array("HTTP/1.1 101 Switching\r\nUpgrade: websocket\r\n\r\nrest".utf8)
    XCTAssertEqual(SceneSocket.headerEnd(head), head.count - 8)
    XCTAssertNil(SceneSocket.headerEnd(Array("HTTP/1.1 101\r\n".utf8)))
  }
}

final class SceneTests: XCTestCase {
  private func message(_ json: String) -> SceneMessage {
    SceneMessage(json: Array(json.utf8))!
  }

  func testHelloFillsTheStore() {
    let hello = message("""
      {"type":"hello","seq":0,"scene":{"w":4,"h":2,"windowId":1,
       "theme":{"name":"dark","bg":"#1e1e1e","fg":"#d4d4d4","accent":"#ff0000"},
       "regions":{"grid":[[{"t":"ab","fg":"#ffffff","b":true},{"t":"cd"}],[{"t":"ef  "}]],
                  "panes":[{"leaf":1,"tabs":[{"label":"a.txt","active":true}]}],
                  "cursor":{"x":1,"y":0},"statusbar":{"rect":{"x":0,"y":1,"w":4,"h":1},"segments":[]}}}}
      """)
    let store = MainActor.assumeIsolated { SceneStore() }
    MainActor.assumeIsolated {
      var seen: SceneChange?
      store.onChange = { seen = $0 }
      store.apply(hello)
      XCTAssertEqual(store.width, 4)
      XCTAssertEqual(store.height, 2)
      XCTAssertEqual(store.lines, ["abcd", "ef  "])
      XCTAssertEqual(store.grid[0][0], CellRun(text: "ab", foreground: SceneColor(red: 255, green: 255, blue: 255), bold: true))
      XCTAssertEqual(store.cursor?.column, 1)
      XCTAssertEqual(store.theme.background, SceneColor(red: 0x1e, green: 0x1e, blue: 0x1e))
      XCTAssertTrue(store.theme.isDark)
      XCTAssertEqual(store.panes.count, 1)
      XCTAssertNotNil(store.regions["statusbar"])
      XCTAssertEqual(seen?.isHello, true)
    }
  }

  func testFramesReplaceRowsAndRegions() {
    let store = MainActor.assumeIsolated { SceneStore() }
    MainActor.assumeIsolated {
      store.apply(message(#"{"type":"hello","seq":0,"scene":{"w":3,"h":3,"regions":{"grid":[[{"t":"aaa"}],[{"t":"bbb"}],[{"t":"ccc"}]],"panes":[],"cursor":{"x":0,"y":0}}}}"#))
      var seen = SceneChange()
      store.onChange = { seen = $0 }
      store.apply(message(#"{"type":"frame","seq":1,"changed":{"regions.grid.1":[{"t":"xyz"}],"regions.cursor":{"x":2,"y":1}}}"#))
      XCTAssertEqual(store.lines, ["aaa", "xyz", "ccc"])
      XCTAssertEqual(seen.rows, IndexSet([0, 1]), "the changed row and both cursor rows redraw")
      XCTAssertTrue(seen.cursorChanged)
      store.apply(message(#"{"type":"frame","seq":2,"changed":{"h":2,"regions.grid.len":2,"regions.panes.len":1,"regions.panes.0":{"leaf":3}}}"#))
      XCTAssertEqual(store.grid.count, 2)
      XCTAssertEqual(store.height, 2)
      XCTAssertEqual(store.panes.first?["leaf"] as? Int, 3)
    }
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
    XCTAssertEqual(enter?["key"] as? String, "Enter")
    let f10 = SceneKeys.message(keyCode: 109, charactersIgnoringModifiers: nil, command: false, control: false, option: false,
                                shift: false, optionAsAlt: false)
    XCTAssertEqual(f10?["key"] as? String, "F10")
    let save = SceneKeys.message(keyCode: 1, charactersIgnoringModifiers: "s", command: true, control: false, option: false,
                                 shift: false, optionAsAlt: false)
    XCTAssertEqual(save?["key"] as? String, "s")
    XCTAssertEqual(save?["meta"] as? Bool, true)
    let redo = SceneKeys.message(keyCode: 6, charactersIgnoringModifiers: "Z", command: true, control: false, option: false,
                                 shift: true, optionAsAlt: false)
    XCTAssertEqual(redo?["key"] as? String, "Z")
    XCTAssertEqual(redo?["shift"] as? Bool, true)
    let bookmark = SceneKeys.message(keyCode: 18, charactersIgnoringModifiers: "!", command: false, control: true, option: false,
                                     shift: true, optionAsAlt: false)
    XCTAssertEqual(bookmark?["code"] as? String, "Digit1", "the digit row names its digit")
  }

  func testTypingGoesToTextInput() {
    XCTAssertNil(SceneKeys.message(keyCode: 0, charactersIgnoringModifiers: "a", command: false, control: false, option: false,
                                   shift: false, optionAsAlt: false))
    XCTAssertNil(SceneKeys.message(keyCode: 14, charactersIgnoringModifiers: "e", command: false, control: false, option: true,
                                   shift: false, optionAsAlt: false), "Option types its character, so dead keys work")
    let alt = SceneKeys.message(keyCode: 3, charactersIgnoringModifiers: "f", command: false, control: false, option: true,
                                shift: false, optionAsAlt: true)
    XCTAssertEqual(alt?["alt"] as? Bool, true)
    XCTAssertEqual(SceneKeys.typing("a\nb").compactMap { $0["key"] as? String }, ["a", "Enter", "b"])
  }
}

/// Messages recorded from a real Fresh session by macos/tools/record_scene.py.
/// Rerun the recorder after bumping the Fresh pin: if Fresh changed what it
/// sends, this fails here instead of in the app.
final class RecordedSceneTests: XCTestCase {
  private func recorded() throws -> [SceneMessage] {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/scene", withExtension: "json"))
    let all = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [Any])
    return try all.map { item in
      let data = try JSONSerialization.data(withJSONObject: item)
      return try XCTUnwrap(SceneMessage(json: Array(data)), "a recorded message didn't parse")
    }
  }

  func testRecordedSessionReplays() throws {
    let messages = try recorded()
    XCTAssertTrue(messages.first?.isHello == true)
    MainActor.assumeIsolated {
      let store = SceneStore()
      var sawPalette = false
      for message in messages {
        store.apply(message)
        if store.regions["palette"] is [String: Any] { sawPalette = true }
      }
      XCTAssertEqual(store.width, 80)
      XCTAssertEqual(store.height, 24)
      XCTAssertEqual(store.grid.count, 24, "one row of runs per terminal row")
      XCTAssertTrue(store.lines.allSatisfy { $0.count == 80 }, "every row covers the frame's width in cells")
      XCTAssertTrue(store.lines.contains { $0.contains("First line. (recorded)") }, "typed keys reached the buffer")
      XCTAssertNotNil(store.cursor)
      XCTAssertNotNil(store.theme.background)
      let tabs = store.panes.first?["tabs"] as? [[String: Any]]
      XCTAssertEqual(tabs?.first?["label"] as? String, "notes.md*", "the edited file's tab says it is modified")
      XCTAssertEqual(tabs?.first?["modified"] as? Bool, true)
      XCTAssertNotNil(CellRect((store.regions["statusbar"] as? [String: Any])?["rect"]), "the status bar has its rectangle")
      let menus = store.regions["menus"] as? [[String: Any]] ?? []
      XCTAssertTrue(menus.contains { $0["label"] as? String == "File" }, "the menu model is in the scene")
      XCTAssertTrue(sawPalette, "the command palette appeared as a region")
      XCTAssertNil(store.regions["palette"] as? [String: Any], "and closed again")
    }
  }
}
