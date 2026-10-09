# Lua scripting

You can automate File Commander (FC) with Lua scripts. A script drives FC
the way you would: it runs commands, presses keys, waits for directories to
load and copies to finish, and reads what the panels show. Use scripts for
file workflows you repeat, for automating the interface, and for tests.

> **Only run scripts you trust.** A script runs with your permissions and has
> the full Lua standard library, including `io`, `os` and LuaJIT's `ffi`. It
> can read, change or delete any file you can.

This guide assumes you know basic Lua. For everyday use of FC, see the
[user guide](user_guide.md); for building FC, see the [README](../README.md).

- [Run a script](#run-a-script)
- [A first script](#a-first-script)
- [Copy matching files](#copy-matching-files)
- [How scripts run](#how-scripts-run)
- [API reference](#api-reference)
- [Events](#events)
- [The state table](#the-state-table)
- [Command IDs](#command-ids)
- [Limitations](#limitations)

## Run a script

```sh
fc run script.lua
```

FC opens its normal full-screen interface, so you can watch the script work.
The script starts once both panels have loaded, and FC exits as soon as the
script ends. The script path is relative to the directory you start FC in, and
so are `dofile`, `require` and `io.open` inside the script.

Run mode differs from a normal start:

- Both panels open in the directory you start FC in.
- Your settings aren't loaded. Key bindings, colors, bookmarks, sort orders and
  columns are FC's defaults. That makes scripts behave the same for everyone.
- The workspace isn't restored, and settings and workspace aren't saved when
  the script ends.
- FC doesn't take the profile lock, so a script can run while you use FC in
  another terminal.
- Transfer recovery is off. Copy and move jobs aren't recorded on disk, and a
  job interrupted when FC exits can't be resumed later.
- The script gets no arguments; extra words after the script path are ignored.
  Pass values in environment variables and read them with `os.getenv`.

`fc run` needs the script path. Without it, FC starts normally and treats
`run` as the left panel's directory.

### Exit codes and errors

| Outcome | Exit code |
| --- | --- |
| The script returns (a returned value is ignored) | 0 |
| The script calls `fc.quit()` | 0 |
| A Lua error: syntax error, `error()`, a failed `assert` or `check` | 1 |
| The script file is missing or unreadable | 1 |
| The [6-second rule](#the-6-second-rule) stops the script | 1 |
| You press `Ctrl+C` while the script runs | 0 |
| The script calls `os.exit(n)` | `n` |

`Ctrl+C` quits FC and abandons the script, yet the exit code is 0. Don't use
`os.exit`: it ends FC without restoring the terminal. Raise an error instead.

When a script fails, FC adds the message to its error list and exits at once,
so you won't see the message. `print` doesn't help either: its output lands
on FC's full screen and disappears when FC exits. To find out what went wrong,
set `FC_LUA_DEBUG_LOG` to a file name:

```sh
FC_LUA_DEBUG_LOG=fc-lua.log fc run copy-jpg.lua
```

FC overwrites that file on each run with its setup steps and the error. For
the [copy example](#copy-matching-files) with an empty source directory, it
contains:

```text
setup: start
setup: loading framework
setup: framework loaded OK
setup: loading script copy-jpg.lua
setup: script loaded, ready for initial resume
tick: starting Lua coroutine (initial resume)
tick: initial resume status = 1
ERROR: [Lua] copy-jpg.lua:21: no *.jpg files in /home/user/empty
```

For results you want to keep, write to a file with `io.open`.

## A first script

This script shows your home directory in the right panel and writes a short
report. Save it as `hello.lua` in a directory of your choice:

```lua
-- hello.lua: show your home directory in the right panel, then
-- write a short report into the directory where you started FC.
local home = os.getenv("HOME")
fc.right_cd(home)
assert(fc.wait_event("dir_changed", 5000), "could not open " .. home)

local s = fc.state()
local report = assert(io.open("fc-report.txt", "w"))
report:write(("left:  %s (%d entries)\n"):format(s.left.path, s.left.item_count))
report:write(("right: %s (%d entries)\n"):format(s.right.path, s.right.item_count))
report:close()
```

Run it from that directory:

```text
$ cd ~/projects
$ fc run hello.lua; echo "exit code $?"
exit code 0
$ cat fc-report.txt
left:  /home/user/projects (4 entries)
right: /home/user (4 entries)
```

`fc.right_cd` only starts loading the directory. The script waits for the
`dir_changed` event before it reads the panel; without the wait, `fc.state()`
would still show the old directory. See [How scripts run](#how-scripts-run).

## Copy matching files

This script copies every `*.jpg` file from one directory to another. It
selects by pattern, runs FC's copy, and waits for the copy job to finish.
Save it as `copy-jpg.lua`:

```lua
-- copy-jpg.lua: copy every *.jpg file in SRC (not subdirectories) to DST.
-- Usage: SRC="$HOME/camera" DST="$HOME/photos" fc run copy-jpg.lua
local src = assert(os.getenv("SRC"), "set SRC to the source directory")
local dst = assert(os.getenv("DST"), "set DST to the destination directory")

local function type_text(text)
  for byte in text:gmatch(".") do fc.key(byte) end
end

-- Source on the left, destination on the right.
fc.left_cd(src)
assert(fc.wait_event("dir_changed", 5000), "could not open " .. src)
fc.right_cd(dst)
assert(fc.wait_event("dir_changed", 5000), "could not open " .. dst)

-- The left panel has the focus when a script starts. glob_select opens
-- a dialog: type the pattern, press Enter, and wait for the dialog to close.
assert(fc.command("glob_select"), "glob_select is not available")
type_text("*.jpg")
fc.key("ret")
assert(fc.wait_event("dialog_closed", 2000), "no *.jpg files in " .. src)
local count = fc.state().left.selected_count

-- copy opens the Copy dialog, which scans the selection first. F5 inside
-- the dialog starts the copy as a background job.
assert(fc.command("copy"), "copy is not available")
assert(fc.wait_event("discovery_completed", 30000), "scan did not finish")
fc.key("f5")
assert(fc.wait_event("dialog_closed", 2000), "copy did not start")
assert(fc.wait_for_jobs(600000), "copy did not finish in time")

local errors = fc.errors()
check(#errors == 0, "%d error(s), latest: %s", #errors, errors[1] or "")

local log = assert(io.open("copy-jpg.log", "a"))
log:write(("copied %d file(s) from %s to %s\n"):format(count, src, dst))
log:close()
```

```text
$ SRC="$HOME/camera" DST="$HOME/photos" fc run copy-jpg.lua; echo "exit code $?"
exit code 0
$ cat copy-jpg.log
copied 3 file(s) from /home/user/camera to /home/user/photos
```

Things to note:

- Pattern matching ignores ASCII case, so `*.jpg` also selects `IMG.JPG`. If
  nothing matches, the dialog stays open with an error. The wait for
  `dialog_closed` then times out and the script fails with exit code 1.
- In the Copy dialog the focus starts on **Cancel**, so the script presses
  `F5` rather than `Enter`. Run mode always uses the default keys.
- The Copy dialog's conflict mode starts at **Replace existing**, so running
  the script again overwrites earlier copies.
- `fc.wait_for_jobs` matters. When a script ends, FC exits and stops any job
  still running.

## How scripts run

FC runs the script on the same thread that draws the screen and handles keys.
While your Lua code runs, FC does nothing else: the screen isn't redrawn, and
results from background work aren't applied to the panels. Directory loading,
scans and copies continue on their own threads.

FC catches up only while the script waits. Three functions wait:
`fc.wait_event`, `fc.wait_for_jobs` and `fc.sleep`. Everything else returns
at once:

- Actions such as `fc.key` and `fc.command` take effect immediately. Opening
  a dialog or toggling a selection shows up in the next `fc.state()`.
- Actions that start background work only start it. After `fc.left_cd`,
  `fc.left_path()` still returns the old directory until `dir_changed` has
  arrived.

Scripts are Lua 5.1, run by LuaJIT with its JIT compiler turned off. Tight
loops therefore run at interpreter speed.

Keys you type while a script waits reach FC as usual and can disturb the
script, so leave the keyboard alone until it ends.

### Waiting for events

An *event* is a short notice that FC records when something happens, such as
a panel finishing a directory load. Each event has a name and a detail string;
the [Events](#events) table lists them all. `fc.wait_event` returns `true` and
the detail when the event arrives, or `nil` when the timeout passes first.

FC keeps your place in the stream of events:

- Each action first discards the events that arrived before it. A wait after
  an action therefore sees only what happened from then on. The actions are
  `fc.key`, `fc.command`, `fc.cmd`, `fc.left_cd`, `fc.right_cd`,
  `fc.cancel_job`, `fc.pause_job` and `fc.resume_job`.
- If the event has already arrived, `fc.wait_event` returns at once.
- A match uses up the events before it and the match itself; later events
  stay for the next wait. To catch several events from one action, wait for
  them in the order FC sends them. For example, `command_executed` comes
  before the command's effects, such as `selection_changed`.
- A wait that times out uses up every event that arrived meanwhile.
  `fc.sleep` uses up nothing.

The usual pattern is an action followed by a wait for its result:

```lua
fc.command("refresh_dir")
assert(fc.wait_event("dir_changed", 5000), "refresh did not finish")
```

### The 6-second rule

FC stops a script that runs for more than 6 seconds without waiting. The debug
log then shows `hard timeout exceeded 6s`, and FC exits with code 1.

The clock restarts each time the script resumes after a real wait. A wait that
returns at once doesn't count: `fc.wait_event` when its event has already
arrived, or `fc.wait_for_jobs` when no jobs are running. A wait itself can be
as long as you like; waiting ten minutes for a copy is fine.

For a long computation, call `fc.sleep(0)` now and then. It lets FC catch up
and restarts the clock.

The rule is checked only while Lua code runs. A blocking call such as
`os.execute("sleep 10")` freezes FC until it returns, and FC doesn't stop it.

### Driving dialogs

Commands such as `copy`, `find` and `glob_select` open a dialog and return.
While a dialog is open:

- Keys go to the dialog. Use `fc.key` to type and to press buttons;
  [Keys inside dialogs](keys.md#keys-inside-dialogs) lists the dialog keys.
- Most commands are unavailable, and `fc.command` returns `false`. The command
  palette is the exception: a command closes the palette and runs.
- `fc.state().left.active_dialog` (or `right`) names a dialog that belongs to
  a panel: `Copy`, `Move`, `Delete`, `Rename`, `Mkdir`, `Find`, `GlobSelect`,
  `GlobDeselect`, `NameToClipboard` or `PathToClipboard`.
- Dialogs that belong to the whole window (`CommandPalette`, `JobList`,
  `ErrorList`, `Bookmarks`, `ThemeColors`, `ConnectSSH`, `RestartEditor`)
  appear only in the `dialog_opened` and `dialog_closed` events.

To make sure the right dialog opened, pass its name as the detail filter:

```lua
fc.command("find")
assert(fc.wait_event("dialog_opened", 2000, "Find"))
```

## API reference

All functions live in the global `fc` table. Only the functions under
[Waiting](#waiting) pause the script.

### Actions

| Function | Returns | Description |
| --- | --- | --- |
| `fc.command(id)` | `true` if the command ran, `false` if the ID is unknown or the command isn't available now | Runs a [command](#command-ids) by its ID. |
| `fc.cmd(id)` | Same as `fc.command` | Another name for `fc.command`. |
| `fc.key(name)` or `fc.key({name, ...})` | nothing | Sends one key, or several in order, as if you typed them. See [Key names](#key-names). |
| `fc.left_cd(path)` | nothing | Starts loading `path` in the left panel's active tab. Wait for `dir_changed` before you read the result. If the directory can't be opened, `error_reported` fires and the panel stays where it was. |
| `fc.right_cd(path)` | nothing | The same for the right panel. |
| `fc.quit()` | nothing | Makes FC exit. The script keeps running until its next wait or until it returns; nothing after that wait runs. |

Give `fc.left_cd` and `fc.right_cd` absolute paths. A relative path is
resolved against the directory FC started in, not the panel's directory, and
`fc.left_path()` returns it unchanged.

### Reading state

| Function | Returns | Description |
| --- | --- | --- |
| `fc.state()` | table | A snapshot of both panels, jobs and errors. See [The state table](#the-state-table). |
| `fc.left_path()` | string | Directory of the left panel's active tab. |
| `fc.right_path()` | string | Directory of the right panel's active tab. |
| `fc.focused()` | string or `nil` | Full path of the focused item in the focused panel. |
| `fc.selected()` | array of strings | Full paths of the selected items in the focused panel. |
| `fc.errors()` | array of strings | Messages in FC's error list, newest first. FC keeps the latest 1,024. |
| `fc.monotonic_ms()` | number | Milliseconds on a clock that never jumps; use differences to measure elapsed time. The starting point is arbitrary. |

### Waiting

| Function | Returns | Description |
| --- | --- | --- |
| `fc.wait_event(name, timeout_ms, detail)` | `true, detail` on a match, `nil` on timeout | Waits for an event. `name` is an event name or an array of names; any of them matches, and the result doesn't say which. `timeout_ms` defaults to 5000. With `detail`, only an event whose detail is exactly that string matches. Returns at once if the event has already arrived. |
| `fc.wait_for_jobs(timeout_ms)` | `true` when no jobs remain, `nil` on timeout | Waits until the job queue is empty, including jobs not yet started. `timeout_ms` defaults to 30000. Returns at once if there are no jobs. |
| `fc.sleep(ms)` | nothing | Waits `ms` milliseconds. `ms` is required. `fc.sleep(0)` just lets FC catch up. |

### Jobs

A *job* is a background file operation, such as a copy. The `job_started` and
`job_completed` events carry the job's ID as their detail; convert it with
`tonumber`.

| Function | Returns | Description |
| --- | --- | --- |
| `fc.cancel_job(id)` | boolean | Cancels the job with that ID, or the running job when `id` is omitted. `false` if there is no such job or it has already stopped. Files already copied are kept. |
| `fc.pause_job(id)` | boolean | Toggles pause: pauses a running job and resumes a paused one. Acts on the running job when `id` is omitted. |
| `fc.resume_job(id)` | boolean | Resumes a paused job. `id` is required. A job that isn't paused is left alone, and the result is still `true`. |
| `fc.job_history()` | array of tables | Finished jobs, oldest first; FC keeps the latest 256. Each has `id`, `type`, `state`, `items_done`, `items_total`, `errors` (failed items), `bytes_done`, `bytes_total` and `recovery_note` (why the job stopped early, usually empty). |

`type` and `state` take the values listed under
[The state table](#the-state-table).

### Key names

`fc.key` accepts these names:

| Key | Name |
| --- | --- |
| A printable character | The character itself, such as `"a"`, `"*"` or `" "` |
| `Enter`, `Esc` | `ret`, `esc` |
| `Tab`, `Shift+Tab` | `tab`, `stab` |
| `Backspace`, `Delete` | `back`, `del` |
| Arrow keys | `up`, `down`, `<-`, `->` |
| `Ctrl` + arrow keys | `cup`, `cdown`, `c<-`, `c->` |
| `F1` to `F12` | `f1` to `f12` |
| `Ctrl` + letter | `cA` to `cZ` (uppercase letter) |
| `Alt` + letter | `aA` to `aZ` (uppercase letter) |

A name of three or more characters that is a command ID runs that command,
like `fc.command` but without a result. FC ignores unknown names without an
error, so `fc.key("Enter")` does nothing; check your spelling.

Characters typed into a panel go to its filter, except keys bound to panel
commands such as `+` or `Space`. To type text that isn't ASCII, send it one
byte at a time, as `type_text` in the [copy example](#copy-matching-files)
does. A multi-byte character passed as one string is ignored.

### Helpers

The script also gets a global function from FC's Lua framework:

| Function | Description |
| --- | --- |
| `check(condition, format, ...)` | If `condition` is false, raises the error `FAIL: ` followed by `string.format(format, ...)`, reported at the caller's line. |

### Testing hooks

FC's own test suite uses these. They work in any script, but ordinary
scripts rarely need them. For how the test suite uses them, see
[Lua suites](dev/testing.md#lua-suites) in the contributor guide.

| Function | Description |
| --- | --- |
| `fc.set_transfer_rate(bytes_per_second)` | Limits how fast jobs copy file data, for the rest of the run; 0 removes the limit. Tests use it to make a copy slow enough to pause or cancel. |
| `fc.test_heartbeat()` | Restarts the 6-second clock without waiting. The screen still doesn't update, so prefer `fc.sleep(0)`. |
| `test_pass(name)` | A global function. Prints `[PASS] name`, records the result for FC's test runner when it runs the script, and restarts the 6-second clock. |

The helpers in `test/helpers.lua` need the test runner's environment and
aren't meant for ordinary scripts.

## Events

| Event | Fires when | Detail |
| --- | --- | --- |
| `dir_changed` | A panel finished loading a directory: after `fc.left_cd` or `fc.right_cd`, entering or leaving a directory, or `refresh_dir`. Automatic re-reads after files change don't send it. | The directory path. It doesn't say which panel. |
| `items_updated` | A panel's listing changed, after a load or because files changed on disk. | `left`, `right` or `both` |
| `selection_changed` | The number of selected items in a panel changed. | `left:N` or `right:N`, where `N` is the new count |
| `focus_changed` | The focus moved to the other panel. | `left` or `right`: the panel that has the focus now |
| `single_panel_mode_changed` | Single-panel mode was turned on or off. | `on` or `off` |
| `tab_created` | A panel opened a new tab, which becomes active. | Index of the new tab, counting from 0 |
| `tab_switched` | A panel switched to another tab. | Index of the now active tab, counting from 0 |
| `tab_closed` | A panel closed a tab. | Index of the tab active after closing, counting from 0 |
| `dialog_opened` | A dialog opened. | The dialog's name, such as `Copy` or `GlobSelect` |
| `dialog_closed` | A dialog closed. | The name of the dialog that closed |
| `command_executed` | A command ran, from `fc.command`, `fc.key`, a key press or the palette. | The command ID |
| `discovery_completed` | The Copy dialog finished scanning what it will copy. | A number identifying the scan |
| `discovery_cancelled` | The Copy dialog's scan stopped early, for example because the dialog closed. | A number identifying the scan |
| `find_completed` | A search in the Find dialog finished. | A number identifying the search |
| `find_cancelled` | A search in the Find dialog was cancelled. | A number identifying the search |
| `job_started` | A job started running. | The job ID |
| `job_state_changed` | A job's state changed. | The new state, such as `running` or `paused` |
| `job_progress` | A running job reported progress. This fires often. | The number of items finished |
| `job_completed` | A job stopped, whether it finished, failed or was cancelled. | The job ID |
| `error_reported` | A message was added to the error list. | The message |
| `errors_cleared` | The error list was cleared (`Esc` three times within a second). | `0` |
| `event_history_expired` | More events piled up than FC keeps (about 4,000), so older ones were dropped. Re-read `fc.state()`. | `resync application state` |

The startup loads of both panels happen before the script starts, so their
events are not delivered.

## The state table

`fc.state()` returns a new table each time. Later changes in FC don't update a
table you already have.

```text
fc.state()
├── left, right                 one table per panel, with the same fields:
│   ├── path                    directory of the active tab
│   ├── loading                 true while a directory load is in progress
│   ├── item_count              entries listed now, after the filter
│   ├── focused_index           position of the focus, counting from 0
│   ├── focused_path            full path of the focused entry, or nil
│   ├── selected_count          number of selected entries
│   ├── selected_paths          array of their full paths
│   ├── filter                  filter text, "" when there is none
│   ├── sort                    name_asc, name_desc, size_asc, size_desc,
│   │                           time_asc or time_desc
│   ├── has_dialog              true while one of the panel's dialogs is open
│   ├── active_dialog           that dialog's name, or nil
│   ├── show_permissions_column true if the permissions column is shown
│   ├── show_owner_group_column true if the owner:group column is shown
│   └── tabs                    array of { path = ..., active = true or false }
├── single_panel_mode           true if only the focused panel is shown
├── key_bindings                table of command ID -> key name; "" when unbound
├── jobs
│   ├── active                  true while a job is running or paused
│   ├── state                   state of the running or last job; nil before
│   │                           the first job
│   ├── type                    type of the running job; nil when none
│   ├── progress                percent done (0 to 100) of the running job
│   ├── items_done              items the running job has finished
│   ├── items_total             items in the running job
│   └── queued                  jobs waiting to start
├── error_count                 number of messages in the error list
└── errors                      array of { message = ..., time = ... },
                                newest first; time is Unix time in seconds
```

Job states are `queued`, `running`, `paused`, `cancelled`, `completed` and
`completed_with_errors`. Job types are `copy`, `move`, `delete`,
`archive_create`, `mkdir`, `rename` and `clipboard`.

Key names in `key_bindings` use the [Key names](#key-names) format.

## Command IDs

Every action in FC is a command with an ID. They are the commands that the
command palette (`F1`) lists. [Keys and commands](keys.md) lists every ID
with its default key, in the [panel](keys.md#panel-commands) and
[global](keys.md#global-commands) tables. Some examples:

```lua
fc.command("select_all")                -- Ctrl+A: select everything
fc.command("toggle_single_panel_mode")  -- Ctrl+O: show only the focused panel
fc.command("refresh_dir")               -- Ctrl+R: re-read the focused panel
```

Commands act on the focused panel, just as keys do. The left panel has the
focus when a script starts; `switch_panel` moves it, and `focus_changed` tells
you where it went.

Prefer `fc.command` to pressing a command's key with `fc.key`. It doesn't
depend on key bindings, and it tells you whether the command ran. To list all
IDs from a script, loop over `fc.state().key_bindings`.

## Limitations

- Scripts run only through `fc run`. You can't start a script from an
  interactive session, add commands, or bind a key to a script.
- A script gets no command-line arguments; use environment variables.
- Run mode starts from FC's defaults and saves nothing (see
  [Run a script](#run-a-script)).
- `fc.state()` doesn't say which panel has the focus. It shows open dialogs
  only for panel dialogs.
- Events carry only a name and a detail string. `dir_changed` and the tab
  events don't say which panel, and a wait on several names doesn't say which
  one matched.
- Lua errors aren't printed to the terminal; use `FC_LUA_DEBUG_LOG`.
- `Ctrl+C` during a script ends FC with exit code 0.
- Blocking Lua calls freeze FC and aren't stopped by the
  [6-second rule](#the-6-second-rule).
- Unknown key names are ignored without an error.
