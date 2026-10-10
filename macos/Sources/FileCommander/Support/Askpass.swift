import AppKit
import ExplainerKit
import Foundation
import SwiftUI

/// A question ssh asks: a password or passphrase, a host key to trust, or a notice.
struct AskpassPrompt: Identifiable, Sendable {
  enum Kind: Sendable { case secret, confirm, notice }
  let id: Int
  let text: String
  let kind: Kind
}

/// Answers ssh's questions with native sheets. ssh runs the bundled
/// fc-askpass (SSH_ASKPASS with SSH_ASKPASS_REQUIRE=force), which forwards
/// each prompt over a private Unix socket and prints the answer.
@MainActor
final class AskpassServer {
  private var socketPath = ""
  private var listener: Int32 = -1
  private var nextID = 0
  private var pending: [Int: (String?) -> Void] = [:]
  private weak var app: AppController?

  func start(app: AppController) {
    self.app = app
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fc-askpass-\(getuid())-\(getpid())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    socketPath = dir.appendingPathComponent("socket").path
    unlink(socketPath)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8.prefix(MemoryLayout.size(ofValue: address.sun_path) - 1))
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      for (i, b) in bytes.enumerated() { raw[i] = b }
      raw[bytes.count] = 0
    }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0, listen(fd, 4) == 0 else { close(fd); return }
    chmod(socketPath, 0o600)
    listener = fd
    if let helper = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("fc-askpass").path,
       FileManager.default.isExecutableFile(atPath: helper) {
      setenv("SSH_ASKPASS", helper, 1)
      setenv("SSH_ASKPASS_REQUIRE", "force", 1)
      setenv("FC_ASKPASS_SOCKET", socketPath, 1)
      if getenv("DISPLAY") == nil { setenv("DISPLAY", ":0", 1) }  // Older OpenSSH wants one before it uses SSH_ASKPASS.
    }
    let path = socketPath
    Thread.detachNewThread { AskpassServer.acceptLoop(fd, path) }
  }

  func stop() {
    if listener >= 0 { close(listener) }
    listener = -1
    unlink(socketPath)
  }

  nonisolated private static func acceptLoop(_ fd: Int32, _ path: String) {
    while true {
      let client = accept(fd, nil, nil)
      if client < 0 { return }
      Thread.detachNewThread { serve(client) }
    }
  }

  nonisolated private static func serve(_ client: Int32) {
    defer { close(client) }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while !data.contains(0x0A) {
      let n = read(client, &buffer, buffer.count)
      if n <= 0 { return }
      data.append(contentsOf: buffer[0..<n])
    }
    guard let line = String(data: data.prefix { $0 != 0x0A }, encoding: .utf8),
          let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String] else { return }
    let text = json["prompt"] ?? ""
    let hint = json["kind"] ?? ""
    let kind: AskpassPrompt.Kind = hint == "none" ? .notice
      : hint == "confirm" || text.contains("(yes/no") || text.lowercased().contains("continue connecting") ? .confirm : .secret
    let semaphore = DispatchSemaphore(value: 0)
    let reply = ReplyBox()
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        AppController.shared.askpass.ask(text: text, kind: kind) { answer in
          reply.value = answer
          semaphore.signal()
        }
      }
    }
    semaphore.wait()
    let response = reply.value.map { "OK " + $0 + "\n" } ?? "CANCEL\n"
    _ = response.withCString { write(client, $0, strlen($0)) }
  }

  private final class ReplyBox: @unchecked Sendable { var value: String? }

  func ask(text: String, kind: AskpassPrompt.Kind, reply: @escaping (String?) -> Void) {
    guard let app else { reply(nil); return }
    if kind == .notice {
      app.flash(text)
      reply("")
      return
    }
    nextID += 1
    pending[nextID] = reply
    let prompt = AskpassPrompt(id: nextID, text: text, kind: kind)
    // A copy or other sheet may be up; ssh waits until the user answers.
    if app.sheet != nil {
      let window = NSApp.mainWindow ?? NSApp.windows.first
      let alert = NSAlert()
      alert.messageText = kind == .confirm ? "Trust this host?" : "SSH asks"
      alert.informativeText = text
      let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
      if kind == .secret { alert.accessoryView = field }
      alert.addButton(withTitle: kind == .confirm ? "Trust and Connect" : "OK")
      alert.addButton(withTitle: "Cancel")
      if let window {
        alert.beginSheetModal(for: window) { response in
          MainActor.assumeIsolated { self.answer(prompt.id, response == .alertFirstButtonReturn ? (kind == .confirm ? "yes" : field.stringValue) : nil) }
        }
      } else {
        let response = alert.runModal()
        answer(prompt.id, response == .alertFirstButtonReturn ? (kind == .confirm ? "yes" : field.stringValue) : nil)
      }
    } else {
      app.sheet = .askpass(prompt)
    }
  }

  func answer(_ id: Int, _ value: String?) {
    pending.removeValue(forKey: id)?(value)
  }
}

struct AskpassSheet: View {
  let prompt: AskpassPrompt
  @Environment(AppController.self) private var app
  @State private var secret = ""

  var body: some View {
    SheetFrame(title: prompt.kind == .confirm ? "Trust This Host?" : "SSH Needs an Answer", subtitle: "", width: 480) {
      Text(prompt.text).font(.system(.body, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      if prompt.kind == .secret {
        SecureField("Password or passphrase", text: $secret).textFieldStyle(.roundedBorder).onSubmit(ok)
          .explainerAnchor("sheet.askpass.secret")
      } else {
        Label("Check the fingerprint with the server's administrator before you trust it.", systemImage: "checkmark.shield")
          .foregroundStyle(.secondary)
      }
    } buttons: {
      Button("Cancel") { app.askpass.answer(prompt.id, nil); app.sheet = nil }.keyboardShortcut(.cancelAction)
      Button(prompt.kind == .confirm ? "Trust and Connect" : "OK", action: ok).keyboardShortcut(.defaultAction)
    }
  }

  private func ok() {
    app.askpass.answer(prompt.id, prompt.kind == .confirm ? "yes" : secret)
    app.sheet = nil
  }
}
