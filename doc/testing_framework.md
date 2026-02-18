---
name: Lua Testing Framework
overview: "Phase 1 (complete): Same-thread coroutine Lua testing framework. Phase 2 (complete): Refactored into scripting.hpp/cpp, encapsulated into LuaScripting class, eliminated globals, added ScheduledUpdates. Event-driven architecture — no periodic polling."
todos:
  - id: scheduled-updates
    content: "Implement ScheduledUpdates class in scripting.hpp/cpp: priority_queue<double> timer thread that sleeps until next scheduled time, posts Event::Custom"
    status: completed
  - id: lua-scripting-class
    content: "Implement LuaScripting class in scripting.hpp/cpp: move all Lua state, event log, pending wait, poll state, C callbacks from main.cpp. Use registry-based 'this' pointer in C callbacks."
    status: completed
  - id: on-event-callback
    content: "Replace g_fire_event global with DialogOverlay::on_event member callback. Set from main.cpp when LuaScripting is active."
    status: completed
  - id: update-main
    content: "Update main.cpp: remove all Lua code, extract app classes to app.hpp, include scripting.hpp, instantiate LuaScripting in lua_mode block, wire on_event callbacks, explicit ftxui::Loop + scripting.tick()"
    status: completed
  - id: build-and-test-phase2
    content: "Build and run test/test_copy.lua to verify refactoring preserves behavior"
    status: completed
  - id: event-driven-discovery
    content: "Make CopyDiscoveryProcess post Event::Custom on completion, remove all periodic polling, rely on schedule_at(deadline) for timeouts"
    status: completed
isProject: false
---

# LuaJIT Testing Framework (Revised)

## 1. Same-Thread Lua Execution with Coroutines

Run Lua on the main UI thread instead of a background thread. This eliminates all synchronization complexity: no promises, no futures, no data races.

```mermaid
sequenceDiagram
    participant Main as MainThread
    participant Loop as FTXUI_Loop
    participant Tick as scripting.tick()
    participant Lua as LuaCoroutine
    Main->>Loop: ftxui::Loop loop(&screen, app.renderer)
    Loop->>Loop: RunOnceBlocking — wait for task
    Note over Loop: First iteration
    Loop-->>Tick: tick() — first call
    Tick->>Lua: lua_resume(co) — start coroutine
    Lua->>Lua: fc.key("f5") — direct OnEvent dispatch
    Lua->>Lua: fc.key("ret") — direct OnEvent dispatch
    Lua->>Tick: fc.wait_event("job_completed") — lua_yield
    Note over Tick: schedule_at(deadline)
    Loop->>Loop: RunOnceBlocking — process events
    Note over Loop: Job finishes, worker posts Event::Custom
    Loop-->>Tick: tick() — poll_async_events → check_waits
    Note over Tick: event log has "job_completed"
    Tick->>Lua: lua_resume(co) — continue test
    Lua->>Lua: assert(#fc.errors() == 0)
    Lua->>Lua: fc.quit()
```



**Why this is better:**

- `fc.key("f5")` calls `component->OnEvent(Event::F5)` directly — synchronous, instant, no thread hop
- State queries (`fc.focused()`, `fc.selected()`) read directly from `Dir`/`Panel` — no marshalling
- Only `fc.wait_event()` yields the coroutine (for async ops like job completion)
- Fully event-driven: all async workers (`FileIOJobs`, `CopyDiscoveryProcess`) post `Event::Custom` on completion — no periodic polling needed
- `ScheduledUpdates` provides precise one-shot wake-ups for timeouts via `schedule_at(deadline)`
- `tick()` runs after every `RunOnceBlocking()` — Lua always sees a consistent, post-render state

**FTXUI loop internals** (from [alex_ftxui/src/ftxui/component/screen_interactive.cpp](../alex_ftxui/src/ftxui/component/screen_interactive.cpp)):

- `RunOnceBlocking()`: wait for one task (blocking) -> handle it -> call `RunOnce()`
- `RunOnce()`: drain all pending tasks non-blocking -> `Draw()`
- `HandleTask()`: if Event -> `component->OnEvent(event)`; if Closure -> call it
- Both `Post(Event)` and `Post(Closure)` go through the **same FIFO queue** — order preserved

**Startup flow in [main.cpp](main.cpp):** *(current implementation — explicit Loop + tick())*

```cpp
if (lua_mode) {
    LuaScripting scripting(app, app.renderer);

    auto fire = [&scripting](const std::string& n, const std::string& d) {
      scripting.fire_event(n, d);
    };
    app.on_event             = fire;
    app.get_left().on_event  = fire;
    app.get_right().on_event = fire;

    if (!scripting.setup(lua_script_path)) return 1;

    ftxui::Loop loop(&screen, app.renderer);
    while (!loop.HasQuitted()) {
        loop.RunOnceBlocking();
        scripting.tick();   // first call starts coroutine; thereafter checks waits
    }
    scripting.cleanup();
} else {
    screen.Loop(app.renderer);
}
```

