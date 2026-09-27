# Systematic code review — 2026-09-27

Reviewed commit: `72034c9d095ec242f6adf647bd076874af015402`.

The review found **37 actionable issues: 11 P1, 24 P2, and 2 P3**. The most urgent are three independently reproduced data-loss paths: deleting a directory symlink deletes its target's contents; cancellation cleanup can delete an untouched destination; and failed archive creation removes the previous archive. Copy confirmation can also use a destination different from the one displayed to the user.

The review above describes the original revision. Implementation is now tracked under each finding: the planned solution is recorded before code changes, then the applied solution, validation, and any deviations are recorded in that finding’s fix commit. Historical source line references refer to the reviewed revision.

## Scope and method

I read the project Markdown starting with `ftxui_notes.md`, then `spec.md`, and used the remaining documents to build a mechanism checklist. I traced each mechanism through its UI entry point, state/data ownership, worker or external-tool implementation, error handling, and available tests. Current code takes precedence when an older plan describes functionality as unfinished.

All 13 existing project Markdown files were read, including the ignored build-setup document:

| Document | Use in this review |
| --- | --- |
| [ftxui_notes.md](ftxui_notes.md) | Component ownership, event routing, focus, rendering, DBMenu and thread rules |
| [spec.md](spec.md) | Mechanisms, behavior, responsiveness goals and proposed features |
| [file_operations.md](file_operations.md) | Discovery, copy/move/delete, progress, conflict and cancellation behavior |
| [completed_jobs.md](completed_jobs.md) | Job lifecycle, ownership, history and intended pause/resume design |
| [testing_framework.md](testing_framework.md) | Lua scheduler, events, waits, assertions and integration tests |
| [fresh_editor_integration_plan.md](fresh_editor_integration_plan.md) | Editor session lifecycle and terminal handoff |
| [fresh_cli_contract.md](fresh_cli_contract.md) | External editor command and binary-resolution contract |
| [static_build_plan.md](static_build_plan.md) | Native/cross builds and distribution contents |
| [build_test_setup.md](build_test_setup.md) | Local dependencies and test/build commands |
| [progress.md](progress.md) | Implementation status claims |
| [../boost/changes.md](../boost/changes.md) | Local filesystem changes |
| [../boost/integrating_boost_filesystem.md](../boost/integrating_boost_filesystem.md) | Dependency integration and modified copy implementation |
| [../boost/filesystem/README.md](../boost/filesystem/README.md) | Vendored library context |

The Markdown inventory excludes generated dependency/build trees and the pre-existing untracked `old_fc`. Code coverage includes the active application translation units and their headers, the local Boost copy extension and relevant copy internals, Lua framework/tests, CMake/toolchain/package files, and the inactive `playground.cpp` experiment. This is not a full audit of unmodified upstream Boost, LuaJIT, Fresh, 7zr, or FTXUI.

Validation used the existing macOS arm64 Debug build and local sibling dependencies. `cmake --build build -j10` succeeded. Linux branches and cross compilation were reviewed statically; they were not executed. No sanitizer build, real cross-device move, or real interactive Fresh session was run.

**Evidence labels:** **Reproduced** means a disposable filesystem fixture, a component-level probe linked to the application's built objects, or a PTY test demonstrated the behavior. **Static** means the source establishes the faulty path but it was not reproduced under a sanitizer or end-to-end runtime. Severity reflects impact, not whether a test happened to trigger it: P1 is urgent data integrity, memory safety, or serious lifecycle failure; P2 is a functional/reliability defect; P3 is a limited-impact implementation defect.

## P1 findings

### R01 — Recursive delete follows directory symlinks outside the selection

