
# File Commander

An orthodox file manager built with FTXUI and C++. Two-panel interface for navigating
directories and running file operations on selected items, with multithreaded execution
and real-time progress reporting.

---

## Design Goals

### 1. UI is Always Responsive

File operations never block the UI thread. Every operation follows this pipeline:

1. **Selection** - User navigates and selects files via keyboard/mouse.
2. **Command dispatch** - A shortcut key opens a confirmation dialog.
3. **Discovery** - A background thread recursively enumerates all files that will be
   affected, building an operation queue. The dialog shows live discovery progress.
4. **Confirmation** - User reviews the file list and confirms (even before discovery
   completes).
5. **Execution** - A worker thread processes the queue. A `ProgressMonitor` thread
   periodically samples file sizes and calculates throughput (Mbps).
6. **Feedback** - The progress bar updates in real-time. Errors accumulate in a log.

The UI thread only does rendering and event routing. All filesystem I/O happens on
background threads, with state updates posted back via `screen.Post()`.

### 2. Machinery First, UI as Observer

The data model (`Dir`, `DirItem`, `CommandArgs`, `JobSpec`, `FileJobs`) is designed
independently of FTXUI. The UI layer observes and issues commands to this machinery.

- `Dir` owns the file listing, sorting, filtering, and selection state.
- `FileJobs` / `ThreadedFileJobs` owns the job queue and execution threads.
- `PanelSharedState` bridges the data model to the FTXUI component tree.
- Dialogs read from and write to `CommandArgs`, then post `JobSpec` to `FileJobs`.

### 3. Extensible Command System

Commands are registered in a central `Commands` catalog with stable IDs and metadata
(`id`, key, description, scope, kind, MRU count). Both direct shortcuts and the command
palette dispatch through this catalog.

### 4. Scriptable via LuaJIT

A `fc` Lua module exposes key dispatch, state/query helpers, event waits, job waits,
and quit controls for automation and end-to-end tests. Scripts run as a UI-thread
coroutine in `run` mode. Usage: `./build/fc run test/test_copy.lua`.

### 5. Platform Boundaries

macOS filesystem monitoring uses FSEvents; Linux has an inotify backend.
The architecture isolates platform-specific code behind
`FileChangeFunnel::create()`. Native release evidence currently covers macOS
arm64; full Linux qualification remains in the release plan. Windows support
is not included in this release.

---

## Architecture Overview

```
main.cpp
  FileCommander : DialogOverlay
    Panel (left) : DialogOverlay
      Dir                 -- data model: items, sort, filter, selection
      PanelSharedState    -- bridge between Dir and FTXUI components
      Files (Dialog)      -- main file list view (DBMenu + filter + sort buttons)
      overlay dialogs     -- Mkdir, Rename, Copy, Move, Delete, Find, Clipboard
      FileChangeFunnel    -- FSEvents watcher, posts changes via FifoQueue
    Panel (right) : DialogOverlay
      (same structure)
    JobProgressBar        -- renders progress for running job
    ErrorListDialog       -- fullscreen scrollable error history
    ResizableSplit        -- draggable divider between panels

file_io_jobs.cpp
  ThreadedFileJobs : FileJobs
    FifoQueue<JobSpec>    -- FIFO job queue
    worker thread         -- pops jobs, runs copy/move/delete/archive-create
    ProgressMonitor       -- separate thread, samples file sizes, calculates Mbps

archive.cpp
  ArchiveService
    archive create        -- builds `.7z` from selected sources via local `7zr`
    archive extract cache -- extracts `.7z` to temp cache for virtual browsing
```

### Key Types