## 2. Action Concept

Unify all key-triggered operations under a named **Action** system. Currently key->operation mappings are spread across three places:

- `Commands::Commands()` in [dialogs.cpp:1123-1134](dialogs.cpp) — file op dialogs
- `handle_global_shortcuts()` in [main.cpp:307-371](main.cpp) — panel switching, refresh, etc.
- `filelist_handle_commands()` in [dialogs.cpp:130-211](dialogs.cpp) — select, enter_dir, etc.

**Action struct:**

```cpp
struct Action {
    std::string name;           // "copy", "select_all", "enter_dir"
    std::string description;    // Human-readable
    std::vector<Event> keys;    // Multiple keys can trigger this
    double last_used_time = 0;  // For MRU priority when keys conflict
    enum class Scope { GLOBAL, PANEL, DIALOG } scope;
};
```

**Action registry** (replaces `Commands::Commands()` and hardcoded key checks):

- **Global scope** (handled at FileCommander level):
  - `switch_panel` — Tab
  - `refresh_dir` — Ctrl+R
  - `target_right` — Ctrl+Right
  - `target_left` — Ctrl+Left
  - `toggle_errors` — Ctrl+E
  - `clear_errors` — Esc (triple-press)
- **Panel scope** (handled in Files/filelist):
  - `select` — Space
  - `select_all` — Ctrl+A
  - `clear_selection` — Esc
  - `enter_dir` — Return
  - `leave_dir` — ?
  - `copy` — F5
  - `move` — F6
  - `mkdir` — F7
  - `delete` — F8
  - `rename` — F2
  - `names_to_clipboard` — Ctrl+N
  - `paths_to_clipboard` — Ctrl+P
  - `find` — F3
- **Dialog scope** (handled within dialogs):
  - `cancel` — Esc
  - `confirm` — Return (dialog-specific)

**Key conflict resolution:** When multiple actions share the same key, the one with the most recent `last_used_time` wins. This allows user customization without breaking defaults.

**Plan for implementation:**

1. Create `ActionRegistry` class with `register_action()`, `lookup_by_key()`, `lookup_by_name()`, `execute()`
2. Refactor `Commands::Commands()` to register actions instead of raw key-dialog pairs
3. Refactor `handle_global_shortcuts()` to use action lookup
4. Refactor `filelist_handle_commands()` to use action lookup
5. Each action stores its handler as `std::function<bool()>` (returns whether it was consumed)

## 3. `fc.key()` Dispatch Logic

`fc.key(name_or_table)` accepts a string or table of strings:

```lua
fc.key("f5")                     -- single key event
fc.key("a")                      -- single character (text input)
fc.key("copy")                   -- action name (len > 2)
fc.key({"cA", "f5", "<-", "ret"}) -- sequence: select all, copy, focus OK, confirm
```

**Dispatch rules for a single name:**

- `#name == 1` : character input -> `Event::Character(name[0])`
- `#name == 2` : event code -> `event_from_string(name)` (covers "f5", "cA", etc.)
- `#name >= 3` : try action registry first -> if not found, try `event_from_string` (covers "up", "esc", "ret", "tab", "down", "back", "stab", "f10"-"f12", "cup", "cdown", "c<-", "c->")

**C implementation:**

```cpp
static int lua_fc_key(lua_State* L) {
    // Handle table argument
    if (lua_istable(L, 1)) {
        int n = lua_objlen(L, 1);
        for (int i = 1; i <= n; i++) {
            lua_rawgeti(L, 1, i);
            lua_fc_key(L);  // recursive call for each element
            lua_pop(L, 1);
        }
        return 0;
    }
    const char* name = luaL_checkstring(L, 1);
    size_t len = strlen(name);

    if (len == 1) {
        g_root->OnEvent(Event::Character(name[0]));
    } else if (len == 2) {
        g_root->OnEvent(event_from_string(name));
    } else {
        // Try action registry first
        if (!g_action_registry.execute_by_name(name)) {
            // Fall back to event_from_string
            g_root->OnEvent(event_from_string(name));
        }
    }
    return 0;
}
```

No yield needed — `OnEvent()` is synchronous on the same thread.

## 4. Events and States

### Events

Events are fired from C++ code and stored in a ring buffer. Lua can wait for specific events.

**Event struct** (member of `LuaScripting`):

```cpp
// In LuaScripting class (scripting.hpp):
struct ScriptEvent {
    std::string name;
    double      timestamp;
    std::string detail;
};
std::deque<ScriptEvent> _event_log;
size_t                  _event_cursor = 0;

// Public API:
void fire_event(const std::string& name, const std::string& detail = "");
```

Events are fired via the `on_event` callback on `DialogOverlay` instances, which is wired
to `scripting.fire_event()` in `main()`. Background events (`job_completed`, `job_started`,
`discovery_completed`) are detected by `poll_async_events()` inside `tick()`.

