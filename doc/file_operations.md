---
name: File Operations
overview: "Architecture, edge cases, gaps, and async UI analysis for copy/move/delete operations in File Commander."
---

# File Operations

## 1. Architecture Overview

File Commander's file operations (copy, move, delete) follow a three-phase pipeline:

```
┌───────────────┐     ┌────────────────┐     ┌───────────────┐
│   Discovery    │────▶│   Execution    │────▶│  Completion   │
│  (background)  │     │  (background)  │     │  (UI thread)  │
└───────────────┘     └────────────────┘     └───────────────┘
```

### 1.1 Discovery Phase

For copy and move, a `CopyDiscoveryProcess` runs in a background thread to:

1. Recursively traverse selected files/directories
2. Resolve symlinks according to user options
3. Detect cycles (symlink loops, directory loops)
4. Build a flat list of operations (mkdir, copy-file, create-symlink)
5. Calculate total byte count for progress tracking
6. Display discovered items in the dialog's file list

Discovery results are stored in a `Dir` object whose `items` vector is the ordered
operation list. The ordering is depth-first to create a tree-like depiction in the
dialog and to ensure parent directories are created before their contents.

### 1.2 Execution Phase

When the user confirms the operation, a `JobSpec` is created from the discovery results
and queued into `ThreadedFileJobs`, a singleton that processes jobs sequentially from a
FIFO queue. The worker thread iterates the item list:

- **directory_file** → `boost::filesystem::create_directory(path)`
- **symlink_file** → `boost::filesystem::create_symlink(link_path, target_path)`
- **regular_file** → `boost::filesystem::copy_file(src, dst, overwrite_existing)`

A `ProgressMonitor` thread samples large-file progress every 200ms for real-time
throughput display. All errors are collected per-item and the job continues.

### 1.3 Completion & Notification

When a job finishes, `_finished_time` is set and `updated()` posts `Event::Custom` to
wake the FTXUI event loop. `CopyDiscoveryProcess::_run()` also posts `Event::Custom`
after discovery completes.

---

## 2. Copy Operation in Detail

### 2.1 Dialog Options

| Option                   | Default | Effect                                                      |
|--------------------------|---------|-------------------------------------------------------------|
| Follow Links in Source   | off     | When on: dereference symlinks, copy their targets           |
| Keep relative links      | on      | When on (and Follow Links off): preserve relative symlinks  |

### 2.2 Symlink Handling Decision Tree

```
Is item a symlink?
├── YES
│   ├── preserve_relative_links AND !follow_links AND link is relative?
│   │   └── Queue relative symlink as-is (preserve target verbatim)
│   │
│   ├── resolve_symlink() → cycle detected (empty path)?
│   │   └── Queue error: "Cyclic symlink"
│   │
│   ├── follow_links?
│   │   └── Recurse into resolved target as if it were the actual item
│   │       (symlink becomes a regular file or directory in destination)
│   │
│   └── Otherwise:
│       └── Canonicalize target to absolute path → queue absolute symlink
│
└── NO → handle as regular file or directory
```

### 2.3 Cycle Detection

**Symlink cycles**: `resolve_symlink()` follows the chain and maintains a visited set.
If an already-visited path is encountered, returns empty path → error.

**Directory cycles**: `_visited_dirs` tracks (source, destination) pairs. If a directory
is `equivalent()` to one already visited, a symlink to the previously copied destination
is created instead of recursing.

### 2.4 Copy-to-Self Detection

Before processing each item, `boost::filesystem::equivalent(source, destination)` is
checked. If they are the same inode, error "Copy to self" is queued.

**Gap**: This checks individual files, not subtree containment. Copying `/a` into `/a/b`
is not detected and will cause infinite recursion during discovery (mitigated only by
the directory cycle detection).

### 2.5 File Conflict Resolution

**Current**: Always uses `copy_options::overwrite_existing`. No user choice.

**Defined but unused** (`CopyConflict` enum):

| Mode    | Intended behavior                                  |
|---------|----------------------------------------------------|
| Replace | Overwrite existing files (current behavior)        |
| Update  | Overwrite only if source is newer                  |
| Skip    | Skip if destination already exists                 |

