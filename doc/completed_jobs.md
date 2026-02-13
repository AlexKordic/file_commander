---
name: Completed Jobs
status: plan
overview: >
  Job lifecycle redesign: completed/paused jobs transfer ownership to the UI thread.
  New JobHistory dialog for inspection. Pause/cancel signaling from UI to worker.
  Eliminates polling for job state detection in scripting.
---

# Completed Jobs — Design Plan

## 1. Problem Statement

Today the job lifecycle has several gaps:

1. **No job history** — `ThreadedFileJobs` holds a single `_job` pointer. Once a new job
   starts, the previous job's data is lost. There is no way to review what happened.

2. **No pause/cancel** — `cancel_job()` exists as interface but is a no-op. There is no
   pause mechanism. A large copy cannot be interrupted.

3. **Polling for state** — `LuaScripting::poll_async_events()` polls timestamps and
   process pointers to detect job start/completion. This is fragile (race conditions with
   fast completions) and carries no detail about which job or what happened.

4. **No job identity** — `JobSpec` has no ID. Events like `job_completed` carry no
   payload. The scripting system cannot distinguish between jobs.

5. **Errors are global** — Job errors go into a global `_errors` deque in
   `ThreadedFileJobs`, disconnected from the specific job that produced them.

---

## 2. Design Overview

### Core Principle

**The worker thread owns a job while executing it. When execution ends (completed,
paused, or cancelled), ownership transfers to the UI thread via a lock-free queue.**

```
                    ┌────────────────────┐
                    │     UI Thread      │
                    │                    │
  add_job()  ──────▶│  _pending_queue    │──────▶  Worker Thread
                    │  (waiting to run)  │         (owns job during execution)
                    │                    │
                    │  _completed_jobs   │◀──────  Worker pushes here when done
                    │  (lock-free queue) │
                    │                    │
                    │  _job_history      │  UI drains _completed_jobs into this
                    │  (vector, UI-only) │  each tick / render
                    └────────────────────┘
```

### Job States

```
   QUEUED ──▶ RUNNING ──▶ COMPLETED
                │    │         │
                │    ▼         ▼
                │  PAUSED   COMPLETED_WITH_ERRORS
                │    │
                │    ▼
                ▼  CANCELLED
             CANCELLED
```

| State                    | Owner          | Description                                |
|--------------------------|----------------|--------------------------------------------|
| `QUEUED`                 | pending queue  | Waiting in FIFO queue for worker            |
| `RUNNING`                | worker thread  | Worker is actively processing items         |
| `PAUSED`                 | UI thread      | Worker yielded; job returned to UI          |
| `CANCELLED`              | UI thread      | User cancelled; partial results in job      |
| `COMPLETED`              | UI thread      | All items processed, no errors              |
| `COMPLETED_WITH_ERRORS`  | UI thread      | All items processed, some failed            |

---

## 3. Job Identity

### 3.1 Job ID

Add a monotonically increasing ID to every job:

```cpp
// In JobSpec:
uint64_t _job_id;

// In ThreadedFileJobs:
std::atomic<uint64_t> _next_job_id{1};

// In add_job():
job->_job_id = _next_job_id.fetch_add(1);
```

### 3.2 Job State Enum

```cpp
enum class JobState {
  QUEUED,
  RUNNING,
  PAUSED,
  CANCELLED,
  COMPLETED,
  COMPLETED_WITH_ERRORS,
};

// In JobStats:
std::atomic<JobState> _state{JobState::QUEUED};
```

### 3.3 Compact Job Summary

When a job completes without errors, we don't need to keep the full `_items` vector
(which can be huge). Create a lightweight summary:

```cpp
struct JobSummary {
  uint64_t              job_id;
  JobInstructions::Type type;       // COPY, MOVE, DELETE
  JobState              state;
  double                queued_time;
  double                started_time;
  double                finished_time;
  int64_t               items_total;
  int64_t               items_processed;
  int64_t               bytes_total;
  int64_t               bytes_processed;
  int64_t               error_count;
  Filepath              source_dir;     // first item's parent for display
  Filepath              dest_dir;       // target for display
};
```

---

## 4. Pause / Cancel Signaling

### 4.1 Signal Flags (UI → Worker)

The UI thread sets atomic flags; the worker thread checks them in the item loop:

```cpp
// In JobSpec (or a new JobControl struct):
std::atomic<bool> _cancel_requested{false};
std::atomic<bool> _pause_requested{false};
```

### 4.2 Worker Loop Changes

The copy/move/delete loops check flags after each item:

```cpp
void run_copy(JobSpec* job) {
  for (auto& item : job->_items) {
    if (job->_cancel_requested) {
      job->_state = JobState::CANCELLED;
      return;  // exits run_copy; caller transfers job to UI
    }
    if (job->_pause_requested) {
      job->_state = JobState::PAUSED;
      return;  // exits run_copy; caller transfers job to UI
    }
    // ... process item ...
    job->_current_item_index++;
  }
}
```

### 4.3 Pause Semantics

- Pause is per-item granularity — the current file finishes before pausing.
- A paused job retains all state: `_items`, `_current_item_index`, `_errors`.
- The UI can display a paused job's details and allow resuming or cancelling.
- Resume: the UI re-enqueues the job. The worker picks it up and resumes from
  `_current_item_index`.

### 4.4 Cancel Semantics

- Cancel is per-item — the current file finishes before stopping.
- A cancelled job is transferred to the UI with partial progress.
- No rollback — files already copied/moved/deleted remain.
- For cancel during large file copy: optionally delete the partial destination file.
  This is a future enhancement.

### 4.5 Cancel/Pause for Queued Jobs

Jobs still in the pending queue can be cancelled immediately (remove from queue).
Pause on a queued job is meaningless — just leave it queued.

---

## 5. Ownership Transfer: Worker → UI