**Where events are fired** (all on UI thread unless noted):


| Event                 | Source location                                                               | Detail          |
| --------------------- | ----------------------------------------------------------------------------- | --------------- |
| `dialog_opened`       | `DialogOverlay::show_dialog()` in [app.hpp](app.hpp) via `on_event` callback  | dialog name     |
| `dialog_closed`       | `DialogOverlay::close_dialog()` in [app.hpp](app.hpp) via `on_event` callback | —               |
| `dir_changed`         | `Panel::move_to()` in [app.hpp](app.hpp) via `on_event` callback              | new path        |
| `items_updated`       | `Dir::partial_refresh()` / `Dir::refresh()` in [commander.cpp](commander.cpp) | —               |
| `selection_changed`   | `Dir::item_toggle_select()` / `Dir::select_all()` / `Dir::clear_selection()`  | count           |
| `job_completed`       | Polled in `tick()` via `_finished_time` timestamp; worker posts `Event::Custom` | job type        |
| `job_started`         | Polled in `tick()` via `_started_time` timestamp; worker posts `Event::Custom`  | job type        |
| `discovery_completed` | Polled in `tick()` via `_running == false`; discovery posts `Event::Custom`     | —               |
| `error_reported`      | `file_operations().report_error()` in [file_io_jobs.cpp](file_io_jobs.cpp)    | message         |
| `errors_cleared`      | `file_operations().clear_errors()`                                            | —               |
| `tab_switched`        | (future — not yet implemented)                                                | side, tab index |
| `tab_created`         | (future)                                                                      | side            |
| `tab_closed`          | (future)                                                                      | side            |


**Background-thread events** (`job_completed`, `job_started`, `discovery_completed`): These originate on worker threads. Rather than fire them directly (thread safety issue), `tick()` → `poll_async_events()` detects state changes on the UI thread. All background operations post `Event::Custom` when they complete, which unblocks `RunOnceBlocking()` and triggers `tick()`:

- **Job start/completion**: Worker thread posts `Event::Custom` via `updated()` (defined in [file_io_jobs.cpp:21-26](file_io_jobs.cpp)). Detected by comparing `_started_time` / `_finished_time` timestamps.
- **Discovery completion**: `CopyDiscoveryProcess::_run()` posts `Event::Custom` after setting `_running = false` (in [dialogs.cpp](dialogs.cpp)). Detected by state transition `_had_discovery → !discovery_running`.

No periodic polling is needed — the event loop unblocks naturally when async work completes.

### States

`fc.state()` returns a comprehensive snapshot as a Lua table:

```lua
{
  left = {
    path = "/Users/alex/code",
    item_count = 15,         -- visible items
    focused_index = 3,
    focused_path = "/Users/alex/code/main.cpp",
    selected_count = 2,
    selected_paths = {"/Users/alex/code/a.txt", "/Users/alex/code/b.txt"},
    filter = "",
    sort = "name_asc",      -- name_asc/name_desc/size_asc/size_desc/time_asc/time_desc
    has_dialog = false,
    active_dialog = nil,     -- or "Copy", "Mkdir", etc.
    -- Tabs (NOT YET IMPLEMENTED - currently always 1 tab)
    -- When implemented: switching active tab on one side does NOT affect
    -- the other side. A "tab_switched" event is fired on the affected side only.
    tabs = {
      {path = "/Users/alex/code", active = true},
    },
  },
  right = { --[[ same structure ]] },
  jobs = {
    active = false,
    type = nil,              -- "copy", "move", "delete", or nil
    progress = 0,            -- 0-100
    items_total = 0,
    items_done = 0,
    queued = 0,
  },
  error_count = 0,
  errors = {},               -- list of {message=, time=}
}
```

**Convenience getters** (shorthand for common queries):

- `fc.focused()` -> `fc.state().left.focused_path` (for active panel)
- `fc.selected()` -> `fc.state().left.selected_paths` (for active panel)
- `fc.left_path()` -> `fc.state().left.path`
- `fc.right_path()` -> `fc.state().right.path`

All state queries are direct reads — no yield, no synchronization needed (same thread).

## 5. Waiting on Events

`fc.wait_event(name, timeout_ms)` yields the coroutine and resumes when the event fires or timeout expires.

```lua
-- Wait for job to complete (max 30 seconds)
local ok = fc.wait_event("job_completed", 30000)
assert(ok, "job did not complete in time")

-- Wait for dialog to close
fc.wait_event("dialog_closed", 5000)

-- Wait for any of several events
fc.wait_event({"dialog_closed", "error_reported"}, 5000)
```

**C implementation:**

