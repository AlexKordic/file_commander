import Foundation

/// Explainer tracing for tests: FC_TRACE=1 writes to stderr, `--trace FILE` to a file.
public enum Trace {
  public static let file: FileHandle? = {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--trace"), i + 1 < args.count else { return nil }
    // Appends, so a run that restarts the app keeps one trace.
    if !FileManager.default.fileExists(atPath: args[i + 1]) { FileManager.default.createFile(atPath: args[i + 1], contents: nil) }
    let handle = FileHandle(forWritingAtPath: args[i + 1])
    handle?.seekToEndOfFile()
    return handle
  }()
  public static let enabled = ProcessInfo.processInfo.environment["FC_TRACE"] != nil || file != nil
  public static func write(_ text: String) {
    guard enabled else { return }
    let data = Data((text.hasSuffix("\n") ? text : text + "\n").utf8)
    if let file { file.write(data) } else { FileHandle.standardError.write(data) }
  }
}