| Type | File | Role |
|------|------|------|
| `DirItem` | commander.hpp | Single file/dir entry with path, type, perms, size, time, selection, visibility |
| `Dir` | commander.hpp | Directory listing: items vector, sort order, filter, selection stats |
| `CommandArgs` | commander.hpp | Selected files + focused item + origin/target paths passed to dialogs |
| `PanelSharedState` | shared_state.hpp | Shared state between Panel and FTXUI dialogs: Dir*, filter, actions, callbacks |
| `Dialog` | dialogs.hpp | Base class for all dialogs: holds `navigation` + `renderer` Components, `OnShow()` |
| `DialogOverlay` | app.hpp | Manages `Container::Tab` + `dbox` overlay pattern for showing dialogs |
| `Panel` | app.hpp | One side of the twin-panel layout: Dir + Files + dialogs + FileChangeFunnel |
| `FileCommander` | app.hpp | Top-level: two Panels + ResizableSplit + global shortcuts + overlays |
| `EditorManager` | editor_manager.hpp | Manages Fresh sessions, open/attach flow, and in-session editor MRU |
| `ArchiveService` | archive.hpp | Archive create/extract orchestration and extraction cache management |
| `JobSpec` | file_io_jobs.hpp | Combines JobInstructions (type + items) + JobStats (progress) + JobInterface (mutex + callback) |
| `ThreadedFileJobs` | file_io_jobs.cpp | Job queue + worker thread + progress monitor |
| `FileChangeFunnel` | commander.hpp | Abstract FS watcher. macOS impl uses FSEvents in `file_change_funnel.cpp` |
| `Theme` | theme.hpp | All colors, decorators, and key bindings in one place |
| `DataSource` / `DBMenu` | alex_ftxui | Virtualized scrollable list: only renders visible rows |

---

## What Is Implemented

### Core UI

- **Twin panel layout** with `ResizableSplit` and a draggable double-line separator.
  Panels auto-resize to 50/50 on terminal width change.
- **File list** using custom `DBMenu` (DataSource-driven virtualized Menu). Only visible
  rows are rendered, enabling directories with thousands of items.
- **Sort buttons** (Name, Size, Date) toggle ASC/DESC. Directories always sort before files.
- **Filter by typing** - substring match (case-insensitive). The filter input doubles as
  the path display (placeholder shows current path, typed text filters).
- **Selection** - Space toggles, Ctrl+A selects all visible, Esc clears. Selection bar
  shows count and byte totals.
- **Focus-as-fallback** - if nothing is selected, the focused item is used for commands.
- **Dialog overlay system** - `DialogOverlay` base class manages `Container::Tab` for
  focus routing and `dbox` + `clear_under_colors` for visual stacking.

### Navigation

- **Enter directory** (Return) and **leave directory** (?). On leaving, the previous
  directory is focused in the parent listing.
- Entering a focused `.7z` item opens a virtual archive directory view.
- Leaving from archive-root (`?`) returns to archive parent and focuses the archive file.
- **Tab** switches focus between left and right panels.
- **Ctrl+Right / Ctrl+Left** navigates the target panel to the focused item's directory.
- **Ctrl+R** refreshes the current directory listing.

### Command Palette

- **Global command palette** on `F1` with fuzzy matching, command descriptions, and
  visible key bindings.
- Supports both panel and global commands.
- Executes focused result on `Enter`.
- Tracks command usage (MRU via `use_count`) and persists it in settings.
- Includes command-key rebinding flow with conflict checks.

### Fresh Editor Integration

- Local Fresh integration is built from `../editor-fresh` when `FC_BUILD_FRESH=ON`.
- Runtime command set:
  - `F4`: open focused item(s) in Fresh
  - `F10`: switch to Fresh and detach back to FC
  - `Restart editor backend` in the palette: checkpoint and restart the backend
- Opening policy:
  - one backend per FC profile; Fresh owns file tabs and tab closure
  - a directory selects its filesystem workspace, then attaches
  - files route explicitly to their local or SSH filesystem workspace, then attach
  - local and remote workspaces retain unsaved buffers when switching
- Attach runs with restored terminal IO so control cleanly returns when Fresh detaches/exits.
- Session metadata (`last_editor_session_id`) and binary override (`fresh_binary_path`)
  are persisted in FC settings.

### File Operations

- **Mkdir** (F7) - text input dialog, validates name conflicts.
- **Rename** (F2) - multi-file rename. Each selected item gets an editable Input field.
  Successfully renamed items are removed from the list; failed ones stay for retry.
