# Architecture

This page explains how File Commander (FC) is put together and lists the rules
a change must not break. Read it before touching threads, jobs, persistence or
command dispatch. Related pages: [building.md](building.md),
[testing.md](testing.md), [fresh_integration.md](fresh_integration.md), the Lua
API in [../scripting.md](../scripting.md) and user-visible behavior in
[../user_guide.md](../user_guide.md). Contribution rules are in
[../../CONTRIBUTING.md](../../CONTRIBUTING.md).

FC targets POSIX systems (macOS and Linux). The guiding idea is "machinery
first, UI as observer". Filesystem facts, operation plans and jobs live in a
core library with no UI. The FTXUI layer renders snapshots of that state and
issues commands. Slow work never runs on the UI thread.

## Processes and threads

```
+-------------------------------- fc process --------------------------------+
| UI thread       FTXUI loop, UiDispatcher drain, panels, dialogs,           |
|                 Lua coroutine (fc run only)                                |
|   ^ every worker result arrives as a closure posted to UiDispatcher        |
| panel loaders   one LatestWork per panel: directory reads, archive         |
|                 extraction, watcher deltas                                 |
| job worker      one ThreadedFileJobs thread: copy, move, delete, archive,  |
|                 mkdir, rename, clipboard; plus a progress monitor and a    |
|                 per-job discovery thread for delete                        |
| request threads CopyPlanner (copy/move preview), Find search               |
| watchers        FSEvents queue (macOS), inotify thread (Linux),            |
|                 3 s rescan thread for SSH tabs                             |
| timer           ScheduledUpdates (fc run only)                             |
+------+------------------------------+-------------------------------+------+
       | posix_spawn /bin/sh -c       | posix_spawnp ssh              | dlopen
       v                              v                               v
  fresh: separate GPL program    ssh -T host python3 -c ...       7z.so: 7-Zip's
  with its own backend           remote_agent.py, two channels    archive library,
                                 per host (listing, bulk)          in-process
```

The loop in `main.cpp` is: drain `UiDispatcher`, run one FTXUI pass
(`Loop::RunOnce`), let the application observe focus and selection changes
(`FileCommander::observe_state`), tick Lua or checkpoint the workspace, then
wait on the dispatcher for at most 16 ms. When the terminal is handed to
another program (Fresh, SSH authentication, log flushing), the dispatcher is
suspended and keeps queued work until the terminal returns.

SSH support installs nothing remotely; the host needs only `python3`.
Interactive authentication happens only from the Connect SSH dialog, with the
terminal handed to `ssh`. Background connections then run `ssh` in `BatchMode`
over the shared ControlMaster socket, send `remote_agent.py` over stdin to
`python3`, and speak a versioned JSON-lines protocol with it. Each host gets
one channel for metadata and listings and one for bulk reads, writes and
digests, so a large transfer does not stall browsing.

## Source layout and build targets

Sources live at the repository root. Library membership in `CMakeLists.txt`,
not directories, defines the boundaries. Dependencies point one way only:
`fc_core` <- `fc_model` <- `fc_ui` <- `fc_lua` <- `fc`, and `fc_model` <-
`fc_engine` <- the macOS app.

| Target | Sources | Links | Rule |
| --- | --- | --- | --- |
| `fc_core` | `commander`, `operation`, `copy_planner`, `file_io_jobs`, `archive`, `location`, `traversal`, `settings`, `workspace`, `transfer_journal`, `remote_fs`, `file_metadata`, `runtime_paths`, `scheduled_updates`, `log`, `err` | Boost.Filesystem (patched subtree), Boost.JSON, threads | No FTXUI, Lua or editor headers. Builds alone with `FC_CORE_ONLY=ON`. |
| `fc_model` | `pane_model`, `app_model`, `dialog_models`, `file_change_funnel`, `editor_manager` | `fc_core`, CoreServices on macOS | The application without a UI toolkit: panes and tabs, the app's command catalog and dispatch, copy discovery, Find, palette ranking, watchers, the editor. No FTXUI. |
| `fc_engine` | `fc_engine` | `fc_model` | The facade the macOS app imports through Swift's C++ interop; value types only. With `libfc_engine_bundle.a` (engine, model, core and Boost in one archive). See [macos_app.md](macos_app.md). |
| `fc_ui` | `app`, `dialogs`, `find_dialog`, `job_dialogs`, `settings_dialogs`, `commands`, `theme`, `custom_controls`, `shared_state` | `fc_model`, FTXUI fork | Panel composition, dialogs, the terminal command catalog. |
| `fc_lua` | `scripting` | `fc_ui`, LuaJIT | Script runner and test adapter; uses application commands and events. |
| `fc` | `main` | `fc_lua` | Startup, main loop, shutdown order. |