### 5.1 Completion Queue

```cpp
// In ThreadedFileJobs:
FifoQueue<std::shared_ptr<JobSpec>> _completed_queue;  // worker → UI
```

The worker pushes completed/paused/cancelled jobs here. The UI thread drains this
queue during each render cycle (or `tick()` in scripting mode).

### 5.2 Worker `run()` Loop (Revised)

```cpp
void run() {
  while (true) {
    std::shared_ptr<JobSpec> job;
    FifoError err = _pending_queue.pop(job);
    if (err == FifoError::Destroyed) break;

    job->_started_time = now();
    job->_state = JobState::RUNNING;

    {
      std::lock_guard lock(_m);
      _active_job = job;  // UI can read this for progress display
    }
    _progress_monitor.add_job(job);

    switch (job->_type) {
    case Type::COPY:   run_copy(job.get());   break;
    case Type::MOVE:   run_move(job.get());   break;
    case Type::DELETE: run_delete(job.get());  break;
    }

    // Determine final state if not already set by pause/cancel
    if (job->_state == JobState::RUNNING) {
      job->_finished_time = now();
      job->_state = job->_errors.empty()
        ? JobState::COMPLETED
        : JobState::COMPLETED_WITH_ERRORS;
    } else {
      // PAUSED or CANCELLED — still record the stop time
      job->_finished_time = now();
    }

    {
      std::lock_guard lock(_m);
      _active_job.reset();
    }

    // Transfer ownership to UI thread
    _completed_queue.push(std::move(job));

    // Wake UI so it can drain the queue
    auto* screen = ScreenInteractive::Active();
    if (screen) screen->Post(Event::Custom);
  }
}
```

### 5.3 UI Drain (in FileCommander render or tick)

```cpp
void drain_completed_jobs() {
  std::shared_ptr<JobSpec> job;
  while (_completed_queue.try_pop(job) == FifoError::OK) {
    uint64_t id = job->_job_id;
    JobState state = job->_state;

    if (state == JobState::COMPLETED) {
      // Clean completion — compact to lightweight summary, free items memory
      _summaries.push_back(make_summary(job));
      // job shared_ptr drops here, releasing _items vector
    } else {
      // PAUSED, CANCELLED, COMPLETED_WITH_ERRORS — keep full JobSpec
      // so user can inspect items, errors, remaining work, and resubmit
      _inspectable_jobs.push_back(std::move(job));
    }

    // Fire scripting event with detail
    if (_on_job_completed) {
      _on_job_completed(id, state);
    }
  }
}
```

---

## 6. Resume After Pause

### 6.1 Mechanism

A paused job has `_current_item_index` set to where it stopped. To resume:

1. UI resets `_pause_requested = false`
2. UI sets `_state = JobState::QUEUED`
3. UI calls `file_operations().add_job(job)` — re-enqueues
4. Worker picks it up, sees `_current_item_index > 0`, continues from there

### 6.2 Worker Loop Adjustment for Resume

```cpp
void run_copy(JobSpec* job) {
  for (int i = job->_current_item_index; i < job->_items.size(); i++) {
    // ... check cancel/pause ...
    // ... process item ...
    job->_current_item_index = i + 1;
  }
}
```

Note: the loop starts from `_current_item_index` instead of 0. Since items are ordered
(directories first, then files), resuming mid-stream is safe — parent directories were
already created.

---

## 7. Job History Storage

### 7.1 Two-Tier Storage

Jobs that need user attention (paused, errored, cancelled) are kept as **full
`JobSpec` objects** so the user can inspect items, errors, and remaining work.
Clean completions are compacted into lightweight summaries.

```cpp
// In ThreadedFileJobs or a new JobHistory class:

// Lightweight summaries — completed jobs with no errors
std::vector<JobSummary> _summaries;

// Full job objects — kept for inspection and possible resubmission:
//   PAUSED              — user can inspect remaining items, resume or cancel
//   COMPLETED_WITH_ERRORS — user can inspect errors, retry failed items
//   CANCELLED           — user can inspect partial progress
std::vector<std::shared_ptr<JobSpec>> _inspectable_jobs;
```

**What is kept in a full `JobSpec` for inspectable jobs:**

| Field                  | PAUSED             | COMPLETED_WITH_ERRORS | CANCELLED           |
|------------------------|--------------------|-----------------------|---------------------|
| `_items`               | Full list          | Full list             | Full list           |
| `_current_item_index`  | Where it stopped   | == `_items.size()`    | Where it stopped    |
| `_errors`              | Errors so far      | All errors            | Errors so far       |
| `_total` (byte stats)  | Partial progress   | Final totals          | Partial progress    |
| Resubmittable?         | Yes (resume)       | Yes (retry failed)    | No (user chose to stop) |

### 7.2 Retention Policy

- Keep last N summaries (default: 100). Older ones are dropped.
- Inspectable jobs (paused, errored, cancelled) stay until the user explicitly
  dismisses them, resubmits them, or the session ends.
- A paused job that is resumed is **moved out** of `_inspectable_jobs` and back
  into the pending queue — it gets a fresh execution cycle but keeps the same
  `_job_id`.
- An errored job whose failed items are retried spawns a **new** job (new ID)
  containing only the failed items. The original job can then be dismissed.
- When an inspectable job is dismissed, convert to summary if desired.

### 7.3 History Access API

```cpp
// New methods on FileJobs:
virtual std::vector<JobSummary>             get_job_summaries() = 0;
virtual std::vector<std::shared_ptr<JobSpec>> get_inspectable_jobs() = 0;
virtual void dismiss_job(uint64_t job_id) = 0;
virtual void resume_job(uint64_t job_id) = 0;
```

---

## 8. Job History Dialog

### 8.1 Purpose

