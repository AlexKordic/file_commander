internal import CFCEngine
internal import CxxStdlib
import Foundation
import Observation

/// The File Commander engine as the app sees it. Workers in C++ wake the app
/// from any thread; the engine then drains on the main actor and publishes
/// value snapshots that SwiftUI observes.
@MainActor @Observable
public final class Engine {
  public static let shared = Engine()

  public private(set) var left = PaneSnapshot()
  public private(set) var right = PaneSnapshot()
  public private(set) var focusedSide = 0
  public private(set) var singlePane = false
  public private(set) var runningJob: JobInfo?
  public private(set) var queuedJobs: Int64 = 0
  public private(set) var jobs: [JobInfo] = []
  public private(set) var recentErrors: [ErrorEntry] = []
  public private(set) var errorCount: Int64 = 0
  public private(set) var bookmarks: [Bookmark] = []
  public private(set) var transferRate: UInt64 = 0
  public private(set) var isStarted = false
  /// Bumped whenever a pane's rows may have changed; listings reload on it.
  public private(set) var listingRevision: [UInt64] = [0, 0]

  /// Requests from commands (dialogs to show), notices (short confirmations)
  /// and editor attaches, delivered after each drain.
  @ObservationIgnored public var onDialog: ((DialogRequest) -> Void)?
  @ObservationIgnored public var onNotice: ((String) -> Void)?
  @ObservationIgnored public var onAttach: ((AttachRequest) -> Void)?
  @ObservationIgnored private var eventObservers: [UUID: ([EngineEvent]) -> Void] = [:]
  @ObservationIgnored private var eventCursor: UInt64 = 0
  @ObservationIgnored private var last = fce.Changes()
  @ObservationIgnored private var timer: Timer?
  @ObservationIgnored private var commandCache: [CommandInfo] = []

  private init() {}

  public struct StartOptions {
    public var left = "", right = ""
    public var restore = true, recovery = true
    public var toolDirectory = ""
    public init() {}
  }

