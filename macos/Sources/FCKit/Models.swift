import Foundation

// Swift values mirroring the engine's C++ structs. Views only ever see these.

public enum LocationKind: Int, Sendable {
  case local, remote, archive
}

public enum FileKind: Int, Sendable {
  case regular, directory, symlink, block, character, fifo, socket, unknown, error, notFound
}

public enum PaneSort: Int, Sendable, CaseIterable {
  case nameAscending, nameDescending, sizeAscending, sizeDescending, dateAscending, dateDescending

  public enum Field: Sendable { case name, size, date }
  public var field: Field {
    switch self {
    case .nameAscending, .nameDescending: return .name
    case .sizeAscending, .sizeDescending: return .size
    case .dateAscending, .dateDescending: return .date
    }
  }
  public var ascending: Bool { rawValue % 2 == 0 }
  public static func make(_ field: Field, ascending: Bool) -> PaneSort {
    switch field {
    case .name: return ascending ? .nameAscending : .nameDescending
    case .size: return ascending ? .sizeAscending : .sizeDescending
    case .date: return ascending ? .dateAscending : .dateDescending
    }
  }
}

public struct TabInfo: Hashable, Sendable {
  public var title = "", path = "", encoded = ""
  public var kind = LocationKind.local
  public var tutorial = false
  public var remoteError = ""
}

public struct PaneSnapshot: Equatable, Sendable {
  public var path = "", encoded = ""
  public var kind = LocationKind.local
  public var readOnly = false
  public var filter = "", remoteError = ""
  public var sort = PaneSort.nameAscending
  public var loading = false, loadingUnattended = false
  /// A long read's progress (an archive being opened), 0 to 100, or -1.
  public var loadPercent = -1
  public var loadMilliseconds = 0.0
  public var itemsTotal: Int64 = 0, itemsVisible: Int64 = 0, itemsSelected: Int64 = 0
  public var bytesSelected: Int64 = 0, bytesTotal: Int64 = 0, largestItem: Int64 = 0
  public var cursorRow: Int64 = -1
  public var showPermissions = false, showOwnerGroup = false
  public var activeTab = 0
  public var tabs: [TabInfo] = []
  public var revision: UInt64 = 0
  public var contentRevision: UInt64 = 0, marksRevision: UInt64 = 0
  public init() {}
}

public struct Row: Hashable, Sendable {
  public var item: Int64 = -1
  public var name = "", path = "", linkTarget = "", warning = ""
  public var permissions = "", owner = "", group = "", date = ""
  public var kind = FileKind.regular
  public var isDirectory = false, isExecutable = false, selected = false, isLink = false
  public var size: Int64 = 0
  public var modified: Int64 = 0
  public init() {}
}

public struct CommandInfo: Hashable, Sendable, Identifiable {
  public var id = "", title = "", menu = "", scope = "", dialog = ""
  public var commanderKey = "", macKey = "", help = ""
  public var hidden = false
  public var useCount = 0
}

public struct DialogRequest: Sendable {
  public var name = ""
  public var side = 0
  public var selected: [String] = []
  public var focused = "", origin = "", target = ""
}

/// An encrypted archive's reader waits on this until `Engine.answerPassword`.
public struct PasswordQuestion: Sendable {
  public var id: Int64 = 0
  public var archive = ""
  /// The last password given for it was refused.
  public var wrong = false
}

public struct AttachRequest: Sendable {
  public var cwd = ""
  public var argv: [String] = []
  public var environment: [String] = []
  /// The Unix socket of the session's scene, for a native editor window; argv is then empty.
  public var sceneSocket = ""
}

public struct JobInfo: Hashable, Sendable, Identifiable {
  public var id: UInt64 = 0
  public var type = "", state = ""
  public var stopped = false
  public var percent = 0.0, currentPercent = 0.0, mbps = 0.0, averageMbps = 0.0
  public var itemsDone: Int64 = 0, itemsTotal: Int64 = 0, itemsFailed: Int64 = 0, itemsSkipped: Int64 = 0, errors: Int64 = 0
  public var bytesDone = 0.0, bytesTotal = 0.0
  public var streaming = false
  public var bytesWritten = 0.0, bytesVerified = 0.0, bytesDurable = 0.0
  public var current = "", recoveryNote = "", firstError = ""
  public var queued = -1.0, started = -1.0, finished = -1.0