A new dialog accessible via keyboard shortcut (e.g. `Ctrl+J`) that shows:
- All completed job summaries (compact one-line per job)
- Inspectable jobs (paused/cancelled/errored) with expandable detail
- Actions: Resume (paused), Dismiss, Inspect errors

### 8.2 Layout

```
╔══════════════════════ Job History [5] ══════════════════════╗
║                                                             ║
║  [#5] COPY  ✓   42 files  1.2 GB   12.4s   avg 98 MB/s   ║
║  [#4] COPY  ⚠   38/40 files  2 errors     [Inspect]       ║
║  [#3] DELETE ✓  156 files  0.3s                             ║
║  [#2] MOVE  ⏸   12/100 files  paused      [Resume][Cancel] ║
║  [#1] COPY  ✓   10 files  50 MB   1.2s                     ║
║                                                             ║
║                              [Dismiss All Clean] [Close]    ║
╚═════════════════════════════════════════════════════════════╝
```

### 8.3 States and Actions

| State                    | Icon | Available Actions                    |
|--------------------------|------|--------------------------------------|
| COMPLETED                | ✓    | (none — summary only)                |
| COMPLETED_WITH_ERRORS    | ⚠    | Inspect, Retry Failed, Dismiss       |
| PAUSED                   | ⏸    | Inspect, Resume, Cancel, Dismiss     |
| CANCELLED                | ✕    | Inspect, Dismiss                     |

**Inspect** opens the sub-dialog (§8.4) showing full job details — items,
progress, errors, remaining work. Both paused and errored jobs can be inspected
because they are kept as full `JobSpec` objects.

**Resume** (paused only) moves the job from `_inspectable_jobs` back into the
pending queue, continuing from `_current_item_index`.

**Retry Failed** (errored only) creates a new job containing only the failed items.

**Dismiss** converts the job to a summary and removes it from the inspectable list.

### 8.4 Inspect View (Sub-Dialog)

When the user selects "Inspect" on an inspectable job (paused, errored, or
cancelled), a sub-dialog shows the full job details. The content adapts based
on job state.

**Errored job — shows error details and retry option:**

```
╔════════════ Job #4 — COPY ⚠ 2 errors ═══════════════════╗
║                                                           ║
║  Source:  /home/user/documents/                           ║
║  Dest:    /backup/documents/                              ║
║  Items:   40 total, 38 done, 2 failed                    ║
║  Bytes:   1.2 GB / 1.3 GB                                ║
║  Time:    12.4s                                           ║
║                                                           ║
║  ── Errors ──────────────────────────────────────────     ║
║  ✕ /home/user/documents/locked.pdf                       ║
║    Failed to copy file: Permission denied                 ║
║  ✕ /home/user/documents/broken_link                      ║
║    Failed to create symlink: File exists                  ║
║                                                           ║
║                         [Retry Failed] [Dismiss] [Close]  ║
╚═══════════════════════════════════════════════════════════╝
```

**Paused job — shows progress, remaining items, and resume option:**

```
╔════════════ Job #2 — MOVE ⏸ paused ═════════════════════╗
║                                                           ║
║  Source:  /home/user/photos/                              ║
║  Dest:    /backup/photos/                                 ║
║  Items:   100 total, 12 done, 88 remaining               ║
║  Bytes:   240 MB / 2.0 GB                                ║
║  Time:    5.1s (before pause)                             ║
║  Errors:  0                                               ║
║                                                           ║
║  ── Remaining Items (next 5 of 88) ─────────────────     ║
║  ○ /home/user/photos/vacation/img_013.jpg    4.2 MB      ║
║  ○ /home/user/photos/vacation/img_014.jpg    3.8 MB      ║
║  ○ /home/user/photos/vacation/img_015.jpg    5.1 MB      ║
║  ○ /home/user/photos/work/scan_001.pdf      12.0 MB      ║
║  ○ /home/user/photos/work/scan_002.pdf       8.4 MB      ║
║  ... and 83 more                                          ║
║                                                           ║
║                   [Resume] [Cancel] [Dismiss] [Close]     ║
╚═══════════════════════════════════════════════════════════╝
```

The inspect view renders different sections depending on state:

| State                 | Shows                                    | Actions                      |
|-----------------------|------------------------------------------|------------------------------|
| COMPLETED_WITH_ERRORS | Errors list, completed items count       | Retry Failed, Dismiss, Close |
| PAUSED                | Remaining items preview, errors (if any) | Resume, Cancel, Dismiss, Close |
| CANCELLED             | Completed items count, errors (if any)   | Dismiss, Close               |

### 8.5 Dialog Implementation

```cpp
struct JobHistoryDialog : Dialog {
  Component _job_list;    // DBMenu for job list
  Component _detail_view; // Rendered when inspecting a specific job
  DataSource _data_source;

  enum class View { LIST, INSPECT };
  View _current_view = View::LIST;
  uint64_t _inspecting_job_id = 0;

  void OnShow() override;
  Element render_list();
  Element render_inspect();
};
```

Register in `FileCommander` (alongside `ErrorListDialog`):
```cpp
_overlay_dialogs["JobHistory"] = std::make_shared<JobHistoryDialog>(...);
```

---

## 9. Scripting Integration

### 9.1 Event Detail

Replace empty `fire_event("job_completed", "")` with structured detail:

```cpp
// In drain_completed_jobs() or wherever the UI processes completion:
std::string detail = "id=" + std::to_string(job->_job_id)
  + " type=" + type_name(job->_type)
  + " state=" + state_name(job->_state)
  + " items=" + std::to_string(job->_current_item_index)
  + " errors=" + std::to_string(job->_errors.size());

fire_event("job_completed", detail);
```

### 9.2 Eliminate Polling for Job Events

Currently `poll_async_events()` detects jobs by comparing timestamps. With the
completion queue, this becomes:

