---
name: Lua Testing Framework
overview: Redesign the Lua testing framework to run on the main UI thread using coroutines, with an action system, event/state concepts, and a synchronous API that requires no sleeps.
todos:
  - id: spec
    content: "Update spec.md section 3.2 with revised design: same-thread coroutines, action concept, events/states, tab state, wait_event API"
    status: pending
  - id: framework-lua
    content: Create fc_framework.lua with key-table wrapper, wait_for_jobs, check(), test_pass()
    status: pending
  - id: helpers-lua
    content: Create test/helpers.lua with setup_copy_test(), file_exists(), dir_exists(), read_file(), cleanup()
    status: pending
  - id: test-copy-lua
    content: Create test/test_copy.lua end-to-end copy test using the new API
    status: pending
  - id: globals-accessors
    content: Add g_app, g_root, g_lua globals and FileCommander public accessors for left/right panels
    status: pending
  - id: coroutine-setup
    content: "Replace background-thread Lua with same-thread coroutine: load framework, load script as coroutine, post initial resume"
    status: pending
  - id: fc-key
    content: Implement lua_fc_key() with len-based dispatch (char / event_from_string / action name), direct OnEvent
    status: pending
  - id: event-system
    content: Implement fire_event(), g_event_log, poll_async_events(), and add fire_event calls to show_dialog/close_dialog/move_to/etc
    status: pending
  - id: wait-event
    content: Implement lua_fc_wait_event() with lua_yield and check_lua_waits() wired into CatchEvent
    status: pending
  - id: state-queries
    content: Implement fc.state(), fc.focused(), fc.selected(), fc.left_path(), fc.right_path(), fc.left_cd(), fc.right_cd()
    status: pending
  - id: build-and-test
    content: Build and run test/test_copy.lua to verify end-to-end
    status: pending
isProject: false
---

# LuaJIT Testing Framework (Revised)

## 1. Same-Thread Lua Execution with Coroutines

Run Lua on the main UI thread instead of a background thread. This eliminates all synchronization complexity: no promises, no futures, no data races.

```mermaid
sequenceDiagram
    participant Main as MainThread
    participant Loop as FTXUI_Loop
    participant Lua as LuaCoroutine
    Main->>Loop: screen.Loop(app.renderer)
    Loop->>Loop: RunOnceBlocking — wait for task
    Note over Loop: Posted closure arrives
    Loop->>Lua: lua_resume(co) — run test script
    Lua->>Lua: fc.key("f5") — direct OnEvent dispatch
    Lua->>Lua: fc.key("ret") — direct OnEvent dispatch
    Lua->>Loop: fc.wait_event("job_completed") — lua_yield
    Loop->>Loop: Draw() — render frame
    Loop->>Loop: RunOnceBlocking — process more tasks
    Note over Loop: Job finishes, updated() posts Event::Custom
    Loop->>Loop: check_lua_waits() — condition met
    Loop->>Lua: lua_resume(co) — continue test
    Lua->>Lua: assert(#fc.errors() == 0)
    Lua->>Lua: fc.quit()
```



**Why this is better:**

- `fc.key("f5")` calls `component->OnEvent(Event::F5)` directly — synchronous, instant, no thread hop
- State queries (`fc.focused()`, `fc.selected()`) read directly from `Dir`/`Panel` — no marshalling
- Only `fc.wait_event()` yields the coroutine (for async ops like job completion)
- The FTXUI event loop handles rendering, background thread callbacks, and coroutine resumption naturally

**FTXUI loop internals** (from [alex_ftxui/src/ftxui/component/screen_interactive.cpp](../alex_ftxui/src/ftxui/component/screen_interactive.cpp)):

- `RunOnceBlocking()`: wait for one task (blocking) -> handle it -> call `RunOnce()`
- `RunOnce()`: drain all pending tasks non-blocking -> `Draw()`
- `HandleTask()`: if Event -> `component->OnEvent(event)`; if Closure -> call it
- Both `Post(Event)` and `Post(Closure)` go through the **same FIFO queue** — order preserved

**Startup flow in [main.cpp](main.cpp):**

```cpp
// In main(), after FileCommander construction:
g_app = &app;
g_root = app.renderer;

if (lua_mode) {
    g_lua = luaL_newstate();
    luaL_openlibs(g_lua);
    // Register C functions...
    // Load framework lua code
    luaL_dofile(g_lua, "fc_framework.lua");
    // Load test script as coroutine
    g_lua_co = lua_newthread(g_lua);
    luaL_loadfile(g_lua_co, script_path);
    // Post initial coroutine resume
    screen.Post([&]() {
        int status = lua_resume(g_lua_co, 0);
        handle_lua_resume_status(status);
    });
}
screen.Loop(app.renderer);
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

**Event struct:**

```cpp
struct LuaEvent {
    std::string name;
    double timestamp;
    std::string detail;  // optional context (e.g., dialog name, job type)
};
static std::deque<LuaEvent> g_event_log;

static void fire_event(const std::string& name, const std::string& detail = "") {
    g_event_log.push_back({name, now(), detail});
    // If Lua coroutine is waiting for this event, it will be resumed
    // on the next check_lua_waits() call
}
```

**Where events are fired** (all on UI thread unless noted):


| Event                 | Source location                                                               | Detail          |
| --------------------- | ----------------------------------------------------------------------------- | --------------- |
| `dialog_opened`       | `DialogOverlay::show_dialog()` in [main.cpp:63](main.cpp)                     | dialog name     |
| `dialog_closed`       | `DialogOverlay::close_dialog()` in [main.cpp:56](main.cpp)                    | —               |
| `dir_changed`         | `Panel::move_to()` in [main.cpp:113](main.cpp)                                | new path        |
| `items_updated`       | `Dir::partial_refresh()` / `Dir::refresh()` in [commander.cpp](commander.cpp) | —               |
| `selection_changed`   | `Dir::item_toggle_select()` / `Dir::select_all()` / `Dir::clear_selection()`  | count           |
| `job_completed`       | Polled in `check_lua_waits()` via `is_stopped()`                              | job type        |
| `job_started`         | Polled in `check_lua_waits()` via `_started_time > 0`                         | job type        |
| `discovery_completed` | Polled in `check_lua_waits()` via `_running == false`                         | —               |
| `error_reported`      | `file_operations().report_error()` in [file_io_jobs.cpp](file_io_jobs.cpp)    | message         |
| `errors_cleared`      | `file_operations().clear_errors()`                                            | —               |
| `tab_switched`        | (future — not yet implemented)                                                | side, tab index |
| `tab_created`         | (future)                                                                      | side            |
| `tab_closed`          | (future)                                                                      | side            |


**Background-thread events** (`job_completed`, `job_started`, `discovery_completed`): These originate on worker threads. Rather than fire them from there (thread safety issue), `check_lua_waits()` polls the relevant state on the UI thread. The worker thread already posts `Event::Custom` via `updated()` (defined in [file_io_jobs.cpp:21-26](file_io_jobs.cpp)), which wakes the event loop and triggers the check.

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

## 10. Files Changed

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

