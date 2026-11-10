import AppKit
import CoreImage
import CoreText
import CryptoKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Image-first recording. The manifest and PNGs are the editable source of the
/// movie; no host application types or commands enter this capture adapter.
public final class TutorialFrameRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  public struct Geometry: Codable, Equatable, Sendable {
    public var x, y, pointsWidth, pointsHeight, scale: Double
    public var width, height: Int
    public init(frame: CGRect, scale: CGFloat) {
      x = frame.minX; y = frame.minY; pointsWidth = frame.width; pointsHeight = frame.height
      self.scale = scale
      // One explicit pixel of padding where needed, never a hidden crop.
      width = (Int((frame.width * scale).rounded()) + 1) / 2 * 2
      height = (Int((frame.height * scale).rounded()) + 1) / 2 * 2
    }
    public var frame: CGRect { CGRect(x: x, y: y, width: pointsWidth, height: pointsHeight) }
  }

  public enum Failure: LocalizedError {
    case recording(String)
    public var errorDescription: String? { if case .recording(let text) = self { return text }; return nil }
  }

  private let state = NSLock()
  private let receive = DispatchQueue(label: "tutorial.capture.receive", qos: .userInitiated)
  private let writes = DispatchQueue(label: "tutorial.capture.png", qos: .userInitiated)
  private let context = CIContext(options: [.cacheIntermediates: false])
  private var stream: SCStream?
  private var folder: URL?
  private var journal: FileHandle?
  private var lesson: [String: String] = [:]
  private var geometry: Geometry?
  private var origin: Int64?
  private var anchorHost: Int64 = 0
  private var anchorUTC: Int64 = 0
  private var pending = 0
  private var failures: [String] = []
  private var frames: [[String: Any]] = []  // writes queue owns these collections
  private var previousPixels: SHA256.Digest?
  private var previousImage: Data?
  private var lastPTS: Int64 = -1
  private var sequence = 0
  private var owner = (lesson: "", step: "preparing")
  private var accepting = false
  private var fps = 30
  private var sourceSamples = 0
  private var coalescedSamples = 0
  private var incompleteSamples = 0
  private var previousEvent: Int64 = 0
  private var suspended = false
  private var sourceFloor: Int64 = 0
  private var lastSourceAbsolute: Int64 = 0
  private var transitionSamples = 0

  public override init() {}

  private static func hostNow() -> Int64 {
    CMTimeConvertScale(CMClockGetTime(CMClockGetHostTimeClock()), timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
  }

  public var elapsedNanoseconds: Int64 {
    state.lock(); let origin = self.origin; state.unlock()
    return max(0, Self.hostNow() - (origin ?? Self.hostNow()))
  }

  public var originNanoseconds: Int64? {
    state.lock(); defer { state.unlock() }
    return origin
  }

  public var failure: String? {
    state.lock(); defer { state.unlock() }
    return failures.first
  }

  public func fail(_ reason: String) {
    state.lock(); defer { state.unlock() }
    if !failures.contains(reason) { failures.append(reason) }
  }

  /// Starts a single take. Waits until the first PNG write completes, so actions do
  /// not race ahead of screen-capture initialization.
  public func start(folder: URL, lesson: [String: String], geometry: Geometry, fps: Int = 30,
                    excludingWindows: Set<UInt32> = [], includingProcessIDs: Set<pid_t>? = nil,
                    includingWindowIDs: Set<UInt32>? = nil) async throws {
    guard (1...60).contains(fps), geometry.width > 0, geometry.height > 0 else {
      throw Failure.recording("Invalid tutorial capture geometry or frame rate")
    }
    guard self.folder == nil else { throw Failure.recording("A recorder instance can only own one take") }
    let fm = FileManager.default
    guard !fm.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) else {
      throw Failure.recording("This take already exists; choose a new output directory")
    }
    try fm.createDirectory(at: folder.appendingPathComponent("frames"), withIntermediateDirectories: true)
    let journalURL = folder.appendingPathComponent("events.jsonl")
    guard fm.createFile(atPath: journalURL.path, contents: nil) else { throw Failure.recording("Cannot create capture journal") }
    journal = try FileHandle(forWritingTo: journalURL)
    self.folder = folder; self.lesson = lesson; self.geometry = geometry; self.fps = fps
    owner = (lesson["id"] ?? "lesson", "preparing")
    anchorHost = Self.hostNow()
    anchorUTC = Int64((Date().timeIntervalSince1970 * 1_000_000_000).rounded())
    var manifest: [String: Any] = ["schema": 1, "status": "recording", "width": geometry.width, "height": geometry.height,
                                  "fps": fps, "lesson": lesson, "frames": []]
    manifest["geometry"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(geometry))
    try saveManifest(manifest)
    let (filter, config) = try await ExplainerRecorder.setup(region: geometry.frame, excludingWindows: excludingWindows,
                                                           includingProcessIDs: includingProcessIDs, includingWindowIDs: includingWindowIDs)
    config.width = geometry.width; config.height = geometry.height
    config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(fps))
    config.queueDepth = 5
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.colorSpaceName = CGColorSpace.sRGB
    config.capturesAudio = false
    state.withLock { accepting = true }
    let stream = SCStream(filter: filter, configuration: config, delegate: self)
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: receive)
    self.stream = stream
    do {
      try await stream.startCapture()
      for _ in 0..<200 {
        if let failure { throw Failure.recording(failure) }
        let ready = await withCheckedContinuation { continuation in
          writes.async { continuation.resume(returning: !self.frames.isEmpty) }
        }
        if ready { return }
        try await Task.sleep(for: .milliseconds(25))
      }
      throw Failure.recording("Screen capture did not deliver an initial image within five seconds")
    } catch {
      fail(error.localizedDescription)
      _ = try? await stop()
      throw error
    }
  }

  public func setOwner(lesson: String, step: String) {
    state.lock(); owner = (lesson, step); state.unlock()
  }

  public func stream(_ stream: SCStream, didStopWithError error: Error) {
    fail("Screen capture stopped unexpectedly: \(error.localizedDescription)")
  }

  /// Timestamp admission on the host clock, not eventual journal/PNG write time.
  public func event(_ type: String, fields: [String: Any] = [:], hostNanoseconds: Int64? = nil) {
    state.lock(); let origin = self.origin; state.unlock()
    let timestamp = hostNanoseconds.map { max(0, $0 - (origin ?? $0)) } ?? elapsedNanoseconds
    writes.async {
      guard let journal = self.journal else { return }
      var event = fields
      event["type"] = type
      event["pts_ns"] = max(self.previousEvent, timestamp)
      self.previousEvent = max(self.previousEvent, timestamp)
      do {
        var data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        data.append(0x0a)
        try journal.write(contentsOf: data)
      } catch { self.fail("Cannot write tutorial event: \(error.localizedDescription)") }
    }
  }

  public func updateProcesses(_ processIDs: Set<pid_t>, excludingWindows: Set<UInt32> = [],
                              includingWindowIDs: Set<UInt32>? = nil, resume: Bool = false) async throws {
    guard let geometry, let stream else { throw Failure.recording("Capture is not active") }
    let (filter, _) = try await ExplainerRecorder.setup(region: geometry.frame, excludingWindows: excludingWindows,
                                                       includingProcessIDs: processIDs, includingWindowIDs: includingWindowIDs)
    try await stream.updateContentFilter(filter)
    if resume {
      let floor = Self.hostNow()
      state.withLock {
        sourceFloor = floor
        writes.async { self.previousPixels = nil }
        suspended = false
      }
      for _ in 0..<200 {
        if let failure { throw Failure.recording(failure) }
        if state.withLock({ lastSourceAbsolute >= floor }) { return }
        try await Task.sleep(for: .milliseconds(25))
      }
      throw Failure.recording("The replacement tutorial window did not deliver an image within five seconds")
    }
  }

  /// A generated image explicitly marks intentional application downtime. The
  /// recorder never falls back to capturing the desktop or another app.
  public func showRestartCard() async throws {
    state.withLock { suspended = true }
    let at = elapsedNanoseconds
    let owner = state.withLock { self.owner }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      writes.async {
        do {
          guard let geometry = self.geometry,
                let canvas = CGContext(data: nil, width: geometry.width, height: geometry.height,
                                       bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure.recording("Cannot draw the restart transition")
          }
          canvas.setFillColor(CGColor(red: 0.055, green: 0.075, blue: 0.10, alpha: 1))
          canvas.fill(CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height))
          let lines = [("Restarting the application", 0.038, 0.54),
                       ("The tutorial continues when the application returns.", 0.018, 0.46)]
          for (text, size, y) in lines {
            let font = CTFontCreateWithName("Helvetica" as CFString, CGFloat(geometry.width) * size, nil)
            let string = NSAttributedString(string: text, attributes: [
              NSAttributedString.Key(kCTFontAttributeName as String): font,
              NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.95, alpha: 1)])
            let line = CTLineCreateWithAttributedString(string)
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            canvas.textPosition = CGPoint(x: (Double(geometry.width) - width) / 2, y: Double(geometry.height) * y)
            CTLineDraw(line, canvas)
          }
          guard let image = canvas.makeImage() else { throw Failure.recording("Cannot render the restart transition") }
          let output = NSMutableData()
          guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.recording("Cannot encode the restart transition")
          }
          CGImageDestinationAddImage(destination, image, nil)
          guard CGImageDestinationFinalize(destination) else { throw Failure.recording("Cannot save the restart transition") }
          let data = output as Data
          try self.persist(data, at: at, absolute: (self.origin ?? self.anchorHost) + at, source: nil, owner: owner,
                           generated: "application_restart")
          self.previousImage = data; self.previousPixels = nil
          continuation.resume()
        } catch { self.fail(error.localizedDescription); continuation.resume(throwing: error) }
      }
    }
    event("restart_card")
  }

  public func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen, buffer.isValid,
          let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
          let rawStatus = attachments.first?[.status] as? Int else { return }
    if rawStatus == SCFrameStatus.idle.rawValue { return }
    guard rawStatus == SCFrameStatus.complete.rawValue else {
      state.lock(); incompleteSamples += 1; state.unlock()
      return
    }
    guard let pixels = buffer.imageBuffer else { fail("Capture delivered a frame without pixels"); return }
    let sampleTime = buffer.presentationTimeStamp
    let absolute = CMTimeConvertScale(sampleTime, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
    state.lock()
    guard accepting else { state.unlock(); return }
    if suspended || absolute < sourceFloor { transitionSamples += 1; state.unlock(); return }
    if pending >= 8 { state.unlock(); fail("PNG output cannot keep up with capture; this take is incomplete"); return }
    if origin == nil { origin = absolute }
    let time = max(0, absolute - origin!)
    let owner = self.owner
    pending += 1; sourceSamples += 1
    state.unlock()
    writes.async {
      defer { self.state.lock(); self.pending -= 1; self.state.unlock() }
      do {
        try self.write(pixels, at: time, absolute: absolute, source: sampleTime, owner: owner)
        self.state.withLock { self.lastSourceAbsolute = absolute }
      } catch { self.fail(error.localizedDescription) }
    }
  }

  /// Finish admitted writes without advancing the image clock. ScreenCaptureKit
  /// may still deliver an older presentation timestamp after this host-clock
  /// marker; static holds belong in durations, not synthetic future PNGs.
  public func flushFrames() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      writes.async {
        continuation.resume()
      }
    }
  }

  private func write(_ pixels: CVPixelBuffer, at time: Int64, absolute: Int64, source: CMTime,
                     owner: (lesson: String, step: String)) throws {
    guard let geometry, CVPixelBufferGetWidth(pixels) == geometry.width, CVPixelBufferGetHeight(pixels) == geometry.height else {
      throw Failure.recording("Screen-capture dimensions changed during the take")
    }
    CVPixelBufferLockBaseAddress(pixels, .readOnly)
    var hash = SHA256()
    if let base = CVPixelBufferGetBaseAddress(pixels) {
      for row in 0..<geometry.height {
        hash.update(bufferPointer: UnsafeRawBufferPointer(start: base.advanced(by: row * CVPixelBufferGetBytesPerRow(pixels)), count: geometry.width * 4))
      }
    }
    CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
    let fingerprint = hash.finalize()
    if previousPixels == fingerprint { coalescedSamples += 1; return }
    let input = CIImage(cvPixelBuffer: pixels)
    guard let image = context.createCGImage(input, from: input.extent) else { throw Failure.recording("Cannot prepare capture image") }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
      throw Failure.recording("Cannot encode capture PNG")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw Failure.recording("PNG encoding failed") }
    let data = output as Data
    try persist(data, at: time, absolute: absolute, source: source, owner: owner)
    previousPixels = fingerprint
    previousImage = data
  }

  private func persist(_ data: Data, at time: Int64, absolute: Int64, source: CMTime?, owner: (lesson: String, step: String), generated: String? = nil) throws {
    guard let folder else { throw Failure.recording("Capture output is not open") }
    guard time > lastPTS else {
      throw Failure.recording("A changed capture image arrived behind a retained timestamp; this take is incomplete")
    }
    let wall = anchorUTC + absolute - anchorHost
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss"
    let utc = formatter.string(from: Date(timeIntervalSince1970: Double(wall / 1_000_000_000))) + String(format: "%06lldZ", (wall % 1_000_000_000) / 1000)
    let safe: (String) -> String = { $0.replacingOccurrences(of: "[^a-zA-Z0-9_.-]", with: "-", options: .regularExpression) }
    let filename = String(format: "frame_%018lldns_\(utc)_f%06d_l-\(safe(owner.lesson))_s-\(safe(owner.step)).png", time, sequence)
    let path = "frames/" + filename
    try data.write(to: folder.appendingPathComponent(path), options: .atomic)
    var frame: [String: Any] = ["pts_ns": time, "utc": utc, "sequence": sequence, "path": path,
                                "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                                "lesson": owner.lesson, "step": owner.step]
    if let source { frame["source_timestamp"] = ["value": source.value, "timescale": source.timescale] }
    if let generated { frame["generated"] = generated }
    frames.append(frame); lastPTS = time; sequence += 1
  }

  @discardableResult
  public func stop() async throws -> URL {
    guard let folder, let geometry else { throw Failure.recording("There is no open tutorial take") }
    do { try await stream?.stopCapture() }
    catch { fail("Screen capture did not stop cleanly: \(error.localizedDescription)") }
    stream = nil
    state.withLock { accepting = false }
    return try await withCheckedThrowingContinuation { continuation in
      writes.async {
        do {
          try self.journal?.synchronize()
          try self.journal?.close(); self.journal = nil
          self.state.lock()
          let failures = self.failures
          let origin = self.origin
          let sourceSamples = self.sourceSamples, incomplete = self.incompleteSamples, transitionSamples = self.transitionSamples
          self.state.unlock()
          let duration = max(self.lastPTS + 1, self.elapsedNanoseconds)
          let manifest: [String: Any] = [
            "schema": 1, "status": failures.isEmpty && !self.frames.isEmpty ? "complete" : "failed",
            "width": geometry.width, "height": geometry.height, "fps": self.fps,
            "geometry": try JSONSerialization.jsonObject(with: JSONEncoder().encode(geometry)),
            "clock": ["origin_host_ns": origin ?? self.anchorHost, "anchor_host_ns": self.anchorHost, "anchor_utc_ns": self.anchorUTC],
            "duration_ns": duration, "lesson": self.lesson, "frames": self.frames,
            "source_samples": sourceSamples, "coalesced_samples": self.coalescedSamples,
            "incomplete_samples": incomplete, "errors": failures,
            "intentional_transition_samples": transitionSamples,
            "provenance": ["platform": "macOS", "os": ProcessInfo.processInfo.operatingSystemVersionString]]
          try self.saveManifest(manifest)
          if let failure = failures.first { throw Failure.recording(failure) }
          guard !self.frames.isEmpty else { throw Failure.recording("No tutorial images were saved") }
          continuation.resume(returning: folder.appendingPathComponent("manifest.json"))
        } catch { continuation.resume(throwing: error) }
      }
    }
  }

  private func saveManifest(_ value: [String: Any]) throws {
    guard let folder else { return }
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
    try data.write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
  }
}
