import AppKit
import Testing
@testable import ExplainerKit

@Test func captureOptionsKeepAnExplicitlyHiddenSidebarAndDecodeOlderSessions() throws {
  let geometry = TutorialFrameRecorder.Geometry(frame: CGRect(x: 3, y: 401, width: 901, height: 632), scale: 2)
  let options: [String: JSONValue] = ["sidebarShown": .bool(false), "collapsedSidebarSections": .array([.string("locations")])]
  let configured = TutorialCaptureConfiguration(folder: "/capture", session: "/session", lesson: ["id": "select"],
                                               geometry: geometry, hostOptions: options)
  let data = try JSONEncoder().encode(configured)
  let roundtrip = try JSONDecoder().decode(TutorialCaptureConfiguration.self, from: data)
  #expect(roundtrip.hostOptions?["sidebarShown"]?.bool == false)
  #expect(roundtrip.hostOptions?["collapsedSidebarSections"]?.strings == ["locations"])
  var older = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  older.removeValue(forKey: "hostOptions")
  let legacy = try JSONDecoder().decode(TutorialCaptureConfiguration.self, from: JSONSerialization.data(withJSONObject: older))
  #expect(legacy.hostOptions == nil)
  #expect(legacy.geometry == geometry)
}

@Test func recordingGeometryUsesSelectedWindowPixelsAndPadsOddEdges() {
  let geometry = TutorialFrameRecorder.Geometry(frame: CGRect(x: 100, y: 50, width: 1000, height: 625), scale: 2)
  #expect(geometry.width == 2000)
  #expect(geometry.height == 1250)
  let odd = TutorialFrameRecorder.Geometry(frame: CGRect(x: 0, y: 0, width: 1001, height: 625), scale: 1)
  #expect(odd.width == 1002)
  #expect(odd.height == 626)
  #expect(odd.pointsWidth == 1001)
}

@Test func presentationMetadataKeepsExactlyOneAction() throws {
  let input = Data(#"{"id":"copy.open","keys":["F5"],"presentation":{"id":"copy.choose","title":"Choose files","narration":"Select the files to copy."}}"#.utf8)
  let step = try JSONDecoder().decode(ExplainerStep.self, from: input)
  #expect(step.action == "keys")
  #expect(step.id == "copy.open")
  #expect(step.presentation?["id"]?.string == "copy.choose")
  #expect(throws: (any Error).self) {
    try JSONDecoder().decode(ExplainerStep.self, from: Data(#"{"id":"bad","keys":["F5"],"caption":"Two actions"}"#.utf8))
  }
}

@MainActor private final class TinyHost: ExplainerHost {
  var hostWindow: NSWindow? { nil }
  var overlayStyle: OverlayStyle { .init() }
  func prepare(_ script: ExplainerScript) async throws {}
  func finish(_ script: ExplainerScript, keepTabs: Bool) async {}
  func press(_ chord: String) async throws {}
  func type(_ character: String) async throws {}
  func evaluate(_ condition: JSONValue) -> Bool { true }
  func describe(_ condition: JSONValue) -> String { "ready" }
  func perform(_ step: ExplainerStep, runner: ExplainerRunner) async throws -> Bool { false }
  func drag(from: String, to: String, duration: Double) async throws {}
  func willRun(_ step: ExplainerStep, index: Int) {}
  func keyLabel(_ chord: String) -> String { chord }
  func expand(_ text: String) -> String { text }
}

@MainActor @Test func recordingHooksBracketActualActionsAndWaitForPacing() async throws {
  let runner = ExplainerRunner(), host = TinyHost()
  let script = try JSONDecoder().decode(ExplainerScript.self, from: Data(#"{"id":"demo","title":"Demo","steps":[{"id":"first","caption":"Hello"},{"id":"second","caption":"Goodbye"}]}"#.utf8))
  var events: [String] = []
  runner.beforeStep = { _, step, _ in
    events.append("before:" + (step.id ?? ""))
    if step.id == "second" { #expect(runner.overlay.caption?.title == "Hello") }
    try await Task.sleep(for: .milliseconds(10))
  }
  runner.afterStep = { _, step, _ in events.append("after:" + (step.id ?? "")) }
  runner.afterLesson = { _ in events.append("finished") }
  try await runner.run(script, host: host)
  #expect(events == ["before:first", "after:first", "before:second", "after:second", "finished"])
  #expect(runner.state == .finished)
}

@MainActor @Test func showMeFallbackActionsAreIncludedInRecordingEvents() async throws {
  let runner = ExplainerRunner(), host = TinyHost()
  let script = try JSONDecoder().decode(ExplainerScript.self, from: Data(#"{"id":"demo","title":"Demo","steps":[{"id":"parent","try":{"show":[{"caption":"Nested action"}]}}]}"#.utf8))
  var events: [String] = []
  runner.beforeStep = { _, step, _ in events.append("start:" + (step.id ?? "")) }
  runner.afterStep = { _, step, _ in events.append("end:" + (step.id ?? "")) }
  try await runner.run(script, host: host)
  #expect(events == ["start:parent", "start:parent.show-0", "end:parent.show-0", "end:parent"])
}