  public var isPaused: Bool { state == "paused" }
  public var isRunning: Bool { state == "running" }
  public var title: String {
    switch type {
    case "COPY": return "Copy"
    case "MOVE": return "Move"
    case "DELETE": return "Delete"
    case "ARCHIVE": return "Create archive"
    case "EXTRACT": return "Extract"
    case "MKDIR": return "New folder"
    case "RENAME": return "Rename"
    case "CLIPBOARD": return "Clipboard"
    default: return type.capitalized
    }
  }
  public var stateTitle: String {
    switch state {
    case "queued": return "Queued"
    case "running":
      if streaming && bytesTotal > 0 && bytesWritten >= bytesTotal {
        if bytesVerified < bytesWritten { return "Verifying" }
        if bytesDurable < bytesWritten { return "Syncing" }
        return "Finishing"
      }
      return "Running"
    case "paused": return "Paused"
    case "cancelled": return "Cancelled"
    case "completed": return "Finished"
    case "completed_with_errors": return "Finished with errors"
    default: return state
    }
  }
}

public struct JobDetail: Sendable {
  public var info = JobInfo()
  public var items: [String] = []
  public var errors: [String] = []
  public var expired = false
}

public struct ErrorEntry: Hashable, Sendable, Identifiable {
  public var message = ""
  public var time = 0.0
  public var id: String { "\(time)|\(message)" }
}

public struct Bookmark: Hashable, Sendable, Identifiable {
  public var title = "", path = "", encoded = ""
  public var kind = LocationKind.local
  public var id: String { encoded }
}

public struct CopyOptions: Sendable {
  public var sources: [String] = []
  public var destination = ""
  public var followLinks = false, keepRelativeLinks = true
  public var conflict = 0
  public init() {}
}

public struct Discovery: Sendable {
  public var running = false, valid = false
  public var bytes: Int64 = 0, files: Int64 = 0, dirs: Int64 = 0, links: Int64 = 0, errors: Int64 = 0, steps: Int64 = 0
  public var current = ""
}

public struct PreviewRow: Hashable, Sendable {
  public var source = "", destination = "", kind = "", message = ""
  public var bytes: Int64 = 0
}

public struct FindInfo: Sendable {
  public var running = false, truncated = false
  public var dirs: Int64 = 0, files: Int64 = 0, errors: Int64 = 0, matches: Int64 = 0
  public var status = ""
}

public struct EngineEvent: Sendable, Hashable {
  public var sequence: UInt64 = 0, request: UInt64 = 0
  public var name = "", detail = ""
}

public enum Format {
  public static func bytes(_ value: Double) -> String {
    if value < 1024 { return String(format: "%.0f B", value) }
    if value < 1024 * 1024 { return String(format: "%.1f KB", value / 1024) }
    if value < 1024 * 1024 * 1024 { return String(format: "%.1f MB", value / (1024 * 1024)) }
    return String(format: "%.1f GB", value / (1024 * 1024 * 1024))
  }
  public static func bytes(_ value: Int64) -> String { bytes(Double(value)) }
  public static func rate(_ bytesPerSecond: UInt64) -> String {
    bytesPerSecond == 0 ? "Unlimited" : bytes(Double(bytesPerSecond)) + "/s"
  }
}

// Empty values for the app (the synthesized initializers are internal).
public extension TabInfo { static var empty: TabInfo { TabInfo() } }
public extension CommandInfo { static var empty: CommandInfo { CommandInfo() } }
public extension DialogRequest { static var empty: DialogRequest { DialogRequest() } }
public extension AttachRequest { static var empty: AttachRequest { AttachRequest() } }
public extension JobInfo { static var empty: JobInfo { JobInfo() } }
public extension JobDetail { static var empty: JobDetail { JobDetail() } }
public extension ErrorEntry { static var empty: ErrorEntry { ErrorEntry() } }
public extension Bookmark { static var empty: Bookmark { Bookmark() } }
public extension Discovery { static var empty: Discovery { Discovery() } }
public extension PreviewRow { static var empty: PreviewRow { PreviewRow() } }
public extension FindInfo { static var empty: FindInfo { FindInfo() } }
public extension EngineEvent { static var empty: EngineEvent { EngineEvent() } }