**Reproduced.** Sources: [commander.cpp:126](../commander.cpp#L126), [file_io_jobs.cpp:383](../file_io_jobs.cpp#L383), [file_io_jobs.cpp:429](../file_io_jobs.cpp#L429).

`DirItem` classifies entries using `status()`, which follows symlinks. Delete discovery recurses on `directory_file` without checking `symlink_ref()`. Selecting `src/link -> outside` therefore queues `src/link/valuable.txt` and removes the actual file in `outside`, before unlinking `src/link`.

The disposable probe selected only the symlink; `outside/valuable.txt` disappeared. A symlink encountered inside an ordinary selected directory has the same problem, and directory-link cycles have no traversal guard.

**Fix direction:** classify deletion targets with `symlink_status()`/`lstat`; remove a link itself and never recurse through it. **Regression:** delete a selected link and a tree containing external/cyclic directory links; all external targets must survive.

**Implementation status:** Applied.

**Planned solution:** classify deletion targets with `symlink_status()`/`lstat`; remove a link itself and never recurse through it.

**Applied solution:** Delete discovery now checks symlink_status at traversal time and only descends into actual directories. Added the fc_review_tests target and an isolated external-link/cycle regression.

**Plan deviations:** None. Link classification is localized to delete; the listing semantics are addressed separately in R15.

**Validation:** Native application and regression target built; fc_review_tests R01 passed for a selected directory link and nested external/cyclic links.

### R02 — Cancellation cleanup can remove a destination that this copy never touched

**Reproduced.** Source: [boost/filesystem/src/operations.cpp:3478](../boost/filesystem/src/operations.cpp#L3478), called by [file_io_jobs.cpp:629](../file_io_jobs.cpp#L629).

The extended `copy_file()` wrapper treats any failure as cancellation if the flag is set, then unconditionally calls `remove(to)`. It does not know whether this invocation created or opened the destination. A missing source and an already-existing destination, with cancellation requested, returns `ENOENT` and deletes that existing destination. In the application, cancellation can arrive after the pre-copy check but before an unrelated failure returns.

**Fix direction:** track ownership of an actual partial output, preferably copy to a unique temporary sibling and atomically commit it. Cancellation must preserve the old destination. **Regression:** cancellation combined with missing source, permission failure, destination conflict, and self-copy must not unlink an untouched file.

**Implementation status:** Applied.

**Planned solution:** track ownership of an actual partial output, preferably copy to a unique temporary sibling and atomically commit it. Cancellation must preserve the old destination.

**Applied solution:** Cancellable POSIX copies write into an exclusively owned temporary sibling directory, clean up only that directory, and commit by atomic rename (replace) or hard-link creation (no replace). Self-copy is rejected before writing. Progress is reported through an atomic byte counter so the UI need not observe the destination while it is staged.

**Plan deviations:** Used a private sibling directory rather than a bare temporary file to establish cleanup ownership. Atomic replacement replaces the destination entry instead of mutating an existing inode; this intentionally preserves other hard links and symlink targets. The unextended Boost overload and Windows fallback retain their existing behavior.

**Validation:** Native build and fc_review_tests R02 passed: missing source, self-copy and in-flight cancellation preserve KEEP; success replaces contents; no staging files remain. git diff --check passed.

### R03 — Archive creation deletes the previous archive before success is possible

**Reproduced.** Source: [archive.cpp:282](../archive.cpp#L282), particularly lines 296–299; dispatch: [dialogs.cpp:855](../dialogs.cpp#L855).

`create_archive()` removes the existing output before running 7zr. Missing tools, failed input reads, invalid arguments, or compression errors consequently destroy the previous archive. Setting the archive tool to `/usr/bin/false` reproduced this with a disposable existing `.7z` file. Selecting the output archive itself as input also exposes the source to this unlink. Copy's selected conflict mode is not passed into the archive job, so choosing Skip does not protect an existing archive.

**Fix direction:** validate inputs and conflict policy, create a temporary archive, and replace the destination only after successful creation. **Regression:** failed creation and Skip must preserve the original byte-for-byte; reject output/source identity.

**Implementation status:** Applied.

**Planned solution:** validate inputs and conflict policy, create a temporary archive, and replace the destination only after successful creation.

**Applied solution:** Archive creation validates inputs, rejects output within a selected input, writes to an owned sibling staging directory, and commits only after successful output validation. The copy conflict mode reaches the archive worker; Skip uses a no-replace commit.

**Plan deviations:** Existing archives in Update mode are explicitly rejected with guidance to choose Replace or Skip; archive freshness cannot safely be inferred from one directory timestamp. Temporary output is cleaned on every failure.

**Validation:** Native build, fc_review_tests R03, and git diff --check passed. Failed tool, Skip, self-input, unsupported Update and staging cleanup were checked against an unchanged OLD archive.

### R04 — Copy confirmation can ignore the edited destination

**Reproduced.** Sources: [dialogs.cpp:775](../dialogs.cpp#L775), [dialogs.cpp:851](../dialogs.cpp#L851).

Destination edits trigger discovery only on the input's Enter callback. Pressing the COPY button or F5 reads the new text to decide whether this is archive creation, but ordinary copy moves the existing discovery vector, whose destinations still point at the old directory. The probe completed discovery for `dst`, changed the input to `dst2`, and confirmed: the file appeared in `dst`, not `dst2`. Replace mode can overwrite files in a location the user no longer sees as the target.

**Fix direction:** bind each discovery result to its exact source/options/destination revision and validate that revision on confirmation; rebuild when it differs. **Regression:** edit the target and confirm via both mouse/button and F5 without pressing Enter in the input.

**Implementation status:** Applied.

**Planned solution:** bind each discovery result to its exact source/options/destination revision and validate that revision on confirmation; rebuild when it differs.

**Applied solution:** Confirmation compares the destination and link options with the discovery snapshot. A changed target restarts discovery and defers the pending confirmation until its completion event, then queues the updated plan. Cancel clears the deferred confirmation.

**Plan deviations:** The updated discovery is automatically confirmed after completion, avoiding an extra confirmation click; the dialog shows Preparing copy while it waits.

**Validation:** Native build and fc_review_tests R04 passed for both F5 and the COPY button: the old target retained KEEP and each edited destination received NEW.

### R05 — Copy discovery exposes a mutating vector and moves it before stopping its writer

**Static.** Sources: [dialogs.cpp:872](../dialogs.cpp#L872), [dialogs.cpp:927](../dialogs.cpp#L927), [dialogs.cpp:950](../dialogs.cpp#L950), [dialogs.cpp:988](../dialogs.cpp#L988), [dialogs.hpp:178](../dialogs.hpp#L178).

The discovery thread appends to `_dir->items` under its mutex, while the UI's DBMenu callbacks read/render/filter that vector without the same mutex. Confirmation moves the vector into a job before destroying/joining the producer. Confirming during discovery can therefore race vector reallocation/move, lose undiscovered entries, or crash. `_running` is also a plain `bool` shared across threads; joining afterward does not make the preceding accesses safe.

**Fix direction:** publish immutable UI snapshots or transfer batches to the UI thread, use a synchronized lifecycle flag, and take a complete frozen job plan only after discovery has finished. **Regression:** repeatedly render, filter, cancel and confirm during a deliberately slowed large discovery under ThreadSanitizer.

**Implementation status:** Applied.

**Planned solution:** publish immutable UI snapshots or transfer batches to the UI thread, use a synchronized lifecycle flag, and take a complete frozen job plan only after discovery has finished.

**Applied solution:** Discovery owns a mutex-protected plan vector and a copied CommandArgs snapshot; only the UI thread appends published batches to its preview Dir. The running flag is atomic. Confirmation waits for completion, joins the producer, then transfers the finished plan. Preview components are detached before discovery storage is destroyed.

**Plan deviations:** Used incremental UI-owned preview batches instead of copying the entire vector every frame. Confirmation remains pending until the complete plan is ready.

**Validation:** Native build and R05 passed while rendering a 600-file discovery and immediately confirming; all 600 files arrived. R04 was rerun and passed. ThreadSanitizer has not yet been run.

### R06 — Partial batch rename leaves input controls bound to invalid row objects

**Static, with component-level symptom reproduced.** Source: [dialogs.cpp:652](../dialogs.cpp#L652), especially input bindings at 659–662 and row erasure at 685.

Each Input stores pointers into a `std::vector<Row>`. If a higher-index rename fails and a lower-index rename succeeds, erasing the successful row moves the failed row and destroys its old object, while the surviving Input retains the old string/cursor pointers. Subsequent rendering or editing accesses an object whose lifetime ended. The probe used `a.txt -> a2.txt` and `b.txt -> missing/b.txt`; editing the surviving control did not update the surviving row's text. No sanitizer-backed crash claim is made.

**Fix direction:** give rows stable storage or rebuild/rebind all surviving controls after erasure. **Regression:** mixed successes/failures followed by typing, cursor movement, and retry, with AddressSanitizer enabled.

**Implementation status:** Applied.

**Planned solution:** give rows stable storage or rebuild/rebind all surviving controls after erasure.

**Applied solution:** Rename rows now have stable individually owned storage. Erasing successful entries only moves owning pointers, so failed rows retain their string and cursor addresses for rendering, editing and retry.

**Plan deviations:** Chose stable row ownership rather than rebuilding every surviving input.

**Validation:** Native build and R06 passed: one rename failed, a lower row succeeded, the surviving Input accepted text into its live row, and retry renamed the remaining file. Sanitizer validation is still pending.

### R07 — Immediate macOS watcher destruction races startup and crashes

**Reproduced.** Source: [file_change_funnel.cpp:72](../file_change_funnel.cpp#L72) and [file_change_funnel.cpp:100](../file_change_funnel.cpp#L100).

The constructor launches a thread that initializes `_runloop_ref`, schedules `_stream`, and starts the loop. Destruction can meanwhile stop/release that stream and call run-loop functions with `_runloop_ref` still null. The mutex in `stop()` does not synchronize with the startup thread. A disposable loop creating and immediately resetting a watcher terminated with `SIGSEGV` (return code `-11`). Rapid navigation and shutdown can exercise this lifecycle.

**Fix direction:** establish startup readiness and perform stream start/stop/release on a coordinated owner thread. **Regression:** repeated immediate create/destroy, rapid tab navigation, and exit during watcher startup.

**Implementation status:** Applied.

**Planned solution:** establish startup readiness and perform stream start/stop/release on a coordinated owner thread.

**Applied solution:** macOS watchers synchronously create/start the FSEvent stream on a dedicated serial dispatch queue. Destruction stops and invalidates delivery, drains queued callbacks, then releases the stream and queue.

**Plan deviations:** Replaced the deprecated run-loop worker entirely with the supported dispatch-queue API instead of adding a startup handshake to it. This removes the null-run-loop and released-stream startup races.

**Validation:** Native build and R07 passed 100 immediate watcher create/destroy cycles. The previous teardown crash did not recur; deprecated run-loop warnings are gone.

### R08 — Panel teardown destroys callback state before stopping its watcher

**Static.** Source: [app.hpp:286](../app.hpp#L286), callback at [app.hpp:548](../app.hpp#L548).

`pending_changes` is declared after `update_funnel`; implicit reverse member destruction destroys the queue before destroying/joining the watcher. A still-running watcher callback captures `this` and pushes into that destroyed queue. Posted UI closures also capture the raw panel pointer without an invalidation token. R07 is a separate watcher-internal startup race; this failure concerns the owner's lifetime even after successful watcher startup.

**Fix direction:** explicitly stop and join the watcher while all callback state is alive, then invalidate/drain posted work before destroying the panel. **Regression:** close the application while a directory is generating events; verify callback and queued-task lifetimes under a sanitizer.

**Implementation status:** Applied.

**Planned solution:** explicitly stop and join the watcher while all callback state is alive, then invalidate/drain posted work before destroying the panel.

**Applied solution:** Panel destruction invalidates a shared callback lifetime token, stops/drains the watcher while the queue and panel state still exist, then closes the queue. Posted UI closures check the token before accessing the panel.

**Plan deviations:** Queued closures are invalidated rather than forcibly removed from the shared screen queue; this avoids disturbing work owned by other components.

**Validation:** Native build and R08 passed: a real watcher queued a UI callback, the panel was destroyed, and executing all retained callbacks afterward was harmless.

### R09 — Job list/details read live job storage without synchronization

**Static.** Sources: [dialogs.cpp:1849](../dialogs.cpp#L1849), [dialogs.cpp:1893](../dialogs.cpp#L1893), [dialogs.cpp:1931](../dialogs.cpp#L1931); writes: [file_io_jobs.cpp:218](../file_io_jobs.cpp#L218), [file_io_jobs.cpp:430](../file_io_jobs.cpp#L430).

The job UI includes the active job and reads its counters, `_items`, and `_errors` directly. Delete workers append items and error paths append errors, allowing vector reallocation while a row renderer holds a reference. These are C++ data races, not just potentially stale progress. Lifecycle timestamps also have unsynchronized readers/writers (`is_stopped()` uses ordinary doubles).

**Fix direction:** expose a consistent job snapshot under the job mutex; keep references into mutable vectors out of render callbacks. Synchronize lifecycle publication as well. **Regression:** inspect and scroll active delete/error-heavy jobs while workers mutate them, under ThreadSanitizer.

**Implementation status:** Applied.

**Planned solution:** expose a consistent job snapshot under the job mutex; keep references into mutable vectors out of render callbacks. Synchronize lifecycle publication as well.

**Applied solution:** JobSpec publishes immutable JobSnapshot objects under its mutex. Job history/detail rendering refreshes these snapshots per frame rather than reading live vectors. Start/final timestamp writes share the mutex, stopped state has acquire/release publication, Lua completion polling reads snapshots, and progress-monitor stop uses a synchronized predicate.

**Plan deviations:** Snapshots include complete item/error vectors for consistency; optimizing large-history snapshot cost is deferred. Progress rendering already held the job lock and retains that approach.

**Validation:** Native build and R09 passed while deleting 1,000 files and repeatedly rendering job details; a retained snapshot remained unchanged. git diff --check passed. ThreadSanitizer remains to be run.

### R10 — Exiting with a paused job hangs forever

**Reproduced.** Sources: [file_io_jobs.cpp:234](../file_io_jobs.cpp#L234), [file_io_jobs.cpp:681](../file_io_jobs.cpp#L681).

`ThreadedFileJobs` destruction only closes the queue and joins the worker. A paused worker is waiting on the job's condition variable, whose predicate requires resume or cancellation. Queue closure neither changes that predicate nor wakes this condition variable. A probe returned from `main()` with a paused worker and remained hung beyond an external three-second deadline.

**Fix direction:** define an explicit shutdown policy, signal active/queued jobs, wake pause waiters, and only then join. **Regression:** exit with paused copy/delete/move jobs and queued work; the process must terminate within a bounded interval.

**Implementation status:** Applied.

**Planned solution:** define an explicit shutdown policy, signal active/queued jobs, wake pause waiters, and only then join.

**Applied solution:** FileJobs now has idempotent explicit shutdown: close the queue, cancel/wake the active job, finalize queued jobs as cancelled without executing them, join the worker, and stop progress monitoring. main calls shutdown while terminal/UI state is still alive; destruction uses the same path.

**Plan deviations:** Added a factory for independent job managers so lifecycle regression tests can exercise shutdown without killing the test process.

**Validation:** Native build, R10 and git diff --check passed. Paused copy/move/delete plus queued work each terminated within two seconds, with all jobs cancelled and original data untouched.

### R11 — Incomplete discovery can be reported as a clean completed copy

**Reproduced.** Sources: [dialogs.cpp:996](../dialogs.cpp#L996), [dialogs.cpp:1082](../dialogs.cpp#L1082), [dialogs.cpp:1124](../dialogs.cpp#L1124), [file_io_jobs.cpp:550](../file_io_jobs.cpp#L550), [file_io_jobs.cpp:367](../file_io_jobs.cpp#L367).

There are two omissions in the discovery-to-result contract. Directory enumeration errors are not checked after constructing/iterating the directory iterator, so an unreadable directory looks empty. Separately, discovery warnings become `status_error` items that the copy worker silently skips without recording a job error. Final state is then chosen from an empty `_errors` vector.

A mode-000 directory containing a file produced `file_count=0, error_count=0`. A job containing an explicit discovery-error item finished `COMPLETED` with zero errors.

**Fix direction:** preserve discovery failures as first-class job errors and handle iterator construction and increment failures. **Regression:** unreadable subdirectories, disappearing entries, cyclic links and copy-to-self must yield explicit incomplete/error results, never clean success.

**Implementation status:** Applied.

**Planned solution:** preserve discovery failures as first-class job errors and handle iterator construction and increment failures.

**Applied solution:** Copy discovery now checks iterator construction and increment errors through one read_children helper and stores enumeration failures in the plan. The copy worker promotes every discovery-error item into job/global errors, so final state becomes completed_with_errors.

**Plan deviations:** Used explicit error-code iteration rather than relying on throwing range iteration. Both ordinary and followed-directory traversal share the same error path.

**Validation:** Native build and R11 passed: a mode-000 directory produces a discovery error, and both its submitted plan and an explicit missing-source error finish completed_with_errors.

## P2 findings

### R12 — Pausing during the final file leaves a finished job permanently marked PAUSED

**Reproduced.** Source: [file_io_jobs.cpp:251](../file_io_jobs.cpp#L251), finalization at [file_io_jobs.cpp:367](../file_io_jobs.cpp#L367).

`pause_job()` immediately changes the state to PAUSED even though the current file is still copying. If it is the last item, the worker finishes without another pause checkpoint. Finalization sets `_finished_time` but only assigns a terminal state when the previous state is RUNNING. A throttled 2 MiB copy ended with `state=PAUSED`, `is_stopped=true`, and the entire 2 MiB destination present. The running-job controls disappear despite the paused state.

**Fix direction:** distinguish pause requested from pause acknowledged, and finalize every finished job to a terminal state. **Regression:** pause at several offsets in a one-file copy, including just before completion.

**Implementation status:** Applied.

**Planned solution:** distinguish pause requested from pause acknowledged, and finalize every finished job to a terminal state.

**Applied solution:** Pause now changes only the request flag; workers acknowledge PAUSED/RUNNING at synchronized checkpoints. Cancellable copies invoke checkpoints between chunks and during bounded throttle sleeps, allowing the final file to pause without being falsely marked stopped. Finalization always chooses a terminal result and clears pending pause; stopped jobs reject pause.

**Plan deviations:** Added intra-file pause checkpoints rather than retaining only per-file pause granularity. Linux accelerated copy paths fall back to the checkpoint-aware buffered path when extended controls are active.

**Validation:** Native build and R12 passed: a one-file transfer paused with stable byte count, resumed with matching contents, completed terminally, and rejected a later pause. Linux fallback changes were reviewed statically.

### R13 — Cancellation does not reach several long-running operations

**Static.** Sources: delete discovery [file_io_jobs.cpp:383](../file_io_jobs.cpp#L383), cross-device move [file_io_jobs.cpp:453](../file_io_jobs.cpp#L453), archive creation [file_io_jobs.cpp:525](../file_io_jobs.cpp#L525).

Delete cancellation closes the traversal queue, but discovery never checks cancellation or the result of `push()` and is still joined afterward. A large traversal therefore continues after cancellation. Cross-device move uses the ordinary recursive Boost copy without the job cancellation token, then removes the source without a cancellation checkpoint. Archive creation blocks in `system()` with no process-control handle or post-call cancellation handling. Cancellation can be ineffective throughout these long operations and the job can still finish as COMPLETED.

**Fix direction:** propagate cancellation through traversal and transfer stages, define safe commit boundaries for moves, and manage archive subprocesses explicitly. **Regression:** cancel each operation while it is inside its long-running phase, not only between items.

**Implementation status:** Applied.

**Planned solution:** propagate cancellation through traversal and transfer stages, define safe commit boundaries for moves, and manage archive subprocesses explicitly.

**Applied solution:** Delete discovery now checks cancellation/queue closure during enumeration and stops when publication fails. Cross-device moves use a cancellable recursive copy into private staging, commit the complete entry, then clean the source. Archive commands run as owned process groups with cancellation, bounded TERM-to-KILL escalation, helper cleanup and leader reaping; cancelled archives never commit.

**Plan deviations:** Moves now use an entry-level atomic commit instead of merging into an existing nonempty destination directory. Source cleanup is intentionally non-cancellable after commit to avoid a partially removed source. The cross-device transfer helper is exposed for direct regression testing without requiring another mounted device.

**Validation:** Native build and R13 passed for cancelled file-move staging, successful recursive move with a preserved symlink, and a cancelled 20-second fake archive tool returning within two seconds while preserving OLD. Delete pause/cancel lifecycle is covered by R10; actual EXDEV routing was not executed on this single-volume host.

### R14 — Completed-item accounting is inconsistent across operations

**Reproduced for move/delete; static for archive.** Sources: [file_io_jobs.cpp:222](../file_io_jobs.cpp#L222), [file_io_jobs.cpp:480](../file_io_jobs.cpp#L480), [file_io_jobs.cpp:520](../file_io_jobs.cpp#L520).

Copy treats `_current_item_index` as a completed count, but delete assigns `size - 1`, move periodically assigns the zero-based loop index and never flushes a final count, and archive assigns `sources.size() - 1` during input collection. A successful one-file move reported `0/1`; a completed two-entry delete reported `1/2`. Detail-row dimming and Lua state use the same value, so the inconsistency affects more than presentation.

**Fix direction:** separate current-item index from completed/failed/skipped counts and publish final values for every operation. **Regression:** one-item and multi-item success/failure/cancel cases for all job types.

**Implementation status:** Applied.

**Planned solution:** separate current-item index from completed/failed/skipped counts and publish final values for every operation.

**Applied solution:** Added separate finalized-attempt, failed and skipped counters while retaining the current-item index for transfer tracking. Move/delete counters now flush every completed attempt, archive counts describe the completed operation rather than input collection, and copy cancellation does not count an unfinished file. UI and Lua done values use the new count; snapshots preserve it.

**Plan deviations:** items_done counts all finalized outcomes (success, failure or skip), with failed/skipped exposed separately in the C++ model; successful count is their difference. This preserves useful done/total progress even when some items fail.

**Validation:** Native build and accumulated R01–R14 regressions passed. R14 checks one-file move, two-entry delete, failed/skipped copy and skipped archive counts. git diff --check passed.

### R15 — Dangling and cyclic symlinks disappear from directory listings

**Reproduced for dangling links.** Source: [commander.cpp:157](../commander.cpp#L157), with the same classification issue at [commander.cpp:126](../commander.cpp#L126).

Listing follows each link using `directory_entry::status()`, then skips the entry when its target cannot be statted. A link is a valid directory entry even when its target is missing or cyclic. The probe created a dangling link and confirmed it was absent from `Dir::items`; users cannot select, rename, delete, or preserve it through normal panel operations.

**Fix direction:** obtain link identity with `symlink_status()` and treat target status as separate optional metadata. **Regression:** visible, selectable dangling absolute/relative links and link cycles; preserve-mode copy must retain the link text.

**Implementation status:** Applied.

**Planned solution:** obtain link identity with `symlink_status()` and treat target status as separate optional metadata.

**Applied solution:** Directory listing, direct DirItem construction and partial refresh classify entries with symlink_status. Link text is retained when target stat fails, while valid directory links still expose directory navigation. Refresh clears obsolete link metadata when an entry becomes a regular file.

**Plan deviations:** Preserved the existing followed-target display type for valid links; link identity remains in symlink_ref and deletion independently uses lstat classification from R01. The initial regression exposed that directory_entry::symlink_status refreshes followed metadata too, so listing uses the standalone path-based symlink_status call.

**Validation:** Native build and R15 passed: dangling and cyclic links remain listed after partial refresh, valid directory links remain navigable, and preserve-mode copy retains a dangling relative target verbatim.

### R16 — Valid symlink chains are falsely detected as cycles

**Reproduced.** Source: [dialogs.cpp:729](../dialogs.cpp#L729), used at [dialogs.cpp:1065](../dialogs.cpp#L1065).

`resolve_symlink()` checks visited paths using `equivalent()`. That function follows links, so in a valid chain `A -> B -> file`, an earlier link and the final file compare equivalent. Follow-links discovery then returns a “Cyclic symlink” warning for a valid chain. The probe created exactly this chain and observed one discovery error. Existing chain tests mainly exercise preservation, which bypasses this path for relative links.

**Fix direction:** detect repeated link objects/paths without dereferencing their final targets. **Regression:** follow chains of two and three links, alongside real self/cyclic links and links through directory aliases.

**Implementation status:** Applied.

**Planned solution:** detect repeated link objects/paths without dereferencing their final targets.

**Applied solution:** Symlink traversal records normalized link paths with canonical parent directories, then reads each link target. Cycle checks never dereference the final link target for identity, so valid chains remain distinct while directory aliases normalize consistently.

**Plan deviations:** Used normalized link paths with canonical parents rather than platform-specific inode identities, retaining portability across supported filesystem APIs.

**Validation:** Native build and R16 passed: a three-link chain materializes the final file and a self-cycle yields a discovery error. R15 passed again after the path-based metadata correction.

### R17 — Symlink copies bypass Replace/Update/Skip conflict handling

**Static.** Source: [file_io_jobs.cpp:569](../file_io_jobs.cpp#L569), compared with conflict handling beginning at [file_io_jobs.cpp:598](../file_io_jobs.cpp#L598).

The symlink branch unconditionally calls `create_symlink()` and returns before evaluating the conflict policy. An existing destination link makes Replace fail instead of replacing it and makes Skip report an error instead of skipping it. This is particularly visible when copying the same symlink-containing directory a second time.

**Fix direction:** define destination-type-aware conflict behavior before dispatching to regular-file/link/directory implementations. **Regression:** each policy with source links and existing regular files, valid links, and dangling links.

**Implementation status:** Applied.

**Planned solution:** define destination-type-aware conflict behavior before dispatching to regular-file/link/directory implementations.

**Applied solution:** Symlink copy evaluates Replace/Update/Skip against destination entry metadata before creation. New links are staged and atomically renamed (replace/update) or linked without replacement (skip), preserving existing targets on errors. Discovery carries the source link timestamp and skipped links update job counters.

**Plan deviations:** Update compares the link entry timestamp from lstat, not the target timestamp. Existing directories are preserved when atomic replacement is invalid rather than recursively removed.

**Validation:** Native build and R17 passed: replacing an existing link preserved its target, Skip retained a dangling link, Update retained a newer file and replaced an older file with the requested link.

### R18 — Copy-dialog shortcuts consume digits typed into inputs

**Reproduced.** Source: [dialogs.cpp:817](../dialogs.cpp#L817).

The outer CatchEvent unconditionally consumes characters `1`, `2`, and `3` to select a conflict mode before the destination/filter input receives them. The probe focused the destination input and typed `1`; the string stayed empty. Normal paths containing these digits cannot be typed correctly, and typing can unexpectedly change conflict policy.

**Fix direction:** scope these shortcuts to the options/list context or require a modifier. **Regression:** type a destination and filter containing all three digits while checking that the conflict mode stays unchanged.

**Implementation status:** Applied.

**Planned solution:** scope these shortcuts to the options/list context or require a modifier.

**Applied solution:** Conflict-mode digit shortcuts are handled only when the conflict control has focus, allowing destination and file-filter inputs to receive ordinary 1/2/3 characters.

**Plan deviations:** Used focus scoping rather than introducing new modifier bindings.

**Validation:** Native build and R18 passed: typing 123 populated the destination without changing policy, and the focused conflict control still accepted its digit shortcut.

### R19 — Full directory refresh loses an active filter

**Reproduced.** Sources: [commander.cpp:152](../commander.cpp#L152), [commander.cpp:294](../commander.cpp#L294).

`move_to()` reconstructs entries with default visibility while retaining `filter.phrase`. `apply_filter()` then returns early for that same phrase, leaving all entries visible. Filtering two files to one, refreshing, and applying the unchanged filter produced two visible files. The displayed filter no longer describes the list being operated on.

**Fix direction:** recompute visibility whenever directory contents are replaced, independently of whether the phrase changed. **Regression:** refresh under an active filter after create/delete/rename, preserving the correct focused visible item.

**Implementation status:** Applied.

**Planned solution:** recompute visibility whenever directory contents are replaced, independently of whether the phrase changed.

**Applied solution:** Dir::move_to forces filter recomputation after replacing and sorting entries. apply_filter has an explicit force option, also used when discovery publishes new preview entries.

**Plan deviations:** Kept the unchanged-phrase fast path for ordinary input events; content replacement explicitly invalidates that cached result.

**Validation:** Native build and R19 passed: adding matching and excluded files then refreshing kept exactly the two matching entries visible with the unchanged phrase.

### R20 — Reactivating an inactive tab restores a stale snapshot

**Reproduced.** Source: [app.hpp:572](../app.hpp#L572).

Only the active tab has a watcher. Switching back copies the saved `Dir` and starts a new watcher without rescanning. Changes that occurred while inactive are absent, and a new watcher does not replay them. A probe created a file in tab A while tab B was active; returning to A did not list it.

**Fix direction:** refresh an inactive tab on activation, preserving filter/selection/focus where possible, or maintain an explicit dirty state backed by continuous observation. **Regression:** create, remove, and rename entries while their tab is inactive, then switch back.

**Implementation status:** Applied.

**Planned solution:** refresh an inactive tab on activation, preserving filter/selection/focus where possible, or maintain an explicit dirty state backed by continuous observation.

**Applied solution:** Activating a saved tab now reconciles its directory from disk before installing a new watcher. Same-directory refresh restores selections by path and reuses focused-path restoration, while the stored filter and column choices remain active.

**Plan deviations:** Refresh happens on activation instead of retaining background watchers for every tab. Moving this enumeration off the UI thread is handled separately by R25.

**Validation:** Native build and R20 passed: an inactive tab observed created/deleted files after activation, retained its filter, and preserved a surviving selection and focused path.

### R21 — Events from the old directory can be applied to the new directory

**Static.** Sources: [app.hpp:547](../app.hpp#L547), [commander.cpp:180](../commander.cpp#L180).

Watcher replacement clears pending events before the old watcher has been stopped. The old watcher can enqueue another batch during replacement, and batches carry no directory generation. `partial_refresh()` finds existing items by basename before validating the parent directory; that validation only runs for insertions. A delayed removal of `old/a.txt` can consequently remove `new/a.txt` from the visible model after navigation.

**Fix direction:** stop the producer before draining it, tag updates with the watched directory/generation, and reject every mismatched update before basename lookup. **Regression:** rapidly navigate between directories sharing filenames while deleting/renaming entries in the old directory.

**Implementation status:** Applied.

**Planned solution:** stop the producer before draining it, tag updates with the watched directory/generation, and reject every mismatched update before basename lookup.

**Applied solution:** Watcher replacement now advances a generation, stops the old producer, then drains its queue. Posted callbacks reject obsolete generations before reading panel state. Dir::partial_refresh validates every event parent before basename lookup, using nonthrowing comparison.

**Plan deviations:** Generation is attached to the callback owning each drained batch rather than adding metadata to every individual filesystem event.

**Validation:** Native build and R21 passed: delayed removal and metadata events from another directory with the same filename left the current model and size unchanged.

### R22 — Watchers discard events that require a full rescan or watch recovery

**Static; Linux was not executed.** Sources: macOS [file_change_funnel.cpp:85](../file_change_funnel.cpp#L85), Linux [file_change_funnel.cpp:213](../file_change_funnel.cpp#L213).

The macOS callback filters by a changed path's parent and does not interpret dropped-event/recursive-rescan flags; events concerning the watched root itself are filtered out. The Linux loop skips all zero-name events before inspecting their masks, including overflow and watched-directory lifecycle events. A lost-event batch or moved/deleted watched root therefore has no rescan/rearm path, leaving the model stale.

**Fix direction:** represent “rescan required” and “watch invalidated” explicitly and recover the panel/watch as appropriate. **Regression:** inject overflow/root-change signals and verify a full reconciliation instead of relying only on ordinary named-file events.

**Implementation status:** Applied.

**Planned solution:** represent “rescan required” and “watch invalidated” explicitly and recover the panel/watch as appropriate.

**Applied solution:** Watcher backends now emit explicit rescan and invalidation events. The panel reconciles the directory, rearms observation, and moves to the nearest existing ancestor when its root disappears. Linux processes zero-name lifecycle and overflow events before ordinary entries; macOS interprets root and dropped-event flags.

**Plan deviations:** Root recovery uses the nearest existing ancestor and reports the change. Linux descriptor teardown was also ordered after worker exit to avoid reuse races; Linux behavior was reviewed but not executed on this macOS host.

**Validation:** Native build and R22 passed: injected overflow reconciled a newly created file, and root invalidation recovered to the parent with a live watcher.

### R23 — Tab changes the layout selector while single-panel mode remains enabled

**Reproduced.** Sources: [app.hpp:1230](../app.hpp#L1230), [app.hpp:1556](../app.hpp#L1556).

Single-panel rendering delegates to a panel whose component remains parented under the split-view branch. The global Tab handler calls that panel's `TakeFocus()`, which activates its ancestor branch in `Container::Tab`. The probe enabled single-panel mode and pressed the panel-switch key: `_main_panels_mode` changed from `1` to `0` without changing the single-panel mode flag. This makes visual layout and scripted state disagree.

**Fix direction:** keep rendering and focus ownership in the same active component tree, or switch the single-view panel without focusing an inactive split branch. **Regression:** actual Tab/Shift-Tab and input navigation after entering single-panel mode, checking the rendered layout as well as the boolean state.

**Implementation status:** Applied.

**Planned solution:** keep rendering and focus ownership in the same active component tree, or switch the single-view panel without focusing an inactive split branch.

**Applied solution:** Split and single-panel presentations now use one component focus tree. The single view renders the focused panel from that tree and routes input only to it, so TakeFocus cannot activate a competing layout branch.

**Plan deviations:** Removed the redundant layout selector entirely rather than reparenting components on each switch. The mode boolean is now the sole layout authority.

**Validation:** Native build and R23 passed with an active FTXUI screen: rendered hidden-panel labels survived Tab, reverse Tab and palette switching, focused ancestry remained valid, and disabling single mode restored split rendering.

### R24 — Ordinary mkdir failures escape the dialog as exceptions

**Reproduced at the dialog boundary.** Source: [dialogs.cpp:445](../dialogs.cpp#L445).

`MkdirDialog::ok()` uses throwing `exists()` and `create_directory()` overloads without catching filesystem exceptions. Entering `missing/child` with a nonexistent parent threw `boost::filesystem::filesystem_error` in the probe. Permission and invalid-path failures can take the same route. The normal app has no corresponding exception boundary to turn these failures into dialog feedback.

**Fix direction:** use error-code overloads and retain the dialog with a useful error message; explicitly choose whether nested paths are supported. **Regression:** missing parent, read-only directory, existing file, and vanished source directory.

**Implementation status:** Applied.

**Planned solution:** use error-code overloads and retain the dialog with a useful error message; explicitly choose whether nested paths are supported.

**Applied solution:** Mkdir uses the error-code create_directory overload, rejects an empty name, reports the path and filesystem error, and closes only after successful creation.

**Plan deviations:** Nested paths require their parent directories to exist; the dialog deliberately creates a single directory rather than silently creating a hierarchy.

**Validation:** Native build and R24 passed for empty name, missing parent, existing file, permission denial, successful creation and a vanished origin. Failures retained the dialog without throwing.

### R25 — Directory navigation and archive browsing perform blocking work on the UI thread

**Static.** Sources: [commander.cpp:152](../commander.cpp#L152), [app.hpp:432](../app.hpp#L432), [archive.cpp:217](../archive.cpp#L217).

Directory listing and per-entry metadata lookup execute synchronously during navigation. Entering an archive synchronously extracts the entire archive through `system()` before returning to the event loop. Large archives or slow/network directories therefore prevent input, redraw, and cancellation for the duration. This directly conflicts with the responsiveness requirement in `spec.md`; it is not merely an optimization opportunity.

**Fix direction:** perform enumeration/extraction on workers, publish bounded updates, and provide loading/cancel states with generation checks. **Regression:** deliberately slow enumeration and extraction while asserting that input and redraw continue promptly.

**Implementation status:** Planned.

**Planned solution:** perform enumeration/extraction on workers, publish bounded updates, and provide loading/cancel states with generation checks.

**Applied solution:** Pending.

**Plan deviations:** Pending.

**Validation:** Pending.

### R26 — Mutations inside an archive operate only on its temporary extraction

**Static.** Sources: [app.hpp:447](../app.hpp#L447), [app.hpp:541](../app.hpp#L541), cache reuse at [archive.cpp:182](../archive.cpp#L182).

Archive browsing changes the ordinary panel directory to the extraction cache, but leaves rename/delete/mkdir/move/editor commands available. Those commands modify temporary files; there is no writeback to the archive. Reopening the same archive can reuse the modified cache, making edits appear persistent even though the archive bytes are unchanged. Watchers are also disabled in archive views, so cache mutations may not update the listing.

**Fix direction:** make archive browsing explicitly read-only except for extraction/copy-out, or implement an explicit commit/writeback workflow. **Regression:** attempt every mutating command in an archive and verify either clear rejection or an actual archive update with truthful UI state.

**Implementation status:** Planned.

**Planned solution:** make archive browsing explicitly read-only except for extraction/copy-out, or implement an explicit commit/writeback workflow.

**Applied solution:** Pending.

**Plan deviations:** Pending.

**Validation:** Pending.

### R27 — Separate application instances share and delete the same archive extraction directory

**Static.** Source: [archive.cpp:192](../archive.cpp#L192).

The extraction directory is a deterministic hash of archive path, size and mtime under a shared per-user temporary directory. Cache bookkeeping is process-local, so a second instance's first extraction removes the directory already in use by the first instance. The first instance's active view, editor, or copy-out job can lose its source files mid-operation.

**Fix direction:** use per-instance extraction roots or interprocess ownership/locking, and never delete another live user's cache reference. **Regression:** browse/copy from the same archive in two concurrent application instances while one starts extraction.

**Implementation status:** Planned.

**Planned solution:** use per-instance extraction roots or interprocess ownership/locking, and never delete another live user's cache reference.

**Applied solution:** Pending.

**Plan deviations:** Pending.

**Validation:** Pending.

### R28 — Next editor session alternates between two sessions instead of cycling through all

**Reproduced with a successful stub foreground runner.** Sources: [editor_manager.cpp:147](../editor_manager.cpp#L147), [editor_manager.cpp:174](../editor_manager.cpp#L174), [editor_manager.cpp:277](../editor_manager.cpp#L277).

`switch_next()` walks an MRU-sorted list, but every successful attachment updates that session's MRU timestamp. Starting with three sessions A, B, C, repeated Next calls produced C, B, C, B; A was never visited. The act of moving through the order continually rewrites that order.

**Fix direction:** use a stable cycle order or freeze an MRU traversal for the duration of switching. **Regression:** traverse three or more sessions in both directions, including failed/dead sessions, and assert every eligible session is reachable.

**Implementation status:** Planned.

**Planned solution:** use a stable cycle order or freeze an MRU traversal for the duration of switching.

**Applied solution:** Pending.

**Plan deviations:** Pending.

**Validation:** Pending.

### R29 — Valid shortcut permutations do not survive saving and loading

**Static.** Sources: conflict validation [app.hpp:845](../app.hpp#L845), loading [app.hpp:965](../app.hpp#L965), saving [app.hpp:1043](../app.hpp#L1043).

Settings restore bindings one at a time through the interactive conflict checker while defaults still occupy their keys. For example, a user can swap Copy/F5 and Move/F6 via a temporary free key, then save. On restart, restoring Copy to F6 conflicts with default Move, and restoring Move to F5 conflicts with default Copy; both failures are ignored and the user's valid mapping is lost.

**Fix direction:** parse and validate the entire mapping, then apply it transactionally after clearing/replacing the old map. **Regression:** save/reload two-key swaps and larger cycles, and report invalid mappings rather than silently discarding them.

**Implementation status:** Planned.

**Planned solution:** parse and validate the entire mapping, then apply it transactionally after clearing/replacing the old map.

**Applied solution:** Pending.

**Plan deviations:** Pending.

**Validation:** Pending.

### R30 — Lua runtime failures hang, while watchdog failures return success to the shell

**Reproduced.** Sources: [scripting.cpp:202](../scripting.cpp#L202), [scripting.cpp:227](../scripting.cpp#L227), [scripting.cpp:450](../scripting.cpp#L450), [main.cpp:94](../main.cpp#L94).

A Lua exception sets `_finished` and posts a redraw, but does not exit the loop. Future ticks immediately return, so even the watchdog stops checking it. A script containing only `error("review deliberate failure")` remained alive until an external eight-second kill. Conversely, the watchdog exits the screen, but `main()` returns 0; the existing editor integration test logged `FAIL: hard timeout exceeded 6s` and exited successfully. The fixed six-second heartbeat window can also preempt an explicitly longer wait or sleep.

**Fix direction:** carry a script result to `main`, exit non-interactive test runs on errors, return nonzero for failure/timeout, and make timeout policy consistent with explicit waits. **Regression:** syntax error, runtime assertion, watchdog timeout, long permitted wait, and successful completion with expected exit codes.

**Implementation status:** Planned.

**Planned solution:** carry a script result to `main`, exit non-interactive test runs on errors, return nonzero for failure/timeout, and make timeout policy consistent with explicit waits.

**Applied solution:** Pending.

**Plan deviations:** Pending.

**Validation:** Pending.

### R31 — Lua wait/event semantics are lossy and do not mean “all jobs finished”

**Static.** Sources: [fc_framework.lua:31](../fc_framework.lua#L31), [scripting.cpp:289](../scripting.cpp#L289), [scripting.cpp:385](../scripting.cpp#L385), [scripting.cpp:412](../scripting.cpp#L412).

`fc.wait_for_jobs()` waits for one generic `job_completed` event; it never verifies an empty queue and stopped active job. Completion polling observes only the latest active-job pointer, so intermediate fast completions can be missed. `items_updated` compares only item counts, missing rename/metadata changes, and the first poll initializes its baseline after actions may already have occurred. Tests can return early or time out even when the intended action happened.

**Fix direction:** publish events at state transitions with stable job IDs and sequence numbers, initialize baselines before actions, and implement an actual queue-drained predicate. **Regression:** multiple queued jobs, several completions between UI frames, same-count renames, and the first selection change of a script.

**Implementation status:** Planned.

**Planned solution:** publish events at state transitions with stable job IDs and sequence numbers, initialize baselines before actions, and implement an actual queue-drained predicate.

**Applied solution:** Pending.

**Plan deviations:** Pending.

**Validation:** Pending.

### R32 — Existing integration tests can pass without verifying their claimed behavior

**The rebind test emitted PASS; its wrong-dialog path and other assertion gaps are established by the source.** Sources: [test/test_rebind.lua:16](../test/test_rebind.lua#L16), [test/test_editor_integration.lua:68](../test/test_editor_integration.lua#L68), [test/test_copy.lua:384](../test/test_copy.lua#L384), [test/test_copy.lua:788](../test/test_copy.lua#L788).

The rebind test chooses F9, which is already assigned to JobList. Rebinding is rejected, but its only subsequent assertion is that some dialog opened; the unchanged F9 opens JobList and the test prints PASS. The editor test still presses F9 although the editor key is now F4, and times out. Dangling-link copy tests permit the destination link to be absent, and some cycle tests assert only that unrelated good files copied. These tests do not guard the failures their names suggest.

**Fix direction:** assert dialog identity, binding state, exact output/link contents, error state, and shell exit status. **Regression:** intentionally disable each behavior under test and confirm the corresponding test fails; add the concrete edge cases in this review.

**Implementation status:** Planned.

**Planned solution:** assert dialog identity, binding state, exact output/link contents, error state, and shell exit status.

**Applied solution:** Pending.

**Plan deviations:** Pending.

**Validation:** Pending.

### R33 — Script mode depends on the working directory and is absent from the distribution contract

**Static.** Sources: [scripting.cpp:164](../scripting.cpp#L164), [cmake/package_dist.cmake.in:11](../cmake/package_dist.cmake.in#L11).

Lua setup loads `fc_framework.lua` using a bare relative path. Running `fc run /absolute/script.lua` from another directory fails unless that directory happens to contain the framework. The package target copies the application and tool binaries, but not this required runtime file, so the advertised scripting mechanism is not self-contained in the distribution.

**Fix direction:** embed the framework or install it as a runtime resource resolved relative to the executable/package. **Regression:** unpack the distribution into a temporary directory and run a trivial script from an unrelated working directory with no source checkout present.

**Implementation status:** Planned.

**Planned solution:** embed the framework or install it as a runtime resource resolved relative to the executable/package.

**Applied solution:** Pending.

**Plan deviations:** Pending.

**Validation:** Pending.

### R34 — Custom build rules do not depend on the source code they compile

**Static.** Sources: [CMakeLists.txt:114](../CMakeLists.txt#L114), [CMakeLists.txt:177](../CMakeLists.txt#L177), [CMakeLists.txt:204](../CMakeLists.txt#L204).

The staged LuaJIT library depends only on `luajit.h`; Fresh depends only on `Cargo.toml`; 7zr depends only on its makefile. After those outputs exist, changing implementation sources or relevant lock/build inputs does not cause Ninja to invoke the underlying build tools. Developers can believe they are testing current dependencies while actually running stale staged binaries. LuaJIT also builds and cleans the shared source tree, which needs care for simultaneous native/cross configurations.

**Fix direction:** use a dependency-aware integration or always invoke the incremental underlying build before staging; isolate configuration-specific products. **Regression:** edit a dependency source without changing its manifest/header and verify the staged output rebuilds for the selected target.

**Implementation status:** Planned.

**Planned solution:** use a dependency-aware integration or always invoke the incremental underlying build before staging; isolate configuration-specific products.

**Applied solution:** Pending.

**Plan deviations:** Pending.

**Validation:** Pending.

### R35 — Clipboard support is macOS-only and ignores nonzero command exit codes

**Static; Linux was not executed.** Source: [commander.cpp:405](../commander.cpp#L405).

`push_to_clipboard()` always invokes `pbcopy`, even in the Linux build. `popen()` can succeed because the shell launched even when `pbcopy` does not exist. The implementation only rejects `pclose() == -1`, ignoring a normal nonzero child exit status; a buffered write can therefore be reported as successful although no clipboard was updated.

**Fix direction:** provide an appropriate platform backend or a clear unsupported/unavailable result, check write/flush and decoded child status, and handle a closed pipe. **Regression:** successful clipboard roundtrip, missing helper, and helper failure on each supported platform.

**Implementation status:** Planned.

**Planned solution:** provide an appropriate platform backend or a clear unsupported/unavailable result, check write/flush and decoded child status, and handle a closed pipe.

**Applied solution:** Pending.

**Plan deviations:** Pending.

**Validation:** Pending.

## P3 findings

### R36 — ColoredInt reads an uninitialized float on construction

**Static.** Source: [custom_controls.cpp:265](../custom_controls.cpp#L265), declaration at line 304.

The constructor clamps `progress_` before initializing it. The field is unrelated to rendering the integer and appears to be leftover gauge code, but reading an indeterminate float is still undefined behavior on a routine render path.

**Fix direction:** remove the unused member/clamp or initialize the member before reading it. **Verification:** compiler/static analysis or a suitable uninitialized-memory check; no new broad UI test suite is needed for this local correction.

**Implementation status:** Planned.

**Planned solution:** remove the unused member/clamp or initialize the member before reading it.

**Applied solution:** Pending.

**Plan deviations:** Pending.

**Validation:** Pending.

### R37 — Selective queue removal does not wake blocked producers

**Static; limited to bounded-queue use.** Source: [fifo_queue.hpp:276](../fifo_queue.hpp#L276), [fifo_queue.hpp:286](../fifo_queue.hpp#L286), compare ordinary pop's notification at line 257.

`erase_if()` and `get()` free queue capacity without notifying `_c_push_blockin_on`. A producer already waiting on a full bounded queue can remain asleep indefinitely after a selective consumer removes an item. Current reviewed application queues use the unbounded default, so this is a latent defect in the reusable mechanism rather than a demonstrated current UI failure.

**Fix direction:** notify waiting producers when selective removal frees capacity. **Regression:** a capacity-one queue, one blocked producer, and a matching `get()` or `erase_if()` must make progress without an unrelated later pop.

**Implementation status:** Planned.

**Planned solution:** notify waiting producers when selective removal frees capacity.

**Applied solution:** Pending.

**Plan deviations:** Pending.

**Validation:** Pending.

## Mechanism coverage

“No additional finding” below means the reviewed code and stated tests did not establish another defect; it is not a guarantee of correctness.

| Mechanism | Reviewed implementation / evidence | Result |
| --- | --- | --- |
| Startup, main loop, shutdown, terminal handoff | `main.cpp`, app construction, `WithRestoredIO`, Lua PTY runs | R07–R10, R30; actual interactive Fresh terminal behavior not exercised |
| FTXUI component tree, overlays, focus, split/single layout | `app.hpp`, dialog navigation/renderers, custom controls | R18, R23, R36; panel-vs-global shortcut scope needs broader interaction coverage |
| Directory model, metadata, sort/filter/selection | `commander.*`, `Files`, `PanelSharedState`; filter/focus/glob tests | R15, R19, R21; no additional sort/glob defect established |
| Partial refresh and native filesystem watchers | `file_change_funnel.cpp`, `Panel::start_watcher`, `Dir::partial_refresh` | R07, R08, R21, R22; macOS teardown reproduced, Linux static only |
| Tabs and focus restoration | `Panel::TabState`, activation, watcher handoff; tabs/focus tests and inactive-tab probe | R20, R23 |
| Bookmarks | `BookmarksDialog`, app persistence and navigation; bookmarks test | No additional bookmark-specific finding; synchronous navigation and persistence limitations still apply |
| Command catalog, palette, dispatch, rebinding | `Commands`, `CommandPaletteDialog`, theme keys, save/load; palette/rebind tests | R29, R32; basic palette test passed |
| Theme/colors, columns, settings persistence | `theme.*`, theme dialog, settings parser/writer | R29, R36; broader invalid-config and restart coverage remains unverified |
| Mkdir and batch rename | Dialog construction, argument snapshots and callbacks; component probes | R06, R24 |
| Copy discovery, tree traversal, link policies | `CopyDiscoveryProcess`, `DirItem`, symlink resolver; fixtures and copy tests | R04, R05, R11, R15, R16 |
| Copy execution, conflict policies, throughput and partial output | Worker copy path and local Boost extension; existing copy suite and direct probes | R02, R11, R12, R14, R17, R18 |
| Move, including cross-device fallback | `MoveDialog`, `run_move`; same-device probe | R13, R14; cross-device execution not exercised |
| Recursive delete | `DeleteDialog`, recursive producer, FIFO consumer; external-link fixture | R01, R13, R14 |
| Job queue, pause/resume/cancel, progress monitor | `file_io_jobs.*`, FIFO, progress UI; pause test and targeted probes | R05, R09–R14, R37 |
| Completed-job history, details, dismissal and errors | `JobListDialog`, `ErrorListDialog`, `JobSpec`, history storage; copy suite history case | R09, R11, R14; retention/design gaps listed below |
| Archive recognition, creation, extraction, cache and virtual navigation | `archive.*`, panel archive stack, copy dispatch; archive test and failed-tool probe | R03, R13, R25–R27 |
| Recursive find and result navigation | `FindDialog` worker/cancellation/results, Lua completion polling; find test | Basic test passed; R25/R31 concerns apply to blocking lifecycle and observed events; slow-filesystem cancellation not timed |
| Fresh editor, sessions, binary resolution and process exits | `editor_manager.*`, `runtime_paths.*`, fake script, three-session stub probe | R28, R32; relative-path documentation mismatch below |
| Clipboard exports | `ToClipboardDialog`, `push_to_clipboard` | R35 |
| Lua API, scheduler, event history, waits and assertion lifecycle | `scripting.*`, `fc_framework.lua`, all test Lua sources; PTY suite and deliberate-error script | R30–R33 |
| Build, dependency staging, static/cross configuration and packaging | CMake, toolchain files, package script, local Boost build integration | Native build passed; R33, R34; full cross-target distribution unverified |
| Logging, error transport, utility types and playground | `log.*`, `err.*`, shared state, FIFO, `playground.cpp` | Error visibility affected by R11/R30; R37; playground is not an active build target |

## Validation results and limitations

### Existing Lua suite

Tests ran sequentially through a PTY with a 140×40 terminal, isolated `XDG_CONFIG_HOME`, an absolute `FC_FRESH_BIN` pointing to the repository's fake editor, and a separate fake-editor log. Exit codes, explicit PASS markers, and the Lua debug log were inspected rather than treating exit code 0 as sufficient.

| Script | Observed result |
| --- | --- |
| `test/test_events.lua` | PASS marker, exit 0 |
| `test/test_palette.lua` | PASS marker, exit 0 |
| `test/test_archive.lua` | PASS marker, exit 0 |
| `test/test_tabs.lua` | PASS marker, exit 0 |
| `test/test_focus_refresh.lua` | PASS marker, exit 0 |
| `test/test_glob.lua` | PASS marker, exit 0 |
| `test/test_bookmarks.lua` | PASS marker, exit 0 |
| `test/test_single_panel.lua` | PASS marker, exit 0; its state assertion does not catch R23 |
| `test/test_find.lua` | PASS marker, exit 0 |
| `test/test_rebind.lua` | PASS marker, exit 0, but false assurance as described in R32 |
| `test/test_editor_integration.lua` | **FAIL:** watchdog after approximately 6.05 seconds; no PASS marker; misleading exit 0 |
| `test/test_pause_resume.lua` | PASS marker, exit 0; does not cover pausing the final file or paused shutdown |
| `test/test_copy.lua` | All 34 numbered cases and final suite PASS marker; exit 0; assertion gaps in R32 still apply |

Thus **12 of 13 scripts emitted PASS markers**, while the editor script failed. This is not equivalent to 12 fully verified mechanisms.

### Focused disposable probes

The C++ probe used the compile flags from `build/compile_commands.json`, linked the application's existing object files with a probe entry point replacing `main.cpp.o`, and exercised public types/functions directly. All destructive cases were confined to newly created temporary directories. No real user files were used. The editor-cycle probe used a runner returning success, so its evidence concerns session ordering, not Fresh's CLI implementation.

| Probe | Observed value / effect | Finding |
| --- | --- | --- |
| Select and delete only a link to an external fixture directory | Target file survival: `false` | R01 |
| Extended Boost copy: missing source, existing destination, cancellation flag true | `ENOENT`; destination survival: `false` | R02 |
| Existing archive, tool set to `/usr/bin/false` | Error returned; previous archive survival: `false` | R03 |
| Finish discovery, edit destination, directly confirm | Old target exists: `true`; new target exists: `false` | R04 |
| Partial batch rename, then edit surviving input | Surviving model text unchanged; invalid binding established by source | R06 |
| Immediately create/reset a macOS watcher | `SIGSEGV`, return code `-11` | R07 |
| Return from main with paused worker | Still alive after 3 seconds; externally killed | R10 |
| Discovery-error item submitted to copy worker | State `4` (`COMPLETED`), zero recorded errors | R11 |
| Discover a mode-000 directory containing a file | Zero discovered files, zero discovery errors | R11 |
| Pause during a throttled single 2 MiB file copy | State `2` (`PAUSED`), stopped flag true, output size `2097152` | R12 |
| Successful one-file move / two-entry delete | Done/total: `0/1` / `1/2` | R14 |
| List a dangling link | Link absent from model | R15 |
| Follow valid `A -> B -> file` chain | One discovery error | R16 |
| Type `1` with destination focused | Destination remains empty | R18 |
| Filter two entries to one, refresh, apply same filter | Visible count changes from 1 to 2 | R19 |
| Create file while its tab is inactive, then reactivate | New file absent from restored model | R20 |
| Enable single panel, switch panel using Tab | Layout selector changes `1 -> 0` | R23 |
| Mkdir with nonexistent parent | Filesystem exception escapes `ok()` | R24 |
| Create three stub editor sessions, repeatedly choose Next | C → B → C → B | R28 |
| Lua script containing an immediate `error(...)` | Error logged, process still alive at 8 seconds; externally killed | R30 |

Temporary harnesses and captured PTY/debug logs were kept outside the repository in `/var/folders/nv/lp72srjd5kj7qxgxb9d8klp40000gn/T/fc-review-lmhimb8e` for local follow-up. That temporary path is evidence from this run, not a permanent test dependency. Future regression tests should be committed alongside fixes.

To reproduce the most destructive cases safely, create independent temporary source/destination/target directories and use only their paths: (1) a `DELETE` `JobSpec` containing `DirItem(link)`; (2) `copy_file(missing_source, existing_destination, copy_file_options{...cancel_requested=&true_flag}, ec)`; (3) `ArchiveService::set_tool_path("/usr/bin/false")` followed by `create_archive(existing_archive, {fixture_source}, source_parent)`. Check the pre-existing target contents after the call, not only its return value. Never use valuable files for these checks.

## Documentation reconciliation and remaining design gaps

These are separated from the defect count because an unimplemented proposal is not automatically a regression.

- `spec.md` and parts of `file_operations.md` still describe conflict options, cancellation, pause/resume, destination editing, tabs, single-panel mode, glob selection, bookmarks, and some columns/platform work as missing. The current implementation contains these mechanisms, with the defects above. Their existence should be reflected in the status documents.
- The known follow-links doubled-filename and directory-into-subtree problems described in older material have corresponding code changes and passing existing tests. They were not copied into this review as current bugs without contrary evidence.
- `completed_jobs.md` proposes a richer ownership/completion design than the implementation. Current pause blocks the single worker on a condition variable, so queued work cannot proceed while it is paused. History retains full job vectors indefinitely until dismissal, rather than bounded summaries. Job-ID control APIs, richer retry/resume ownership, and parts of the proposed Lua contract are not present.
- The editor is bound to **F4** and JobList to **F9** in `theme.cpp`; editor documentation/test comments and the integration test still use F9. Update them together with R32.
- The documented `FC_FRESH_BIN=./test/fakes/fresh_fake.sh` example conflicts with `normalize_tool_reference()`, which resolves references containing a slash relative to the executable directory. The validation run used an absolute path. Clarify whether explicit relative overrides should be relative to the caller's working directory or the executable, then make examples and tests consistent.
- Absolute build-time tool paths take precedence while they still exist; only missing absolute paths fall back to an executable-adjacent binary. Test distribution relocation both with and without the original build tree available to establish the intended runtime precedence.
- Cross-target builds, actual cross-device moves, watcher overflow recovery, real editor terminal interaction, restart persistence beyond the source trace, and archive behavior with unusual option-like filenames remain important validation gaps. They were not claimed as tested.

## Suggested repair order

1. Address R01–R04 and R11 first: preserve data and make operation results truthful.
2. Establish synchronized discovery/job snapshots and explicit shutdown/ownership rules for R05–R10, then fix the pause/cancel state machine in R12–R14.
3. Correct link semantics, panel/filter/tab/watch behavior, archive workflow, and editor/persistence behavior in R15–R29.
4. Fix test exit semantics and assertions before relying on the suite as a release gate; add targeted regressions for the repaired mechanisms. Complete runtime packaging and build dependency fixes, then the small P3 corrections.