  /// Starts the engine; returns an error message, or nil on success.
  public func start(_ options: StartOptions) -> String? {
    fce.set_wake({ _ in
      DispatchQueue.main.async { MainActor.assumeIsolated { Engine.shared.drain() } }
    }, nil)
    var o = fce.StartOptions()
    o.left = std.string(options.left)
    o.right = std.string(options.right)
    o.restore = options.restore
    o.recovery = options.recovery
    o.tool_dir = std.string(options.toolDirectory)
    let result = fce.start(o)
    guard result.ok else { return String(result.error) }
    isStarted = true
    timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
      MainActor.assumeIsolated { Engine.shared.drain() }
    }
    drain(force: true)
    return nil
  }

  /// Saves the workspace and settings and stops jobs; interrupted transfers come back paused.
  public func stop() {
    guard isStarted else { return }
    timer?.invalidate()
    fce.stop()
    isStarted = false
  }

  public var profileDirectory: String { String(fce.profile_dir()) }

  // MARK: Draining

  public func drain(force: Bool = false) {
    guard isStarted else { return }
    let changes = fce.drain()
    if force || changes.left_revision != last.left_revision || changes.layout_revision != last.layout_revision {
      left = Engine.snapshot(0)
      listingRevision[0] &+= 1
    }
    if force || changes.right_revision != last.right_revision || changes.layout_revision != last.layout_revision {
      right = Engine.snapshot(1)
      listingRevision[1] &+= 1
    }
    if force || changes.layout_revision != last.layout_revision {
      focusedSide = Int(fce.focused_side())
      singlePane = fce.single_pane()
    }
    if force || changes.jobs_revision != last.jobs_revision {
      refreshJobs()
    }
    if force || changes.errors_revision != last.errors_revision {
      recentErrors = Engine.errorList(50)
      errorCount = fce.error_count()
    }
    if force || changes.bookmarks_revision != last.bookmarks_revision {
      bookmarks = fce.bookmarks().map {
        Bookmark(title: String($0.title), path: String($0.path), encoded: String($0.encoded),
                 kind: LocationKind(rawValue: Int($0.kind.rawValue)) ?? .local)
      }
    }
    let rate = fce.transfer_rate()
    if rate != transferRate { transferRate = rate }
    last = changes
    for request in changes.dialogs {
      onDialog?(DialogRequest(name: String(request.name), side: Int(request.side), selected: Engine.strings(request.selected),
                              focused: String(request.focused), origin: String(request.origin), target: String(request.target)))
    }
    for notice in changes.notices { onNotice?(String(notice)) }
    for attach in changes.attaches {
      onAttach?(AttachRequest(cwd: String(attach.cwd), argv: Engine.strings(attach.argv), environment: Engine.strings(attach.environment),
                              sceneSocket: String(attach.scene_socket)))
    }
    if !eventObservers.isEmpty {
      let batch = fce.events_since(eventCursor)
      eventCursor = batch.cursor
      let events = batch.events.map { EngineEvent(sequence: $0.sequence, request: $0.request, name: String($0.name), detail: String($0.detail)) }
      if !events.isEmpty { for observer in eventObservers.values { observer(events) } }
    }
  }

  private func refreshJobs() {
    let running = fce.running_job()
    runningJob = running.present ? Engine.job(running.job) : nil
    queuedJobs = running.queued
    jobs = fce.jobs().map(Engine.job)
  }

  /// Observes application events (the same stream Lua scripts read) from now on.
  public func observeEvents(_ handler: @escaping ([EngineEvent]) -> Void) -> UUID {
    if eventObservers.isEmpty { eventCursor = fce.events_since(UInt64.max).cursor }
    let id = UUID()
    eventObservers[id] = handler
    return id
  }
  public func stopObserving(_ id: UUID) { eventObservers[id] = nil }

  // MARK: Panes

  public func pane(_ side: Int) -> PaneSnapshot { side == 0 ? left : right }
  public var focusedPane: PaneSnapshot { pane(focusedSide) }

  public func rowCount(_ side: Int) -> Int { Int(fce.row_count(Int32(side))) }
  public func row(_ side: Int, _ row: Int) -> Row { Engine.row(fce.row(Int32(side), Int64(row))) }
  public func rowNamed(_ side: Int, _ name: String) -> Int? {
    let r = fce.row_named(Int32(side), std.string(name))
    return r < 0 ? nil : Int(r)
  }
  public func selectedRows(_ side: Int) -> [Int] { fce.selected_rows(Int32(side)).map { Int($0) } }
  public func rows(_ side: Int, from: Int, count: Int) -> [Row] {
    fce.rows(Int32(side), Int64(from), Int64(count)).map(Engine.row)
  }

  public func setFocusedSide(_ side: Int) { fce.set_focused_side(Int32(side)); drain() }
  public func setSinglePane(_ on: Bool) { fce.set_single_pane(on); drain() }
  public func setCursor(_ side: Int, row: Int) { fce.set_cursor(Int32(side), Int64(row)); drain() }
  public func toggleRow(_ side: Int, row: Int) { fce.toggle_row(Int32(side), Int64(row)); drain() }
  public func setRowSelected(_ side: Int, row: Int, selected: Bool) { fce.set_row_selected(Int32(side), Int64(row), selected); drain() }
  public func setSelectedRows(_ side: Int, rows: [Int]) {
    var list = fce.IndexList()
    for r in rows { list.push_back(Int64(r)) }
    fce.set_selected_rows(Int32(side), list)
    drain()
  }
  public func selectAll(_ side: Int) { fce.select_all(Int32(side)); drain() }
  public func clearSelection(_ side: Int) { fce.clear_selection(Int32(side)); drain() }
  @discardableResult public func globSelect(_ side: Int, pattern: String, select: Bool) -> Int {
    let n = Int(fce.glob_select(Int32(side), std.string(pattern), select)); drain(); return n
  }
  public func setFilter(_ side: Int, _ text: String) { fce.set_filter(Int32(side), std.string(text)); drain() }
  public func setSort(_ side: Int, _ order: PaneSort) { fce.set_sort(Int32(side), Int32(order.rawValue)); drain() }
  public func setColumns(_ side: Int, permissions: Bool, ownerGroup: Bool) { fce.set_columns(Int32(side), permissions, ownerGroup); drain() }
  @discardableResult public func openRow(_ side: Int, row: Int) -> Bool { let ok = fce.open_row(Int32(side), Int64(row)); drain(); return ok }
  public func goUp(_ side: Int) { fce.go_up(Int32(side)); drain() }
  public func navigate(_ side: Int, to location: String, focus: String = "") {
    fce.navigate(Int32(side), std.string(location), std.string(focus)); drain()
  }
  public func refresh(_ side: Int) { fce.refresh(Int32(side)); drain() }
  public func stopLoading(_ side: Int) { fce.stop_loading(Int32(side)); drain() }
  public func switchTab(_ side: Int, to index: Int) { fce.switch_tab(Int32(side), Int32(index)); drain() }
  public func newTab(_ side: Int, location: String = "", tutorial: Bool = false) {
    fce.new_tab(Int32(side), std.string(location), tutorial); drain()
  }
  public func closeTab(_ side: Int, index: Int) { fce.close_tab(Int32(side), Int32(index)); drain() }
  public func moveTab(_ side: Int, from: Int, to: Int) { fce.move_tab(Int32(side), Int32(from), Int32(to)); drain() }
  public func closeTutorialTabs() { fce.close_tutorial_tabs(); drain() }
  public func setKeepTutorialTabs(_ keep: Bool) { fce.set_keep_tutorial_tabs(keep) }
  public func adoptTutorialTabs(prefix: String) { fce.adopt_tutorial_tabs(std.string(prefix)); drain() }

  // MARK: Commands

  public var commands: [CommandInfo] {
    if commandCache.isEmpty { commandCache = Engine.commandList() }
    return commandCache
  }
  public func command(_ id: String) -> CommandInfo? { commands.first { $0.id == id } }
  public func isAvailable(_ id: String) -> Bool { fce.command_available(std.string(id)) }
  @discardableResult public func execute(_ id: String) -> Bool {
    let ok = fce.execute(std.string(id))
    drain()
    return ok
  }
  public func palette(_ query: String) -> [String] { Engine.strings(fce.palette(std.string(query))) }

  // MARK: Dialog work

  public func copyDiscover(_ options: CopyOptions) -> UInt64 {
    var o = fce.CopyOptions()
    o.sources = Engine.cxx(options.sources)
    o.destination = std.string(options.destination)
    o.follow_links = options.followLinks
    o.keep_relative_links = options.keepRelativeLinks
    o.conflict = Int32(options.conflict)
    return fce.copy_discover(o)
  }
  public func discovery(_ session: UInt64) -> Discovery {
    let d = fce.discovery(session)
    return Discovery(running: d.running, valid: d.valid, bytes: d.bytes, files: d.files, dirs: d.dirs, links: d.links,
                     errors: d.errors, steps: d.steps, current: String(d.current))
  }
  public func discoveryPreview(_ session: UInt64, from: Int, count: Int) -> [PreviewRow] {
    fce.discovery_preview(session, Int64(from), Int64(count)).map {
      PreviewRow(source: String($0.source), destination: String($0.destination), kind: String($0.kind), message: String($0.message), bytes: $0.bytes)
    }
  }
  public func discoveryCancel(_ session: UInt64) { fce.discovery_cancel(session) }
  /// Starts the planned copy; returns an error message or nil.
  public func copyStart(_ session: UInt64, side: Int) -> String? {
    let error = String(fce.copy_start(session, Int32(side)))
    drain()
    return error.isEmpty ? nil : error
  }

  public struct Submitted { public var error: String?; public var job: UInt64 }
  private func submitted(_ r: fce.SubmitResult) -> Submitted {
    let e = String(r.error)
    drain()
    return Submitted(error: e.isEmpty ? nil : e, job: r.job)
  }
  public func submitMove(_ sources: [String], to target: String, side: Int) -> Submitted {
    submitted(fce.submit_move(Engine.cxx(sources), std.string(target), Int32(side)))
  }
  public func submitDelete(_ sources: [String], side: Int) -> Submitted { submitted(fce.submit_delete(Engine.cxx(sources), Int32(side))) }
  public func submitMkdir(in folder: String, name: String) -> Submitted { submitted(fce.submit_mkdir(std.string(folder), std.string(name))) }
  public func submitRename(_ sources: [String], names: [String]) -> Submitted {
    submitted(fce.submit_rename(Engine.cxx(sources), Engine.cxx(names)))
  }
  public func copyToClipboard(_ side: Int, names: Bool) { fce.copy_to_clipboard(Int32(side), names); drain() }
  /// The extraction popup: everything in `archive` into `folder`, in one pass. `conflict`: 0 replace, 1 update if newer, 2 skip.
  public func submitExtract(_ archive: String, into folder: String, conflict: Int) -> Submitted {
    submitted(fce.submit_extract(std.string(archive), std.string(folder), Int32(conflict)))
  }
  /// "Browse anyway" and Open as Archive: shows `archive` as a read-only folder.
  public func browseArchive(_ side: Int, _ archive: String) { fce.browse_archive(Int32(side), std.string(archive)); drain() }
  /// The folder an archive is extracted into by default: its name without the archive suffix.
  public nonisolated static func archiveFolderName(_ archive: String) -> String { String(fce.archive_folder_name(std.string(archive))) }
  /// Whether extracting `archive` offers a folder named after it: a compressed tar holds many files, a compressed file one.
  public nonisolated static func archiveHoldsMany(_ archive: String) -> Bool { fce.archive_holds_many(std.string(archive)) }
  /// Whether the listing shows `name` with an archive icon.
  public nonisolated static func isArchiveName(_ name: String) -> Bool { !String(fce.archive_icon(std.string(name))).isEmpty }

  public func findStart(root: String, pattern: String) -> String? {
    let s = String(fce.find_start(std.string(root), std.string(pattern)))
    return s.isEmpty ? nil : s
  }
  public func findStop() { fce.find_stop() }
  public func findInfo() -> FindInfo {
    let f = fce.find_info()
    return FindInfo(running: f.running, truncated: f.truncated, dirs: f.dirs, files: f.files, errors: f.errors, matches: f.matches, status: String(f.status))
  }
  public func findResults(from: Int, count: Int) -> [String] { Engine.strings(fce.find_results(Int64(from), Int64(count))) }
  public func findReveal(_ side: Int, path: String) { fce.find_reveal(Int32(side), std.string(path)); drain() }

  // MARK: Jobs and errors

  public func jobDetail(_ id: UInt64) -> JobDetail {
    let d = fce.job_detail(id)
    return JobDetail(info: Engine.job(d.info), items: Engine.strings(d.items), errors: Engine.strings(d.errors), expired: d.expired)
  }
  @discardableResult public func pauseJob(_ id: UInt64) -> String? { message(fce.pause_job(id)) }
  @discardableResult public func resumeJob(_ id: UInt64) -> String? { message(fce.resume_job(id)) }
  @discardableResult public func cancelJob(_ id: UInt64) -> String? { message(fce.cancel_job(id)) }
  public func dismissJob(_ id: UInt64) { fce.dismiss_job(id); refreshJobs() }
  public func setTransferRate(_ bytesPerSecond: UInt64, persist: Bool) {
    fce.set_transfer_rate(bytesPerSecond, persist); drain()
  }
  public func errors(count: Int) -> [ErrorEntry] { Engine.errorList(count) }
  public func clearErrors() { fce.clear_errors(); drain(force: false) }
  public nonisolated func reportError(_ message: String) { fce.report_error(std.string(message)) }

  private func message(_ s: std.string) -> String? {
    let text = String(s)
    drain()
    return text.isEmpty ? nil : text
  }

  // MARK: Bookmarks

  public func addBookmark(_ location: String) { fce.add_bookmark(std.string(location)); drain() }
  public func removeBookmark(_ encoded: String) { fce.remove_bookmark(std.string(encoded)); drain() }

  // MARK: Editor

  public func openInEditor() -> String? { message(fce.open_in_editor()) }
  public func switchToEditor() -> String? { message(fce.switch_to_editor()) }
  /// 0 ready, 1 needs confirmation for a legacy checkpoint, 2 failed.
  public func restartEditor(allowLegacy: Bool) -> (status: Int, error: String) {
    let r = fce.restart_editor(allowLegacy)
    return (Int(r.status), String(r.error))
  }
  public func setEditorSession(store: String, environment: [String]) {
    fce.set_editor_session(std.string(store), Engine.cxx(environment))
  }
  public func setEditorSwitchKey(_ key: String) { fce.set_editor_switch_key(std.string(key)) }
  /// Attaches carry the session's scene socket when it has one, for a native editor window.
  public func setEditorSceneAttach(_ on: Bool) { fce.set_editor_scene_attach(on) }

  // MARK: SSH

  /// Runs ssh's interactive authentication; blocks, so call it off the main actor.
  public nonisolated static func sshAuthenticate(_ host: String) -> Int { Int(fce.ssh_authenticate(std.string(host))) }
  public func sshOpen(host: String, path: String) -> String? { message(fce.ssh_open(std.string(host), std.string(path))) }
  public nonisolated static func setEndpointCommand(host: String, command: String) {
    fce.set_endpoint_command(std.string(host), std.string(command))
  }

  public nonisolated static func displayLocation(_ encoded: String) -> String { String(fce.display_location(std.string(encoded))) }

  // MARK: Conversions

  private static func snapshot(_ side: Int) -> PaneSnapshot {
    let p = fce.pane(Int32(side))
    var s = PaneSnapshot()
    s.path = String(p.path)
    s.encoded = String(p.encoded)
    s.kind = LocationKind(rawValue: Int(p.kind.rawValue)) ?? .local
    s.readOnly = p.read_only
    s.filter = String(p.filter)
    s.remoteError = String(p.remote_error)
    s.sort = PaneSort(rawValue: Int(p.sort)) ?? .nameAscending
    s.loading = p.loading
    s.loadingUnattended = p.loading_unattended
    s.loadMilliseconds = p.load_ms
    s.itemsTotal = p.items_total
    s.itemsVisible = p.items_visible
    s.itemsSelected = p.items_selected
    s.bytesSelected = p.bytes_selected
    s.bytesTotal = p.bytes_total
    s.largestItem = p.largest_item
    s.cursorRow = p.cursor_row
    s.showPermissions = p.show_permissions
    s.showOwnerGroup = p.show_owner_group
    s.activeTab = Int(p.active_tab)
    s.tabs = p.tabs.map {
      TabInfo(title: String($0.title), path: String($0.path), encoded: String($0.encoded),
              kind: LocationKind(rawValue: Int($0.kind.rawValue)) ?? .local, tutorial: $0.tutorial, remoteError: String($0.remote_error))
    }
    s.revision = p.revision
    s.contentRevision = p.content_revision
    s.marksRevision = p.marks_revision
    return s
  }

  private static func row(_ r: fce.RowInfo) -> Row {
    var row = Row()
    row.item = r.item
    row.name = String(r.name)
    row.path = String(r.path)
    row.linkTarget = String(r.link_target)
    row.warning = String(r.warning)
    row.permissions = String(r.permissions)
    row.owner = String(r.owner)
    row.group = String(r.group)
    row.date = String(r.date)
    row.kind = FileKind(rawValue: Int(r.kind.rawValue)) ?? .unknown
    row.isDirectory = r.is_dir
    row.isExecutable = r.is_executable
    row.selected = r.selected
    row.isLink = r.is_link
    row.size = r.size
    row.modified = r.modified
    return row
  }

  private static func job(_ j: fce.JobInfo) -> JobInfo {
    JobInfo(id: j.id, type: String(j.type), state: String(j.state), stopped: j.stopped, percent: j.percent,
            currentPercent: j.current_percent, mbps: j.mbps, averageMbps: j.average_mbps, itemsDone: j.items_done,
            itemsTotal: j.items_total, itemsFailed: j.items_failed, itemsSkipped: j.items_skipped, errors: j.errors,
            bytesDone: j.bytes_done, bytesTotal: j.bytes_total, current: String(j.current),
            recoveryNote: String(j.recovery_note), firstError: String(j.first_error), queued: j.queued, started: j.started,
            finished: j.finished)
  }

  private static func errorList(_ count: Int) -> [ErrorEntry] {
    fce.errors(Int32(count)).map { ErrorEntry(message: String($0.message), time: $0.time) }
  }

  private static func commandList() -> [CommandInfo] {
    fce.commands().map {
      CommandInfo(id: String($0.id), title: String($0.title), menu: String($0.menu), scope: String($0.scope),
                  dialog: String($0.dialog), commanderKey: String($0.commander_key), macKey: String($0.mac_key),
                  help: String($0.help), hidden: $0.hidden, useCount: Int($0.use_count))
    }
  }

  private static func strings(_ list: fce.StringList) -> [String] { list.map { String($0) } }
  private static func cxx(_ list: [String]) -> fce.StringList {
    var v = fce.StringList()
    for s in list { v.push_back(std.string(s)) }
    return v
  }
}
