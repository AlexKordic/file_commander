import Foundation
import Observation
import SwiftProtobuf

/// A color from the scene.
public struct SceneColor: Hashable, Sendable {
  public var red, green, blue: UInt8

  public init(red: UInt8, green: UInt8, blue: UInt8) {
    self.red = red
    self.green = green
    self.blue = blue
  }

  /// `0xRRGGBB`, as the scene carries colors.
  public init(packed: UInt32) {
    self.init(red: UInt8(packed >> 16 & 0xFF), green: UInt8(packed >> 8 & 0xFF), blue: UInt8(packed & 0xFF))
  }
}

/// A run of cells with one style. Each `Character` of `text` fills one cell; a
/// wide character is followed by the blank cell it covers, as Fresh draws it.
public struct CellRun: Equatable, Sendable {
  public var text: String
  public var foreground, background: SceneColor?
  public var bold, italic, underline, reverse: Bool
  /// How many cells the run covers.
  public var cells: Int

  public init(text: String, foreground: SceneColor? = nil, background: SceneColor? = nil,
              bold: Bool = false, italic: Bool = false, underline: Bool = false, reverse: Bool = false) {
    self.text = text
    self.foreground = foreground
    self.background = background
    self.bold = bold
    self.italic = italic
    self.underline = underline
    self.reverse = reverse
    cells = text.count
  }

  /// A grid row's runs: its text, cut at each run's byte length, with each
  /// run's style (fg | bg << 25 | flags << 50; a color 0x1RRGGBB, 0 for the
  /// default; flags bold 1, italic 2, underline 4, reverse 8).
  public static func runs(_ row: WireGridRow) -> [CellRun] {
    var out: [CellRun] = []
    out.reserveCapacity(row.runBytes.count)
    let utf8 = row.text.utf8
    var start = utf8.startIndex
    for (length, style) in zip(row.runBytes, row.runStyles) {
      let end = utf8.index(start, offsetBy: Int(length), limitedBy: utf8.endIndex) ?? utf8.endIndex
      let color = { (c: UInt64) -> SceneColor? in c & 1 << 24 != 0 ? SceneColor(packed: UInt32(c & 0xFF_FFFF)) : nil }
      let flags = style >> 50
      out.append(CellRun(text: String(decoding: utf8[start..<end], as: UTF8.self), foreground: color(style & 0x1FF_FFFF),
                         background: color(style >> 25 & 0x1FF_FFFF), bold: flags & 1 != 0, italic: flags & 2 != 0,
                         underline: flags & 4 != 0, reverse: flags & 8 != 0))
      start = end
    }
    return out
  }

  /// A popup line's spans as runs.
  public static func runs(_ line: WirePopupLine) -> [CellRun] {
    line.spans.map {
      CellRun(text: $0.text, foreground: $0.hasFg ? SceneColor(packed: $0.fg) : nil, background: $0.hasBg ? SceneColor(packed: $0.bg) : nil,
              bold: $0.bold, italic: $0.italic, underline: $0.underline, reverse: $0.reverse)
    }
  }
}

/// A rectangle of cells.
public struct CellRect: Equatable, Sendable {
  public var x, y, width, height: Int

  public init(x: Int, y: Int, width: Int, height: Int) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public init(_ rect: WireRect) {
    self.init(x: Int(rect.x), y: Int(rect.y), width: Int(rect.w), height: Int(rect.h))
  }

  public func contains(column: Int, row: Int) -> Bool {
    column >= x && column < x + width && row >= y && row < y + height
  }
}

/// The colors of Fresh's theme that chrome is drawn with.
public struct SceneTheme: Equatable, Sendable {
  public var name = ""
  public var background, foreground, accent, muted, selection: SceneColor?
  public var menuBackground, menuForeground, menuHighlight, menuHighlightForeground: SceneColor?
  public var popupBackground, popupForeground, border: SceneColor?
  public var statusBackground, statusForeground, tabActiveBackground: SceneColor?