### 2.6 Execution Details

- Jobs are processed sequentially (one at a time) from a FIFO queue
- Individual item failures do not stop the job — errors are collected
- Progress is updated every 200ms for UI refresh
- Large files (>10MB) get per-file progress sampling via `ProgressMonitor`
- All items use the same lock (`job->_m`), unlocked during I/O operations

---

## 3. Move Operation

Move tries `boost::filesystem::rename()` first (instant for same-filesystem).
If it fails with `cross_device_link`, falls back to copy + delete with flags:
`copy_options::overwrite_existing | recursive | copy_symlinks`.

**Gaps**: Same as copy regarding conflict resolution, attribute preservation, etc.

---

## 4. Delete Operation

Iterates selected items and calls `boost::filesystem::remove_all()` for directories
or `boost::filesystem::remove()` for files. Errors are collected per-item.

---

## 5. Edge Cases: What Is Handled

| Edge case                        | Handling                                              |
|----------------------------------|-------------------------------------------------------|
| Regular files                    | `copy_file()` with overwrite                          |
| Directories (recursive)          | Depth-first traversal, `create_directory()`           |
| Symlinks (absolute)              | Canonicalized to absolute, `create_symlink()`         |
| Symlinks (relative, preserved)   | Target string preserved verbatim                      |
| Symlinks (followed/dereferenced) | Resolved target treated as regular file/dir           |
| Cyclic symlinks (A→B→A)         | Detected by `resolve_symlink()`, error reported       |
| Cyclic directories (A/sub→A)    | Detected by `_visited_dirs`, replaced with symlink    |
| Copy-to-self (same inode)        | Detected by `equivalent()`, error reported            |
| Large files (>10MB)              | Per-file progress monitoring at 200ms interval        |
| Multiple jobs                    | Queued FIFO, processed sequentially                   |
| I/O errors on individual items   | Error collected, job continues with remaining items   |

---

## 6. Edge Cases: What Is NOT Handled

### 6.1 Attribute Preservation

| Attribute              | Status              | Notes                                            |
|------------------------|---------------------|--------------------------------------------------|
| File permissions       | **Not preserved**   | Destination gets default permissions (umask)      |
| Timestamps (mtime)     | **Not preserved**   | Destination gets current time                     |
| Ownership (uid/gid)    | **Not preserved**   | Destination gets current user                     |
| Extended attrs (xattr) | **Not preserved**   | macOS resource forks, Linux security labels lost  |
| ACLs                   | **Not preserved**   | Access control lists not copied                   |

### 6.2 Special File Types

| File type          | Status              | Notes                                           |
|--------------------|---------------------|-------------------------------------------------|
| Block devices      | **Not handled**     | May error or be skipped silently                 |
| Character devices  | **Not handled**     | Same                                             |
| Named pipes (FIFO) | **Not handled**     | Same                                             |
| Unix sockets       | **Not handled**     | Same                                             |
| Hard links         | **Not detected**    | Multiple hard links to same inode copied as separate files |
| Sparse files       | **Not preserved**   | Holes filled with zeros, inflating disk usage    |

### 6.3 Symlink Edge Cases

| Edge case                          | Status               | Notes                                           |
|------------------------------------|-----------------------|-------------------------------------------------|
| Dangling symlinks                  | **Partially handled** | `resolve_symlink()` returns original path; behavior depends on follow mode |
| Dangling + follow_links            | **Not handled**       | Will try to recurse into non-existent target    |
| Relative symlink target rewriting  | **Not done**          | When copying to different depth, relative targets may become invalid |
| Directory symlinks (Windows)       | **Not handled**       | Uses `create_symlink` not `create_directory_symlink` |
| Symlink permissions                | **Ignored**           | `lchown`/`lchmod` not called                    |
| Cross-device relative symlinks     | **Not adjusted**      | Relative target may point to wrong location     |
| Follow-links file symlink          | **BUG**               | Destination path doubles filename (see 6.6)     |

### 6.4 Conflict Resolution

