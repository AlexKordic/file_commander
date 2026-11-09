import AppKit
import OverlayCore

setvbuf(stdout, nil, _IOLBF, 0)

let options: Options
do {
  options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
  fputs("fc-promo-overlay: \(error)\n\n\(Options.usage)\n", stderr)
  exit(2)
}
if options.help {
  print(Options.usage)
  exit(0)
}

let theme: Theme
do {
  theme = try options.theme.map { try Theme.load(Data(contentsOf: $0)) } ?? Theme()
} catch {
  fputs("fc-promo-overlay: theme: \(error)\n", stderr)
  exit(2)
}

if options.printTheme {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  print(String(decoding: (try? encoder.encode(theme)) ?? Data(), as: UTF8.self))
  exit(0)
}

let application = NSApplication.shared
if options.snapshot != nil {
  do {
    try Snapshot.render(options: options, theme: theme)
    exit(0)
  } catch {
    fputs("fc-promo-overlay: snapshot: \(error)\n", stderr)
    exit(1)
  }
}

// The live overlay has no Dock icon and never takes focus from the terminal;
// a replay opens an ordinary window.
application.setActivationPolicy(options.replay == nil ? .accessory : .regular)
let delegate = AppDelegate(options: options, theme: theme)
application.delegate = delegate
application.run()