```cpp
struct PendingWait {
    std::vector<std::string> event_names;
    double deadline;
};
static std::optional<PendingWait> g_pending_wait;
static size_t g_event_cursor = 0;  // position in event log when wait started

static int lua_fc_wait_event(lua_State* L) {
    // Collect event name(s)
    std::vector<std::string> names;
    if (lua_istable(L, 1)) { /* collect from table */ }
    else { names.push_back(luaL_checkstring(L, 1)); }
    int timeout_ms = luaL_optinteger(L, 2, 5000);

    // Check if event already in log (since last wait)
    for (size_t i = g_event_cursor; i < g_event_log.size(); i++) {
        for (auto& name : names) {
            if (g_event_log[i].name == name) {
                g_event_cursor = g_event_log.size();
                lua_pushboolean(L, 1);
                return 1;  // already happened, no yield
            }
        }
    }

    // Not yet — yield coroutine
    g_pending_wait = PendingWait{names, now() + timeout_ms / 1000.0};
    g_event_cursor = g_event_log.size();
    return lua_yield(L, 0);
}
```

**Resumption mechanism — `check_lua_waits()`:**

Called from a `CatchEvent` wrapper around the root component, triggered on every event (including `Event::Custom` posted by background threads):

```cpp
static void check_lua_waits() {
    if (!g_pending_wait) return;

    // Check for polled events (job completion, discovery, etc.)
    poll_async_events();  // adds to g_event_log if detected

    // Check event log for match
    for (size_t i = g_event_cursor; i < g_event_log.size(); i++) {
        for (auto& name : g_pending_wait->event_names) {
            if (g_event_log[i].name == name) {
                // Match! Resume coroutine with true
                g_pending_wait.reset();
                lua_pushboolean(g_lua_co, 1);
                int status = lua_resume(g_lua_co, 1);
                handle_lua_resume_status(status);
                return;
            }
        }
    }
    g_event_cursor = g_event_log.size();

    // Check timeout
    if (now() > g_pending_wait->deadline) {
        g_pending_wait.reset();
        lua_pushnil(g_lua_co);  // nil = timeout
        int status = lua_resume(g_lua_co, 1);
        handle_lua_resume_status(status);
    }
}
```

## 6. Panel Navigation

`fc.left_cd(path)` and `fc.right_cd(path)` call `Panel::move_to()` directly (same thread):

```cpp
static int lua_fc_left_cd(lua_State* L) {
    auto path = boost::filesystem::path(luaL_checkstring(L, 1));
    g_app->get_left().move_to(path);
    return 0;
}
```

Requires public accessors on `FileCommander`:

```cpp
Panel& get_left() { return left; }
Panel& get_right() { return right; }
```

## 7. Framework Lua Code

Loaded before the test script. Provides convenience wrappers and the coroutine runner.

`**fc_framework.lua`:**

```lua
-- Wrap fc.key to accept tables
local _raw_key = fc.key
fc.key = function(name_or_list)
    if type(name_or_list) == "table" then
        for _, name in ipairs(name_or_list) do _raw_key(name) end
    else
        _raw_key(name_or_list)
    end
end

-- Test helper: wait for jobs to finish
fc.wait_for_jobs = function(timeout_ms)
    return fc.wait_event("job_completed", timeout_ms or 30000)
end

-- Test assertions
function check(cond, fmt, ...)
    if not cond then error(string.format("FAIL: " .. fmt, ...), 2) end
end

function test_pass(name)
    print("[PASS] " .. name)
end
```

## 8. Copy Test

`**test/test_copy.lua`:**

```lua
local h = dofile("test/helpers.lua")
local src, dst = h.setup_copy_test()
-- src has: alpha.txt, beta.txt, subdir/gamma.txt

fc.left_cd(src)
fc.right_cd(dst)

-- Select all, open copy dialog, confirm
fc.key({"cA", "f5"})
fc.wait_event("discovery_completed", 5000)
fc.key({"<-", "ret"})   -- focus COPY button, confirm

-- Wait for copy job
fc.wait_for_jobs()

-- Verify
check(#fc.errors() == 0, "no errors after copy")
check(h.file_exists(dst .. "/alpha.txt"), "alpha.txt copied")
check(h.file_exists(dst .. "/subdir/gamma.txt"), "subdir/gamma.txt copied")
check(h.read_file(dst .. "/alpha.txt") == "alpha content\n", "content matches")

h.cleanup(src, dst)
test_pass("copy")
fc.quit()
```

## 9. Tab State (Not Yet Implemented)

Document in spec.md and in `fc.state()` return structure:

- Each panel side (left/right) has a `tabs` array. Currently always contains exactly one entry.
- When tabs are implemented:
  - Each tab has its own `Dir`, sort order, filter, selection, and `FileChangeFunnel`
  - Switching the active tab on one side does NOT affect the other side
  - A `tab_switched` event is fired, scoped to the affected side only
  - `fc.state().left.tabs[1].active == true` for the current tab
  - New actions: `tab_new`, `tab_close`, `tab_next`, `tab_prev`

## 10. Files Changed (Phase 1 — Completed)

**Spec update:** [doc/spec.md](doc/spec.md) — rewrite section 3.2 with this design

**C++ implementation** (in [main.cpp](main.cpp)):