| Feature                            | Status               | Notes                                           |
|------------------------------------|-----------------------|-------------------------------------------------|
| Skip existing files                | **Not implemented**   | `CopyConflict::Skip` defined but unused         |
| Update (overwrite if newer)        | **Not implemented**   | `CopyConflict::Update` defined but unused       |
| Ask per-file                       | **Not implemented**   | Would require async dialog during job           |
| Ask once (all/none)                | **Not implemented**   | No "overwrite all" / "skip all" option          |
| Rename on conflict                 | **Not implemented**   | No "copy as foo(1).txt" logic                   |

### 6.5 Robustness

| Feature                            | Status               | Notes                                           |
|------------------------------------|-----------------------|-------------------------------------------------|
| Job cancellation                   | **Stub only**         | Method exists but is a no-op                     |
| Pause/resume                       | **Not implemented**   |                                                  |
| Retry on error                     | **Not implemented**   | Individual failures are permanent                |
| Atomic copy (temp + rename)        | **Not implemented**   | Interrupted copy leaves partial file             |
| Disk space pre-check               | **Not implemented**   | May fill disk mid-copy                           |
| Copy-into-self (subtree)           | **Not detected**      | Copying /a into /a/b causes infinite discovery   |
| Destination path editing           | **Commented out**     | UI element exists but is disabled                |
| Empty directory names              | **Not validated**     |                                                  |
| Path length limits                 | **Not checked**       | May fail on deeply nested structures             |

### 6.6 Bugs Found During Testing

#### 6.6.1 Symlink creation argument order (FIXED)

`file_io_jobs.cpp` had `create_symlink(link_path, target)` but Boost/std expects
`create_symlink(target, link_path)`. This caused all symlink copies to fail with I/O
errors. **Fixed**: swapped arguments.

#### 6.6.2 Follow-links mode destination path for file symlinks (OPEN)

When `follow_links=true` and a symlink points to a regular file, `_discover()` recurses
with:
```cpp
this->_discover({DirItem(symlink_target, item.type(), item.perms())}, new_record_path);
```
The recursive call treats `new_record_path` (e.g., `dst/link_name.txt`) as a directory
and appends the resolved target's filename, producing `dst/link_name.txt/original.txt`.
This fails because `link_name.txt` is not a directory.

**Correct fix**: When following a symlink to a regular file, directly queue the file copy
with destination = `new_record_path` instead of recursing.

#### 6.6.3 Fast-discovery event detection race (FIXED)

`poll_async_events()` detected `discovery_completed` by tracking a running→stopped
transition via `_had_discovery`. If discovery completed between polls (faster than one
poll cycle), the event was never fired. **Fixed**: track process pointer identity to
detect new completions that were never seen running.

#### 6.6.4 Lua error spin loop (FIXED)

When a Lua test error occurred, `_finished` was set but the FTXUI event loop continued
spinning at 100% CPU. **Fixed**: `tick()` now calls `screen.Exit()` when `finished()`.

#### 6.6.5 `fc.quit()` used `_exit(0)` (FIXED)

`fc.quit()` called `_exit(0)` which skipped all cleanup. **Fixed**: now sets `_finished`
and calls `screen.Exit()` for graceful shutdown.

---

## 7. Comparison with Similar Tools

### 7.1 Midnight Commander (mc)

| Feature                     | mc               | File Commander    |
|-----------------------------|------------------|-------------------|
| Preserve attributes         | ✅ Checkbox      | ❌ Not implemented |
| Preserve timestamps         | ✅ Yes           | ❌ Not implemented |
| Follow symlinks             | ✅ Checkbox      | ✅ Checkbox        |
| Conflict: overwrite         | ✅ Per-file ask  | ✅ Always overwrite |
| Conflict: skip              | ✅ Skip / Skip All | ❌ Not implemented |
| Conflict: overwrite if newer| ✅ Update        | ❌ Not implemented |
| Background operation        | ❌ Blocking      | ✅ Background thread |
| Progress display            | ✅ Bar + ETA     | ✅ Bar + Mbps     |
| Job queue                   | ❌ One at a time | ✅ FIFO queue     |
| Job cancellation            | ✅ Yes           | ❌ Stub only      |
| Error handling              | ✅ Skip/Abort/Retry | ✅ Collect + continue |