  public init() {}

  init(_ t: WireTheme) {
    let color = { (has: Bool, value: UInt32) in has ? SceneColor(packed: value) : nil }
    name = t.name
    background = color(t.hasBg, t.bg)
    foreground = color(t.hasFg, t.fg)
    accent = color(t.hasAccent, t.accent)
    muted = color(t.hasMuted, t.muted)
    selection = color(t.hasSelectionBg, t.selectionBg)
    menuBackground = color(t.hasMenuBg, t.menuBg)
    menuForeground = color(t.hasMenuFg, t.menuFg)
    menuHighlight = color(t.hasMenuHi, t.menuHi)
    menuHighlightForeground = color(t.hasMenuHighlightFg, t.menuHighlightFg)
    popupBackground = color(t.hasPopupBg, t.popupBg)
    popupForeground = color(t.hasPopupFg, t.popupFg)
    border = color(t.hasBorder, t.border)
    statusBackground = color(t.hasStatusBg, t.statusBg)
    statusForeground = color(t.hasStatusFg, t.statusFg)
    tabActiveBackground = color(t.hasTabActiveBg, t.tabActiveBg)
  }

  /// Whether text on the editor background should be light.
  public var isDark: Bool {
    guard let bg = background else { return true }
    return 0.299 * Double(bg.red) + 0.587 * Double(bg.green) + 0.114 * Double(bg.blue) < 128
  }
}

/// Fresh's timing for one frame, sent while telemetry is on.
public struct FrameTiming: Sendable {
  /// How many of this client's messages Fresh had applied when it built the frame.
  public var ack: Int
  /// Building the scene, and encoding it and this frame, in ms.
  public var buildMs, diffMs: Double
  /// Of building: rendering the editor into cells, and hashing the grid's rows, in ms.
  public var renderMs, gridMs: Double
  /// Bytes of earlier frames still queued for the socket ahead of this one.
  public var queued: Int
  /// Earlier frames this client had not yet applied when this one was sent.
  public var ahead: Int
  /// Wheel lines Fresh's smooth scrolling still owes.
  public var owed: Int
  /// The line at the top of the active view (0-based).
  public var top: Int
  /// Fresh's CPU time so far, in ms.
  public var cpuMs: Double
  /// Allocations and bytes of Fresh's previous push (an `alloc-stats` build).
  public var prevAllocs, prevAllocBytes: Int?

  init(_ t: WireTiming) {
    ack = Int(t.ack)
    buildMs = t.buildMs
    diffMs = t.encodeMs
    renderMs = t.renderMs
    gridMs = t.gridMs
    queued = Int(t.queued)
    ahead = Int(t.ahead)
    owed = Int(t.owed)
    top = Int(t.top)
    cpuMs = t.cpuMs
    prevAllocs = t.hasPrevAllocs ? Int(t.prevAllocs) : nil
    prevAllocBytes = t.hasPrevAllocBytes ? Int(t.prevAllocBytes) : nil
  }
}

/// One message from Fresh, decoded off the main thread: a `ServerHello`'s
/// whole scene or a `Frame`, with its grid rows already turned into runs.
public struct SceneMessage: @unchecked Sendable {
  public let isHello: Bool
  /// Present only in the server's initial hello.
  public let protocolVersion: UInt32?
  /// Advertised by the initial hello; false for frames and older backends.
  public let composeRegionProbes: Bool
  public let nativePopupProjection: Bool
  public let composeSourceSelections: Bool
  public let composeSemanticIndex: Bool
  public let composeDocumentText: Bool
  public let composeDocumentUpdates: Bool
  public let sequence: Int
  /// What changed (everything, for a hello).
  public let frame: WireFrame
  /// Rows sent in full, decoded, by row index.
  public let gridRows: [Int: [CellRun]]
  /// Rows the client already has, by where they were in its previous frame:
  /// rows `to..<to+count` become the previous `from..<from+count`.
  public let gridCopies: [(to: Int, from: Int, count: Int)]
  /// The new number of grid rows, when it changed.
  public let gridCount: Int?
  /// Fresh's timing, when the client asked for telemetry.
  public let timing: FrameTiming?
  /// When the reader had the whole message (system uptime, as `NSEvent.timestamp`),
  /// how long decoding it took, and its size: for telemetry.
  public internal(set) var receivedAt: TimeInterval = 0
  public internal(set) var parseSeconds: TimeInterval = 0
  public internal(set) var bytes = 0

