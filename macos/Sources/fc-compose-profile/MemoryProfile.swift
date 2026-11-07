import Foundation
import CoreText
import Darwin
import FreshKit
import CryptoKit

/// Current memory and live malloc allocation complement the process
/// high-water mark. A high-water mark alone cannot identify retained layouts.
private func memorySample() throws -> [String: Any] {
  var info = task_vm_info_data_t()
  var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
  let capacity = Int(count)
  let status = withUnsafeMutablePointer(to: &info) { pointer in
    pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
      task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
    }
  }
  guard status == KERN_SUCCESS else { throw ProfileFailure.layout("task_info: \(status)") }
  var allocation = malloc_statistics_t()
  // The SDK defines a nil zone as the sum across all malloc zones.
  malloc_zone_statistics(nil, &allocation)
  return ["resident_bytes": info.resident_size, "physical_footprint_bytes": info.phys_footprint,
    "process_peak_rss_bytes": peakRSS(), "malloc_live_bytes": allocation.size_in_use,
    "malloc_live_blocks": allocation.blocks_in_use]
}

/// All layouts remain live through the post-pool sample, then are explicitly
/// released. No views, image decoding, backend or geometry JSON are involved.
func profileMemory(input: URL, output: URL) throws {
  let data = try Data(contentsOf: input), pane = try WireComposePane(serializedBytes: data)
  let body = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
  let code = CTFontCreateWithName("Menlo" as CFString, 18, nil)
  let batches: [(String, [CGFloat])] = [
    ("one-pane", [960]), ("four-panes", [960, 960, 960, 960]), ("four-widths", [480, 640, 960, 480]),
  ]
  var samples: [[String: Any]] = []
  func record(_ phase: String, batch: String, iteration: Int, layouts: [ComposePaneLayout], milliseconds: Double? = nil) throws {
    var sample = try memorySample()
    sample["phase"] = phase; sample["batch"] = batch; sample["iteration"] = iteration
    sample["live_panes"] = layouts.count
    sample["live_fragments"] = layouts.reduce(0) { $0 + $1.text.fragments.count }
    if let milliseconds { sample["layout_ms"] = milliseconds }
    samples.append(sample)
  }
  try record("baseline", batch: "none", iteration: 0, layouts: [])
  for iteration in 0..<3 {
    for (name, widths) in batches {
      var held: [ComposePaneLayout] = []
      try autoreleasepool {
        let (layouts, elapsed) = try milliseconds {
          try widths.map { width -> ComposePaneLayout in
            guard let layout = ComposePaneLayout(pane: pane, body: body, monospace: code, width: width) else {
              throw ProfileFailure.layout("memory: \(name), width \(width)")
            }
            return layout
          }
        }
        held = layouts
        try withExtendedLifetime(held) {
          try record("before-pool-drain", batch: name, iteration: iteration, layouts: held, milliseconds: elapsed)
        }
      }
      try withExtendedLifetime(held) {
        try record("live-after-pool-drain", batch: name, iteration: iteration, layouts: held)
      }
      held.removeAll()
      try record("released", batch: name, iteration: iteration, layouts: held)
    }
  }
  #if DEBUG
  let configuration = "debug"
  #else
  let configuration = "release"
  #endif
  let report: [String: Any] = [
    "profile": configuration, "os": ProcessInfo.processInfo.operatingSystemVersionString,
    "scope": "Layout-only live/released memory; malloc statistics sum all zones, and task_info also covers non-malloc memory. No GUI, image decoding, backend, or geometry serialization. Samples lie outside layout timing.",
    "input": input.lastPathComponent, "input_bytes": data.count,
    "input_sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
    "projection_bytes": pane.text.utf8.count, "body_font": "Helvetica 18", "code_font": "Menlo 18",
    "samples": samples,
  ]
  try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: output, options: .atomic)
}