The UI-free core is the boundary that matters. `fc_model` holds what both
interfaces need above it; FTXUI-dependent orchestration stays in `fc_ui`, and
the macOS app (`macos/`) is a second observer of `fc_model`. Configure also embeds
`remote_agent.py` and `fc_framework.lua` into generated headers, builds `fresh` (Cargo) and 7-Zip's archive library `7z.so` (7-Zip's makefile) as side targets, and bakes their paths in as defaults. The Boost.Filesystem changes (cancellable, throttled, staged
`copy_file`) are described in [../../boost/changes.md](../../boost/changes.md).

| Test executable | Links | CTest names |
| --- | --- | --- |
| `fc_core_tests` | `fc_core` | `fc.core` |
| `fc_contract_tests` | `fc_core` | `fc.contract.*` |
| `fc_lifetime_tests` | `fc_core` | `fc.lifetime.*` |
| `fc_file_fault_tests` | `fc_core` | `fc.fault.*` |
| `fc_transfer_recovery_tests` | `fc_core` | `fc.recovery.*` |
| `fc_remote_fs_tests` | `fc_core` | `fc.remote.filesystem` |
| `fc_remote_transfer_tests` | `fc_core` | `fc.remote.transfers` |
| `fc_resource_tests` | `fc_core` | `fc.extended.resources`, `fc.benchmark.publication` |
| `fc_remote_ui_tests` | `fc_ui` | `fc.remote.panels` |
| `fc_render_benchmarks` | `fc_ui` | `fc.benchmark.render` |
| `fc_command_tests` | `fc_lua` | `fc.command.*` |
| `fc_review_tests` | `fc_lua` | `fc.regression.*` |
| `fc_model_tests` | `fc_engine` | `fc.model.*` |

A core-only build produces the first eight and `fc_model_tests`. Python drivers run the real `fc`
binary in PTYs for the remaining suites; see [testing.md](testing.md).

## Key types

| Type | File | Role |
| --- | --- | --- |
| `Location` | `location.hpp` | Durable identity of a place: a local path, an archive chain plus internal path, or an SSH target plus absolute path. Encoded as a plain path, `fc-archive:<outer>!<nested>!/<internal>` or `fc-ssh:<target>:<path>`; the archive chain and the SSH target are percent-escaped, and an archive's internal path follows `!/` as is, so `/`, `parent_path()` and `filename()` work inside an archive. SSH and archive paths travel as a `Filepath` holding the encoded string; test them with `is_remote()`, `is_archive_path()` or `is_virtual_path()`. |
| `DirItem`, `Dir`, `DirectorySnapshot`, `PanelViewState` | `commander.hpp` | One entry, a panel listing, an immutable loader result, and the view preferences (sort, filter) that survive publication. |
| `OperationPlan`, `Operation` | `operation.hpp` | Immutable typed steps (copy file, create directory or symlink, move, delete, rename, ...). Executors interpret only these. |
| `CopyPlanner` | `copy_planner.hpp` | Builds a copy/move plan on its own thread using `traverse()`. |
| `JobSpec`, `JobSnapshot`, `FileJobs` | `file_io_jobs.hpp` | A submitted job, a frame-safe copy of its state, and the job manager interface (`file_operations()` is the process instance). |
| `TransferJournal` | `transfer_journal.hpp` | Per-job plan and progress records used for crash recovery. |
| `ArchiveFS`, `create_archive` | `archive.hpp` | Archives as a read-only filesystem: `inspect`, `list` and a batched `extract` over `fc-archive:` paths, backed by a small cache of open archives; `extract_all`, the extraction popup's one pass; the password prompt and the session's passwords; `ReadProgress` for long reads on the loader thread; and creation in the format the destination's name says. |
| `ArchiveFormat`, `archive_destination` | `archive_formats.hpp` | The suffix table, decided by name only so it is safe on the UI thread: what `Enter` does (browse, offer extraction, refuse), the format to hint to 7-Zip, whether FC writes it, and what copying to a name creates or why it is refused. |
| `SevenZip::Archive`, `SevenZip::create`, `read_compressed_tar`, `create_compressed_tar` | `sevenzip.hpp` | 7-Zip's archive library, `7z.so`, loaded with `dlopen`: an archive's entries, extraction of chosen entries to chosen files, new archives. A compressed tar is read and written in one pass through a bounded pipe between two threads, the compressor on one and tar on the other. Only `sevenzip.cpp` sees 7-Zip's COM-style types. |
| `RemoteFS` | `remote_fs.hpp` | SSH filesystem calls, one function per agent method. |
| `Commands`, `KeyBindings` | `commands.hpp`, `theme.hpp` | Command catalog (stable IDs, scope, dialog, description) and the key bound to each. |
| `FileCommander`, `Panel`, `DialogOverlay` | `app.hpp` | Application root, one side of the two-panel layout, and the overlay mechanism both use. |
| `PanelSharedState` | `shared_state.hpp` | What a panel's dialogs may reach: its `Dir`, poster, job manager, command dispatch. |
| `ApplicationEvents` | `application_events.hpp` | Bounded event stream that Lua and tests read. |
| `SettingsStore`, `AppSettings` | `settings.hpp` | Preferences file and the shared atomic writer. |
| `WorkspaceStore`, `WorkspaceLease` | `workspace.hpp` | Tab/focus/selection checkpoint and the profile lock. |
| `EditorManager` | `editor_manager.hpp` | Fresh session identity, launch and attach. |
| `UiDispatcher`, `LatestWork`, `ScheduledUpdates` | own headers | UI mailbox, "latest request wins" worker, timer. |