- **Copy** (F5) - background `CopyDiscoveryProcess` recursively enumerates source files
  in a separate thread. Handles symlinks (follow/preserve-relative/cyclic detection).
  Shows live discovery progress (byte count, dir count, file count). Uses
  `boost::filesystem::copy_file` with `overwrite_existing`.
- **Move** (F6) - uses `boost::filesystem::rename`. Falls back to copy+delete for
  cross-device moves (`EXDEV` / `cross_device_link` error).
- **Delete** (F8) - separate discovery and execution threads via `FifoQueue<DirItem>`.
  Discovery recursively enumerates, execution deletes as items arrive.
- **Names to clipboard** (Ctrl+N) / **Paths to clipboard** (Ctrl+P) - copies via `pbcopy`.

### Archive Support

- Archive format support for this phase: `.7z`.
- **Create archive**: in Copy dialog, when destination path ends with `.7z`, operation
  is dispatched as an `ARCHIVE_CREATE` job instead of file-copy.
- **Browse archive as directory**: pressing Return on a `.7z` file extracts it to a
  temp cache and navigates panel into extracted contents.
- **Extract from archive**: copy from virtual archive view to a normal directory uses
  existing Copy dialog flow (same UX as normal file copy).
- Extraction cache is keyed by archive identity (`canonical path + size + mtime`) and
  reused in-session when unchanged.
- Archive tooling defaults to local `7zr` built from `../lzma2600` (see build section).

### Job System

- `ThreadedFileJobs` manages a FIFO queue of `JobSpec` objects.
- One worker thread processes jobs sequentially.
- `ProgressMonitor` runs in a separate thread, periodically (200ms) sampling destination
  file sizes for large files (>10MB) to calculate per-file and total Mbps.
- `JobProgressBar` renders: `[queued] [TYPE] | [total%] avg_Mbps items | [item%] Mbps path`
- Errors from job execution are reported to the global error log.

### Real-Time Directory Monitoring

- macOS: `FSEvents` via `DirEvents` class. Watches the current directory per panel.
  Events are filtered to only include direct children (not recursive subdirectories).
- Changes are batched into `UpdatedFiles` and posted to the UI thread via
  `FifoQueue + screen.Post()`. `Dir::partial_refresh()` applies changes incrementally
  (add new items, update existing, remove deleted).
- On directory change (`move_to`), the old watcher is replaced with a new one.

### Error Management

- Global error log in `ThreadedFileJobs._errors` with monotonically increasing timestamps.
- Quick preview: bottom of screen shows last N errors (configurable `max_errors_to_show`).
- **Error list dialog** (Ctrl+E) - fullscreen scrollable list using `DBMenu`.
- **Clear errors** - triple-press Esc within 1 second clears all errors.

### Theme System

- `Theme` struct holds all colors, decorators, and key bindings.
- Pre-built `Decorator` values for direct `|` application (e.g., `theme().files_selected`).
- File type colors: directories (turquoise), symlinks (magenta), executables (green blend),
  regular files (white), plus colors for block/character/fifo/socket/reparse/unknown.
- Size-relative background gauge (`BgGaugeLeft`) behind filenames shows relative file size.
- `ColoredInt` renders numbers with different colors per 3-digit group.

### Custom FTXUI Extensions

- `DBMenu` - DataSource-driven virtualized menu (in alex_ftxui fork).
- `ColoredInt` - custom Node for colored number rendering.
- `BgGaugeLeft` - NodeDecorator for partial background fill.
- `ShowInputCursor` - NodeDecorator that inverts pixel at cursor position.
- `ClearUnder` - NodeDecorator that clears background before rendering (for dialog overlays).
- `LogAdapter` - redirects log output through `WithRestoredIO` while FTXUI is active.
- `event_from_string` - maps string tokens to FTXUI Event values for CLI automation.

### LuaJIT Scripting

- `./build/fc run script.lua` runs a Lua test script as a coroutine on the UI thread.
- Available API includes `fc.key(...)`, `fc.state()`, `fc.wait_event(...)`,
  `fc.wait_for_jobs(...)`, `fc.sleep(...)`, `fc.quit()`.