### 7.2 Double Commander

| Feature                     | Double Commander | File Commander    |
|-----------------------------|------------------|-------------------|
| Preserve attributes         | ✅ Yes           | ❌ Not implemented |
| Preserve timestamps         | ✅ Yes           | ❌ Not implemented |
| Conflict resolution dialog  | ✅ Ask/Overwrite/Overwrite Older/Skip | ❌ Always overwrite |
| Rename masks                | ✅ Regex rename  | ❌ Not implemented |
| Queue management            | ✅ Parallel + serial | ✅ Serial queue  |
| File masks (filter)         | ✅ Yes           | ❌ Not implemented |
| Background operation        | ✅ Yes           | ✅ Yes            |
| Job cancellation            | ✅ Yes           | ❌ Stub only      |
| Hard link detection         | ✅ Yes           | ❌ Not implemented |
| Sparse file support         | ✅ Yes           | ❌ Not implemented |
| Extended attributes         | ✅ Partial       | ❌ Not implemented |

### 7.3 Summary of Missing Features (Priority Order)

**High priority** (expected by users):

1. **Job cancellation** — critical for large operations
2. **Conflict resolution UI** — Skip / Overwrite / Overwrite-if-newer / Rename
3. **Preserve timestamps** — `last_write_time()` on destination after copy
4. **Preserve permissions** — `permissions()` on destination after copy

**Medium priority** (quality-of-life):

5. **Copy-into-self (subtree) detection** — prevent infinite discovery
6. **Dangling symlink handling** — detect and warn, don't silently create broken symlinks
7. **Relative symlink target rewriting** — adjust relative targets when tree depth changes
8. **Disk space pre-check** — compare total bytes with free space on destination
9. **Destination path editing** — UI element exists but is disabled
10. **Atomic copy** — copy to `.tmp` then rename for crash safety

**Low priority** (advanced):

11. **Hard link detection** — track inodes, copy once + hardlink for duplicates
12. **Extended attributes** — `fgetxattr`/`fsetxattr` on Linux, `copyfile` flags on macOS
13. **Sparse file preservation** — detect holes via `SEEK_HOLE`/`SEEK_DATA`
14. **Ownership preservation** — requires root or CAP_CHOWN
15. **Parallel copy** — multiple worker threads for many small files
16. **Retry on error** — with exponential backoff for transient failures

---

## 8. Async UI Gaps

The goal is for the UI to remain fully responsive during all file operations — no popup
dialogs should block or interrupt the user. This section documents what is missing.

### 8.1 Current Async Architecture

```
┌──────────────┐     ┌──────────────────┐     ┌──────────────────┐
│  UI Thread   │     │  Discovery Thread │     │  Job Worker      │
│  (FTXUI)     │     │  (per dialog)     │     │  (singleton)     │
│              │     │                   │     │                  │
│ ┌──────────┐ │     │ _discover()       │     │ run_copy()       │
│ │ CopyDialog│◀├────│  posts Event::    │     │ run_move()       │
│ │ progress  │ │    │  Custom when done │     │ run_delete()     │
│ └──────────┘ │     └──────────────────┘     │                  │
│              │                               │ posts Event::    │
│ ┌──────────┐ │                               │ Custom via       │
│ │ JobBar   │◀├───────────────────────────────│ updated()        │
│ │ progress │ │                               └──────────────────┘
│ └──────────┘ │
└──────────────┘
```

**What works today**:

- Discovery runs in background — dialog shows progress while scanning
- File I/O runs in background — progress bar shows throughput
- Multiple jobs queue and execute sequentially
- All notifications use `Event::Custom` / `updated()` — no blocking calls
- Lua scripting uses event-driven `tick()` — no periodic polling

### 8.2 What Would Block the UI (Current Gaps)

#### 8.2.1 Conflict Resolution Dialogs

**Problem**: When implementing "Ask per-file" conflict resolution, the naive approach
is to show a dialog from the worker thread and wait for user input. This blocks the
worker thread AND requires the UI thread to show/dismiss the dialog synchronously.

