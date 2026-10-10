import AppKit
import Foundation

/// The demo files explainers work on, in ~/Library/Application Support/File
/// Commander/Tutorial: no folder there triggers a privacy prompt, and nothing
/// of the user's is touched. Built from fixed data, so every run looks the same.
struct TutorialWorld {
  let root: URL
  var home: URL { root.appendingPathComponent("home") }
  var server: URL { root.appendingPathComponent("server") }
  /// HOME for the tutorial's Fresh session. It lives beside the demo files, not
  /// in them, because Fresh's backend keeps running and writing after a tutorial.
  var profile: URL { root.deletingLastPathComponent().appendingPathComponent("TutorialEditor") }
  var demoSSH: URL { root.appendingPathComponent("demo-ssh") }
  static let demoHost = "demo-server"

  static let photos = ["cathedral-steps", "cliff-path-at-sunset", "fishing-boats", "harbour-at-dawn", "lighthouse",
                       "night-ferry", "old-town-market", "street-musicians"]
  static let mib = 1 << 20

  static var defaultRoot: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("File Commander/Tutorial", isDirectory: true)
  }

  init(root: URL = TutorialWorld.defaultRoot) { self.root = root }

  /// Expands {world}, {home} and {server} in a script value.
  func expand(_ text: String) -> String {
    text.replacingOccurrences(of: "{home}", with: home.path)
      .replacingOccurrences(of: "{server}", with: server.path)
      .replacingOccurrences(of: "{world}", with: root.path)
      .replacingOccurrences(of: "{demo}", with: "ssh://\(TutorialWorld.demoHost)\(server.path)")
  }

  func contains(_ path: String) -> Bool {
    let decoded = path.hasPrefix("fc-ssh:") || path.hasPrefix("ssh://") ? path : URL(fileURLWithPath: path).standardizedFileURL.path
    return decoded.hasPrefix(root.path) || decoded.contains(server.path)
  }

  /// Removes and recreates every demo file.
  func build(sevenZip: String?) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: root.path) {
      // Only ever delete a folder this code created: the marker says so, or it is
      // the app's own folder in Application Support.
      guard fm.fileExists(atPath: root.appendingPathComponent(".fc-tutorial-world").path) || root == TutorialWorld.defaultRoot else {
        throw NSError(domain: "Tutorial", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(root.path) exists but wasn't made by the tutorial"])
      }
      try fm.removeItem(at: root)
    }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("File Commander tutorial demo files\n".utf8).write(to: root.appendingPathComponent(".fc-tutorial-world"))

    // Names of different lengths: the editor explainer quotes each with Home and End.
    for (index, name) in TutorialWorld.photos.enumerated() {
      try photo(home.appendingPathComponent("camera/\(name).jpg"), title: name, seed: index,
                size: (3 + index % 4) * TutorialWorld.mib + index * 997, day: 20 + index % 7)
    }
    for number in 31...36 {
      try sized(home.appendingPathComponent("camera/MOV_00\(number).mov"), (8 + number % 4) * TutorialWorld.mib, day: 26)
    }
    for (name, day) in [("beach", 3), ("city", 4), ("harbour", 6)] {
      try photo(home.appendingPathComponent("photos/2026/\(name).jpg"), title: name, seed: day, size: 2 * TutorialWorld.mib + day * 4099, day: day)
    }
    for (name, day) in [("mountains", 12), ("lake", 14)] {
      try photo(home.appendingPathComponent("photos/2025/\(name).jpg"), title: name, seed: day + 20, size: TutorialWorld.mib + day * 811, day: day)
    }
    let albums = [("Night Drive", ["Neon Rain", "Coastline", "After Hours", "Slow Lights"]), ("Field Notes", ["North Wind", "Paper Maps", "Low Tide"])]
    for (album, tracks) in albums {
      for (index, track) in tracks.enumerated() {
        try sized(home.appendingPathComponent("music/\(album)/\(String(format: "%02d", index + 1)) \(track).flac"),
                  (14 + index * 2) * TutorialWorld.mib, day: 11 + index)
      }
    }
    try fm.createDirectory(at: home.appendingPathComponent("backup"), withIntermediateDirectories: true)
    let site = [
      "index.html": "<!doctype html>\n<title>Field Notes</title>\n<h1>Field Notes</h1>\n<p>Photos and music from the road.</p>\n",
      "style.css": "body { font: 18px/1.5 system-ui; margin: 4rem auto; max-width: 42rem; }\nh1 { color: #2d6cdf; }\n",
      "app.js": TutorialWorld.galleryJS,
      "README.md": "# Field Notes website\n\nStatic site. Upload `index.html`, `style.css` and `app.js` to the server.\n",
    ]
    for (name, body) in site { try text(home.appendingPathComponent("projects/website/\(name)"), body, day: 22) }
    try text(home.appendingPathComponent("projects/notes/ideas.md"), "# Ideas\n\n- Print the harbour photos\n- Finish the coastline track\n", day: 18)
    try text(home.appendingPathComponent("projects/notes/todo.md"), "# To do\n\n- [ ] Back up the music folder\n- [ ] Publish the website\n", day: 19)
    try text(home.appendingPathComponent("projects/tools/backup.sh"), "#!/bin/sh\n# Copies the camera roll to the backup disk.\ncp -R ../../camera ../../backup/\n", day: 21)
    chmod(home.appendingPathComponent("projects/tools/backup.sh").path, 0o755)
    try text(home.appendingPathComponent("projects/tools/copy-jpg.lua"), TutorialWorld.copyScript(home: home.path), day: 21)
    try text(home.appendingPathComponent("todo.txt"), "Back up music\nPublish website\nSort camera roll\n", day: 25)
    try text(home.appendingPathComponent("README.md"), "# Demo home\n\nFile Commander's tutorial made these files. They go away when the tutorial ends.\n", day: 1)
    // Links: one to a folder, one whose target is missing, for the delete explainer.
    try fm.createSymbolicLink(atPath: home.appendingPathComponent("latest-photos").path, withDestinationPath: "photos/2026")
    try fm.createSymbolicLink(atPath: home.appendingPathComponent("old-link").path, withDestinationPath: "photos/1999")
    // An unreadable file: copies record the error and keep going.
    let locked = home.appendingPathComponent("photos/2025/unreadable.jpg")
    try photo(locked, title: "locked", seed: 99, size: TutorialWorld.mib, day: 27)
    chmod(locked.path, 0o000)

    if let sevenZip, fm.isExecutableFile(atPath: sevenZip) {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: sevenZip)
      process.arguments = ["a", "-bd", "-y", home.appendingPathComponent("website-2025.7z").path, "."]
      process.currentDirectoryURL = home.appendingPathComponent("projects/website")
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      setDate(home.appendingPathComponent("website-2025.7z"), day: 2)
    }

    for (name, body) in [("index.html", "<!doctype html>\n<title>Field Notes</title>\n<h1>Coming soon</h1>\n"),
                         ("404.html", "<!doctype html>\n<title>Not found</title>\n<h1>Nothing here</h1>\n"),
                         ("robots.txt", "User-agent: *\nAllow: /\n")] {
      try text(server.appendingPathComponent(name), body, day: 15)
    }
    try photo(server.appendingPathComponent("assets/hero.jpg"), title: "hero", seed: 42, size: 384 * 1024, day: 15)

    // The demo server: FC's real remote agent, run locally instead of over ssh.
    try """
    #!/usr/bin/env python3
    # File Commander tutorial: a stand-in for ssh that runs the command locally.
    import os, shlex, sys
    command = shlex.split(sys.argv[-1])
    if command and command[0] == 'python3':
        os.execv(sys.executable, [sys.executable, *command[1:]])
    os.execvp(command[0], command)

    """.write(to: demoSSH, atomically: true, encoding: .utf8)
    chmod(demoSSH.path, 0o755)

    // Fresh reads $HOME/.config/fresh: no auto-closing brackets or auto-indent,
    // so the editor explainer types every character itself.
    let fresh = profile.appendingPathComponent(".config/fresh")
    try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
    try """
    {
      "check_for_updates": false,
      "editor": { "auto_close": false, "auto_indent": false, "tab_size": 2 },
      "plugins": {
        "orchestrator": { "enabled": true, "settings": { "autoOpenDock": "never" } },
        "welcome_screen": { "enabled": true, "settings": { "showOnStartup": false } }
      }
    }

    """.write(to: fresh.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
  }

  /// Removes the demo files. Deleting needs write access to the folders only,
  /// so the unreadable file goes too.
  func remove() {
    if FileManager.default.fileExists(atPath: root.appendingPathComponent(".fc-tutorial-world").path) {
      try? FileManager.default.removeItem(at: root)
    }
  }

  // MARK: Files

  private func setDate(_ url: URL, day: Int, hour: Int = 10) {
    var c = DateComponents()
    c.year = 2026; c.month = 9; c.day = max(1, min(day, 28)); c.hour = hour
    let date = Calendar(identifier: .gregorian).date(from: c) ?? Date()
    try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
  }

  private func text(_ url: URL, _ body: String, day: Int) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try body.write(to: url, atomically: true, encoding: .utf8)
    setDate(url, day: day)
  }

  /// A file of `size` bytes; the tail is a hole, so building is instant.
  private func sized(_ url: URL, _ size: Int, day: Int, head: Data = Data()) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: head)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(max(size, head.count)))
    try handle.close()
    setDate(url, day: day)
  }

  /// A real JPEG, so thumbnails and Quick Look show a picture, padded to `size`.
  private func photo(_ url: URL, title: String, seed: Int, size: Int, day: Int) throws {
    try sized(url, size, day: day, head: TutorialWorld.jpeg(title: title, seed: seed))
  }

  static func jpeg(title: String, seed: Int) -> Data {
    let width = 960, height = 640
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { return Data() }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let hue = CGFloat((seed * 37) % 100) / 100
    let gradient = NSGradient(colors: [NSColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1),
                                       NSColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.45, alpha: 1)])
    gradient?.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -60)
    NSColor(white: 1, alpha: 0.18).setFill()
    NSBezierPath(ovalIn: NSRect(x: 560, y: 300, width: 260, height: 260)).fill()
    let label = title.replacingOccurrences(of: "-", with: " ").capitalized
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 54, weight: .bold), .foregroundColor: NSColor.white]
    label.draw(at: NSPoint(x: 48, y: 52), withAttributes: attributes)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) ?? Data()
  }

  /// The scripting guide's example, with the demo folders filled in.
  static func copyScript(home: String) -> String {
    """
    -- copy-jpg.lua: copy every *.jpg file in SRC (not subfolders) to DST.
    -- From doc/scripting.md. Run: SRC=... DST=... fc run copy-jpg.lua
    local src = os.getenv("SRC") or "\(home)/camera"
    local dst = os.getenv("DST") or "\(home)/backup"

    local function type_text(text)
      for byte in text:gmatch(".") do fc.key(byte) end
    end

    fc.left_cd(src)
    assert(fc.wait_event("dir_changed", 5000), "could not open " .. src)
    fc.right_cd(dst)
    assert(fc.wait_event("dir_changed", 5000), "could not open " .. dst)

    assert(fc.command("glob_select"), "glob_select is not available")
    type_text("*.jpg")
    fc.key("ret")
    assert(fc.wait_event("dialog_closed", 2000), "no *.jpg files in " .. src)
    local count = fc.state().left.selected_count

    assert(fc.command("copy"), "copy is not available")
    assert(fc.wait_event("discovery_completed", 30000), "scan did not finish")
    fc.key("f5")
    assert(fc.wait_event("dialog_closed", 2000), "copy did not start")
    assert(fc.wait_for_jobs(600000), "copy did not finish in time")
    fc.sleep(1500)
    print(("copied %d file(s) from %s to %s"):format(count, src, dst))

    """
  }

  static let galleryJS = """
  // Builds the photo grid on the home page.
  const grid = document.querySelector('#gallery');



  for (const name of photos) {
    const figure = document.createElement('figure');
    figure.innerHTML = `<img src="photos/${name}" alt="">`;
    grid.append(figure);
  }

  """
}
