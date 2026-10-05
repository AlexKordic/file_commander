# Editor workflow and interruption recovery

Review date: 2026-10-05. Status: EW-01 through EW-06 implemented. The findings
below describe the reviewed baseline; the implementation notes describe current
behavior and its recovery limits.

Reviewed File Commander revision: `213196066011ebc6ede102dc6034791a6da9d589`.
Reviewed Fresh revision: `21610e4530a5dbd56027dcae81f3b05fccc2c465`, pinned in
[dependencies.json](../dependencies.json).

This document replaces the multiple-editor-session design in
[fresh_editor_integration_plan.md](fresh_editor_integration_plan.md).
[fresh_cli_contract.md](fresh_cli_contract.md) describes the implemented CLI
integration.

## Required user experience

- Use one persistent editor instance, with an easy switch to the editor and back
  to File Commander (FC).
- Open each file as a persistent editor tab. Opening an already open file focuses
  its existing tab. Opening another file must not replace the previous tab.
- Fresh controls tab closure, save/discard prompts, and recovery of unsaved text.
  FC navigation, switching, and exit must not close editor tabs. Switching back
  must not reopen tabs that the user closed in Fresh.
- On FC restart, restore the workspace and reconnect to the same editor session.
  If the editor process is gone, Fresh must recover its own saved workspace and
  recoverable unsaved buffers.

### Recorded decision: interrupted transfers

**Interrupted transfers are always paused on startup, requiring an explicit
Resume action.** This is a decided requirement, not an optional recovery mode.

- Every restored interrupted (nonterminal) transfer starts in `Paused`, whether
  its persisted state was running, queued, or paused. Completed and explicitly
  cancelled transfers retain their terminal states.
- Startup, workspace restoration, and switching to/from the editor must not
  enqueue recovered transfers or resume their filesystem mutations.
- Show preserved progress and the reason for the pause. Resume applies only to
  the transfer(s) explicitly selected by the user.
- Validate remaining work before executing it. Changed sources, destination
  conflicts, missing volumes, or uncertain completion state must leave the
  transfer paused with an actionable explanation until resolved.
- Preserve completed work. Do not automatically replay copies, overwrites,
  moves, or source deletion after restart. A separate destructive job such as
  delete must likewise never be replayed automatically.
- If a transfer cannot safely resume, keep its recovery record and explain why;
  do not silently restart it from scratch. Offer explicit cancel/restart choices.

This decision applies to recovery after interruption. Merely switching to the
editor during the same FC process does not itself pause healthy live transfers.

### Implemented interaction details

The implementation uses the following choices:

- Keep `F4` as open-selected-files in the editor.
- `F10` switches in both directions by default; the FC palette can rebind it.
  Each Fresh attachment receives the current binding. `Alt+F` opens the File menu.
- Use one stable FC-owned session per configuration profile. A lifetime profile
  lock rejects a second interactive FC for that profile; a different
  `XDG_CONFIG_HOME` selects an independent profile. Session creation also has
  a backend startup lock.
- Opening a directory reuses the editor. On first use it can establish project
  context; later opens must preserve tabs and not silently replace project
  context. Changing project context is outside the attach/open operation.
- An editor backend and its terminal attachment are one logical editor instance.
  Returning to FC detaches the terminal client; it does not quit the backend.

## Implementation and recovery guarantees

| Finding | Implementation | Regression coverage |
| --- | --- | --- |
| EW-01 | Fresh creates its backend in a separate Unix session, serializes startup, and bounds readiness waits. | Real PTY/client disconnect, process-group hangup, concurrent backend startup. |
| EW-02 | Fresh checkpoints named sessions every two seconds and on detach/shutdown; restores tabs, view state, dirty file and untitled text; dirty buffers prevent idle exit. | Backend kill/restart twice, tab order/active tab/cursor, closed-tab persistence, dirty/untitled text, dirty idle survival and clean idle restart, unchanged source files. |
| EW-03 | FC checkpoints `editor_session.json` before launching, reconstructs the session registry, and retries the same identity after failure. | Manager regression and FC restart/reattachment tests. |
| EW-04 | Files and directories reuse one session; previous/next-session commands are compatibility aliases. Fresh owns tab closure. | Single-session manager contract and real multi-file Fresh tests. |
| EW-05 | `F10` attaches/detaches; binding overrides travel with each attachment; the terminal returns to FC. | Real FC/Fresh round trip with dirty text, selection/input restoration, failed launch, F8 override. |
| EW-06 workspace | FC checkpoints both panels every 500 ms, before editor handoff and on graceful exit. Restores tabs, focus, selections, filters, layout and view options. | Workspace schema/failure tests; real PTY HUP, TERM and KILL with either FC or Fresh foreground; duplicate-profile rejection. |
| EW-06 transfers | Journal before queueing, durable commit boundaries, all interrupted records restored paused, explicit selected-job Resume, conservative reconciliation. | Process exits before/after copy commit, same-filesystem rename, repeated move cleanup interruption, changed files/parents, corrupt records, cancellation, directory access, shutdown and real job-dialog Resume. |