**Solution approach**: The worker thread should:
1. Pause execution and post a conflict event to the UI thread
2. UI thread shows a non-modal conflict resolution widget (inline, not popup)
3. User's choice is communicated back via a condition variable or promise
4. Worker thread resumes with the user's decision

**Alternative**: Pre-scan for conflicts during discovery and present all conflicts
at once before execution starts. This avoids mid-operation interruption but won't catch
conflicts from concurrent filesystem modifications.

#### 8.2.2 Error Dialogs During Operation

**Problem**: Currently errors are silently collected. If we want to offer retry/skip/abort
per-error, the same blocking dialog problem arises.

**Solution approach**: Same as conflicts — pause worker, post event, non-modal inline UI,
resume on user choice. Or: batch errors and show summary at end with option to retry
failed items.

#### 8.2.3 Permission Elevation

**Problem**: Some operations may fail because the current user lacks permission (e.g.,
copying into `/usr/local`). Tools like Nautilus offer "authenticate" to re-run with
elevated privileges.

**Solution approach**: This is out of scope for a terminal application. Errors should
be clearly reported and the user should re-run with appropriate privileges.

#### 8.2.4 Discovery → Execution Transition

**Problem**: Currently the user must click "COPY" after discovery completes. For
automated testing, this requires explicit key presses. For user experience, this is
a deliberate confirmation step.

**Gap for full automation**: No option for "auto-confirm after discovery" which would
make the operation fully fire-and-forget.

### 8.3 Proposed Non-Blocking Conflict Resolution Architecture

```
Worker Thread                    UI Thread
    │                                │
    ├── copy file A                  │
    ├── copy file B                  │
    ├── file C exists at dest!       │
    │                                │
    ├── post ConflictEvent{          │
    │     src, dst, size, time}      │
    ├── wait on _conflict_cv  ──────▶│
    │                                ├── show inline conflict widget
    │                                │   [Overwrite] [Skip] [Overwrite All] [Skip All]
    │                                │
    │   ◀────── user clicks ─────────┤
    ├── _conflict_cv notified        │
    │   with Resolution::Skip        │
    │                                │
    ├── skip file C                  │
    ├── copy file D                  │
    └── done                         │
```

Key properties:
- Worker thread blocks on cv, not on UI — UI remains fully responsive
- "Overwrite All" / "Skip All" sets a sticky policy, no more pauses
- The conflict widget is part of the progress bar area, not a modal popup
- Multiple concurrent operations each get their own conflict state

### 8.4 Missing for Complete Async Operation

| Gap                                  | Impact                              | Effort |
|--------------------------------------|-------------------------------------|--------|
| Job cancellation (real)              | Can't stop large copy               | Low    |
| Non-blocking conflict resolution     | Can't ask user during copy          | Medium |
| Non-blocking error retry             | Can't retry failed items            | Medium |
| Auto-confirm after discovery         | Requires manual COPY click          | Low    |
| Progress ETA calculation             | No estimated time remaining         | Low    |
| Parallel discovery + execution       | Must wait for full discovery first  | High   |
| Streaming discovery → execution      | Could start copying while scanning  | High   |

---

## 9. Test Coverage Plan

The test suite (`test/test_copy.lua`) should cover the following scenarios. Each test
creates an isolated temp directory structure, performs the operation, and verifies results.

### 9.1 Basic Copy Tests

| Test                    | Source structure                          | Verification                          |
|-------------------------|------------------------------------------|---------------------------------------|
| Single file             | `file.txt`                               | Content matches                       |
| Multiple files          | `a.txt`, `b.txt`, `c.txt`               | All present, content matches          |
| Nested directories      | `d1/d2/d3/file.txt`                      | Full tree recreated                   |
| Empty directory         | `empty_dir/`                             | Directory exists in destination       |
| Large file count        | 50+ files in one directory               | All copied, count matches             |
| Deep nesting            | 10+ levels deep                          | Full path preserved                   |

### 9.2 Symlink Tests

