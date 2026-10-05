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

Exit `0` means success; `2` from `session open-file` means a new backend started
and is also successful. Other statuses are failures. Startup is serialized and
bounded to ten seconds, the handshake to ten seconds, and FC's noninteractive
open command to 25 seconds. Interactive editing has no duration limit. Failed
attachment retains the identity for retry and reports the failure.

## Recovery and dependency

The pinned Fresh backend runs in its own Unix process session. It checkpoints
named sessions every two seconds and on detach/clean shutdown, using an atomic
private JSON file under Fresh's data directory at `sessions/<id>.json`. This
stores workspace/tab state and recoverable dirty and untitled text separately
from source files. After abrupt backend loss, edits since the last successful
checkpoint can be lost. A failed restore retains the checkpoint and reports an
error instead of overwriting it.

Dirty buffers prevent idle shutdown. Clean sessions default to a one-hour idle
timeout; `FRESH_SESSION_IDLE_TIMEOUT_SECS` can adjust that positive duration.
Protocol version 2 rejects older backends that lack this integration. Save work
and quit such an old editor explicitly before reconnecting with the new build.

Fresh is built from the exact revision in `dependencies.json` with
`cargo build --release --locked`, then staged under
`<build>/third_party/fresh/bin/fresh`. The default source checkout is
`../editor-fresh`. The committed [dependency bundle](../dependencies/README.md)
makes the integration changes reproducible without an unpublished remote fork.