Recovery files live in the FC configuration profile: `workspace.json`,
`editor_session.json`, and `transfers/<id>.{plan,state}.json`. Preferences remain
separate. An explicit command-line panel path takes precedence over saved panel
paths; it does not resume transfers or create a different editor identity.
Missing locations use an existing ancestor while retaining the intended tab
state. Invalid checkpoints remain on disk and are reported rather than silently
replaced. Writes use private temporary files, atomic rename and directory fsync.

Fresh's named-session checkpoint lives under its own data directory. Dirty text
is recovery data, not an implicit Save to the source file. Abrupt loss can discard
edits since the last successful two-second checkpoint. FC's corresponding panel
state window is 500 ms. Undo history remains live across detach/reattach; it is
not serialized as part of backend crash recovery.

### Transfer controls and limits

Open **Job List (`F9`)**, select a transfer, then press **`r` to Resume**, **`p` to
Pause**, or **`c` to Cancel**. Details show the reason a transfer remains paused.
Dismiss applies only to finished history. Lua exposes `fc.resume_job(id)`, optional
IDs for `fc.cancel_job(id)` / `fc.pause_job(id)`, and `recovery_note` in job history.

Resume is **file-level**, not byte-level. Completed journaled items are retained;
an incomplete private staging item can be removed and recopied only after an
explicit Resume and validation. Copy/move identity checks include filesystem and
inode identity, sizes, modification/change timestamps, modes and symlink targets.
A proven copy commit advances without replaying it. A proven cross-volume move
commit resumes source cleanup only while the destination and remaining source
entries still match. An interrupted same-volume rename is reconciled by identity.
Staged data and destination directories are flushed before recording commit and
starting source cleanup. The immutable discovered plan and mutable progress are
stored separately, with a 64 MiB per-record limit; oversized journals reject job
submission before execution.

Changed files, destination conflicts, changed parent/volume identity, inaccessible
paths, or uncertain completion leave recovery paused with an explanation. The
user can resolve the issue and retry Resume, or explicitly Cancel the recovery
and start a new operation through the usual dialog after reviewing the files.
Recovered delete, archive, rename and other non-copy/move operations require that
explicit cancel/new-operation route. No destructive job is replayed automatically.
Cancellation retains committed files; recovery never interprets Cancel as Undo.
Unexpected private staging data is retained when ownership cannot be proven.

The guarantees cover interruption and subsequent restart. Validation cannot lock
out unrelated applications changing the same filesystem during execution.

## Findings and fix plans

P1 findings risk losing work or breaking recovery. P2 findings prevent the
requested workflow or leave significant usability gaps.

### EW-01 — P1: shell hangup can kill the editor and lose unsaved work

**Finding.** Fresh's `spawn_server_detached` redirects standard streams but
leaves the server in the originating process group. The available `daemonize`
function is not called by this startup path. In the isolated real-editor probe,
disconnecting only the client preserved both tabs and unsaved text, but sending
`SIGHUP` to the originating process group killed the server. A new server did not
restore either the tabs or unsaved text. The original file on disk was unchanged.

**Source.** In the pinned Fresh checkout,
`crates/fresh-editor/src/server/daemon/unix.rs:63` (`spawn_server_detached`),
and `crates/fresh-editor/src/main.rs:2492` (server entry point).

**Fix plan.**

1. Give the Unix backend its own process session, independent of the launching
   terminal's process group, using a safe spawn/daemonization path. Preserve
   intended working directory, configuration, and restrictive file permissions.