| Test                        | Source structure                             | Verification                          |
|-----------------------------|---------------------------------------------|---------------------------------------|
| Absolute symlink            | `link -> /absolute/target`                  | Symlink created, target preserved     |
| Relative symlink (file)     | `link -> ./target.txt`                      | Relative target preserved             |
| Relative symlink (parent)   | `sub/link -> ../target.txt`                 | Relative target preserved             |
| Symlink to directory        | `link -> ./subdir/`                         | Symlink created (not copied as dir)   |
| Chain: A→B→C                | `a->b`, `b->c`, `c` is regular file        | Depends on follow mode                |
| Circular: A→B→A             | `a->b`, `b->a`                              | Error reported, no infinite loop      |
| Self-referencing: A→A       | `a->a`                                      | Error reported                        |
| Dangling symlink            | `link -> /nonexistent`                      | Behavior documented                   |
| Follow mode: symlink→file   | `link -> file.txt` with follow_links=true   | Regular file copied (not symlink)     |
| Follow mode: symlink→dir    | `link -> dir/` with follow_links=true       | Directory contents copied             |

### 9.3 Directory Edge Cases

| Test                          | Source structure                          | Verification                          |
|-------------------------------|------------------------------------------|---------------------------------------|
| Mixed content dir             | Files + dirs + symlinks in one dir       | All types present                     |
| Dir with special chars        | `dir with spaces/`, `dir"quote/`         | Names preserved                       |
| Hidden files                  | `.hidden`, `.hidden_dir/`                | Copied (not filtered)                 |
| Permission-restricted file    | File with 000 permissions                | Error reported or file skipped        |
| Unicode filenames             | `café.txt`, `日本語.txt`                  | Names preserved                       |

### 9.4 Overwrite/Conflict Tests

| Test                          | Setup                                    | Verification                          |
|-------------------------------|------------------------------------------|---------------------------------------|
| Overwrite existing file       | Dest has `file.txt` with different content | Source content wins                  |
| Overwrite with larger file    | Source larger than existing dest          | Full content written                  |
| Overwrite with smaller file   | Source smaller than existing dest         | File truncated to source size         |
| Overwrite existing directory  | Dest has matching dir structure           | Files overwritten, extras remain      |

### 9.5 Copy-to-Self and Overlap Tests

| Test                          | Setup                                    | Verification                          |
|-------------------------------|------------------------------------------|---------------------------------------|
| Copy file to same directory   | Select file, dest = same dir             | Error "Copy to self"                  |
| Copy dir into itself          | Select `/a`, dest = `/a/b`              | Error or cycle detection              |

---

## 10. Implementation Notes for Future Work

### 10.1 Preserve Timestamps

```cpp
// After copy_file():
boost::filesystem::last_write_time(dst_path, boost::filesystem::last_write_time(src_path));
```

### 10.2 Preserve Permissions

```cpp
// After copy_file():
boost::filesystem::permissions(dst_path, source_item.perms());
```

### 10.3 Job Cancellation

Add `std::atomic<bool> _cancelled{false}` to `JobSpec`. Check in the copy loop:

```cpp
for (auto& item : job->_items) {
  if (job->_cancelled) break;
  // ... process item
}
```

### 10.4 Conflict Resolution (Non-Blocking)

```cpp
// In JobSpec:
enum class ConflictPolicy { ASK, OVERWRITE_ALL, SKIP_ALL };
std::atomic<ConflictPolicy> _conflict_policy{ConflictPolicy::OVERWRITE_ALL};

struct PendingConflict {
  DirItem source, destination;
  std::promise<ConflictPolicy> resolution;
};
std::optional<PendingConflict> _pending_conflict;
std::condition_variable        _conflict_cv;
```

### 10.5 Relative Symlink Target Rewriting

When the destination tree has a different depth than the source, relative symlink
targets need adjustment. For example:

```
Source:  /src/sub/link -> ../data/file.txt   (resolves to /src/data/file.txt)
Dest:    /dst/sub/link -> ../data/file.txt   (resolves to /dst/data/file.txt — OK if /dst/data exists)
```

This works if the entire source tree is copied. It breaks if only a subtree is copied,
because the relative target may escape the copied tree. Detection: check if the resolved
target falls within the source tree; if not, convert to absolute or warn.
