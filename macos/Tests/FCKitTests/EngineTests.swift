import Foundation
import Testing
@testable import FCKit

// The engine is a process-wide singleton with a profile lock, so one test
// drives it through a whole session.
@MainActor
@Test func engineSession() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("fckit-\(UUID().uuidString)")
  let photos = root.appendingPathComponent("photos")
  try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
  for name in ["lighthouse.jpg", "night-ferry.jpg", "notes.txt"] {
    try Data(name.utf8).write(to: photos.appendingPathComponent(name))
  }
  setenv("XDG_CONFIG_HOME", root.appendingPathComponent("config").path, 1)
  defer { try? FileManager.default.removeItem(at: root) }

  let engine = Engine.shared
  var options = Engine.StartOptions()
  options.left = root.path
  options.right = photos.path
  #expect(engine.start(options) == nil)
  defer { engine.stop() }

  func settle(_ what: String, _ predicate: () -> Bool) async {
    for _ in 0..<400 where !predicate() {
      try? await Task.sleep(for: .milliseconds(10))
      engine.drain()
    }
    #expect(predicate(), "\(what)")
  }
  await settle("right pane listed") { !engine.right.loading && engine.rowCount(1) == 3 }
  #expect(engine.row(1, 0).name == "lighthouse.jpg")
  #expect(engine.rowNamed(1, "notes.txt") == 2)

  engine.setFocusedSide(1)
  #expect(engine.focusedSide == 1)
  #expect(engine.globSelect(1, pattern: "*.jpg", select: true) == 2)
  #expect(engine.right.itemsSelected == 2)

  var requests: [DialogRequest] = []
  engine.onDialog = { requests.append($0) }
  #expect(engine.execute("copy"))
  #expect(requests.first?.name == "Copy")
  #expect(requests.first?.selected.count == 2)
  #expect(requests.first?.target == root.path)

  let made = engine.submitMkdir(in: root.path, name: "2026")
  #expect(made.error == nil)
  await settle("mkdir finished") { engine.jobDetail(made.job).info.state == "completed" }

  engine.setTransferRate(1_048_576, persist: false)
  #expect(engine.transferRate == 1_048_576)
  #expect(engine.palette("ssh").first == "connect_ssh")
}