2. Make startup report the actual backend identity and readiness. Bound startup
   waits and clean up failed launches without killing unrelated processes.
3. Keep terminal attachment short-lived and reconnectable. Client disconnect or
   shell hangup must not mean editor quit.
4. Implement EW-02 as well: process isolation cannot protect against a backend
   crash, explicit termination, or machine restart.

**Acceptance checks.** A real PTY test opens two files, modifies one without
saving, closes the client, and then hangs up the launching process group. The
same backend remains attachable with both tabs and unsaved text intact. Check
backend process/session identity, terminal restoration, and failure cleanup.

### EW-02 — P1: editor session mode lacks durable recovery

**Finding.** Fresh's session-server loop omits the periodic recovery autosave
and workspace save/restore calls used in standalone mode. It also exits after
one hour without clients without checking for modified buffers. The probe found
no recovery or workspace files after four seconds with dirty text, beyond the
configured default two-second recovery interval. The idle-timeout behavior was
established by source inspection, not by waiting an hour in a runtime test.

**Source.** In Fresh, `crates/fresh-editor/src/server/editor_server.rs:189`
(idle exit), `:311` (server loop), and `:341` (editor initialization);
`crates/fresh-editor/src/main.rs:2058` (one-hour timeout), `:2762` (standalone
recovery autosave), and `:2774` (standalone workspace save). Existing recovery
and workspace helpers are in `src/app/recovery_actions.rs` and
`src/app/workspace.rs`, relative to `crates/fresh-editor`.

**Fix plan.**

1. Run periodic recovery checkpoints in session mode, including while no client
   is attached. Include dirty file buffers and untitled buffers without writing
   their contents into the user's source files as an implicit Save.
2. Persist the editor workspace: open tabs and order, active tab, cursor/view
   state, and the identity of associated recovery buffers. Restore once before
   processing new open requests, merging requests without duplicate tabs.
3. Persist tab closure so recovery does not resurrect deliberately closed tabs
   or buffers whose changes the user explicitly discarded.
4. Prevent idle shutdown from discarding modified buffers. Prefer keeping the
   backend alive while dirty; any clean idle exit must checkpoint the workspace.
5. Use versioned, atomic recovery data scoped to the stable editor identity.
   Report checkpoint/restore errors and retain recoverable data on failure.

**Acceptance checks.** After a completed checkpoint, kill and restart the
backend and verify tab order, active tab, cursor, dirty and untitled text, and
unchanged source files. Verify closed tabs stay closed. Exercise idle expiry
with an injected clock/short test timeout, with and without dirty buffers.
Document the checkpoint interval and resulting possible loss window; do not
promise recovery of keystrokes that were never checkpointed.

### EW-03 — P1: FC restart loses access to the saved editor session

**Finding.** Loading `last_editor_session_id` restores only a string, leaving
the session registry empty. Switching reports `No editor sessions available`.
Opening a file then creates a different session because the saved ID is absent
from the registry. The old backend and its tabs may still exist but are not
reached by the normal workflow. The manager probe reproduced both failures.

**Source.** [editor_manager.cpp](../editor_manager.cpp):82
(`set_last_session_id`), :232 (`open_files_in_last_session`), and :273/:296
(switching); [app.cpp](../app.cpp):733 and :763 (load/save editor identity).

**Fix plan.**

1. Persist stable session identity and enough ownership/context metadata to
   reconstruct the manager. Checkpoint identity before launching or handing
   over the terminal, not only when FC exits.
2. Reconcile restored metadata with the live backend. Reattach the owned session
   if healthy; if it is gone, restart the same logical session and let Fresh
   restore its workspace through EW-02.
3. Distinguish unavailable, incompatible, and failed backends. Use bounded
   discovery/open/startup waits and surface a recoverable error instead of
   allocating another identity after every failure.
4. Reconnection must work if the original working directory has been deleted.
   Use a validated fallback without changing session ownership. Handle
   simultaneous launches without duplicate backends or checkpoint overwrites.

**Acceptance checks.** Exit and restart FC with Fresh still alive: switching
works immediately and uses the same ID and backend. Repeat after terminating
Fresh: the same logical session recovers. Cover missing original directory,
stale metadata, launch failure, and concurrent startup. Do not reopen tabs that
were closed inside Fresh merely because FC previously requested those files.