- Remove background thread Lua execution; add same-thread coroutine execution
- Add globals: `g_app`, `g_root`, `g_lua`, `g_lua_co`, `g_event_log`, `g_pending_wait`
- Add `check_lua_waits()` wired into `CatchEvent` wrapper
- Implement all `lua_fc_*` C functions
- Add public accessors to `FileCommander` for panels
- Add `fire_event()` calls to `show_dialog()`, `close_dialog()`, `move_to()`, etc.

**Action system** (plan only — full implementation deferred):

- Add `Action` struct and `ActionRegistry` to [dialogs.hpp](dialogs.hpp) / [dialogs.cpp](dialogs.cpp)
- Refactor `Commands`, `handle_global_shortcuts`, `filelist_handle_commands` to use actions

**New files:**

- `fc_framework.lua` — preloaded Lua framework code
- `test/helpers.lua` — test setup/teardown utilities
- `test/test_copy.lua` — first end-to-end test

---

# Phase 2: Refactoring — Encapsulation & Globals Elimination

## 11. Overview

Phase 1 added ~540 lines of Lua scripting code directly into `main.cpp` using 15+ file-scope
globals. This phase moves all Lua code into `scripting.hpp` / `scripting.cpp`, encapsulates
state into classes, and eliminates every C++ global. Lua-side globals (`fc`, `check`, etc.)
remain unchanged.

**Goals:**

1. **`class LuaScripting`** — owns all Lua state, event log, poll state, C callbacks
2. **`class ScheduledUpdates`** — general-purpose timer thread replacing the crude 50ms poll loop
3. **`DialogOverlay::on_event`** callback member — replaces `g_fire_event` global
4. **Explicit `ftxui::Loop` with `tick()`** — replaces `CatchEvent` wrapper, eliminates "first event" hack
5. **main.cpp** shrinks back to application-level wiring only

## 12. ScheduledUpdates

Replaces the `start_lua_poll_timer()` / `stop_lua_poll_timer()` detached thread that
blindly sleeps 50ms in a loop. `ScheduledUpdates` is a general-purpose mechanism that can
serve Lua polling, future animations, or any timed screen refresh.

**Design:**

```cpp
// scripting.hpp
class ScheduledUpdates {
public:
  ScheduledUpdates() = default;
  ~ScheduledUpdates();  // calls stop()

  void start();   // launches background thread (idempotent)
  void stop();    // signals exit, joins thread

  /// Schedule a one-shot screen update at a specific timestamp (now()-based).
  void schedule_at(double timestamp);

  /// Start periodic screen updates every interval_ms milliseconds.
  /// Replaces any previous periodic interval. 0 = disable.
  void start_periodic(int interval_ms);

  /// Stop periodic updates (equivalent to start_periodic(0)).
  void stop_periodic();

private:
  // Min-heap: soonest timestamp on top
  std::priority_queue<double, std::vector<double>, std::greater<double>> _timers;
  std::mutex              _mutex;
  std::condition_variable _cv;
  std::atomic<bool>       _running{false};
  int                     _periodic_ms = 0;
  std::thread             _thread;

  void run();  // thread function
};
```

**Thread function pseudocode (`run()`):**

```
while _running:
    lock mutex
    compute next_wake = min(soonest timer, now + periodic_interval)
    if nothing scheduled:
        wait on _cv until notified (new timer, periodic change, or stop)
        continue
    wait_for(lock, next_wake - now)  // or until _cv notified
    if not _running: break
    // remove expired one-shot timers
    while !_timers.empty() && _timers.top() <= now():
        _timers.pop()
    unlock
    screen->Post(Event::Custom)   // wake the FTXUI event loop
```

`_cv` is notified on: `schedule_at()`, `start_periodic()`, `stop_periodic()`, `stop()`.
This gives precise wake-up timing instead of constant 50ms polling.

**Why this is needed:**

`RunOnceBlocking()` blocks on `task_receiver_->Receive()` until an event arrives. When
the Lua coroutine is waiting for a background job or timeout, nothing would unblock the
main loop without `ScheduledUpdates` posting `Event::Custom` at the right time.

**Usage in LuaScripting:**

- `_scheduler.start()` is called once in `setup()` — the thread idles on the cv until needed
- When a Lua wait begins (`fc.wait_event` / `fc.sleep`): `_scheduler.schedule_at(deadline)`
  schedules a one-shot wakeup at the timeout time
- No periodic polling needed — all async completions (job, discovery) post `Event::Custom`
  themselves, which unblocks `RunOnceBlocking()` and triggers `tick()`
- `_scheduler.stop()` is called in `cleanup()` to join the thread

## 13. LuaScripting Class

All Lua-related state and logic encapsulated in one class. No file-scope globals.

### 13.1 Class Declaration