```cpp
void poll_async_events() {
  // Jobs: drain the completion queue directly
  drain_completed_jobs();  // fires events with detail
  // No more timestamp comparison needed for jobs

  // Discovery: still needs polling (or add a similar queue)
  // ...
}
```

Or better: `drain_completed_jobs()` posts events into `_event_log` directly, and
`check_waits()` picks them up.

### 9.3 New Lua API

**Registration in `scripting.cpp`:**

```cpp
// clang-format off
reg("key",         l_key);
reg("quit",        l_quit);
// ... existing registrations ...
reg("wait_event",  l_wait_event);
reg("sleep",       l_sleep);
// New job management API:
reg("run_dialog",  l_run_dialog);
reg("wait_job",    l_wait_job);
reg("job_status",  l_job_status);
reg("job_errors",  l_job_errors);
reg("job_items",   l_job_items);
reg("job_history", l_job_history);
reg("cancel_job",  l_cancel_job);
reg("pause_job",   l_pause_job);
reg("resume_job",  l_resume_job);
// clang-format on
```

**Quick reference:**

| Lua Function                  | Returns              | Blocking? | Purpose                              |
|-------------------------------|----------------------|-----------|--------------------------------------|
| `fc.run_dialog()`             | `job_id` or `nil`    | No        | Confirm active dialog, get job ID    |
| `fc.wait_job(id, timeout)`    | result table or `nil` | Yes (yield) | Wait for job terminal state        |
| `fc.job_status(id)`           | info table or `nil`  | No        | Query any job's current state        |
| `fc.job_errors(id)`           | error list or `nil`  | No        | Get per-job error details            |
| `fc.job_items(id, off, lim)`  | item list or `nil`   | No        | Get items slice (remaining/all)      |
| `fc.job_history()`            | list of summaries    | No        | All known jobs                       |
| `fc.cancel_job(id)`           | `bool`               | No        | Signal cancel on running/queued job  |
| `fc.pause_job(id)`            | `bool`               | No        | Signal pause on running job          |
| `fc.resume_job(id)`           | `bool`               | No        | Re-queue a paused job                |

Framework helpers (in `fc_framework.lua`):

| Lua Function                  | Returns              | Purpose                              |
|-------------------------------|----------------------|--------------------------------------|
| `fc.run_and_wait(timeout)`    | result table         | `run_dialog()` + `wait_job()` combo  |
| `fc.copy_and_wait(timeout)`   | result table         | F5 + discovery + run + wait combo    |

---

#### `fc.run_dialog()` — Accept Current Dialog and Return Job ID

The key new function. Replaces the brittle keyboard navigation
(`fc.key({"<-", "ret"})`) currently used to click the OK/COPY button. Directly
triggers the active dialog's confirm action and returns the job ID assigned by
`add_job()`.

```lua
local job_id = fc.run_dialog()
-- Returns: integer job_id on success, nil if no dialog is active or dialog
--          has no job to run (e.g. empty selection, discovery not started)
```

**Why this is better than key simulation:**

- No fragile focus/navigation assumptions (button position, tab order)
- Returns the job ID immediately — the test knows exactly which job to wait on
- Works regardless of dialog type (Copy, Move, Delete)
- Discovery must be complete before calling (for Copy); otherwise returns nil

**Design: store `_last_job_id` in Dialog base class**

Instead of duplicating the job-creation logic in a separate `accept()` method,
we store the job ID as a side-effect of the existing `run_copy()` / `ok()` paths:

1. Dialog base class gets a `_last_job_id` field, nulled on `OnShow()`
2. Existing `run_copy()`, `ok()` methods are untouched — `add_job()` now returns
   the assigned `_job_id`, and the dialog stores it in `_last_job_id`
3. `accept()` simply calls the existing confirm method, then returns `_last_job_id`

Zero code duplication. The button-click and scripting paths share the exact same
confirm logic.

**Dialog base class change:**

```cpp
// In Dialog (dialogs.hpp):
struct Dialog {
  // ... existing members ...

  /// Job ID of the last job created by this dialog.
  /// Set by confirm methods (run_copy, ok), cleared on OnShow().
  std::optional<uint64_t> _last_job_id;

  void OnShow() override {
    _last_job_id = std::nullopt;   // reset on every dialog open
    // ... existing OnShow logic ...
  }

  /// Programmatically confirm this dialog. Calls the dialog's normal
  /// confirm path, then returns _last_job_id.
  /// Default: returns nullopt (dialog has no job, e.g. Mkdir, Rename).
  virtual std::optional<uint64_t> accept() { return std::nullopt; }
};
```

**Minimal changes to existing confirm methods:**

```cpp
// add_job() returns the assigned ID (one-line change in file_io_jobs.cpp):
uint64_t ThreadedFileJobs::add_job(std::shared_ptr<JobSpec> job) {
  job->_job_id = _next_job_id.fetch_add(1);
  _pending_queue.push(job);
  return job->_job_id;
}

// CopyDialog::run_copy() — add ONE line:
void CopyDialog::run_copy() {
  if (!_discovery_process) return;
  auto job = std::make_shared<JobSpec>(JobSpec::Type::COPY,
                                       std::move(_discovery_process->_dir->items));
  _clear_operation_state();
  _last_job_id = file_operations().add_job(job);   // ← store job ID
  app->dir->clear_selection();
  app->action.close_dialog();
}

// DeleteDialog::ok() — add ONE line:
void DeleteDialog::ok() {
  std::vector<DirItem> items;
  for (auto& p : app->action.arguments->selected) items.emplace_back(p);
  auto job = std::make_shared<JobSpec>(JobSpec::Type::DELETE, std::move(items));
  _last_job_id = file_operations().add_job(job);   // ← store job ID
  app->dir->clear_selection();
  app->action.close_dialog();
}

// MoveDialog::ok() — add ONE line:
void MoveDialog::ok() {
  // ... build items as before ...
  auto job = std::make_shared<JobSpec>(JobSpec::Type::MOVE, std::move(items));
  _last_job_id = file_operations().add_job(job);   // ← store job ID
  app->dir->clear_selection();
  app->action.close_dialog();
}
```

