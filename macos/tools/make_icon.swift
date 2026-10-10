// Draws File Commander's app icon (two panes and a copy arrow) and writes an
// .iconset folder for iconutil. Usage: swift make_icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ size: Int) -> Data {
  let s = CGFloat(size)
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  // Apple's icon grid: the shape fills about 80% of the canvas.
  let inset = s * 0.1
  let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
  let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
  NSGraphicsContext.current?.saveGraphicsState()
  let shadow = NSShadow()
  shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
  shadow.shadowBlurRadius = s * 0.02
  shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
  shadow.set()
  NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.36, blue: 0.86, alpha: 1), NSColor(srgbRed: 0.05, green: 0.13, blue: 0.42, alpha: 1)])!
    .draw(in: shape, angle: -90)
  NSGraphicsContext.current?.restoreGraphicsState()
  // Two panes.
  let paneWidth = body.width * 0.33, paneHeight = body.height * 0.56
  let top = body.minY + body.height * 0.2
  for (index, x) in [body.minX + body.width * 0.13, body.maxX - body.width * 0.13 - paneWidth].enumerated() {
    let pane = NSRect(x: x, y: top, width: paneWidth, height: paneHeight)
    NSColor.white.withAlphaComponent(index == 0 ? 0.95 : 0.8).setFill()
    NSBezierPath(roundedRect: pane, xRadius: s * 0.025, yRadius: s * 0.025).fill()
    NSColor(srgbRed: 0.16, green: 0.36, blue: 0.86, alpha: 0.85).setFill()
    for row in 0..<4 {
      let line = NSRect(x: pane.minX + paneWidth * 0.14, y: pane.maxY - paneHeight * (0.2 + CGFloat(row) * 0.19),
                        width: paneWidth * (row == 1 ? 0.5 : 0.68), height: paneHeight * 0.07)
      NSBezierPath(roundedRect: line, xRadius: line.height / 2, yRadius: line.height / 2).fill()
    }
  }
  // The copy arrow between them.
  let arrow = NSBezierPath()
  let midY = top + paneHeight * 0.5, left = body.midX - body.width * 0.11, right = body.midX + body.width * 0.11
  arrow.move(to: NSPoint(x: left, y: midY))
  arrow.line(to: NSPoint(x: right - s * 0.04, y: midY))
  arrow.lineWidth = s * 0.035
  arrow.lineCapStyle = .round
  NSColor(srgbRed: 1, green: 0.82, blue: 0.3, alpha: 1).setStroke()
  arrow.stroke()
  let head = NSBezierPath()
  head.move(to: NSPoint(x: right, y: midY))
  head.line(to: NSPoint(x: right - s * 0.07, y: midY + s * 0.055))
  head.line(to: NSPoint(x: right - s * 0.07, y: midY - s * 0.055))
  head.close()
  NSColor(srgbRed: 1, green: 0.82, blue: 0.3, alpha: 1).setFill()
  head.fill()
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
  try render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
  try render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