- Errors from Lua scripts are reported to the error log.

---

## Known Bugs

| Bug | Details |
|-----|---------|
| Copy dir into itself | No guard when source and destination overlap at directory level. The per-file `equivalent()` check catches file-to-self but not subtree containment. |
| macOS mounted volumes | External filesystem changes (e.g., `mkdir` on a mounted flash disk) may not trigger FSEvents. |
| Focused item drift | `focused_id` is an index into `Dir::items`. When `partial_refresh` inserts/removes items, the focused index may point to a different file. Should track by path instead. |

---

## What Is Left To Do

### Priority 1: Complete Core Operations

#### 1.1 Copy Overwrite Options (replace / update / skip)

Currently all copies use `overwrite_existing`. Need conflict resolution UI.

**Steps:**
1. Add `CopyConflict` enum (already defined: `Replace`, `Update`, `Skip`) to `CopyDialog`.
2. Add a `Radiobox` or three `Checkbox` components to CopyDialog for selecting conflict mode.
3. Pass the selected mode through `CopyDiscoveryProcess` to the job items. Store it in
   `JobSpec` or per-item metadata.
4. In `ThreadedFileJobs::run_copy()`, before `copy_file()`:
   - `Skip`: check if destination exists, skip if it does.
   - `Update`: check if destination exists AND source is newer, skip if not.
   - `Replace`: current behavior (overwrite).
5. Add `destination_path` input back to CopyDialog (currently commented out) so users can
   edit the target path.

#### 1.2 Job Cancellation

`cancel_job()` exists but is a no-op. Jobs have no cancellation token.

**Steps:**
1. Add `std::atomic<bool> _cancelled{false}` to `JobSpec`.
2. In `ThreadedFileJobs::run_copy/move/delete`, check `_cancelled` before processing each
   item. Break the loop if true. Set `_finished_time`.
3. In `CopyDiscoveryProcess::_discover`, check `_running` before processing each item
   (partially done already).
4. Implement `cancel_job()` in `ThreadedFileJobs`: set the flag, optionally remove from queue
   if not yet started.
5. Add a cancel button/shortcut to the progress bar or a new task management dialog.

#### 1.3 Job Pause / Resume