  /// Decodes a message of type `kind` (`SceneWire.Kind`): nil for one that
  /// isn't a hello or a frame, or doesn't decode.
  public init?(kind: UInt64, payload: ArraySlice<UInt8>) {
    let frame: WireFrame
    switch SceneWire.Kind(rawValue: kind) {
    case .serverHello:
      guard let hello = try? WireServerHello(serializedBytes: Array(payload)) else { return nil }
      isHello = true
      protocolVersion = hello.version
      composeRegionProbes = hello.composeRegionProbes
      nativePopupProjection = hello.nativePopupProjection
      composeSourceSelections = hello.composeSourceSelections
      composeSemanticIndex = hello.composeSemanticIndex
      composeDocumentText = hello.composeDocumentText
      composeDocumentUpdates = hello.composeDocumentUpdates
      frame = hello.scene
    case .frame:
      guard let decoded = try? WireFrame(serializedBytes: Array(payload)) else { return nil }
      isHello = false
      protocolVersion = nil
      composeRegionProbes = false
      nativePopupProjection = false
      composeSourceSelections = false
      composeSemanticIndex = false
      composeDocumentText = false
      composeDocumentUpdates = false
      frame = decoded
    default:
      return nil
    }
    self.frame = frame
    sequence = Int(frame.seq)
    var rows: [Int: [CellRun]] = [:]
    for row in frame.rows { rows[Int(row.index)] = CellRun.runs(row) }
    gridRows = rows
    gridCopies = stride(from: 0, to: frame.copies.count - 2, by: 3).map {
      (to: Int(frame.copies[$0]), from: Int(frame.copies[$0 + 1]), count: Int(frame.copies[$0 + 2]))
    }
    gridCount = frame.hasGridLen ? Int(frame.gridLen) : nil
    timing = frame.hasTiming ? FrameTiming(frame.timing) : nil
  }
}

/// What one applied message changed, for views that redraw selectively.
public struct SceneChange: Sendable {
  public var rows = IndexSet()
  public var sizeChanged = false
  public var cursorChanged = false
  public var themeChanged = false
  /// The regions that changed, by name: `panes`, `cursor`, `menus`,
  /// `statusbar`, `fileExplorer`, `separators`, `popups`, `palette`,
  /// `trustDialog`, `contextMenu`, `keybindingEditor`, `settings`.
  public var regions = Set<String>()
  public var isHello = false
}

/// The scene as last sent, kept current by applying Fresh's messages.
@MainActor
@Observable
public final class SceneStore {
  public private(set) var width = 0
  public private(set) var height = 0
  public private(set) var theme = SceneTheme()
  public private(set) var cursor: (column: Int, row: Int)?
  public private(set) var windowID = 0
  /// Raises with every applied message.
  public private(set) var revision = 0
  /// The editor's latest copy: its sequence number and text.
  public private(set) var clipboard: (sequence: Int, text: String)?