```cpp
// scripting.hpp
class LuaScripting {
public:
  /// Construct with references to the app and root component for OnEvent dispatch.
  LuaScripting(FileCommander& app, ftxui::Component root);
  ~LuaScripting();

  /// Load fc_framework.lua + test script, prepare coroutine. Returns false on error.
  bool setup(const std::string& script_path);

  /// Called after every RunOnceBlocking() in the explicit Loop.
  /// On first call: starts the Lua coroutine (initial lua_resume).
  /// On subsequent calls: polls async events, checks pending waits,
  /// resumes coroutine if a wait condition is met or timed out.
  void tick();

  /// Fire a named event from C++ code (Panel, DialogOverlay, etc.)
  void fire_event(const std::string& name, const std::string& detail = "");

  /// Has the Lua script finished (completed or errored)?
  bool finished() const;

  /// Close Lua state and stop scheduler.
  void cleanup();

private:
  // --- Application references (replaces g_app, g_root) ---
  FileCommander&   _app;
  ftxui::Component _root;

  // --- Lua VM (replaces g_lua, g_lua_co, g_lua_finished) ---
  lua_State* _lua    = nullptr;
  lua_State* _lua_co = nullptr;
  bool       _finished = false;
  bool       _started  = false;   // has initial resume happened?

  // --- Event log (replaces g_event_log, g_event_cursor) ---
  struct ScriptEvent {
    std::string name;
    double      timestamp;
    std::string detail;
  };
  std::deque<ScriptEvent> _event_log;
  size_t                  _event_cursor = 0;

  // --- Pending wait (replaces g_pending_wait) ---
  struct PendingWait {
    std::vector<std::string> event_names;
    double                   deadline;
    bool                     sleep_mode = false;
  };
  std::optional<PendingWait> _pending_wait;

  // --- Async poll state (replaces g_had_running_job, etc.) ---
  bool   _had_running_job = false;
  bool   _had_discovery   = false;
  int    _poll_count = 0;
  double _last_job_finished_time = -1;
  double _last_job_started_time  = -1;

  // --- Timer thread (replaces g_poll_active + detached thread) ---
  ScheduledUpdates _scheduler;

  // --- Debug logging (replaces g_lua_log) ---
  FILE* _log_file = nullptr;
  void  log(const char* msg);
  void  log(const std::string& msg) { log(msg.c_str()); }

  // --- Internal methods (replaces free functions) ---
  void poll_async_events();     // detect job_started/completed, discovery_completed
  void handle_resume_status(int status);  // handle lua_resume return code
  void check_waits();           // called from tick(): check event log + timeout, resume if met

  // --- Lua C callbacks: access 'this' via registry, not globals ---
  static LuaScripting* from_lua(lua_State* L);  // extract 'this' from registry

  static int l_key(lua_State* L);
  static int l_quit(lua_State* L);
  static int l_left_cd(lua_State* L);
  static int l_right_cd(lua_State* L);
  static int l_left_path(lua_State* L);
  static int l_right_path(lua_State* L);
  static int l_focused(lua_State* L);
  static int l_selected(lua_State* L);
  static int l_errors(lua_State* L);
  static int l_state(lua_State* L);
  static int l_wait_event(lua_State* L);
  static int l_sleep(lua_State* L);

  // --- Helpers ---
  static void push_panel_state(lua_State* L, Panel& panel);
  Panel& get_focused_panel();
};
```

### 13.2 Registry-Based C Callback Pattern

The `this` pointer is stored once in the Lua registry under a known key. C callbacks
retrieve it with `from_lua(L)`. Functions are registered with plain `lua_pushcfunction`
— no closures, no upvalues needed.

Additionally, `this` is passed to `__framework_init(context)` in `fc_framework.lua`,
so the Lua side can also hold a reference if needed for future Lua-side extensions.

**Registration (in `setup()`):**

```cpp
// 1. Store 'this' in Lua registry — accessible from any C callback
lua_pushlightuserdata(_lua, this);
lua_setfield(_lua, LUA_REGISTRYINDEX, "fc_scripting");

// 2. Register 'fc' table with plain C functions (no upvalues)
lua_newtable(_lua);

auto reg = [this](const char* name, lua_CFunction fn) {
  lua_pushcfunction(_lua, fn);
  lua_setfield(_lua, -2, name);
};

reg("key",        l_key);
reg("quit",       l_quit);
reg("left_cd",    l_left_cd);
// ... etc

lua_setglobal(_lua, "fc");

// 3. Load fc_framework.lua (defines __framework_init, wraps fc.key, etc.)
luaL_dofile(_lua, "fc_framework.lua");

// 4. Call __framework_init(context) — pass 'this' to Lua side
lua_getglobal(_lua, "__framework_init");
lua_pushlightuserdata(_lua, this);
lua_call(_lua, 1, 0);
```

**Retrieval (in each C callback):**

