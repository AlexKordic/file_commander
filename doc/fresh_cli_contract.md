# Fresh CLI contract for File Commander

FC owns one persistent editor identity per configuration profile. Directory and file opens reuse that identity and route to a filesystem
workspace without closing existing tabs. Local and SSH workspaces coexist in
one backend; endpoint and root jointly identify the workspace.
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
- In FC, `F1` opens the palette. **Restart editor backend** checkpoints and
  restarts the same editor identity using the installed Fresh binary, then
  switches to it. It has no default shortcut; it can be rebound in the palette.

### Explicit backend restart

The restart dialog defaults to Cancel. A supporting backend confirms that it
wrote dirty/untitled recovery and workspace state before stopping. A failed
checkpoint or disabled recovery/restore setting leaves it running. Other
attached clients must detach first. Restart does not save unsaved text over
source files; undo history and running embedded shell processes do not survive
the process restart.

Older FC-integrated backends (including the previous 0.2.3 pin) require a second
confirmation: **restart using the available checkpoint, accepting that recent
edits may be lost**. Cancel allows the user to save and quit first. Consent is
specific to that invocation and is not remembered after closing the dialog.
The command requests ordinary shutdown over the matching protocol; it never
force-kills a backend or removes live sockets. Failure to stop is shown in FC.

FC invokes `fresh --cmd session prepare-restart <id>` with noninteractive stdin
and captured diagnostics. Exit 0 means the old backend has stopped (or was
already absent); FC then attaches with the installed binary. Exit 20 requests
legacy confirmation without stopping the editor. Only explicit confirmation
adds `--allow-legacy-checkpoint`. All other failures retain the dialog and show
the diagnostic. The new handshake's `fc_restart` capability is independent of
IPC protocol 4 and the existing FC integration capability.

## Invocation and identity

Binary resolution is `fresh_binary_path` in FC settings, then `FC_FRESH_BIN`,
then the bundled build-time default. Relative overrides are normalized before
changing directories.

The profile's `editor_session.json` stores a stable ID and original working
directory. FC writes it atomically before launching the editor, and a short
process lock prevents concurrent identity creation. Restarting FC reconstructs
this identity; a missing original directory uses a valid launch fallback.

Local file opens use absolute canonical paths; SSH opens use absolute paths on
the selected host. FC passes the filesystem identity explicitly:

```text
fresh --cmd session open-location <session_id> <target-or-minus> <root> <control-path-or-minus> [abs_files...]
fresh -a <session_id>
```

Switching attaches. Directory opens route an empty file list to that root, then
attach. `-` identifies the local filesystem. SSH file opens use `/` as the
workspace root; SSH directory opens use the selected directory. FC restores
terminal IO around attachment and resumes its own terminal after detach.

Exit `0` means the location was routed and queued. The handshake requires
`fc_locations`; an older running backend reports that Restart editor backend
is needed. A queued remote open connects asynchronously, with connection errors
shown inside Fresh.
The open command receives `/dev/null` as stdin: upstream may auto-attach on its
first file open when stdin is a terminal. Only FC's explicit attachment owns the
terminal. Startup lock acquisition and daemon readiness are each bounded to ten
seconds, the handshake to ten seconds, and FC's entire noninteractive command
to 25 seconds. A readiness timeout stops only the backend spawned by that attempt, allowing a
retry without a competing late startup. Interactive editing has no duration limit. Failed attachment
retains the identity for retry and reports the failure.

## Recovery and dependency

The backend runs in its own Unix process session. It checkpoints native Fresh
recovery data and workspace state every two seconds and on detach; native exit
persistence handles shutdown. Recovery stores dirty and untitled text separately
from source files. A crash can lose edits since the last successful checkpoint.
FC keeps self-contained snapshots of dirty buffers, including large files, so
external replacement or deletion of a source does not discard unsaved text.
Recovery leaves the disk version untouched and warns when it changed; review
before saving. This retains the old integration's full-snapshot memory/I/O cost.
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
record intact. Recovery must be enabled to import and remain enabled for unsaved-buffer crash
recovery. Subsequent starts use native
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
makes the integration changes reproducible from the pinned upstream base. The
same history is published in the
[`fc-editor-workflow` branch](https://github.com/AlexKordic/fresh/tree/fc-editor-workflow)
of the Fresh fork.

The upstream baseline is `b10f9084f5eae571e9b8dac1a0f3694384bcb53d` (0.5.2 plus
40 commits), built with Rust 1.95. It includes the daemon recovery tick fix after
the 0.5.2 tag. FC's patch series also fixes cursor clamping before dirty-text
recovery and duplicate adoption of recovered untitled buffers. Fresh is now
GPL-3.0-or-later; the distribution includes its license, dependency manifest,
patch bundle, and reconstruction instructions.

See [SSH workflow](ssh_workflow.md) for remote persistence, transfer contracts
and native qualification.
