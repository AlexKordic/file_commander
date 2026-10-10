// Waits for a process to exit, then opens File Commander again with the given
// arguments. The crash recovery explainer starts it just before the app kills
// itself, so the tutorial can continue after the restart.
//
//   fc-relaunch <pid> <File Commander.app or executable> [arguments...]
import Darwin
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 3, let pid = pid_t(arguments[1]) else {
  FileHandle.standardError.write(Data("usage: fc-relaunch <pid> <app> [arguments...]\n".utf8))
  exit(2)
}
let target = arguments[2]
let extra = Array(arguments.dropFirst(3))

// Leave the parent's session, so its death doesn't take this process along.
setsid()

let queue = kqueue()
var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT), fflags: NOTE_EXIT, data: 0, udata: nil)
var event = kevent()
if kevent(queue, &change, 1, nil, 0, nil) == 0 {
  var timeout = timespec(tv_sec: 30, tv_nsec: 0)
  _ = kevent(queue, nil, 0, &event, 1, &timeout)
}
// The process may have gone before the watch started; either way, wait a moment for the lock to drop.
usleep(300_000)

let process = Process()
if target.hasSuffix(".app") {
  process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
  process.arguments = ["-n", target, "--args"] + extra
} else {
  process.executableURL = URL(fileURLWithPath: target)
  process.arguments = extra
}
do {
  try process.run()
  if target.hasSuffix(".app") { process.waitUntilExit() }
} catch {
  FileHandle.standardError.write(Data("fc-relaunch: \(error)\n".utf8))
  exit(1)
}