**Per-dialog `accept()` — thin wrappers over existing methods:**

```cpp
// CopyDialog::accept()
std::optional<uint64_t> CopyDialog::accept() {
  run_copy();            // reuses 100% of existing logic
  return _last_job_id;   // set by run_copy() → add_job()
}

// DeleteDialog::accept()
std::optional<uint64_t> DeleteDialog::accept() {
  ok();
  return _last_job_id;
}

// MoveDialog::accept()
std::optional<uint64_t> MoveDialog::accept() {
  ok();
  return _last_job_id;
}
```

**C++ implementation (`l_run_dialog`):**

```cpp
int LuaScripting::l_run_dialog(lua_State* L) {
  auto* self = from_lua(L);

  auto* dialog = self->_app.get_active_dialog();
  if (!dialog) { lua_pushnil(L); return 1; }

  auto job_id = dialog->accept();
  if (!job_id) { lua_pushnil(L); return 1; }

  lua_pushinteger(L, *job_id);
  return 1;
}
```

The entire `l_run_dialog` is 7 lines. No dialog-type switching, no special cases.

---

#### `fc.wait_job(job_id, timeout_ms)` — Wait for a Specific Job

Waits until the job with the given ID reaches a terminal state (COMPLETED,
COMPLETED_WITH_ERRORS, or CANCELLED). Returns a table with the job's final state.

```lua
local result = fc.wait_job(job_id, 30000)
-- Returns on success:
--   {id=5, type="copy", state="completed", items=42, errors=0,
--    bytes_total=1048576, bytes_processed=1048576, elapsed=12.4}
-- Returns nil on timeout
```

**C++ implementation:**

This works like `l_wait_event` but instead of matching event names, it matches
a `job_completed` event whose detail contains the target job ID. Alternatively,
maintain a `_completed_job_ids` set that `drain_completed_jobs()` populates, and
check it directly:

```cpp
int LuaScripting::l_wait_job(lua_State* L) {
  auto* self = from_lua(L);
  uint64_t job_id = luaL_checkinteger(L, 1);
  double timeout  = luaL_optnumber(L, 2, 30000);

  // Check if already completed
  auto* result = self->find_completed_job(job_id);
  if (result) {
    push_job_result(L, *result);
    return 1;
  }

  // Not yet — set up a wait
  self->_pending_wait = PendingWait{
    .job_id  = job_id,
    .deadline = now() + timeout / 1000.0,
  };
  self->_scheduler.schedule_at(self->_pending_wait->deadline);
  return lua_yield(L, 0);
}
```

`check_waits()` is extended: after draining completed jobs, if a `_pending_wait`
has a `job_id`, check the completed set instead of the event log.

---

#### `fc.job_status(job_id)` — Query a Specific Job

Non-blocking query. Returns the current state of any known job (running, queued,
completed, or unknown).

```lua
local info = fc.job_status(job_id)
-- Returns:
--   {id=5, type="copy", state="running", items_total=42, items_done=20,
--    bytes_total=1048576, bytes_processed=524288, errors=0, queued=0}
-- Returns nil if job_id is not known (too old, never existed)
```

**C++ implementation:**

Checks three places in order:
1. Active job (`_active_job`) — if `_job_id` matches, it's running
2. Pending queue — scan for queued job with matching ID (state = "queued")
3. Job history — summaries + inspectable jobs

```cpp
int LuaScripting::l_job_status(lua_State* L) {
  auto* self = from_lua(L);
  uint64_t job_id = luaL_checkinteger(L, 1);

  // Check active job
  auto jobinfo = file_operations().get_running_job();
  if (jobinfo.job && jobinfo.job->_job_id == job_id) {
    push_job_info(L, jobinfo.job);
    return 1;
  }

  // Check completed/inspectable history
  auto* hist = file_operations().find_job(job_id);
  if (hist) {
    push_job_result(L, *hist);
    return 1;
  }

  lua_pushnil(L);
  return 1;
}
```

---

#### `fc.job_errors(job_id)` — Get Errors for a Specific Job

Returns the error list for any inspectable job (paused, errored, or cancelled).
All three states are kept as full `JobSpec` objects, so their `_errors` vector
is always available.

```lua
local errs = fc.job_errors(job_id)
-- Returns: {
--   {path="/foo/bar.txt", message="Permission denied"},
--   {path="/foo/link",    message="Failed to create symlink: File exists"},
-- }
-- Returns empty table if job has no errors (e.g. paused with 0 errors)
-- Returns nil if job_id is not known or is a compacted summary
```

**C++ implementation:**

Finds the job in `_inspectable_jobs` (paused, errored, or cancelled — all kept
as full `JobSpec`), iterates `_errors` vector:

```cpp
int LuaScripting::l_job_errors(lua_State* L) {
  auto* self = from_lua(L);
  uint64_t job_id = luaL_checkinteger(L, 1);

  auto job = file_operations().find_inspectable_job(job_id);
  if (!job) { lua_pushnil(L); return 1; }

  lua_newtable(L);
  int idx = 1;
  for (auto& err : job->_errors) {
    lua_newtable(L);
    lua_pushstring(L, err.path_ref().native().c_str());
    lua_setfield(L, -2, "path");
    lua_pushstring(L, err.warning_ref().value_or("unknown").c_str());
    lua_setfield(L, -2, "message");
    lua_rawseti(L, -2, idx++);
  }
  return 1;
}
```

---

#### `fc.job_items(job_id, offset, limit)` — Get Items for an Inspectable Job