  /// Every row of the frame.
  @ObservationIgnored public private(set) var grid: [[CellRun]] = []
  @ObservationIgnored public private(set) var panes: [WirePane] = []
  @ObservationIgnored public private(set) var composeAcceptances: [UInt64: ComposeAcceptance] = [:]
  @ObservationIgnored public private(set) var menus: [WireMenuEntry] = []
  @ObservationIgnored public private(set) var statusBar: WireStatusView?
  @ObservationIgnored public private(set) var fileExplorer: WireFileExplorerView?
  @ObservationIgnored public private(set) var separators: [WireSeparator] = []
  @ObservationIgnored public private(set) var popups: [WireScenePopup] = []
  @ObservationIgnored public private(set) var nativePopupProjection = false
  @ObservationIgnored public private(set) var composeSourceSelections = false
  @ObservationIgnored public private(set) var composeSemanticIndex = false
  @ObservationIgnored public private(set) var composeDocumentText = false
  @ObservationIgnored public private(set) var composeDocumentUpdates = false
  @ObservationIgnored public private(set) var palette: WirePaletteView?
  @ObservationIgnored public private(set) var trustDialog: WireTrustDialogView?
  @ObservationIgnored public private(set) var contextMenu: WireContextMenuView?
  @ObservationIgnored public private(set) var keybindingEditor: WireKeybindingEditorView?
  @ObservationIgnored public private(set) var settings: WireSettingsView?
  /// Raises when the region of that name (`SceneChange.regions`) changes.
  public private(set) var regionRevisions: [String: Int] = [:]

  /// Called after each message with what it changed.
  @ObservationIgnored public var onChange: ((SceneChange) -> Void)?

  public init() {}