## Design rules

1. **Only the UI thread touches UI state.** FTXUI components, `Dir`, panels
   and dialogs belong to the UI thread. Workers post closures through
   `UiDispatcher::poster()` and never call FTXUI; only `main.cpp` posts
   `Event::Custom` after draining. *Enforced by `ui_dispatcher.hpp`,
   `main.cpp`.*
2. **Late results are dropped, not applied.** Every posted closure checks a
   lifetime flag and a generation number before mutating anything
   (`Panel::_callback_alive` and `_load_generation`, `Dialog::_alive` and
   `_submission_generation`, the `LatestWork` token). *Enforced by `app.cpp`,
   `Dialog::submit`.*
3. **One owner per state category.** Filesystem facts arrive as snapshots or
   deltas published into `Dir`; view preferences stay in `PanelViewState` and
   `PanelSharedState`; execution state lives in `ThreadedFileJobs`; disk state
   goes through `SettingsStore`/`WorkspaceStore`; open archives belong to `ArchiveFS`. Observers read copies such as `JobSnapshot`.
4. **No filesystem I/O on the UI thread.** Listings, archives included, run on the panel loader; traversals run on planner or Find threads; even mkdir,
   rename and clipboard run as jobs and report back. *Enforced by `Panel`,
   `Dialog::submit`.*
5. **Workers never prompt.** The conflict policy (Replace, Update, Skip) is
   fixed in the dialog before submission. An I/O error is recorded and the
   item skipped; the user reviews results in the Job List and Error List.
   *Enforced by `ThreadedFileJobs::run_*`.*
6. **Output is staged privately and committed atomically.** A file copy writes
   `.fc-copy-XXXXXX/data` beside the destination and commits by `rename`
   (replace) or `link` (no replace). Cross-device moves stage `.fc-move-*`,
   copy and verify metadata, commit, then remove the source. Archive creation
   uses `.fc-archive-*`; SSH copies also verify SHA-256. Cancellation removes
   only owned staging, never an existing destination. A copy out of an archive extracts each file into its own `.fc-copy-*/data` and commits it the same way. *Enforced by the patched `copy_file`, `move_by_copy`, `create_archive`, `run_remote`, `run_archive_copy`.*
7. **Link semantics are chosen per operation.** Listings use `symlink_status`
   and keep dangling or cyclic links visible. Delete never descends through a
   link and removes children first. Copy keeps relative link text, makes other
   links absolute, or follows them when asked; a directory reached twice becomes
   a link. Find never follows links. *Enforced by `traverse()` and
   `TraversalPolicy`, `CopyPlanner`, `ThreadedFileJobs::_discover_files`.*
8. **Traversal is iterative and bounded.** `traverse()` is depth-first and
   holds at most one iterator per level. Defaults are 1,000,000 entries and
   depth 1,024; Find uses 100,000. Hitting a budget sets `truncated` and
   records an error instead of continuing silently. *Enforced by
   `traversal.cpp`.*
