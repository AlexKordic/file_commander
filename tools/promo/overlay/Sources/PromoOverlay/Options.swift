import CoreGraphics
import Foundation
import OverlayCore

struct Options {
  var socket = "/tmp/fc-promo-overlay.sock"
  var theme: URL?
  var terminalApp = "iTerm2"
  var windowID: CGWindowID?
  var calibrationFile = CalibrationStore.defaultURL
  var replay: URL?
  var speed = 1.0
  var backdrop: URL?
  var grid = (cols: 120, rows: 34)
  var cell = (width: 9.0, height: 19.0)
  var snapshot: URL?
  var at = 0.0
  var headless = false
  var verbose = false
  var printTheme = false
  var help = false

  static let usage = """
  usage: fc-promo-overlay [options]

  Draws captions, highlights, a pointer and key badges over the terminal while
  tools/promo/play.py --overlay drives FC.

    --socket PATH        Unix socket play.py connects to (default /tmp/fc-promo-overlay.sock)
    --theme FILE         theme JSON; lists only the values it changes
    --terminal-app NAME  app that owns the terminal window (default iTerm2)
    --window-id N        follow this window instead of the frontmost terminal window
    --calibration FILE   where calibrations are kept
                         (default ~/Library/Application Support/fc-promo-overlay/calibration.json)

  Replay and preview, without FC:
    --replay FILE        play an events.jsonl written by play.py --events
    --speed N            replay N times faster
    --backdrop FILE      draw a text screen (play.py --screens) on a stand-in window
    --grid COLSxROWS     stand-in grid when the log has no start event (default 120x34)
    --cell WxH           stand-in cell size in points (default 9x19)
    --snapshot OUT.png   render the replay's state at --at SECONDS to a PNG and exit
    --at SECONDS         time for --snapshot

    --headless           no window; print the events received (protocol check)
    --verbose            log the followed window and every event
    --print-theme        print every theme value with its default, as JSON
  """

  struct ParseError: Error, CustomStringConvertible {
    let description: String
  }

  static func parse(_ arguments: [String]) throws -> Options {
    var options = Options()
    var rest = arguments[...]
    func value(_ flag: String) throws -> String {
      guard let next = rest.popFirst() else { throw ParseError(description: "\(flag) needs a value") }
      return next
    }
    func pair(_ flag: String) throws -> (Double, Double) {
      let parts = try value(flag).split(separator: "x").compactMap { Double($0) }
      guard parts.count == 2, parts.allSatisfy({ $0 > 0 }) else { throw ParseError(description: "\(flag) expects AxB") }
      return (parts[0], parts[1])
    }
    while let flag = rest.popFirst() {
      switch flag {
      case "--socket": options.socket = try value(flag)
      case "--theme": options.theme = URL(fileURLWithPath: try value(flag))
      case "--terminal-app": options.terminalApp = try value(flag)
      case "--window-id":
        guard let id = UInt32(try value(flag)) else { throw ParseError(description: "--window-id expects a number") }
        options.windowID = id
      case "--calibration": options.calibrationFile = URL(fileURLWithPath: try value(flag))
      case "--replay": options.replay = URL(fileURLWithPath: try value(flag))
      case "--speed":
        guard let speed = Double(try value(flag)), speed > 0 else { throw ParseError(description: "--speed expects a positive number") }
        options.speed = speed
      case "--backdrop": options.backdrop = URL(fileURLWithPath: try value(flag))
      case "--grid":
        let (cols, rows) = try pair(flag)
        options.grid = (Int(cols), Int(rows))
      case "--cell": options.cell = try pair(flag)
      case "--snapshot": options.snapshot = URL(fileURLWithPath: try value(flag))
      case "--at":
        guard let at = Double(try value(flag)) else { throw ParseError(description: "--at expects seconds") }
        options.at = at
      case "--headless": options.headless = true
      case "--verbose": options.verbose = true
      case "--print-theme": options.printTheme = true
      case "-h", "--help": options.help = true
      default: throw ParseError(description: "unknown option \(flag)")
      }
    }
    if options.snapshot != nil, options.replay == nil { throw ParseError(description: "--snapshot needs --replay") }
    return options
  }
}

/// The stand-in window used by replays and snapshots.
struct PreviewLayout {
  let size: CGSize
  let calibration: Calibration

  init(cols: Int, rows: Int, cell: (width: Double, height: Double)) {
    calibration = Calibration(left: 14, top: 40, cellWidth: cell.width, cellHeight: cell.height)
    size = CGSize(width: 28 + Double(cols) * cell.width, height: 54 + Double(rows) * cell.height)
  }

  /// The recorded terminal size, from the log's first start event.
  static func grid(of events: [TimedEvent], fallback: (cols: Int, rows: Int)) -> (cols: Int, rows: Int) {
    for timed in events {
      if case let .start(cols, rows, _) = timed.event { return (cols, rows) }
    }
    return fallback
  }
}
