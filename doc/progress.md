# Change Description

Summary of staged changes across 8 files (+457 / -145 lines).

---

## Copy Dialog: Background File Discovery

**dialogs.cpp, dialogs.hpp**

- Moved copy file discovery to a background thread via new `CopyDiscoveryProcess` class.
- Discovery runs in a separate thread, so the UI stays responsive during recursive traversal.
- Added `CopyDiscoveryProgress` for progress (dirs, links, errors, current path).
- Introduced `resolve_symlink()` helper for symlink resolution.
- Symlink handling: cyclic detection, `_queue_link` for links, `_queue_error` for failures.
- New discovery methods: `_queue_dir`, `_queue_file`, `_queue_link`, `_queue_error`, `_stat_file`, `_discover`.
- Replaced synchronous file list with `_filelist_wrapper` that shows discovery output.
- Destination path input temporarily disabled (commented out).
- TODOs: refactor discovery state, run `_queue_files` in background, show progress before OK, cancel support.

---

## Command-Line Key Simulation

**main.cpp, file_panel.cpp, file_panel.hpp**

- Added `event_from_string()` to map strings to FTXUI `Event` values.
- Supports arrows, backspace, delete, escape, return, tab, F1–F12, Ctrl+A–Z, Alt+A–Z (e.g. `<-`, `->`, `cA`, `aB`).
- New background thread posts command-line args (index 3+) as keyboard events to the screen once it is active.
- Enables simulating key presses from the command line for automation/testing.

---

## Theme & Config

**theme.hpp**

- Replaced `copy_files_min_y` (fixed 50) with `copyfiles_height_screen_portion` (0.9).
- Copy dialog file list height is now a fraction of screen height.

**.vscode/launch.json**

- Updated launch args for debugging (paths and command-line event simulation).

---

## Spec Documentation

**doc/spec.md**

- Replaced example output with project spec.
- Added History section and rationale for the tool.
- Highlighted command palette, terminal UI, multithreading workflow.
- Documented baseline requirements (copy, move, delete, rename, mkdir, twin panels, columns).
- Added TODO items (platform differences, dir notifications, boost::filesystem limits, GUI limits, spacing).

---

## Code Review Fixes

**dialogs.cpp**

- Fixed `CopyDialog::render()`: use `_discovery_process` for file list, progress (bytes/dirs/files), and filter instead of removed `_files`, `_operation_state`, `_bytes_total`.
- Fixed `CopyDialog::OnShow()`: removed `_virtual_dir` reference, added early exit when no selection, call `_start_new_discovery()` to start discovery.
- Fixed `CopyDiscoveryProcess` constructor: copy `b_follow_links` and `b_preserve_relative_links` from parent.
- Fixed `CopyDiscoveryProcess::_queue_link`: replaced undefined `q` with `_dir->items.emplace_back()`.

**file_io_jobs.cpp**

- Fixed `ProgressInfo::update()`: corrected Mbps sign – use `(new_size - current_size)` and `(ts - last_ts)`.
- Fixed `ProgressMonitor` run loop: iterator-based erase to avoid invalidation when removing stopped jobs.
- Fixed `move_id_by`: added mutex lock when accessing `_errors.size()`.

**main.cpp**

- Fixed `job_type_to_string`: added `default` case to handle all enum values.

**commander.cpp**

- Fixed `Dir::_sort`: comparator return type changed from `int` to `bool`.
