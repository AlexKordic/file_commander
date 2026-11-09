import AppKit
import AVFoundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Records the host app's windows (annotations included) inside a screen
/// region to an H.264 movie with ScreenCaptureKit. Needs the Screen Recording
/// permission, which is asked for only when recording starts.
public final class ExplainerRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
  private let lock = NSLock()
  private var stream: SCStream?
  private var writer: AVAssetWriter?
  private var input: AVAssetWriterInput?
  private var sessionStarted = false
  private let queue = DispatchQueue(label: "explainer.recorder")
  private var filter: SCContentFilter?
  private var configuration: SCStreamConfiguration?

  public override init() {}

  /// Starts recording `region` (screen coordinates, bottom-left origin) to `output`.
  public func start(region: CGRect, output: URL) async throws {
    let (filter, configuration) = try await ExplainerRecorder.setup(region: region)
    self.filter = filter
    self.configuration = configuration
    try? FileManager.default.removeItem(at: output)
    let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: configuration.width,
      AVVideoHeightKey: configuration.height,
      AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000, AVVideoExpectedSourceFrameRateKey: 30],
    ])
    input.expectsMediaDataInRealTime = true
    writer.add(input)
    writer.startWriting()
    lock.withLock {
      self.writer = writer
      self.input = input
      self.sessionStarted = false
    }
    let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    try await stream.startCapture()
    self.stream = stream
  }

  public func stop() async {
    try? await stream?.stopCapture()
    stream = nil
    let (writer, input) = lock.withLock { (self.writer, self.input) }
    input?.markAsFinished()
    await writer?.finishWriting()
    lock.withLock {
      self.writer = nil
      self.input = nil
    }
  }

  public func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen, buffer.isValid,
          let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
          let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
    lock.withLock {
      guard let writer, let input else { return }
      if !sessionStarted {
        writer.startSession(atSourceTime: buffer.presentationTimeStamp)
        sessionStarted = true
      }
      if input.isReadyForMoreMediaData { input.append(buffer) }
    }
  }

  /// One still of `region`, as PNG.
  public static func still(region: CGRect, to url: URL) async throws {
    let (filter, configuration) = try await setup(region: region)
    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
  }

  /// An animated GIF from stills, for README previews.
  public static func gif(from images: [URL], to url: URL, secondsPerFrame: Double = 1.6, maxWidth: CGFloat = 960) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, images.count, nil) else { return }
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for file in images {
      guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                       kCGImageSourceThumbnailMaxPixelSize: maxWidth] as CFDictionary) else { continue }
      CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: secondsPerFrame]] as CFDictionary)
    }
    CGImageDestinationFinalize(destination)
  }

  private static func setup(region: CGRect) async throws -> (SCContentFilter, SCStreamConfiguration) {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let screens = await MainActor.run { NSScreen.screens.map { ($0.frame, $0.backingScaleFactor, $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) } }
    guard let (screenFrame, scale, displayID) = screens.first(where: { $0.0.intersects(region) }) ?? screens.first,
          let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
      throw NSError(domain: "ExplainerKit", code: 2, userInfo: [NSLocalizedDescriptionKey: "No display to record"])
    }
    let apps = content.applications.filter { $0.processID == getpid() }
    let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
    let configuration = SCStreamConfiguration()
    // ScreenCaptureKit measures from the display's top left, in points.
    let local = CGRect(x: region.minX - screenFrame.minX, y: screenFrame.maxY - region.maxY, width: region.width, height: region.height)
    configuration.sourceRect = local
    configuration.width = Int(region.width * scale) / 2 * 2
    configuration.height = Int(region.height * scale) / 2 * 2
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    configuration.showsCursor = false
    configuration.scalesToFit = false
    return (filter, configuration)
  }
}

/// Captions and pages made from a run's timeline.
public enum ExplainerExport {
  public struct Cue: Sendable {
    public var start: Double, end: Double
    public var title: String, subtitle: String
  }

  public static func cues(_ timeline: [TimelineEvent], end: Double) -> [Cue] {
    var cues: [Cue] = []
    for event in timeline where event.kind == "caption" || event.kind == "uncaption" {
      if var last = cues.popLast() {
        last.end = event.time
        cues.append(last)
      }
      if event.kind == "caption" { cues.append(Cue(start: event.time, end: end, title: event.text, subtitle: event.detail)) }
    }
    return cues.filter { $0.end > $0.start }
  }

  private static func stamp(_ t: Double, separator: String) -> String {
    let ms = Int((t * 1000).rounded())
    return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, separator, ms % 1000)
  }

  public static func srt(_ cues: [Cue]) -> String {
    cues.enumerated().map { i, c in
      "\(i + 1)\n\(stamp(c.start, separator: ",")) --> \(stamp(c.end, separator: ","))\n\(c.title)" + (c.subtitle.isEmpty ? "" : "\n\(c.subtitle)") + "\n"
    }.joined(separator: "\n")
  }

  public static func vtt(_ cues: [Cue]) -> String {
    "WEBVTT\n\n" + cues.map { c in
      "\(stamp(c.start, separator: ".")) --> \(stamp(c.end, separator: "."))\n\(c.title)" + (c.subtitle.isEmpty ? "" : "\n\(c.subtitle)") + "\n"
    }.joined(separator: "\n")
  }

  /// A README-style page: summary, video, and each caption with its still.
  /// With light and dark media, images use <picture> so GitHub matches the reader's theme.
  public static func markdown(script: ExplainerScript, cues: [Cue], stills: [String: [String]], video: String?, preview: String?) -> String {
    var out = "# \(script.title)\n\n\(script.summary)\n\n"
    if let preview { out += "![\(script.title)](\(preview))\n\n" }
    if let video { out += "Video: [\(video)](\(video)), captions in `\(script.id).srt` and `\(script.id).vtt`.\n\n" }
    for (i, cue) in cues.enumerated() {
      out += "## \(i + 1). \(cue.title)\n\n"
      if !cue.subtitle.isEmpty { out += "\(cue.subtitle)\n\n" }
      let key = String(format: "%02d", i + 1)
      if let images = stills[key] {
        if images.count == 2 {
          out += "<picture>\n  <source media=\"(prefers-color-scheme: dark)\" srcset=\"\(images[1])\">\n  <img alt=\"\(cue.title)\" src=\"\(images[0])\">\n</picture>\n\n"
        } else if let image = images.first {
          out += "![\(cue.title)](\(image))\n\n"
        }
      }
    }
    return out
  }
}