```cpp
static LuaScripting* from_lua(lua_State* L) {
  lua_getfield(L, LUA_REGISTRYINDEX, "fc_scripting");
  auto* self = static_cast<LuaScripting*>(lua_touserdata(L, -1));
  lua_pop(L, 1);
  return self;
}

static int l_key(lua_State* L) {
  auto* self = from_lua(L);
  if (!self->_root) return luaL_error(L, "fc not initialized");
  const char* name = luaL_checkstring(L, 1);
  // ... dispatch using self->_root->OnEvent(...)
}
```

The registry is shared across the main state and all coroutines, so `from_lua(L)` works
identically whether called from `_lua` or `_lua_co`. One registry lookup per C callback
call — negligible cost for a test framework.

**Lua side (`fc_framework.lua`):**

```lua
local _cpp_context = nil

function __framework_init(context)
  _cpp_context = context
  -- Available for future Lua-side extensions that may need
  -- to pass context back to C helper functions
end
```

### 13.3 Globals Eliminated

| Old global                | New location                         |
| ------------------------- | ------------------------------------ |
| `g_fire_event`            | `DialogOverlay::on_event` callback   |
| `g_lua_log` / `lua_log()` | `LuaScripting::_log_file` / `log()` |
| `g_app`                   | `LuaScripting::_app`                |
| `g_root`                  | `LuaScripting::_root`               |
| `g_lua`                   | `LuaScripting::_lua`                |
| `g_lua_co`                | `LuaScripting::_lua_co`             |
| `g_lua_finished`          | `LuaScripting::_finished`           |
| `g_event_log`             | `LuaScripting::_event_log`          |
| `g_event_cursor`          | `LuaScripting::_event_cursor`       |
| `g_pending_wait`          | `LuaScripting::_pending_wait`       |
| `g_poll_active`           | `ScheduledUpdates::_running`         |
| `g_had_running_job`       | `LuaScripting::_had_running_job`    |
| `g_had_discovery`         | `LuaScripting::_had_discovery`      |
| `g_poll_count`            | `LuaScripting::_poll_count`         |
| `g_last_job_*_time`       | `LuaScripting::_last_job_*_time`    |

## 14. Event Callback: `DialogOverlay::on_event`

Replace `g_fire_event` (a file-scope `std::function`) with a member on `DialogOverlay`.
Since both `Panel` and `FileCommander` inherit from `DialogOverlay`, they all get it.
`DialogOverlay` is now defined in `app.hpp` (extracted from `main.cpp`).

**Change in app.hpp (DialogOverlay class):**

```cpp
class DialogOverlay {
public:
  // Event callback — set by main.cpp when LuaScripting is active, no-op otherwise
  std::function<void(const std::string&, const std::string&)> on_event;

  // ... existing members ...

protected:
  void close_dialog() {
    // ... existing logic ...
    if (on_event) on_event("dialog_closed", "");     // was: g_fire_event
  }
  void show_dialog(std::string name) {
    // ... existing logic ...
    if (on_event) on_event("dialog_opened", name);   // was: g_fire_event
  }
};

// In Panel::move_to():
  if (on_event) on_event("dir_changed", where.native());  // was: g_fire_event
```

**Wiring in main.cpp (`main()`):**

```cpp
if (lua_mode) {
  LuaScripting scripting(app, app.renderer);

  auto fire = [&scripting](const std::string& n, const std::string& d) {
    scripting.fire_event(n, d);
  };
  // Wire all three DialogOverlay instances
  app.on_event             = fire;
  app.get_left().on_event  = fire;
  app.get_right().on_event = fire;

  if (!scripting.setup(lua_script_path)) return 1;

  // Explicit Loop — Lua tick() runs after every render pass
  ftxui::Loop loop(&screen, app.renderer);
  while (!loop.HasQuitted()) {
    loop.RunOnceBlocking();
    scripting.tick();   // first call starts coroutine; thereafter checks waits
  }
  scripting.cleanup();
} else {
  screen.Loop(app.renderer);
}
```

This cleanly decouples DialogOverlay/Panel from any Lua dependency. In normal (non-Lua)
mode, `on_event` is default-constructed (empty) and the `if (on_event)` checks are no-ops.

**CopyDiscoveryProcess event posting (dialogs.cpp):**

To complete the event-driven model, `CopyDiscoveryProcess::_run()` now posts
`Event::Custom` after discovery finishes, ensuring `RunOnceBlocking()` unblocks
immediately:

```cpp
void CopyDiscoveryProcess::_run() {
  _discover(selected, _target);
  _running = false;
  // Notify the FTXUI event loop so tick() can detect completion
  auto* screen = ScreenInteractive::Active();
  if (screen) screen->Post(Event::Custom);
}
```

Without this, the main loop would block indefinitely in `RunOnceBlocking()` waiting for
an event after discovery completes — there's no periodic polling to fall back on.

### 14.1 Explicit Loop vs CatchEvent

Phase 1 used a `CatchEvent` wrapper to intercept every FTXUI event and call
`check_lua_waits()`. This required a "first event" hack (`lua_started` flag) because
`screen.Post()` doesn't work before `Install()`.

