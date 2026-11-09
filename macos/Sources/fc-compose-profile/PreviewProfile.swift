import Foundation
import CoreText
import CryptoKit
import FreshKit

/// Exercises the same immutable capture / detached prepare / validated handoff
/// as the native preview controller, without opening a window or drawing.
@MainActor
func profilePreviews(input: URL, output: URL) async throws {
  let bytes = try Data(contentsOf: input)
  let body = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
  let code = CTFontCreateWithName("Menlo" as CFString, 18, nil)
  var cold: [Double] = [], plain: [Double] = [], shared: [Double] = []
  var capture: [Double] = [], sharedCapture: [Double] = []
  var identityChecks: [Double] = [], geometryChecks: [Double] = []
  var geometryHash = "", fragmentCount = 0, tableCount = 0

  func request(_ width: CGFloat, hints: [ComposeTableMeasurements] = []) throws -> (ComposePreviewRequest, Double) {
    // Decode separately so content comparisons cannot rely on shared storage.
    let pane = try WireComposePane(serializedBytes: bytes)
    let (request, elapsed) = milliseconds {
      ComposePreviewRequest(pane: pane, body: body, monospace: code, width: width, tableMeasurements: hints)
    }
    guard let request else { throw ProfileFailure.layout("preview capture") }
    return (request, elapsed)
  }
  func prepare(_ request: ComposePreviewRequest) async throws -> (ComposePaneLayout, Double) {
    let start = ProcessInfo.processInfo.systemUptime
    let prepared = try await Task.detached(priority: .userInitiated) { try request.prepare() }.value
    guard let layout = prepared.layout(matching: request) else { throw ProfileFailure.layout("preview handoff") }
    return (layout, (ProcessInfo.processInfo.systemUptime - start) * 1000)
  }

  for iteration in 0..<3 {
    let (baseRequest, _) = try request(960)
    let (base, coldMS) = try await prepare(baseRequest)
    let (plainRequest, captureMS) = try request(640)
    let (sharedRequest, sharedCaptureMS) = try request(640, hints: [base.tableMeasurements])
    let (sameIdentity, identityMS) = milliseconds { plainRequest.isEquivalent(to: sharedRequest) }
    let (sameGeometry, geometryMS) = milliseconds { plainRequest.hasSameGeometry(as: sharedRequest) }
    guard sameIdentity, sameGeometry else { throw ProfileFailure.layout("hint changed request identity") }
    identityChecks.append(identityMS); geometryChecks.append(geometryMS)
    let independent: ComposePaneLayout, reused: ComposePaneLayout
    let plainMS: Double, sharedMS: Double
    // Interleave the controls to reduce systematic first-run ordering effects.
    if iteration % 2 == 0 {
      (independent, plainMS) = try await prepare(plainRequest)
      (reused, sharedMS) = try await prepare(sharedRequest)
    } else {
      (reused, sharedMS) = try await prepare(sharedRequest)
      (independent, plainMS) = try await prepare(plainRequest)
    }
    // Full glyph/font/position/source-map comparison stays outside the timer.
    let reference = try geometry(independent), actual = try geometry(reused)
    guard reference == actual else { throw ProfileFailure.layout("preview hints changed geometry") }
    let hash = SHA256.hash(data: actual).map { String(format: "%02x", $0) }.joined()
    guard geometryHash.isEmpty || geometryHash == hash else { throw ProfileFailure.layout("preview geometry changed between samples") }
    geometryHash = hash; fragmentCount = reused.text.fragments.count; tableCount = reused.text.tables.count
    if iteration == 0 {
      try actual.write(to: output.deletingPathExtension().appendingPathExtension("geometry.json"), options: .atomic)
    }
    cold.append(coldMS); plain.append(plainMS); shared.append(sharedMS)
    capture.append(captureMS); sharedCapture.append(sharedCaptureMS)
  }
  #if DEBUG
  let configuration = "debug"
  #else
  let configuration = "release"
  #endif
  let pane = try WireComposePane(serializedBytes: bytes)
  let report: [String: Any] = [
    "profile": configuration, "pane_bytes": bytes.count,
    "pane_sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
    "source_window": [pane.sourceStart, pane.sourceEnd], "projection_bytes": pane.text.utf8.count,
    "scope": "three serial immutable preview captures, detached preparation and exact-request handoffs; excludes formatting, GUI paint, image I/O and interactive latency",
    "control": "same binary and inputs with no measurement hints; no prior pane/source map supplied to either changed-width worker",
    "body_font": "Helvetica 18", "code_font": "Menlo 18", "initial_width": 960, "changed_width": 640,
    "cold_worker_ms": cold, "resized_without_hints_ms": plain, "resized_with_hints_ms": shared,
    "capture_without_hints_ms": capture, "capture_with_hints_ms": sharedCapture,
    "identity_check_ms": identityChecks, "geometry_check_ms": geometryChecks,
    "fragments": fragmentCount, "tables": tableCount, "geometry_sha256": geometryHash,
    "geometry_equal_each_sample": true, "process_peak_rss_bytes": peakRSS(),
    "rss_scope": "process high-water mark including full geometry JSON comparisons",
  ]
  let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
  try data.write(to: output, options: .atomic)
  print(String(decoding: data, as: UTF8.self))
}