9. **Archives are read-only and never extracted to be browsed.** Listing an archive reads its index; copying out extracts only the files copied, in one pass per archive. A compressed tar has no index: listing it is one pass over the stream, and `Enter` offers the one-pass extraction instead. Mutations of `fc-archive:` paths are rejected in the UI (`archive_mutation_error`) and again in the worker (`validate_mutation_paths`). An open archive is reused while its file's device, inode, size and nanosecond mtime/ctime are unchanged; it is not a content hash. At most 16 archives stay open; ones in use are never closed. A nested archive is read from a private copy of its entry. FC builds every destination path itself: entries are normalized, and one-pass extraction checks each place it writes with links resolved against the destination's real path. Encrypted data is checked with a test pass before anything is written. *Enforced by `ArchiveFS`, `run_archive_copy` and `run_extract`.*
   A password is asked for on the reading thread, which waits; the thread that installed the prompt (the UI thread) is never made to wait and fails instead. The TUI asks with `ArchivePasswordDialog`; the engine hands questions to the app in `Changes::passwords` and gets answers through `answer_password`. *Enforced by `ArchiveFS::set_password_prompt`.*
10. **One serial job worker, by design, and pause holds it.** Jobs run one at a
    time from a bounded queue. Pause blocks the worker on `JobSpec::_pause_cv`
    at item boundaries and inside the file data loop, so queued jobs wait.
    Cancel always beats pause; resume keeps the job ID. *Enforced by
    `ThreadedFileJobs::wait_for_resume`.*
11. **One command dispatch path.** Shortcuts, the palette and Lua
    `fc.command`/`fc.cmd` all call `FileCommander::execute_command(id)`, which
    checks availability, runs the handler, counts usage once and publishes
    `command_executed`. Raw key injection (`fc.key`) exists for UI tests.
    *Enforced by `register_commands` and `test/command_contracts.cpp`.*
12. **Persisted files are replaced atomically.** `SettingsStore::atomic_write`
    writes a private temporary file, fsyncs, renames and fsyncs the directory.
    Each file is atomic alone; `settings.json` and `theme_colors.json` are not
    one transaction. Files with an unknown version are rejected.
13. **One interactive FC per profile.** `WorkspaceLease` holds an exclusive
    `flock` on `workspace.lock`; a second instance exits with a message. The
    editor identity has its own short lock. `fc run` takes no lock.
14. **Journaled transfers resume paused, never automatically.** In interactive
    mode every job is journaled before it is queued. On startup, interrupted
    records are restored as PAUSED; only an explicit Resume validates and
    requeues them. Copy and move resume per file; other kinds must be cancelled
    and resubmitted. *Enforced by `TransferJournal::restore`, `prepare_resume`.*
15. **Fresh is a separate GPL program.** FC starts `fresh` as a process and
    passes the session ID, location and SSH control path on its command line.
    Never link Fresh code into FC or copy it into this repository.
16. **Lua is a same-thread coroutine.** `LuaScripting` resumes the script
    after each loop pass; it yields only inside `fc.wait_event`,
    `fc.wait_for_jobs` and `fc.sleep`. A count hook (JIT off for the
    coroutine) enforces the watchdog.

## Data on disk

The profile directory is `$XDG_CONFIG_HOME/file_commander`, or
`~/.config/file_commander` when `XDG_CONFIG_HOME` is unset.

| Path | Written | Contents |
| --- | --- | --- |
| `settings.json` | graceful exit | Preferences: panel paths, sort and columns, layout, bookmarks, key bindings, command usage, Fresh binary override, last editor session. |
| `theme_colors.json` | Theme Colors dialog, graceful exit | Color token overrides. |
| `workspace.json` | every 500 ms when changed, before editor hand-off, on exit | Tabs, active tab, focus, selections, filters, layout. An invalid file is kept and disables checkpointing for that run. |
| `workspace.lock` | startup | Profile lock (`flock`). |
| `editor_session.json` (+ `.lock`) | before launching Fresh | Editor session ID and working directory. |
| `transfers/<id>.plan.json`, `<id>.state.json` | before queueing, at commit points | Immutable plan and mutable progress of a job; 64 MiB limit each, larger plans are rejected. Removed when the job is dismissed or ages out of history. |

`fc run` skips the lock, settings, workspace and transfer journals; tests
isolate the profile by setting `XDG_CONFIG_HOME`.

Outside the profile: private copies of nested archives live in `$TMPDIR/file_commander_archive_cache/nested-*` (owner-only, removed when the nested archive closes); SSH control sockets in the private
`/tmp/fcmd-ssh-<uid>/`; staging directories beside destinations as described
in rule 6.

## UI structure

Three FTXUI patterns carry the whole interface:

- **Navigation tree vs render tree.** Components decide focus and event
  routing; `Renderer(navigation, lambda)` builds the visible elements each
  frame. Panels are combined this way, so layout can differ from focus order.