The explicit `ftxui::Loop` eliminates all of this:

- **`Loop` constructor calls `PreMain()` → `Install()`** — the screen is fully set up,
  `task_sender_`/`task_receiver_` are live, and `screen.Post()` works before entering
  the `while` loop. No first-event hack needed.
- **`tick()` runs after `RunOnceBlocking()`** — all pending events have been processed,
  the frame has been drawn, and the component tree is in a consistent state. Lua state
  queries always see the latest state.
- **No event interception** — `tick()` doesn't receive or inspect FTXUI events. It simply
  polls async state and checks the event log. Events fired during `HandleTask()` (inside
  `RunOnceBlocking()`) are already in the log by the time `tick()` runs.
- **`tick()` flow:**
  1. If `!_started`: call `lua_resume(_lua_co, 0)` to start the coroutine, set `_started = true`
  2. If `_pending_wait`: call `poll_async_events()`, then `check_waits()`
  3. If a wait matched or timed out: resume coroutine with result

**FTXUI execution sequence per iteration:**

```
RunOnceBlocking():
  Receive(&task)           — blocks until event/closure arrives
  HandleTask(component, task)
    → component->OnEvent()  — fires on_event callbacks into scripting event log
  RunOnce():
    drain remaining tasks (non-blocking)
    Draw()                  — render frame
——— returns to while loop ———
scripting.tick()           — poll, check waits, maybe resume coroutine
```

## 15. File Layout After Refactoring

```
app.hpp             — DialogOverlay (with on_event callback member)
                      Panel, FileCommander, JobProgressBar
                      Extracted from main.cpp to break circular dependencies
                      (scripting.cpp needs FileCommander/Panel definitions)

scripting.hpp       — ScheduledUpdates class declaration
                      LuaScripting class declaration
                      #include "app.hpp", forward declarations

scripting.cpp       — ScheduledUpdates implementation
                      LuaScripting implementation (setup, tick, fire_event, cleanup,
                      all l_* static callbacks, poll_async_events, check_waits, etc.)
                      #include for lua.h, lualib.h, lauxlib.h

main.cpp            — main() function only (plus LogAdapter)
                      #include "app.hpp", #include "scripting.hpp"
                      No Lua headers, no Lua code, no Lua globals

dialogs.cpp         — CopyDiscoveryProcess::_run() posts Event::Custom on completion
                      (ensures event-driven wake-up, no periodic polling needed)

fc_framework.lua    — __framework_init(context) stores C++ context pointer
```

**What was moved/changed:**

- `DialogOverlay`, `Panel`, `FileCommander`, `JobProgressBar` → extracted from `main.cpp` to `app.hpp`
- `g_fire_event` global → replaced by `DialogOverlay::on_event` member callback
- All Lua code (~540 lines) → moved to `scripting.cpp`
- `CatchEvent` wrapper → replaced by explicit `ftxui::Loop` + `scripting.tick()`
- `CopyDiscoveryProcess::_run()` → now posts `Event::Custom` after `_running = false`
- Periodic polling (`start_periodic(50)`) → eliminated; replaced by `schedule_at(deadline)` + event-driven `Event::Custom` posts from all async workers

## 16. CMakeLists.txt Update

Add `scripting.cpp` to the build:

```cmake
add_executable(fc
  main.cpp
  scripting.cpp    # <-- new
  dialogs.cpp
  # ... etc
)
```

## 17. Implementation Order (all completed)

1. ~~**`ScheduledUpdates`** in `scripting.hpp` + `scripting.cpp` — self-contained, testable in isolation~~ ✓
2. ~~**`LuaScripting`** class declaration in `scripting.hpp`~~ ✓
3. ~~**`LuaScripting`** implementation in `scripting.cpp` — move all functions, convert globals to members, store `this` in Lua registry, register plain `lua_pushcfunction`s, implement `tick()` with first-call start logic~~ ✓
4. ~~**Extract `app.hpp`** — move `DialogOverlay`, `Panel`, `FileCommander`, `JobProgressBar` out of `main.cpp` to break circular dependency with `scripting.cpp`~~ ✓
5. ~~**`DialogOverlay::on_event`** — add member, replace `g_fire_event` references~~ ✓
6. ~~**Update `main.cpp`** — remove Lua code & globals, add `#include "scripting.hpp"`, replace `CatchEvent` wrapper with explicit `ftxui::Loop` + `scripting.tick()`, wire `on_event` callbacks~~ ✓
7. ~~**Update `CMakeLists.txt`** — add `scripting.cpp`~~ ✓
8. ~~**Event-driven discovery** — make `CopyDiscoveryProcess::_run()` post `Event::Custom`, remove all `start_periodic()` / `stop_periodic()` calls, replace with `schedule_at(deadline)`~~ ✓
9. ~~**Build & test** — `build/fc run test/test_copy.lua` passes with event-driven architecture, no periodic polling~~ ✓