### EW-04 — P2: directory opens create additional editor instances

**Finding.** Opening a directory always creates a new session ID and appends
another session. Opening files targets the last session. The manager probe
opened two directories and observed two sessions. This follows the earlier
design but conflicts with the requested single-editor workflow.

**Source.** [app.cpp](../app.cpp):640 and :649 (directory routing);
[editor_manager.cpp](../editor_manager.cpp):190
(`open_directory_new_session`).

**Fix plan.**

1. Replace per-directory session creation and session-ring routing with one
   ensure-session/open/attach path using EW-03's stable identity.
2. Send all selected files to that session as persistent tabs. Preserve the
   existing canonical-path deduplication behavior and focus an existing tab
   when a file is reopened.
3. Reuse the session for directory opens with the project-context behavior
   described above. Fresh's current `session open-file` skips directories, so
   directory handling needs an explicit supported path.
4. Remove previous/next-session UI concepts or keep documented compatibility
   aliases that attach the single session. Update help, command labels, Lua
   integration, and the CLI contract. Never close tabs on panel navigation.

**Acceptance checks.** Open files from multiple directories and panels, open
multiple selected files together, and reopen one file. Exactly one backend
session exists; each distinct file has one persistent tab. Opening directories
and switching panels preserves existing tabs, dirty text, and project context.

### EW-05 — P2: there is no dependable one-key round trip

**Finding.** FC exposes `F10` as return-to-FC, but its handler is a no-op and FC
cannot receive keys while Fresh owns the terminal. Fresh's default `F10` opens
its menu, and its default keymap has no detach shortcut. Fresh already has a
detach action that preserves the backend. Quit is a different operation and
can prompt about dirty buffers or terminate the editor.

**Source.** [theme.cpp](../theme.cpp):228 (bindings);
[app.cpp](../app.cpp):860 (no-op handler). In Fresh,
`crates/fresh-editor/keymaps/default.json:13` (menu binding),
`crates/fresh-editor/src/app/input.rs:240` (detach action), and
`crates/fresh-editor/src/server/editor_server.rs:263` (client detach).

**Fix plan.**

1. Provide a clearly named switch-editor command in FC that attaches the stable
   session without opening or closing files. Bind the same configurable key to
   Fresh's `detach` action for the return trip.
2. Deliver the binding through integration-scoped configuration while
   respecting user overrides. Ensure it actually reaches a newly spawned
   backend: the existing detached spawn forwards only the session name.
3. Restore terminal modes, screen, panel focus, cursor, filters, and selection
   on return. Switching must not invoke editor Save, Close, or Quit.
4. Show the current switch key in both applications' help. Handle attach/startup
   failures without leaving FC's terminal unusable; bound connection setup, not
   the duration of an interactive editing session.

**Acceptance checks.** Repeatedly switch in both directions with several tabs
and dirty text. Preserve editor cursor and undo state while the backend is live,
as well as FC panel state. Test a configured key override, first launch, failed
attach, and a tab closed by the editor. Verify the return action never asks to
discard buffers and leaves the backend alive.

### EW-06 — P2: FC cannot fully restore where the user left off

**Finding.** FC saves settings when the normal interactive loop exits. It does
not checkpoint ongoing workspace changes. Persisted panel state has only the
active location and some view options; panel tab lists, per-tab cursor, filters,
selection, and transfer recovery records are absent. Transfer plans and progress
remain in memory. Shutdown cancels active work rather than persisting it.

**Source.** [main.cpp](../main.cpp):115 (interactive loop and exit save);
[settings.hpp](../settings.hpp):6 (persisted schema);
[app.cpp](../app.cpp):747 (`save_settings`) and :354/:443 (in-memory panel tab
state); [file_io_jobs.cpp](../file_io_jobs.cpp):391 (worker shutdown).

In isolated FC PTY probes, Ctrl+C and SIGTERM saved the latest panel paths;
SIGHUP and SIGKILL did not. None restored panel tabs. These probes interrupted
FC while it owned the terminal; they do not establish graceful shutdown behavior
while FC is waiting for an attached editor. Suspending and resuming the same
process with shell job control is separate from recovery on a new app start.

**Fix plan — workspace.**

1. Add a versioned runtime workspace checkpoint separate from user preferences.
   Store both panels' tab lists and active indices, logical locations including
   archive views, focused item identity/path, filters, selections, sort/view
   options, panel focus/layout, and the stable editor identity.
