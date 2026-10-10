// SSH_ASKPASS helper for File Commander: forwards ssh's prompt to the app over
// the private socket in FC_ASKPASS_SOCKET and prints the answer. Exit 1 cancels.
import Foundation

let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
let kind = ProcessInfo.processInfo.environment["SSH_ASKPASS_PROMPT"] ?? ""
guard let path = ProcessInfo.processInfo.environment["FC_ASKPASS_SOCKET"] else {
  FileHandle.standardError.write(Data("fc-askpass: FC_ASKPASS_SOCKET is not set\n".utf8))
  exit(1)
}

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: address.sun_path) - 1))
withUnsafeMutableBytes(of: &address.sun_path) { raw in
  for (i, b) in bytes.enumerated() { raw[i] = b }
  raw[bytes.count] = 0
}
let connected = withUnsafePointer(to: &address) {
  $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard fd >= 0, connected == 0 else { exit(1) }

let request = try! JSONSerialization.data(withJSONObject: ["prompt": prompt, "kind": kind]) + Data("\n".utf8)
_ = request.withUnsafeBytes { write(fd, $0.baseAddress, request.count) }

var reply = Data()
var buffer = [UInt8](repeating: 0, count: 4096)
while !reply.contains(0x0A) {
  let n = read(fd, &buffer, buffer.count)
  if n <= 0 { break }
  reply.append(contentsOf: buffer[0..<n])
}
close(fd)
let line = String(decoding: reply.prefix { $0 != 0x0A }, as: UTF8.self)
guard line.hasPrefix("OK ") else { exit(1) }
print(line.dropFirst(3))
exit(0)