Returns a slice of the item list for any inspectable job. Particularly useful
for paused jobs to see remaining work, but also works for errored/cancelled jobs
to see what was processed.

```lua
-- Get remaining items for a paused job (items from current_item_index onward)
local info = fc.job_status(job_id)
local remaining = fc.job_items(job_id, info.items_done, 20)
-- Returns: {
--   {path="/home/user/photos/vacation/img_013.jpg", size=4200000},
--   {path="/home/user/photos/vacation/img_014.jpg", size=3800000},
--   ...
-- }

-- Get all items (completed + remaining)
local all_items = fc.job_items(job_id, 0, 100)

-- Returns nil if job_id is not inspectable (compacted summary or unknown)
```

**C++ implementation:**

```cpp
int LuaScripting::l_job_items(lua_State* L) {
  auto* self = from_lua(L);
  uint64_t job_id = luaL_checkinteger(L, 1);
  int offset = luaL_optinteger(L, 2, 0);
  int limit  = luaL_optinteger(L, 3, 50);

  auto job = file_operations().find_inspectable_job(job_id);
  if (!job) { lua_pushnil(L); return 1; }

  lua_newtable(L);
  int idx = 1;
  int end = std::min(offset + limit, (int)job->_items.size());
  for (int i = offset; i < end; i++) {
    auto& item = job->_items[i];
    lua_newtable(L);
    lua_pushstring(L, item.path_ref().native().c_str());
    lua_setfield(L, -2, "path");
    lua_pushinteger(L, item.size());
    lua_setfield(L, -2, "size");
    lua_rawseti(L, -2, idx++);
  }
  return 1;
}
```

---

#### `fc.job_history()` — Get All Job History

Returns a list of all known jobs (running + completed + inspectable).

```lua
local jobs = fc.job_history()
-- Returns: {
--   {id=5, type="copy",   state="completed",            items=42, errors=0},
--   {id=4, type="copy",   state="completed_with_errors", items=40, errors=2},
--   {id=3, type="delete", state="completed",            items=156, errors=0},
--   {id=2, type="move",   state="paused",               items=100, items_done=12, errors=0},
--   {id=1, type="copy",   state="completed",            items=10, errors=0},
-- }
```

---

#### `fc.cancel_job(job_id)` — Cancel a Running or Queued Job

```lua
local ok = fc.cancel_job(job_id)
-- Returns: true if cancel was signaled, false if job not found or already done
```

Sets `_cancel_requested = true` on the job. The worker will stop after the current
item. For queued jobs, removes from the pending queue immediately.

---

#### `fc.pause_job(job_id)` — Pause a Running Job

```lua
local ok = fc.pause_job(job_id)
-- Returns: true if pause was signaled, false if job not found or not running
```

Sets `_pause_requested = true`. The worker stops after the current item and
transfers the job to the completion queue with state PAUSED.

---

#### `fc.resume_job(job_id)` — Resume a Paused Job

```lua
local ok = fc.resume_job(job_id)
-- Returns: true if job was re-queued, false if job not found or not paused
```

Resets the pause flag, sets state to QUEUED, and re-enqueues via `add_job()`.

---

### 9.3.1 Updated `fc_framework.lua` Helpers

```lua
--- Run the current dialog and wait for the resulting job to complete.
--- Returns the job result table, or errors on timeout.
fc.run_and_wait = function(timeout_ms)
  local job_id = fc.run_dialog()
  if not job_id then
    error("run_and_wait: no dialog to confirm or dialog cannot produce a job", 2)
  end
  local result = fc.wait_job(job_id, timeout_ms or 30000)
  if not result then
    error(string.format("run_and_wait: job %d timed out", job_id), 2)
  end
  return result
end

--- Open copy dialog, wait for discovery, run, wait for job. Returns job result.
fc.copy_and_wait = function(timeout_ms)
  fc.key("f5")
  fc.wait_event("discovery_completed", timeout_ms or 10000)
  return fc.run_and_wait(timeout_ms)
end
```

### 9.3.2 Example Test With New API

Compare the old test pattern vs the new one:

**Old (fragile key navigation):**
```lua
fc.key("cA")
fc.key("f5")
fc.wait_event("discovery_completed", 10000)
fc.key({"<-", "ret"})     -- navigate to COPY button and press
fc.wait_for_jobs()         -- wait for generic "job_completed" event
local errs = fc.errors()   -- check global error list
check(#errs == 0, ...)
```

**New (direct, typed, per-job):**
```lua
fc.key("cA")
fc.key("f5")
fc.wait_event("discovery_completed", 10000)
local result = fc.run_and_wait()
check(result.state == "completed", "copy succeeded: state=%s", result.state)
check(result.errors == 0, "no errors: got %d", result.errors)
-- Or inspect per-job errors:
if result.errors > 0 then
  local errs = fc.job_errors(result.id)
  for _, e in ipairs(errs) do print(e.path .. ": " .. e.message) end
end
```

### 9.4 Discovery Events

Apply the same pattern to discovery: instead of polling `_running` flags, have
`CopyDiscoveryProcess` push a completion notification into a queue that the UI drains.

```cpp
// In CopyDiscoveryProcess::_run():
_running = false;
// Instead of just posting Event::Custom, also push a discovery result
_parent->_discovery_completed_queue.push(DiscoveryResult{
  .file_count = _progress.file_count,
  .dir_count  = _progress.dir_count,
  .byte_count = _progress.byte_count,
  .error_count = _progress.error_count,
});
```

---

## 10. Progress Display Changes

### 10.1 Active Job Progress Bar (unchanged for running jobs)

The `JobProgressBar` continues to read from `_active_job` via
`file_operations().get_running_job()`. This shows the currently executing job.

### 10.2 Paused Job Indicator

When there are paused jobs, show a compact indicator below the progress bar:

```
⏸ 1 paused job — Ctrl+J to manage
```

