import Foundation
import CoreText
import Darwin
import FreshKit

func milliseconds<T>(_ work: () throws -> T) rethrows -> (T, Double) {
  let start = ProcessInfo.processInfo.systemUptime
  let result = try work()
  return (result, (ProcessInfo.processInfo.systemUptime - start) * 1000)
}

func peakRSS() -> Int64 {
  var usage = rusage()
  return getrusage(RUSAGE_SELF, &usage) == 0 ? Int64(usage.ru_maxrss) : 0
}

enum ProfileFailure: Error { case arguments, layout(String), noFixtures }

func profile() throws {
  let args = CommandLine.arguments
  guard args.count == 3 else { throw ProfileFailure.arguments }
  let input = URL(fileURLWithPath: args[1], isDirectory: true), output = URL(fileURLWithPath: args[2])
  let files = try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "pb" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
  guard !files.isEmpty else { throw ProfileFailure.noFixtures }
  let body = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
  let code = CTFontCreateWithName("Menlo" as CFString, 18, nil)
  var records: [[String: Any]] = []
  for file in files {
    let bytes = try Data(contentsOf: file), name = file.deletingPathExtension().lastPathComponent
    var decode: [Double] = [], cold: [Double] = [], retained: [Double] = [], multiple: [Double] = []
    var resized: [Double] = [], returned: [Double] = []
    var sharedMultiple: [Double] = []
    var baseline: ComposePaneLayout?
    for _ in 0..<3 {
      try autoreleasepool {
        let (pane, decodeMS) = try milliseconds { try WireComposePane(serializedBytes: bytes) }
        let (layout, coldMS) = milliseconds { ComposePaneLayout(pane: pane, body: body, monospace: code, width: 960) }
        guard let layout else { throw ProfileFailure.layout(name) }
        let (warm, retainedMS) = milliseconds { ComposePaneLayout(pane: pane, body: body, monospace: code, width: 960, reuse: layout) }
        guard warm?.text === layout.text else { throw ProfileFailure.layout("\(name): unchanged input did not reuse measured layout") }
        let (narrow, resizedMS) = milliseconds { ComposePaneLayout(pane: pane, body: body, monospace: code, width: 640, reuse: layout) }
        guard let narrow else { throw ProfileFailure.layout("\(name): resize failed") }
        let (restored, returnedMS) = milliseconds { ComposePaneLayout(pane: pane, body: body, monospace: code, width: 960, reuse: narrow) }
        guard let restored, restored.text.fragments.count == layout.text.fragments.count,
              restored.text.tables.map(\.columns) == layout.text.tables.map(\.columns) else {
          throw ProfileFailure.layout("\(name): returning to the same width changed the geometry")
        }
        let widths = [CGFloat(480), 640, 960, 480]
        // Distinct decodes model separately delivered split panes; shared
        // inputs must compare by content rather than protobuf storage identity.
        let inputs = try widths.map { _ in try WireComposePane(serializedBytes: bytes) }
        let (independent, multipleMS) = try milliseconds {
          let panes = try zip(inputs, widths).map { input, width in
            guard let value = ComposePaneLayout(pane: input, body: body, monospace: code, width: width) else { throw ProfileFailure.layout(name) }
            return value
          }
          // Retain all four layouts at once, as independent editor splits do.
          precondition(panes.reduce(0) { $0 + $1.text.fragments.count } > 0)
          return panes
        }
        let (shared, sharedMS) = try milliseconds {
          var panes: [ComposePaneLayout] = []
          for (input, width) in zip(inputs, widths) {
            guard let value = ComposePaneLayout(pane: input, body: body, monospace: code, width: width,
              sharingMeasurementsWith: panes) else { throw ProfileFailure.layout(name) }
            panes.append(value)
          }
          return panes
        }
        // Geometry comparison stays outside the timed construction. The first
        // shared pane has no previous provider: this includes its cold cost.
        guard zip(independent, shared).allSatisfy({ a, b in
          a.text.fragments.map(\.range) == b.text.fragments.map(\.range)
            && a.text.fragments.map(\.rect) == b.text.fragments.map(\.rect)
            && a.text.tables.map(\.columns) == b.text.tables.map(\.columns)
        }) else {
          throw ProfileFailure.layout("\(name): sharing changed split geometry")
        }
        decode.append(decodeMS); cold.append(coldMS); retained.append(retainedMS); multiple.append(multipleMS)
        resized.append(resizedMS); returned.append(returnedMS)
        sharedMultiple.append(sharedMS)
        baseline = layout
      }
    }
    let layout = baseline!
    records.append([
      "case": name, "pane_bytes": bytes.count, "projection_bytes": layout.text.projection.text.utf8.count,
      "fragments": layout.text.fragments.count, "attachments": layout.text.attachments.count, "tables": layout.text.tables.count,
      "decode_ms": decode, "cold_layout_ms": cold, "retained_layout_ms": retained, "four_panes_ms": multiple,
      "resized_layout_ms": resized, "returned_layout_ms": returned,
      "shared_four_panes_ms": sharedMultiple,
      "process_peak_rss_bytes": peakRSS(),
    ])
  }
  #if DEBUG
  let configuration = "debug"
  #else
  let configuration = "release"
  #endif
  let report: [String: Any] = [
    "profile": configuration,
    "scope": "protobuf decode and measured native layout; excludes plugin formatting, image I/O/decode, drawing and input-to-paint latency",
    "rss_scope": "process high-water mark since start, including prior cases",
    "body_font": "Helvetica 18", "code_font": "Menlo 18", "width_points": 960,
    "cases": records,
  ]
  let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
  try data.write(to: output, options: .atomic)
  print(String(decoding: data, as: UTF8.self))
}

do { try profile() }
catch {
  FileHandle.standardError.write(Data("Compose resource profile failed: \(error)\nUsage: fc-compose-profile INPUT_DIRECTORY OUTPUT_JSON\n".utf8))
  exit(1)
}
