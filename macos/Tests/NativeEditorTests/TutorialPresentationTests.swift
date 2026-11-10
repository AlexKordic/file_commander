import Foundation
import XCTest
import ExplainerKit
@testable import FileCommander

final class TutorialPresentationTests: XCTestCase {
  func testResumeRetakesStaleCapturesAfterAnInterruptedPresentationMigration() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let take = root.appendingPathComponent("capture/sample")
    try FileManager.default.createDirectory(at: take, withIntermediateDirectories: true)
    let script = try JSONDecoder().decode(ExplainerScript.self, from: Data(#"{"id":"sample","title":"Sample","steps":[]}"#.utf8))
    let geometry = TutorialFrameRecorder.Geometry(frame: .init(x: 0, y: 0, width: 901, height: 849), scale: 2)
    let options: [String: JSONValue] = ["sidebarShown": .bool(false), "freshConfig": .object(["theme": .string("builtin://light")])]
    let old = TutorialCaptureConfiguration(folder: take.path, session: take.path, lesson: ["id": "sample"], geometry: geometry,
                                           hostOptions: ["sidebarShown": .bool(false)])
    try JSONEncoder().encode(old).write(to: take.appendingPathComponent("config.json"))
    try JSONEncoder().encode(script).write(to: take.appendingPathComponent("lesson.json"))
    try Data(#"{"status":"complete"}"#.utf8).write(to: take.appendingPathComponent("manifest.json"))
    XCTAssertEqual(TutorialPresentation.retakes(root: root, scripts: [script], options: options, geometry: geometry,
                                               presentationChanged: false), ["sample"])
    var current = old; current.hostOptions = options
    try JSONEncoder().encode(current).write(to: take.appendingPathComponent("config.json"))
    XCTAssertEqual(TutorialPresentation.retakes(root: root, scripts: [script], options: options, geometry: geometry,
                                               presentationChanged: false), [])
  }

  func testFreshSnapshotPreservesLightThemeAndDisabledPluginsWithoutPrivateSettings() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source.appendingPathComponent("themes"), withIntermediateDirectories: true)
    try Data(#"{"theme":"builtin://light","editor":{"line_numbers":false},"plugins":{"orchestrator":{"enabled":false,"settings":{"api_key":"PRIVATE_TEST_VALUE"}}},"env":{"TOKEN":"PRIVATE_TEST_VALUE"}}"#.utf8)
      .write(to: source.appendingPathComponent("config.json"))
    try Data(#"{"editor":{"relative_line_numbers":true}}"#.utf8).write(to: source.appendingPathComponent("config_macos.json"))
    try Data(##"{"name":"Custom","background":"#ffffff"}"##.utf8).write(to: source.appendingPathComponent("themes/custom.json"))
    let snapshot = try TutorialPresentation.freshSettings(folder: source)
    XCTAssertEqual(snapshot.configuration["theme"]?.string, "builtin://light")
    XCTAssertEqual(snapshot.configuration["editor"]?["line_numbers"]?.bool, false)
    XCTAssertEqual(snapshot.configuration["editor"]?["relative_line_numbers"]?.bool, true)
    XCTAssertEqual(snapshot.configuration["plugins"]?["orchestrator"]?["enabled"]?.bool, false)
    XCTAssertNil(snapshot.configuration["env"])
    XCTAssertNil(snapshot.configuration["plugins"]?["orchestrator"]?["settings"])
    let world = TutorialWorld(root: root.appendingPathComponent("world"))
    try world.writeFreshConfiguration(options: ["freshConfig": .object(snapshot.configuration), "freshThemes": .object(snapshot.themes)])
    let data = try Data(contentsOf: world.profile.appendingPathComponent(".config/fresh/config.json"))
    let written = try JSONDecoder().decode([String: JSONValue].self, from: data)
    XCTAssertEqual(written["theme"]?.string, "builtin://light")
    XCTAssertEqual(written["plugins"]?["orchestrator"]?["enabled"]?.bool, false)
    XCTAssertEqual(written["editor"]?["auto_indent"]?.bool, false)
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("PRIVATE_TEST_VALUE"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: world.profile.appendingPathComponent(".config/fresh/themes/custom.json").path))
  }
}