### 10.3 Queued Jobs Count

Already shown in `JobProgressBar` but can be enhanced:

```
[2 queued] COPY | 45% avg 98 MB/s 38/42 items | 78% 120 MB/s large_file.zip
```

---

## 11. No Popup Interruption Principle

**Critical design constraint**: Copy/move/delete operations must NEVER show a popup
dialog that blocks the operation. All communication between the worker thread and UI
is via:

1. **Atomic flags** — UI sets `_cancel_requested` / `_pause_requested`
2. **Completion queue** — Worker pushes finished jobs for UI to process
3. **Progress callback** — `updated()` posts `Event::Custom` for progress refresh

The worker thread never waits for user input. If a conflict or error occurs during
execution, the worker applies the pre-configured policy:

| Scenario              | Policy                                          |
|-----------------------|-------------------------------------------------|
| File exists at dest   | Apply `CopyConflict` setting (Replace/Skip/Update) chosen before job starts |
| Permission denied     | Record error, skip item, continue                |
| Disk full             | Record error, skip item, continue                |
| I/O error             | Record error, skip item, continue                |
| Symlink cycle         | Already handled during discovery                 |

After the job finishes (or is paused), the user can inspect it via the Job History
dialog and resubmit work:

- **Paused jobs** can be resumed (same job, continues from where it stopped)
- **Errored jobs** can have their failed items retried (new job with only failed items)

### 11.1 Resubmit Workflows

#### Resume a Paused Job

Resume moves the full `JobSpec` from `_inspectable_jobs` back into the pending
queue. The worker picks it up and continues from `_current_item_index`:

```cpp
void resume_paused(uint64_t job_id) {
  auto job = remove_inspectable_job(job_id);
  if (!job || job->_state != JobState::PAUSED) return;
  job->_pause_requested = false;
  job->_state = JobState::QUEUED;
  // Keep the same _job_id — this is the same logical job
  _pending_queue.push(std::move(job));
}
```

Note: the job keeps its original `_job_id`. Lua scripts that called
`fc.wait_job(job_id)` before the pause will resume waiting and receive the
final result when the job completes.

#### Retry Failed Items

"Retry Failed" creates a **new** `JobSpec` (new `_job_id`) containing only
the failed items from the original job:

```cpp
uint64_t retry_failed(uint64_t job_id) {
  auto old_job = find_inspectable_job(job_id);
  if (!old_job || old_job->_errors.empty()) return 0;
  auto retry = std::make_shared<JobSpec>(old_job->_type, std::move(old_job->_errors));
  return file_operations().add_job(retry);  // new _job_id assigned
}
```

The original errored job can then be dismissed (converted to summary) since
its failed items now belong to the new retry job.

---

## 12. Wire Protocol Summary

### UI Thread → Worker Thread

| Signal              | Mechanism                    | Granularity     |
|---------------------|------------------------------|-----------------|
| New job             | `_pending_queue.push(job)`   | Job-level       |
| Cancel              | `job->_cancel_requested = true` | Checked per-item |
| Pause               | `job->_pause_requested = true`  | Checked per-item |

### Worker Thread → UI Thread

| Signal              | Mechanism                          | Payload              |
|---------------------|------------------------------------|----------------------|
| Progress update     | `job->updated()` → `Event::Custom` | Read from `_active_job` fields |
| Job done            | `_completed_queue.push(job)` + `Event::Custom` | Full JobSpec with state |

### UI Thread Internal

| Signal              | Mechanism                          | Payload              |
|---------------------|------------------------------------|----------------------|
| Drain completions   | `drain_completed_jobs()` in tick/render | JobSpec → summary or inspectable |
| Fire script event   | `fire_event("job_completed", detail)` | Job ID, type, state, counts |

---

## 13. File Changes Summary

| File                | Changes                                                    |
|---------------------|------------------------------------------------------------|
| `file_io_jobs.hpp`  | Add `JobState` enum, `_job_id`, `_cancel_requested`, `_pause_requested` to `JobSpec`. Add `JobSummary` struct. Extend `FileJobs` interface with history/resume/dismiss methods. Add `find_job()`, `find_inspectable_job()` accessors. Change `add_job()` to return `uint64_t`. |
| `file_io_jobs.cpp`  | Rework `run()` loop: check cancel/pause flags, push to `_completed_queue` instead of keeping `_job`. Add `drain_completed_jobs()`. Resume support in `run_copy`/`run_move`/`run_delete` (start from `_current_item_index`). `add_job()` returns assigned `_job_id`. |
| `dialogs.hpp`       | Add `std::optional<uint64_t> _last_job_id` and `virtual accept()` to `Dialog` base. Declare `JobHistoryDialog`. |
| `dialogs.cpp`       | Add `_last_job_id = file_operations().add_job(job)` to existing `run_copy()`, `ok()` methods (one line each). Add thin `accept()` wrappers that call existing confirm methods and return `_last_job_id`. Clear `_last_job_id` in `OnShow()`. Implement `JobHistoryDialog` with list + inspect views. |
| `app.hpp`           | Register `JobHistoryDialog`. Add shortcut (Ctrl+J). Update `JobProgressBar` to show paused indicator. Add `drain_completed_jobs()` call in render. |
| `scripting.hpp`     | Remove `_had_running_job`, `_last_job_*` poll state. Add `find_completed_job()`, `push_job_result()`, `push_job_info()` helpers. Add `PendingWait.job_id` field. |
| `scripting.cpp`     | Replace job polling with `drain_completed_jobs()` + event fire. Register `l_run_dialog`, `l_wait_job`, `l_job_status`, `l_job_errors`, `l_job_items`, `l_job_history`, `l_cancel_job`, `l_pause_job`, `l_resume_job`. Update `fire_event` calls with job detail. Extend `check_waits()` for job-ID-based waits. |
| `fc_framework.lua`  | Add `fc.run_and_wait()`, `fc.copy_and_wait()` convenience wrappers. |
| `main.cpp`          | Wire `drain_completed_jobs()` into the explicit `ftxui::Loop`. |

