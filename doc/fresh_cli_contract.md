# Fresh CLI contract for File Commander

FC owns one persistent editor identity per configuration profile. A directory
open establishes its initial project directory; subsequent directory opens and
file opens reuse that identity without changing the project or closing tabs.
Fresh owns tab closure, dirty prompts, saving, and unsaved-buffer recovery.

## Controls

- `F4`: open selected files as tabs, focusing existing tabs for reopened files.
- `F10`: switch to the editor; the same key in the attached editor detaches and
  returns to FC, retaining tabs, dirty buffers, cursor, and undo state.
- The palette can rebind the switch key. FC sends its current key token in
  `FC_EDITOR_SWITCH_KEY` with each attachment. Fresh applies it to that client;
  global Fresh configuration is untouched. `Alt+F` still opens Fresh's File menu.
- `Ctrl+Y` / `Ctrl+U` remain compatibility shortcuts to the same editor.
  The saved command ID `switch_to_file_commander` now performs the editor toggle.
- Fresh Quit is an explicit editor operation, separate from detach.

## Invocation and identity

Binary resolution is `fresh_binary_path` in FC settings, then `FC_FRESH_BIN`,
then the bundled build-time default. Relative overrides are normalized before
changing directories.

The profile's `editor_session.json` stores a stable ID and original working
directory. FC writes it atomically before launching the editor, and a short
process lock prevents concurrent identity creation. Restarting FC reconstructs
this identity; a missing original directory uses a valid launch fallback.

File opens use absolute canonical paths:

```text
fresh --cmd session open-file <session_id> <abs_file_1> [abs_file_n...]
fresh -a <session_id>
```

Switching and directory opens only attach. `session open-file` skips directory
arguments, so FC does not send directories through that operation. FC restores
terminal IO around attachment and resumes its own terminal after detach.

Exit `0` means success. FC also accepts legacy exit `2` from `session open-file`.
The open command receives `/dev/null` as stdin: upstream may auto-attach on its
first file open when stdin is a terminal. Only FC's explicit attachment owns the
terminal. Startup lock acquisition and daemon readiness are each bounded to ten
seconds, the handshake to ten seconds, and FC's entire noninteractive command
to 25 seconds. Interactive editing has no duration limit. Failed attachment
retains the identity for retry and reports the failure.

## Recovery and dependency

The backend runs in its own Unix process session. It checkpoints native Fresh
recovery data and workspace state every two seconds and on detach; native exit
persistence handles shutdown. Recovery stores dirty and untitled text separately
from source files. A crash can lose edits since the last successful checkpoint.
Dirty buffers prevent idle shutdown. Clean sessions default to one hour;
`FRESH_SESSION_IDLE_TIMEOUT_SECS` accepts a positive override.

FC-owned daemons use a private data directory at
`<Fresh data directory>/fc-daemons/<session_id>`, with mode `0700`. The internal
`FRESH_FC_DATA_DIR` environment variable directs every native persistence store
there, including on macOS, where `XDG_DATA_HOME` alone does not redirect it.
Configuration and runtime socket locations remain the normal Fresh locations.
This keeps two named editors over the same project from sharing workspace state.

On first startup after this upgrade, the backend imports an old
`sessions/<session_id>.json` checkpoint, including tab order, active tab, cursor,
dirty files and untitled text. It writes native recovery and workspace state
before renaming the old record to `.json.imported`, retaining the original bytes
as a backup. A failed import is reported during the handshake and leaves the old
record intact. Recovery must be enabled to import. Subsequent starts use native
state, so the backup cannot resurrect tabs closed since the upgrade.

This pin uses upstream IPC protocol **4** plus a separate FC integration
capability **1**. It refuses live 0.2.3 backends and unpatched upstream backends
instead of silently losing the switch binding. Save and quit an existing old
editor before reconnecting with the new build; FC never kills it automatically.
The old binary cannot read the new native recovery store; `.json.imported` is a
pre-upgrade backup, not a continuously updated downgrade checkpoint.

Fresh is built from the exact revision in `dependencies.json` with
`cargo build --release --locked -p fresh-editor --bin fresh`, then staged under
`<build>/third_party/fresh/bin/fresh`. The default source checkout is
`../editor-fresh`. The committed [dependency bundle](../dependencies/README.md)
makes the integration changes reproducible without an unpublished remote fork.

The upstream baseline is `b10f9084f5eae571e9b8dac1a0f3694384bcb53d` (0.5.2 plus
40 commits), built with Rust 1.95. It includes the daemon recovery tick fix after
the 0.5.2 tag. FC's patch series also fixes cursor clamping before dirty-text
recovery and duplicate adoption of recovered untitled buffers. Fresh is now
GPL-3.0-or-later; the distribution includes its license, dependency manifest,
patch bundle, and reconstruction instructions.