2. Checkpoint changes with a bounded debounce; flush before terminal handoff and
   on graceful exit. Reuse the atomic-write machinery in
   [settings.cpp](../settings.cpp), with clear error reporting and a defined
   durability policy. Coordinate writers for simultaneous FC instances.
3. Route handled shutdown signals through an async-signal-safe notification to
   normal application code. Cover SIGHUP and SIGTERM while FC is foreground and
   while the editor is foreground. SIGKILL cannot be handled; restoration must
   rely on the last successful checkpoint.
4. Validate restored locations and item identities. Use a clear fallback for
   missing directories/volumes while retaining recoverable tab state. Define
   explicit command-line path precedence and migrate the existing settings.

**Fix plan — interrupted transfers.**

1. Add a durable job journal before scheduling work. Record operation/options,
   source/destination identities, discovered items, staging ownership, committed
   items, errors, and enough progress to reconcile interruption boundaries.
2. Record recoverable execution phases around destination commit and source
   cleanup. A crash between filesystem mutation and journal update must be
   reconciled without blindly repeating the mutation or deleting an unverified
   source. Preserve staging data needed for that reconciliation.
3. Load every interrupted nonterminal job as `Paused` and keep it out of the
   worker queue. Show progress and an explicit Resume action. Never restore the
   old running/queued state into automatic execution; retain terminal history
   without turning completed or cancelled jobs into resumable work.
4. On explicit Resume, revalidate sources, destinations, conflicts, permissions,
   available volumes, and recorded completion. Resume only validated remaining
   work. Retain the paused state with an explanation when validation fails.
5. Define file-level versus byte-level resume guarantees. Reusing partial bytes
   requires validated staging/source identity; otherwise restart only the
   incomplete item after explicit Resume, retaining completed items. Unsafe or
   unsupported cases need explicit restart/cancel choices.

**Acceptance checks.** Restore all panel tabs and view state after normal exit,
SIGHUP, and SIGKILL after a completed checkpoint, including editor-foreground
interruption. Test missing locations, corrupt checkpoints, and migration.
Restore previously running, queued, and paused transfers and assert all are
paused with no transfer writes, overwrites, or deletions before Resume. Resume
one selected job and verify others remain paused. Inject repeated crashes around
destination commit/source cleanup; completed work must not be replayed and
changed files must not be silently overwritten or removed.

## Qualification of the implementation

Tested FC revision before the manual-category split: `d9302fcf4d701914d5cc39cf5387e2fa5b2bc5fd`. The subsequent
documentation commit does not change executable sources. Full evidence summary:
[macOS arm64 editor workflow qualification](qualification/macos-arm64-editor-workflow-2026-10-05.json).

- Release build and dependency reconstruction/rebuild passed; the distribution
  tarball was produced with the pinned Fresh binary.
- All new editor/workspace/transfer recovery checks passed, including the real
  FC Job List Resume action and both applications' foreground interruption cases.
- ASan/UBSan: **36/36** core checks passed.
- ThreadSanitizer: **19/19** lifetime and transfer recovery checks passed.
- Strict release lane: **189/196** passed, with no skipped checks. Seven required
  checks still fail in this tool session: the EXDEV fixture is unavailable;
  FSEvents cannot start, affecting three watcher tests, two Lua tests and the
  relocated package smoke test. The native release gate therefore remains open.

