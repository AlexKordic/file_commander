import AppKit
import OverlayCore
import QuartzCore

/// A stand-in terminal window for replays and snapshots: a dark window with a
/// title bar and, optionally, a text screen (play.py --screens output) laid on
/// the same cell grid the overlay uses.
enum Backdrop {
  static func make(size: CGSize, grid: CellGrid, lines: [String], scale: CGFloat) -> CALayer {
    let layer = CALayer()
    layer.frame = CGRect(origin: .zero, size: size)
    layer.backgroundColor = color("#0B0E14")
    layer.cornerRadius = 10
    layer.masksToBounds = true

    let bar = CALayer()
    bar.frame = CGRect(x: 0, y: 0, width: size.width, height: max(0, grid.originY - 6))
    bar.backgroundColor = color("#1C212B")
    layer.addSublayer(bar)
    for (index, hex) in ["#FF5F57", "#FEBC2E", "#28C840"].enumerated() {
      let light = CALayer()
      light.frame = CGRect(x: 14 + Double(index) * 20, y: bar.frame.midY - 6, width: 12, height: 12)
      light.cornerRadius = 6
      light.backgroundColor = color(hex)
      bar.addSublayer(light)
    }

    // Size a monospaced font so one character is exactly one cell wide.
    let probe = NSFont.monospacedSystemFont(ofSize: 100, weight: .regular)
    let advance = textSize("MMMMMMMMMM", font: probe).width / 10 / 100
    let font = NSFont.monospacedSystemFont(ofSize: grid.cellWidth / advance, weight: .regular)
    for (row, line) in lines.prefix(grid.rows).enumerated() {
      let text = makeText(font, color: color("#D8DEE9"), scale: scale, alignment: .left)
      text.isWrapped = false
      text.truncationMode = .none
      text.string = line
      text.frame = CGRect(x: grid.originX, y: grid.originY + Double(row) * grid.cellHeight,
                          width: Double(grid.cols) * grid.cellWidth + grid.cellWidth, height: grid.cellHeight)
      layer.addSublayer(text)
    }
    return layer
  }
}