**Steps:**
1. Add `std::atomic<bool> _paused{false}` and a `std::condition_variable` to `JobSpec`.
2. In the worker loop, after each item: if `_paused`, wait on the condition variable.
3. Add pause/resume controls to `JobProgressBar` or a task management dialog.
4. `ProgressMonitor` should skip paused jobs (don't sample file sizes).

#### 1.4 Focused Item Tracking by Path

Currently `focused_id` is an index. When `Dir::partial_refresh` adds/removes items,
the index silently shifts to a different file.

**Steps:**
1. Store a `Filepath _focused_path` alongside `focused_id` in `DataSource`.
2. After `partial_refresh` + `_sort()`, scan `Dir::items` to find `_focused_path` and
   update `focused_id` to its new index.
3. If the focused file was deleted, move focus to the nearest visible neighbor.

---

### Priority 2: Panel Features

#### 2.1 Panel Tabs

Each panel should support multiple tabs, each with its own Dir, sort, filter, and selection.

**Steps:**
1. Uncomment and implement the `DirCollection` struct in `commander.hpp`:
   ```cpp
   struct DirCollection {
     std::vector<Dir> tabs;
     int selected_tab = 0;
   };
   ```
2. Change `Panel` to hold a `DirCollection` instead of a single `Dir`.
3. Add tab bar rendering above the file list (horizontal list of dir names).
4. Add key bindings for new-tab (inherit config from current), close-tab, switch-tab.
5. Only create/update `FileChangeFunnel` for the active tab. Deferred refresh for
   background tabs.
6. Each `Files` dialog instance needs its own `DataSource`, filter input, and sort state.

#### 2.2 Single Panel Full-Width Mode

**Steps:**
1. Add a `bool _single_panel_mode` flag to `FileCommander`.
2. Add a toggle shortcut (e.g., Ctrl+O) in `handle_global_shortcuts`.
3. In the renderer lambda: when single-panel, render only the focused panel at full
   width. Show the other panel's path in a small header/footer bar.
4. `ResizableSplit` should be bypassed in single-panel mode.

#### 2.3 Glob Select / Deselect

**Steps:**
1. Create a `GlobSelectDialog : Dialog` with an Input for the glob pattern and
   OK/Cancel buttons.
2. On OK, iterate `Dir::items` and toggle selection for items matching the glob
   (use `boost::filesystem::path::extension()` or a simple glob matcher).
3. Register the dialog in `Panel::_overlay_dialogs` with a key shortcut (e.g., `+` for
   select, `-` for deselect, matching Norton Commander convention).

#### 2.4 Directory Bookmarks

**Steps:**
1. Create a `BookmarksDialog : Dialog` that shows a list of saved paths.
2. Store bookmarks in a `std::vector<Filepath>` on `Theme` or a dedicated config struct.
3. Allow adding current dir as bookmark, removing bookmarks, and navigating to a bookmark.
4. Integrate with "Keep state across runs" (see 3.3) for persistence.

---

### Priority 3: Extensibility

#### 3.1 Command Palette (vscode-like F1)

Status: **Implemented**

Implemented behavior:
1. `F1` opens global `CommandPaletteDialog`.
2. Fuzzy search filters panel and global commands.
3. Rows show description + current key binding.
4. `Enter` executes focused command.
5. Usage updates MRU ranking (`use_count`) and persists via settings.

Remaining follow-ups are tracked under registry/persistence/rebinding improvements.

#### 3.2 LuaJIT Testing Framework

Lua scripts drive the full UI for automated end-to-end testing. The test script runs
on the **main UI thread** as a Lua coroutine, so key dispatches and state queries are
synchronous with zero overhead. Only async waits (job completion, discovery) yield the
coroutine back to the FTXUI event loop.

**Design principles:**
- **Same thread**: `fc.key("f5")` calls `component->OnEvent(Event::F5)` directly —
  no thread hop, no marshalling. State queries read `Dir`/`Panel` directly.
- **Coroutine-based**: the test script runs inside `lua_resume()`. It yields only
  when waiting for an async event (`fc.wait_event`). The FTXUI event loop resumes
  it when the condition is met or timeout expires.
- **Event-driven waits**: `fc.wait_event("job_completed", 30000)` replaces `sleep()`.
  Background threads (copy worker, progress monitor) post `Event::Custom` which
  wakes the event loop and triggers `check_lua_waits()`.
- **Plain Lua**: test scripts use `assert()`, `io`, `os` from the standard library.
  No special test runner — `./fc run test/test_copy.lua`.

**Startup flow** (in `main.cpp`):
1. Create `FileCommander` as usual. Store global `g_app` and `g_root` pointers.
2. Create Lua state, register C functions, load `fc_framework.lua`.
3. Load the test script as a Lua coroutine.
4. Post a closure via `screen.Post()` that calls `lua_resume(co, 0)`.
5. Enter `screen.Loop()`. The posted closure fires on the first event loop iteration,
   starting the test script.

##### Action Concept

Unify all key-triggered operations under named **actions**. Currently key→operation
mappings are spread across `Commands::Commands()` (file op dialogs),
`handle_global_shortcuts()` (panel switching, refresh), and `filelist_handle_commands()`
(select, enter_dir). An action system centralises them.

```cpp
struct Action {
  std::string name;           // "copy", "select_all", "enter_dir"
  std::string description;    // Human-readable
  std::vector<Event> keys;    // Multiple keys can trigger this
  double last_used_time = 0;  // MRU priority when keys conflict
  enum class Scope { GLOBAL, PANEL, DIALOG } scope;
};
```

Action registry (replaces `Commands` and hardcoded key checks):
- **Global scope**: `switch_panel`, `refresh_dir`, `target_right`, `target_left`,
  `toggle_errors`, `clear_errors`.
- **Panel scope**: `select`, `select_all`, `clear_selection`, `enter_dir`, `leave_dir`,
  `copy`, `move`, `mkdir`, `delete`, `rename`, `names_to_clipboard`,
  `paths_to_clipboard`, `find`.
- **Dialog scope**: `cancel`, `confirm`.

Key conflict resolution: when multiple actions share the same key, the one with the
most recent `last_used_time` wins.

##### `fc.key()` Dispatch

`fc.key(name_or_table)` accepts a string or a table of strings:
```lua
fc.key("f5")                        -- single key event
fc.key("a")                         -- single character (text input)
fc.key("copy")                      -- action name (len > 2)
fc.key({"cA", "f5", "<-", "ret"})   -- sequence
```

Dispatch rules for a single name:
- `#name == 1` : character input → `Event::Character(name[0])`
- `#name == 2` : event code → `event_from_string(name)` ("f5", "cA", etc.)
- `#name >= 3` : try action registry first; fall back to `event_from_string`
  (covers "up", "esc", "ret", "tab", "down", "back", "f10"–"f12", etc.)

No yield needed — `OnEvent()` is synchronous on the same thread.

##### Events

Events are fired from C++ into a ring buffer. Lua can wait for them.

| Event | Fired when | Detail |
|-------|-----------|--------|
| `dialog_opened` | `DialogOverlay::show_dialog()` | dialog name |
| `dialog_closed` | `DialogOverlay::close_dialog()` | — |
| `dir_changed` | `Panel::move_to()` | new path |
| `items_updated` | `Dir::partial_refresh()` / `Dir::refresh()` | — |
| `selection_changed` | `Dir::item_toggle_select/select_all/clear_selection` | count |
| `job_started` | Polled via `_started_time > 0` | job type |
| `job_completed` | Polled via `is_stopped()` | job type |
| `discovery_completed` | Polled via `_running == false` | — |
| `error_reported` | `file_operations().report_error()` | message |
| `errors_cleared` | `file_operations().clear_errors()` | — |
| `tab_switched` | (future — not yet implemented) | side, tab index |
| `tab_created` | (future) | side |
| `tab_closed` | (future) | side |

Background-thread events (`job_completed`, `job_started`, `discovery_completed`) are
detected by polling on the UI thread. The worker thread already posts `Event::Custom`
via `updated()`, which wakes the event loop.

##### States

`fc.state()` returns a comprehensive snapshot:
```lua
{
  left = {
    path = "/Users/alex/code",
    item_count = 15,
    focused_index = 3,
    focused_path = "/Users/alex/code/main.cpp",
    selected_count = 2,
    selected_paths = {"/Users/alex/code/a.txt", "/Users/alex/code/b.txt"},
    filter = "",
    sort = "name_asc",
    has_dialog = false,
    active_dialog = nil,
    -- Tabs (NOT YET IMPLEMENTED - currently always 1 tab).
    -- When implemented: switching active tab on one side does NOT
    -- affect the other side. A "tab_switched" event is fired on
    -- the affected side only.
    tabs = { {path = "/Users/alex/code", active = true} },
  },
  right = { --[[ same structure ]] },
  jobs = {
    active = false,
    type = nil,
    progress = 0,
    items_total = 0,
    items_done = 0,
    queued = 0,
  },
  error_count = 0,
  errors = {},
}
```

Convenience getters: `fc.focused()`, `fc.selected()`, `fc.left_path()`,
`fc.right_path()`. All direct reads — no yield.

##### Waiting on Events

```lua
fc.wait_event("job_completed", 30000)                -- single event
fc.wait_event({"dialog_closed", "error_reported"}, 5000)  -- any of
```

Returns `true` on match, `nil` on timeout. Yields the coroutine; resumes when
`check_lua_waits()` detects the event or timeout in the FTXUI event loop.

##### API Reference

| Function | Returns | Yields | Description |
|----------|---------|--------|-------------|
| `fc.key(name)` | — | no | Dispatch key/action. Accepts string or table. |
| `fc.left_cd(path)` | — | no | Navigate left panel to path. |
| `fc.right_cd(path)` | — | no | Navigate right panel to path. |
| `fc.state()` | table | no | Full state snapshot (see above). |
| `fc.focused()` | string | no | Focused path in active panel. |
| `fc.selected()` | table | no | Selected paths in active panel. |
| `fc.left_path()` | string | no | Left panel directory path. |
| `fc.right_path()` | string | no | Right panel directory path. |
| `fc.errors()` | table | no | All error messages. |
| `fc.wait_event(name, ms)` | bool/nil | yes | Wait for event with timeout. |
| `fc.wait_for_jobs(ms)` | bool/nil | yes | Shorthand for wait_event("job_completed"). |
| `fc.sleep(ms)` | — | yes | Yield for N ms (escape hatch). |
| `fc.quit()` | — | no | Exit the application. |

##### Key Names

| Category | Names |
|----------|-------|
| Arrows | `up`, `down`, `<-`, `->` |
| Ctrl+arrows | `cup`, `cdown`, `c<-`, `c->` |
| Special | `ret`, `esc`, `tab`, `stab`, `back`, `del` |
| Function | `f1`–`f12` |
| Ctrl+letter | `cA`–`cZ` |
| Character | Any single char: `" "`, `"?"`, `"a"` |

##### Test Directory Structure

```
fc_framework.lua          -- preloaded framework code
test/
  helpers.lua             -- shared setup/teardown utilities
  test_copy.lua           -- copy: single file, dirs, symlinks
  test_move.lua           -- move: same device, cross-device
  test_delete.lua         -- delete: files, dirs, nested
  test_mkdir.lua          -- mkdir: create, name conflict
  test_rename.lua         -- rename: single, multi-file
  test_navigation.lua     -- enter/leave dirs, tab, filter
```

Run: `./fc run test/test_copy.lua`

#### 3.3 Persist State Across Runs

**Steps:**
1. Define a settings file location (e.g., `~/.config/file_commander/settings.json`).
2. On exit, serialize: panel paths, tab states, sort orders, bookmarks, window size,
   key binding overrides, command MRU order.
3. On startup, load and apply. Fall back to defaults for missing fields.
4. Optionally support loading settings from HTTP URL (fetch JSON on startup).

#### 3.4 Shortcut Rebinding

The `Theme` struct already holds all key bindings. Need a UI to change them.

**Steps:**
1. In the command palette, add an "edit shortcut" action per command.
2. Show a "press new key" capture dialog (a `CatchEvent` that records the next event).
3. Update `Theme` in memory and persist to settings file.
4. Handle conflicts: warn if a key is already bound to another command.

---

### Priority 4: Find Files

#### 4.1 Find Dialog with BFS

**Steps:**
1. Create `FindDialog : Dialog` with inputs for: search path, filename pattern (glob or
   regex), content search (optional).
2. Run a breadth-first traversal in a background thread (reuse `FifoQueue` pattern from
   delete discovery).
3. Results accumulate in a virtual `Dir` with an empty parent path ("Result-Tab" concept).
4. Allow the `Dir` to contain items from different parent directories.
5. Show results in a `DBMenu` with live updates as the search progresses.
6. On completion, the result becomes a new tab in the source panel.

#### 4.2 Result-Tabs Concept

A `Dir` that holds a mixed set of files from various directories.

**Steps:**
1. Allow `Dir::path` to be empty (sentinel for result-tab mode).
2. In result-tab mode, `partial_refresh` is a no-op (no FS watcher).
3. `leave_dir()` on a result-tab should close the tab.
4. File operations on result-tab items use each item's actual parent path.
5. Store per-directory ignore lists in settings (for future find-in-project use).

### Priority 6: Platform Support

#### 6.1 Linux inotify

**Steps:**
1. Create `LinuxDirEvents : FileChangeFunnel` using `inotify_init`, `inotify_add_watch`.
2. Run an `epoll` loop in a background thread.
3. Map `IN_CREATE`, `IN_DELETE`, `IN_MOVED_FROM`, `IN_MOVED_TO`, `IN_MODIFY` to
   `DirItemUpdated::Event`.
4. Guard with `#ifdef __linux__` in `FileChangeFunnel::create()`.

### Priority 7: Polish

#### 7.3 Additional Columns

Currently showing: name, size (colored), date. Need to add:
- Permissions (octal or rwx display)
- Owner / Group
- Configurable column visibility and order per tab.

**Steps:**
1. Add `perms_string()` and `owner_string()` methods to `DirItem`.
2. Store column configuration in `Dir` or `PanelSharedState`.
3. Modify `filelist_transform` to render enabled columns.
4. Add column toggle shortcuts or a column picker dialog.

#### 7.4 Drag and Drop to External Apps

- Investigate `CLIdrag` (https://github.com/rkevin-arch/CLIdrag).
- Implement as a command triggered by mouse-drag event.
- Consider shared-library approach for multi-instance coordination.
- Note: not feasible over SSH.

---

### Priority 8: Integration

#### Text editor

Status: **Implemented (Fresh integration)**

Implemented:
1. Build integration with local source at `../editor-fresh`.
2. Runtime handoff from FC to Fresh with restored terminal IO.
3. Session-aware open/switch flows via `EditorManager`.
4. Palette + shortcut integration for editor commands.
5. Contract documented in `doc/fresh_cli_contract.md`.

Deferred:
1. Windows-specific integration path.

---

## Baseline Requirements for Orthodox File Manager

| Requirement | Status |
|-------------|--------|
| Twin panel layout | Done |
| Copy | Done (missing overwrite options) |
| Move | Done (with cross-device fallback) |
| Delete | Done (with discovery+execution threads) |
| Rename / Multi-rename | Done |
| Mkdir | Done |
| Columns: name, size, date | Done |
| Columns: permissions, owner, group | Not yet |
| Sort on any column | Done (name, size, date) |
| File type indication | Done (colors + `/` prefix for dirs) |
| Symlink display | Done (shows `->` target on second row) |
| Directory change notifications | Done (macOS), missing (Linux, Windows) |
| Background operations | Done |
| Progress display | Done |
| Global command palette | Done (`F1`, fuzzy search, execute, MRU) |
| Fresh editor handoff | Done (local Fresh build + runtime attach/switch) |
| Archive create/extract (`.7z`) | Done (create via Copy dialog, browse virtual dir, extract via copy) |

---

## History

### Motivation

An orthodox file manager (Norton Commander style) reimagined for 2025 with:

- **Command palette** (vscode-like) - single key to access all commands, fuzzy search,
  MRU ordering, visible shortcuts, edit shortcuts in-place.
- **Terminal UI via FTXUI** - accessible over SSH, beautiful with 256-color terminals,
  no GUI dependencies.
- **Multithreaded file operations** - the single biggest difference from traditional
  terminal file managers. File operations never freeze the UI. Discovery and execution
  happen concurrently with live progress.
- **Filter by typing** - no separate search mode; just type to filter the current listing.
- **LuaJIT scripting** - custom commands without recompilation.
- **No integrated terminal** - focused tool, not a terminal multiplexer.

### Workflow

1. Navigate directories in the twin-panel view.
2. Select files (Space / Ctrl+A / glob).
3. Press a command key (F5=Copy, F6=Move, F7=Mkdir, F8=Delete, F2=Rename).
4. A dialog opens showing the operation parameters and a preview of affected files.
5. Background discovery enumerates all files recursively (for Copy/Delete).
6. Confirm the operation. It runs in a background thread.
7. Progress bar shows live throughput and item counts.
8. Continue working in the panels while operations execute.

---

## Links

- [Midnight Commander reference](https://www.redhat.com/en/blog/midnight-commander-file-manager)
- [copy_file_range vs sendfile performance](https://unix.stackexchange.com/questions/771238/linux-syscalls-advantage-of-copy-file-range-over-sendfile)
- [CLIdrag for terminal drag-and-drop](https://github.com/rkevin-arch/CLIdrag)
- [Howl editor (potential builtin editor)](https://howl.io/)
- [Clipboard monitoring on Windows](https://stackoverflow.com/questions/65840288/monitor-clipboard-changes-c-for-all-applications-windows)
