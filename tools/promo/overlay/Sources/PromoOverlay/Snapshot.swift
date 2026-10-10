import AppKit
import ImageIO
import OverlayCore
import UniformTypeIdentifiers

/// Renders the overlay's state at one moment of a recorded run to a PNG, with
/// animations off, so layouts can be checked without opening a window.
enum Snapshot {
  struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  static func render(options: Options, theme: Theme) throws {
    guard let replay = options.replay, let output = options.snapshot else { return }
    Motion.animated = false
    let events = try EventLog.load(replay)
    let grid = PreviewLayout.grid(of: events, fallback: options.grid)
    let layout = PreviewLayout(cols: grid.cols, rows: grid.rows, cell: options.cell)
    let scale: CGFloat = 2
    let scheduler = VirtualScheduler()
    let controller = OverlayController(theme: theme, scheduler: scheduler, calibration: layout.calibration, scale: scale)
    controller.resize(layout.size)
    controller.handle(TimedEvent(time: 0, event: .start(cols: grid.cols, rows: grid.rows, title: "")))
    for timed in events where timed.time <= options.at {
      scheduler.advance(to: timed.time)
      controller.handle(timed)
    }
    scheduler.advance(to: options.at)
    let lines = try options.backdrop.map { try String(contentsOf: $0, encoding: .utf8).components(separatedBy: "\n") } ?? []
    controller.setBackdrop(Backdrop.make(size: layout.size, grid: controller.grid, lines: lines, scale: scale))
    CATransaction.flush()

    let width = Int(layout.size.width * scale), height = Int(layout.size.height * scale)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw Failure(description: "cannot create a \(width)x\(height) bitmap") }
    // The root layer's geometry is flipped (y down); a bitmap context's y axis
    // points up, so flip the context to match.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: scale, y: -scale)
    controller.root.render(in: context)
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw Failure(description: "cannot write \(output.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw Failure(description: "cannot write \(output.path)") }
  }
}
