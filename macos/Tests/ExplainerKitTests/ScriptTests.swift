import Foundation
import Testing
@testable import ExplainerKit

/// Every explainer the app ships must decode, and steps keep their options.
@Test func appExplainersDecode() throws {
  let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../Sources/FileCommander/Explainers").standardizedFileURL
  let catalog = try ExplainerCatalog.load(from: folder)
  #expect(catalog.scripts.count >= 25)
  #expect(!catalog.chapters.isEmpty)
  for script in catalog.scripts {
    #expect(!script.steps.isEmpty, "\(script.id) has no steps")
    #expect(catalog.chapters.contains { $0.id == script.chapter }, "\(script.id) has an unknown chapter")
  }
  #expect(catalog.script("copy")?.steps.contains { $0.option("as_job")?.string == "photos" } == true)
}

@Test func stepNeedsOneAction() {
  let bad = Data(#"{"caption": "A", "keys": ["F5"]}"#.utf8)
  #expect(throws: (any Error).self) { try JSONDecoder().decode(ExplainerStep.self, from: bad) }
  let good = try? JSONDecoder().decode(ExplainerStep.self, from: Data(#"{"caption": "A", "sub": "B", "hold": 500}"#.utf8))
  #expect(good?.action == "caption")
  #expect(good?.hold == 0.5)
}

@Test func captionsBecomeCues() {
  let timeline = [TimelineEvent(time: 1, kind: "caption", text: "One", detail: "first"),
                  TimelineEvent(time: 3, kind: "caption", text: "Two"),
                  TimelineEvent(time: 5, kind: "uncaption", text: "")]
  let cues = ExplainerExport.cues(timeline, end: 9)
  #expect(cues.count == 2)
  #expect(cues[0].end == 3)
  #expect(ExplainerExport.srt(cues).contains("00:00:01,000 --> 00:00:03,000\nOne\nfirst"))
  #expect(ExplainerExport.vtt(cues).hasPrefix("WEBVTT"))
}

@Test func anchorQualifiers() {
  #expect(AnchorRegistry.qualifier("pane.left.row[name=a.jpg]", "name") == "a.jpg")
  #expect(AnchorRegistry.qualifier("sheet.copy.conflict[mode=skip]", "mode") == "skip")
  #expect(AnchorRegistry.qualifier("toolbar.copy", "name") == nil)
}