- **Dialog overlay.** `DialogOverlay` keeps a `Container::Tab` whose index
  selects the main document or one overlay. `show_dialog(name)` swaps in the
  dialog, calls `OnShow()`, and rendering stacks it with `dbox` and
  `clear_under_colors`. `FileCommander` owns global dialogs (errors, jobs,
  bookmarks, theme, palette, SSH, editor restart); each `Panel` owns its own
  (mkdir, rename, copy, move, delete, find, glob, clipboard).
- **Virtualized lists.** `DBMenu` with a `DataSource` asks callbacks for the
  item count and builds elements only for visible rows. File panels, the copy
  preview, Find, the error list, bookmarks, palette and theme dialogs use it.

To add a dialog, derive from `ftxui::Dialog` (`dialogs.hpp`), put it in the
file for its area (`dialogs.cpp`, `find_dialog.cpp`, `job_dialogs.cpp`,
`settings_dialogs.cpp`), register it in the `Panel` or `FileCommander`
constructor under a name, and open it through a command (below).

## Adding a feature

**New command**
- Add a key field to `KeyBindings` in `theme.hpp` with a default in
  `theme.cpp` (`Event::Custom` means palette only).
- Add a `Command` entry in `commands.cpp` with a stable ID, scope and kind.
- `SHOW_DIALOG` commands name a registered dialog. Panel callbacks go in
  `execute_file_command` (`dialogs.cpp`); global ones in
  `FileCommander::register_commands` (`app.cpp`), with an availability
  predicate.
- Add `FC_COMMAND_CASE(id)` to `test/command_cases.inc` and its contract to
  `test/command_contracts.cpp`; the test fails while the catalog and the list
  differ.

**New job type**
- Add an `OperationType` and any new `Operation::Kind` in `operation.hpp`.
- Build the plan off the UI thread, in `fc_core`, using `traverse()` for trees.
- Execute it in `ThreadedFileJobs` (`file_io_jobs.cpp`): check cancel, then
  `wait_for_resume`, at every step; record errors and continue; stage output.
- Decide its recovery story in `transfer_journal.cpp`; by default it is
  journaled but not resumable. Handle SSH paths or reject them in `run_remote`.
- Submit from a dialog with `Dialog::submit` and add a label in
  `job_type_to_string` (`app.hpp`).

**New Lua function**
- Prefer exposing behavior as a command, reachable through `fc.command`.
- Otherwise declare a static `l_*` in `scripting.hpp`, implement it in
  `scripting.cpp` and register it in `LuaScripting::setup`. Pure-Lua helpers
  go in `fc_framework.lua`.
- Never block: waiting functions set a `PendingWait` and yield. Document it in
  [../scripting.md](../scripting.md).

**New setting**
- Preference: add a field to `AppSettings` (`settings.hpp`), validate it in
  `SettingsStore::load`, write it in `save` (`settings.cpp`), apply it in
  `FileCommander::load_settings` and capture it in `save_settings` (`app.cpp`).
- Per-tab state that must survive a crash belongs in `TabWorkspace`
  (`workspace.hpp`) and `Panel::capture_workspace`/`restore_workspace`.
- Extend the `fc.contract.settings` or `fc.contract.workspace` case in
  `test/core_contracts.cpp`.

## Known limitations

- **A paused job occupies the only worker.** Everything queued behind it,
  including small mkdir, rename and clipboard jobs, waits until it is resumed
  or cancelled.
- **Tool path lookup is executable-relative.** `fresh_binary_path` and
  `FC_FRESH_BIN` values containing a slash but not starting with one resolve
  against the directory of `fc`, not the caller's working directory. Without an
  override, a `fresh` next to `fc` wins over the build-time path, and so does a `7z.so` next to `fc` or in `../lib/file-commander/`.
- **Blocking system calls are not interruptible.** A hung directory read keeps
  that panel's loader busy; newer requests wait behind it.
- **Preferences are saved only on graceful exit.** A crash keeps the 500 ms
  workspace checkpoint but loses preference changes made since startup.
- **Local copy keeps file mode and directory access only.** Timestamps,
  ownership and extended attributes are not preserved; cross-device moves keep
  all of them, and SSH copies keep mode, mtime and extended attributes.
- **Resume is per file, not per byte.** An interrupted file restarts from the
  beginning after its owned staging is checked and removed.
- **Watchers cover only the active tab of each panel.** Archive views have no
  watcher; SSH tabs rescan every three seconds.
- **Process-wide singletons remain.** `file_operations()`, `archive_service()`,
  `commands()`, `keys()` and `theme()` are globals; isolated job managers come
  from `make_file_jobs()`. `DirItem`-based job adapters still sit beside the
  typed plans.