  public func apply(_ message: SceneMessage, acceptedCompose: WireComposeEditReceipt? = nil) {
    let frame = message.frame
    if message.isHello {
      composeAcceptances.removeAll(); nativePopupProjection = message.nativePopupProjection
      composeSourceSelections = message.composeSourceSelections
      composeSemanticIndex = message.composeSemanticIndex
      composeDocumentText = message.composeDocumentText
      composeDocumentUpdates = message.composeDocumentUpdates
    }
    let previousWindow = windowID
    var change = SceneChange()
    change.isHello = message.isHello
    if message.isHello {
      grid = []
      panes = []
      menus = []
      statusBar = nil
      fileExplorer = nil
      separators = []
      popups = []
      palette = nil
      trustDialog = nil
      contextMenu = nil
      keybindingEditor = nil
      settings = nil
    }
    if frame.hasWidth, Int(frame.width) != width {
      width = Int(frame.width)
      change.sizeChanged = true
    }
    if frame.hasHeight, Int(frame.height) != height {
      height = Int(frame.height)
      change.sizeChanged = true
    }
    if frame.hasWindowID { windowID = Int(frame.windowID) }
    if frame.hasTheme {
      theme = SceneTheme(frame.theme)
      change.themeChanged = true
    }
    if frame.hasClipboard { clipboard = (Int(frame.clipboard.seq), frame.clipboard.text) }
    if frame.hasCursor {
      let next = (column: Int(frame.cursor.x), row: Int(frame.cursor.y))
      if next.column != cursor?.column || next.row != cursor?.row {
        change.cursorChanged = true
        if let old = cursor { change.rows.insert(old.row) }
        change.rows.insert(next.row)
      }
      cursor = next
      change.regions.insert("cursor")
    }
    // Copies read the rows as they were, before this message.
    let previous = grid
    if let count = message.gridCount {
      if count < grid.count { grid.removeLast(grid.count - count) }
      while grid.count < count { grid.append([]) }
      change.sizeChanged = change.sizeChanged || message.isHello
    }
    for copy in message.gridCopies {
      for offset in 0..<max(0, copy.count) {
        let to = copy.to + offset, from = copy.from + offset
        guard to >= 0, to < grid.count, from >= 0, from < previous.count else { continue }
        grid[to] = previous[from]
        change.rows.insert(to)
      }
    }
    for (index, row) in message.gridRows where index < grid.count {
      grid[index] = row
      change.rows.insert(index)
    }
    let previousPanes = panes
    if frame.hasPaneLen {
      let count = Int(frame.paneLen)
      if count < panes.count { panes.removeLast(panes.count - count) }
      while panes.count < count { panes.append(WirePane()) }
    }
    for update in frame.panes where Int(update.index) < panes.count {
      var pane = update.pane
      if pane.hasCompose, previousWindow == windowID,
         let previous = previousPanes.first(where: { $0.leaf == pane.leaf && $0.hasBuffer && pane.hasBuffer && $0.buffer == pane.buffer }) {
        pane.compose = pane.compose.retainingTableMeasurements(from: previous.hasCompose ? previous.compose : nil)
      }
      panes[Int(update.index)] = pane
    }
    if let receipt = acceptedCompose, receipt.matches(receipt.scope, epoch: receipt.epoch, notBefore: composeAcceptances[receipt.leaf]),
       let index = panes.firstIndex(where: { ComposeAcceptance(receipt).matches($0, window: UInt64(windowID)) }) {
      let acceptance = ComposeAcceptance(receipt)
      let updated = frame.panes.contains { $0.pane.leaf == receipt.leaf && $0.pane.hasBuffer && $0.pane.buffer == receipt.buffer }
      // A reply is self-contained even when the pane diff is omitted or still
      // older than its source. A same/newer pane explicitly in this frame may
      // contain a later cursor and remains authoritative.
      if panes[index].compose.bufferRevision < receipt.pane.bufferRevision
          || !updated && panes[index].compose.bufferRevision == receipt.pane.bufferRevision {
        panes[index].compose = receipt.pane.retainingTableMeasurements(from: panes[index].compose)
      }
      composeAcceptances[receipt.leaf] = acceptance
      change.regions.insert("panes")
    }
    if !composeAcceptances.isEmpty {
      let live = Dictionary(panes.map { ($0.leaf, $0) }, uniquingKeysWith: { _, last in last })
      composeAcceptances = composeAcceptances.filter { leaf, acceptance in
        live[leaf].map { acceptance.matches($0, window: UInt64(windowID)) } ?? false
      }
    }
    if frame.hasPaneLen || !frame.panes.isEmpty { change.regions.insert("panes") }
    func region(_ present: Bool, _ name: String, _ apply: () -> Void) {
      guard present else { return }
      apply()
      change.regions.insert(name)
    }
    region(frame.hasMenus, "menus") { menus = frame.menus.menus }
    region(frame.hasStatusBar, "statusbar") { statusBar = frame.statusBar.hasValue ? frame.statusBar.value : nil }
    region(frame.hasFileExplorer, "fileExplorer") { fileExplorer = frame.fileExplorer.hasValue ? frame.fileExplorer.value : nil }
    region(frame.hasSeparators, "separators") { separators = frame.separators.separators }
    region(frame.hasPopups, "popups") { popups = frame.popups.popups }
    region(frame.hasPalette, "palette") { palette = frame.palette.hasValue ? frame.palette.value : nil }
    region(frame.hasTrustDialog, "trustDialog") { trustDialog = frame.trustDialog.hasValue ? frame.trustDialog.value : nil }
    region(frame.hasContextMenu, "contextMenu") { contextMenu = frame.contextMenu.hasValue ? frame.contextMenu.value : nil }
    region(frame.hasKeybindingEditor, "keybindingEditor") {
      keybindingEditor = frame.keybindingEditor.hasValue ? frame.keybindingEditor.value : nil
    }
    region(frame.hasSettings, "settings") { settings = frame.settings.hasValue ? frame.settings.value : nil }
    for name in change.regions { regionRevisions[name, default: 0] += 1 }
    revision += 1
    onChange?(change)
  }

  /// The text of one grid row.
  public func text(row: Int) -> String {
    guard row >= 0, row < grid.count else { return "" }
    return grid[row].map(\.text).joined()
  }

  /// Every grid row as text.
  public var lines: [String] { (0..<grid.count).map { text(row: $0) } }
}