---

## 14. Implementation Order

### Steps 1–3: DONE

1. **Add `JobState`, `_job_id`, cancel/pause flags** to `JobSpec` ✅
   - `JobState` enum added to `file_io_jobs.hpp` (QUEUED, RUNNING, PAUSED, CANCELLED, COMPLETED, COMPLETED_WITH_ERRORS)
   - `std::atomic<JobState> _state` in `JobStats`, `uint64_t _job_id` in `JobSpec`
   - `std::atomic<bool> _cancel_requested`, `_pause_requested` in `JobSpec`
   - `#include <atomic>` added

2. **Add `_completed_queue` and `drain_completed_jobs()`** ✅
   - Renamed `_job` → `_active_job` in `ThreadedFileJobs`
   - Added `_completed_queue` (`FifoQueue<shared_ptr<JobSpec>>`) for worker → UI transfer
   - Added `_next_job_id` atomic counter (starts at 1)
   - `add_job()` now assigns `_job_id` and returns `uint64_t` (was `FifoError`)
   - `run()` sets `_state = RUNNING`, determines final state (COMPLETED / COMPLETED_WITH_ERRORS), pushes to `_completed_queue`
   - `drain_completed_jobs()` added to `FileJobs` interface and `ThreadedFileJobs`
   - Drain called from `handle_global_shortcuts` on `Event::Custom` (event phase, not render phase)
   - `_active_job` kept after completion (backward compat with scripting poll)

3. **Implement cancel** ✅
   - `_cancel_requested` check at top of each item in `run_copy`, `run_move`, `run_delete`
   - `run_delete`: closes discovery FifoQueue on cancel to stop the discovery thread
   - `run_copy`: boost `copy_file_options.cancel_requested` enables mid-file cancellation;
     ECANCELED return detected and handled cleanly (no spurious error, partial file removed by boost)
   - `cancel_job()` implemented (sets `_cancel_requested = true`)
   - Cancel button added to `JobProgressBar` as a proper FTXUI `Button` Component,
     wrapped with `Maybe(&_has_running_job)`, added to component tree via `Container::Vertical`
   - `_transfer_rate` fixed from `volatile` to `std::atomic<uint64_t>`

   **Lua API added (early, for testing):**
   - `fc.set_transfer_rate(bytes_per_second)` — global transfer rate limit
   - `fc.cancel_job()` — cancel the currently running job
   - `fc.state().jobs.state` — job state field (running/completed/cancelled/etc.)

   **Test added:**
   - Test 29 (`test_cancel_copy`): 10×1MB files at 2MB/s rate, cancel after 2.5s,
     verifies partial copy, state=="cancelled", no errors

4. **Implement pause** ✅
   - `_pause_requested` check added at top of each item loop in `run_copy`, `run_move`, `run_delete`
   - Check is between items only — does NOT interrupt mid-file copy (no `pause_requested` in `copy_file_options`)
   - Cancel takes priority: cancel check comes before pause check in all loops
   - `run_delete`: closes discovery FifoQueue on pause to stop the discovery thread
   - `pause_job()` added to `FileJobs` interface and `ThreadedFileJobs`
   - Pause button added to `JobProgressBar` alongside cancel, both wrapped with `Maybe(&_has_running_job)`
   - `fc.pause_job()` exposed in Lua scripting

   **Test added:**
   - Test 30 (`test_pause_copy`): 10×1MB files at 2MB/s, pause after 2.5s,
     verifies partial copy, state=="paused", no errors

### Steps 5–10: TODO

5. **Implement resume**
   - Adjust copy/move/delete loops to start from `_current_item_index`
   - Wire resume action from Job History dialog

6. **Add `JobSummary` and two-tier history storage**
   - Compact completed-no-error jobs into summaries
   - Keep full `JobSpec` for inspectable jobs

7. **Implement `JobHistoryDialog`**
   - List view with all jobs
   - Inspect view for errored/paused/cancelled jobs
   - Actions: Resume, Cancel, Dismiss, Retry Failed

8. **Add `_last_job_id` to Dialog base and `accept()` wrappers**
   - Add `std::optional<uint64_t> _last_job_id` to `Dialog`, clear in `OnShow()`
   - Add `_last_job_id = file_operations().add_job(job)` to existing `run_copy()`, `ok()` (one line each)
   - Add thin `accept()` overrides that call existing confirm methods and return `_last_job_id`

9. **Update scripting integration**
   - Replace polling with drain-based event firing
   - Add job detail to events
   - Register all new Lua functions:
     - `fc.run_dialog()` — accept dialog, return job_id
     - `fc.wait_job(id, timeout)` — yield until job reaches terminal state
     - `fc.job_status(id)` — non-blocking job query
     - `fc.job_errors(id)` — per-job error list
     - `fc.job_items(id, offset, limit)` — item slice for inspectable jobs
     - `fc.job_history()` — all jobs summary
     - `fc.cancel_job(id)` — signal cancel (upgrade existing to accept job ID)
     - `fc.pause_job(id)` — signal pause
     - `fc.resume_job(id)` — re-queue paused job
   - Add `fc.run_and_wait()`, `fc.copy_and_wait()` to `fc_framework.lua`

10. **Update tests**
    - Migrate existing tests from key-simulation to `fc.run_dialog()` / `fc.run_and_wait()`
    - Add tests for cancel/pause/resume via `fc.cancel_job()` / `fc.pause_job()` / `fc.resume_job()`
    - Add tests for `fc.job_status()` and `fc.job_errors()` inspection
    - Verify job history inspection via `fc.job_history()`
    - Verify retry-failed workflow