The user subsequently chose to put those seven checks in the `manual` category.
Automatic lanes now exclude them and retain package creation/integrity checks;
manual results are reported separately. See [build and test setup](build_test_setup.md#manual-environment-checks).
This reclassification does not change the historical results above. The new
**automatic lane passes 190/190** at `ed62486`, with package creation/integrity
passing and the seven manual tests listed separately as not run.
[Automatic qualification record](qualification/macos-arm64-automatic-2026-10-05.json).

Run the manual category from a normal macOS Terminal:

```sh
python3 tools/test_exdev_volume.py --manual-build build-release
```

It supplies a disposable APFS volume and runs every manual-category test.
The earlier user-reported 178/178 result applies to the earlier revision only.
Fresh's release build and real PTY tests passed; its Rust unit-test target was
not runnable with the uncached development dependencies available here.

## Fix commits

Fresh fixes are committed in its repository and included in the pinned dependency
bundle, so a clean bootstrap can reproduce them:

- `1f7d5e68b`: EW-01 backend isolation and bounded startup.
- `12a246546`: EW-02 named-session workspace and unsaved-buffer recovery.
- `356a98808`: EW-05 attachment-specific switch key and bounded handshake.

FC fixes are separate commits:

- `15c5985`: reproducible Fresh bundle, bootstrap support and exact revision pin.
- `8d98949`: EW-03 editor identity persistence and reconnection.
- `445fa07`: EW-04 one editor for files and directories.
- `66703ed`: EW-05 configurable editor round trip and real PTY coverage.
- `f69ec5a`: EW-06 workspace checkpoints and interruption handling.
- `3b46c89`: EW-06 transfer journaling, paused startup and validated Resume.
- `0b02641`: preserve discovered delete progress without replaying deletion.
- `d9302fc`: strengthen editor tab/cursor and clean-idle recovery tests.

## Original review evidence

Local review artifacts are in the ignored directory
`build-review-evidence/editor-ergonomics/`; they are not distributed with the
repository. The findings above preserve their conclusions for reviewers who
do not have those files.

| Evidence | Observed result |
| --- | --- |
| `session-probe.log` | Two directory opens created two sessions; switching after restoring an ID failed; the next file open did not reuse that ID. |
| `interrupt-results.json` | Ctrl+C/SIGTERM saved current paths; SIGHUP/SIGKILL did not; panel tabs were not persisted. |
| `fresh-results.json` | Client-only disconnect preserved dirty text and tabs; group SIGHUP killed the backend; a new backend restored neither; source file unchanged. |
| `fresh-results.json` and source inspection | No recovery/workspace files after four seconds; session loop omits standalone persistence calls. |

At the reviewed baseline, the existing tests did not establish the requested workflow
(the tests have since been replaced or extended):

- [test/test_fresh_terminal.py](../test/test_fresh_terminal.py) sends Ctrl+Q
  after detecting Fresh. It tests quit and terminal return, not detach with dirty
  buffers, reattachment, or crash recovery.
- [test/test_editor_integration.lua](../test/test_editor_integration.lua)
  uses a fake Fresh binary and checks command invocation, not actual tabs.
- R28 in [test/review_regressions.cpp](../test/review_regressions.cpp)
  intentionally checks a three-session ring, reflecting the old design.

The previously reported native release result (178/178 passing) remains valid
for that earlier revision only. New qualification must include the recovery tests
listed above; it cannot inherit the earlier release result.

## Implementation sequence and commit boundaries

Keep each fix independently reviewable with its relevant regression coverage.

1. **EW-01, Fresh:** isolate backend lifetime from the launching shell and add
   real process-group/PTY coverage.
2. **EW-02, Fresh:** add session recovery/workspace persistence and protect dirty
   buffers from idle shutdown. Test backend restart and deterministic idle expiry.
3. **Dependency integration:** commit the Fresh changes in its repository, make
   the revised source obtainable through the declared dependency source, then
   update the exact Fresh revision in `dependencies.json`. Verify bootstrap and
   packaged binaries use that revision; a local unpinned patch is insufficient.
4. **EW-03, FC:** persist/reconstruct stable editor identity and reconnect across
   FC restarts, including concurrency and failure handling.
5. **EW-04, FC:** consolidate file/directory opens into the one-session workflow;
   replace session-ring tests and update the CLI contract and integration docs.
6. **EW-05, both applications:** implement the configurable attach/detach key,
   propagate configuration to the backend, and add real round-trip tests. Pin
   any additional Fresh change before qualifying FC.
7. **EW-06, FC workspace:** add checkpoint schema, migration, state capture,
   restoration, and signal/handoff integration.
8. **EW-06, transfer recovery:** add journal/reconciliation and the mandatory
   paused-on-startup state, followed by explicit validated Resume. Test crash
   boundaries and absence of automatic execution.

Run focused tests for each fix, then the complete native release lane and
applicable sanitizer lanes against the final pinned dependency build. Include
real Fresh PTY tests as well as deterministic manager/journal tests. Qualification
must cover shell interruption while either application owns the terminal, editor
backend loss, and startup with interrupted transfers; success is preservation of
the specified state, not merely a clean process exit.
