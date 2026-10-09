# Fresh integration

File Commander (FC) uses [Fresh](https://github.com/sinelaw/fresh) as its
editor. Fresh is a separate program licensed under GPL-3.0-or-later. FC starts
the `fresh` executable and talks to it only through its command line and its
session protocol; no Fresh code is linked into `fc`. This page is the contract
between the two programs. What users see (keys, what survives a crash) is in
the [editor guide](../editor.md).

Terms used on this page:

- **Backend**: the long-running Fresh server process (Fresh calls it a
  daemon). It owns tabs, buffers and recovery data, and outlives FC.
- **Client**: a short-lived `fresh` process that FC starts, either to send one
  command to the backend or to attach the terminal to it.
- **Editor identity**: the backend's session name. FC keeps one per
  configuration profile.
- **Workspace**: a Fresh window rooted at one filesystem location. A location
  is an endpoint (the local machine or an SSH host) plus a root directory.
  Local and SSH workspaces coexist in one backend.

Fresh owns tab closing, dirty-buffer prompts, saving and unsaved-text
recovery. FC never closes a tab or writes a file on the editor's behalf.

## Pinned revision

FC builds Fresh from revision `39a8f267c2b1934e8316923e025d035ecf5601f9` on
the `fc-editor-workflow` branch of the FC fork. Its upstream base is
`b10f9084f5eae571e9b8dac1a0f3694384bcb53d`, which is Fresh 0.5.2 plus 40
upstream commits; FC's integration commits sit on top. The pinned Rust
toolchain is 1.95 (`rust-toolchain.toml` in the Fresh checkout).
`dependencies.json` holds the authoritative values. The fork's changes, the
bundle and the source-reconstruction steps are described in
[dependencies/README.md](../../dependencies/README.md); licensing is in
[THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md).

A backend at this revision reports IPC protocol 4, FC integration level 1, and
the `fc_restart` and `fc_locations` capabilities (see
[Handshake and capabilities](#handshake-and-capabilities)).

## Building and packaging

With `FC_BUILD_FRESH=ON` (the default), CMake builds Fresh from
`FC_FRESH_SOURCE_DIR` with:

```sh
cargo build --release --locked -p fresh-editor --bin fresh
```

`FC_FRESH_SOURCE_DIR` defaults to the sibling checkout `../editor-fresh`; the
bootstrap layout passes `build-deps/fresh`. The binary is staged at
`<build dir>/third_party/fresh/bin/fresh`. Staging copies to a `.new` file and
renames it into place, because a backend started from the previous binary may
still be running. The staged path is compiled into `fc` as the build-time
default (`FC_FRESH_DEFAULT_BIN`).

If the checkout has no `Cargo.toml`, CMake warns and the build-time default
becomes a plain `fresh` looked up on `PATH`. Cross-compiling with
`FC_BUILD_FRESH=ON` is refused; build Fresh for the target separately.
Distribution packages put `fresh` next to `fc` in `bin/`. Configure checks the
checkout against the pin unless `FC_ALLOW_UNPINNED_DEPENDENCIES=ON`; see
[building.md](building.md).

## Finding the binary

FC resolves the binary every time it runs a Fresh command
(`EditorManager::resolved_binary` in `editor_manager.cpp`). The first source
that is set and non-empty wins:

| Order | Source | Notes |
| --- | --- | --- |
| 1 | `fresh_binary_path` in `settings.json` | In FC's configuration directory: `$XDG_CONFIG_HOME/file_commander/`, else `~/.config/file_commander/`. |
| 2 | `FC_FRESH_BIN` environment variable | |
| 3 | Bundled binary | A file named `fresh` next to the running `fc`; otherwise the build-time default. |

Values from rows 1 and 2 pass through `normalize_tool_reference` in
`runtime_paths.cpp`. "Executable directory" below means the directory of the
running `fc`, with symlinks resolved.

- **Absolute path**: used if the file exists. If it does not, a file with the
  same name in the executable directory is used instead, when there is one.
  Otherwise the path is used as given and the launch fails.
- **Relative path containing `/`** (or `\`), such as `bin/fresh` or
  `../editor-fresh/target/release/fresh`: resolved against the executable
  directory, never against FC's current working directory, then lexically
  normalized. The result is used whether or not the file exists.
- **Bare name** such as `fresh`: the file of that name in the executable
  directory if it exists; otherwise the bare name is left for `/bin/sh` to look
  up on `PATH`.

Use an absolute path for an override unless "relative to `fc`" is what you
mean.

## Editor identity

FC stores the identity in `editor_session.json` in the configuration
directory:

```json
{"version":1,"id":"fc-0123abcd-4567ef01-89abcdef","cwd":"/absolute/path"}
```

- `id` is created on first use: `fc-` followed by three groups of eight random
  hexadecimal digits. When reading, only letters, digits, `-` and `_` are
  accepted.
- `cwd` is the absolute directory the identity was created for. FC runs every
  Fresh command from it, or from its own current directory if `cwd` no longer
  exists.
- FC writes the record atomically before every open, switch, restart and
  attach. Creating or re-reading the identity holds an exclusive `flock` on
  `editor_session.json.lock`, waiting at most two seconds, so two FC processes
  on one profile share one identity.
- A record that cannot be read, is larger than 64 KiB, has another version, or
  has an invalid `id` or a relative `cwd` is never overwritten. Editor commands
  report that error until the file is repaired or removed.
- `settings.json` also saves `last_editor_session_id` on graceful exit. FC uses
  it only when `editor_session.json` does not exist.

## How FC runs Fresh

`EditorManager::run_command` starts each command as
`/bin/sh -c 'cd <cwd> && exec <fresh> <args...>'`, quoting every argument. The
child inherits FC's environment, with `FC_EDITOR_SWITCH_KEY` replaced by FC's
current value (see [Switch key](#switch-key)).

| Kind | Commands | stdin | stdout and stderr | Time limit |
| --- | --- | --- | --- | --- |
| Noninteractive | `open-location`, `prepare-restart` | `/dev/null` | Captured; up to 8 KiB becomes the error text | 25 s |
| Interactive | `-a` (attach) | FC's terminal | FC's terminal | None |

Noninteractive commands run in their own process group. Their stdin is
`/dev/null` because upstream Fresh may attach automatically when stdin is a
terminal; only FC's explicit attach may own the terminal. When the 25-second
limit expires, FC sends `SIGKILL` to that process group and reports exit 124.
The backend is unaffected because Fresh starts it in its own Unix session.

Before an attach, FC checkpoints its own `workspace.json` and hands the
terminal back to normal I/O; it resumes its UI when the client exits. If FC is
told to shut down while a client runs, it sends that client `SIGTERM`, then
`SIGKILL` after one second. The backend keeps running.

### Commands

```text
fresh --cmd session open-location <id> <target> <root> <control-path> [files...]
fresh -a <id>
fresh --cmd session prepare-restart <id> [--allow-legacy-checkpoint]
```

`open-location` starts the backend if needed, then routes a location to its
workspace and queues the file opens. FC fills the arguments like this:

| Argument | Local location | SSH location |
| --- | --- | --- |
| `target` | `-` | The endpoint: an SSH config alias or `user@host` |
| `root` | Absolute directory | Absolute directory on the host |
| `control-path` | `-` | OpenSSH control socket for that endpoint (`RemoteFS::control_path`); Fresh passes it to its own `ssh` as `-o ControlPath=...` |
| `files` | Absolute canonical paths | Absolute paths on the host |

FC chooses the root as follows:

- **Directory open**: the directory itself, with no files. FC then attaches.
- **Local file open**: the identity's `cwd`.
- **SSH file open**: `/` on that host. Files from several hosts become one
  `open-location` call per host.

Exit 0 means the backend accepted the location and queued the opens. A remote
workspace then connects asynchronously; connection errors appear inside Fresh,
not in FC.

`-a` attaches the terminal, starting the backend first if it is not running.
FC uses it for every switch to the editor and after each successful
`open-location` or restart.

`prepare-restart` is described under [Backend restart](#backend-restart).

### Exit codes

| Code | Source | Meaning to FC |
| --- | --- | --- |
| 0 | `open-location` | Location routed and opens queued. |
| 0 | `prepare-restart` | The old backend has stopped, or was not running. |
| 0 | `-a` | The client detached or the editor quit. |
| 20 | `prepare-restart` | The backend cannot confirm a restart checkpoint. Nothing was stopped; FC asks for legacy consent. Returned only without `--allow-legacy-checkpoint`. |
| 124 | FC | FC killed a noninteractive command after 25 s. |
| 126, 127 | `/bin/sh` | The binary is not executable, or was not found. |
| 128 + N | FC | The command was killed by signal N. |
| Other nonzero | Fresh (usually 1) | Failure. FC shows the captured output, or a generic message with the exit code. |

A failed attach is reported as `Failed to attach session '<id>' (exit N)`. The
identity is kept, so the next attempt retries the same backend.

## Handshake and capabilities

Every Fresh client opens the backend's control socket and exchanges a hello
message. At the pinned revision the backend's hello carries:

| Field | Value | Meaning |
| --- | --- | --- |
| `protocol_version` | 4 | Upstream IPC protocol. |
| `fc_integration` | 1 | The backend honors `FC_EDITOR_SWITCH_KEY` per client. Upstream backends report 0. |
| `fc_restart` | true | The backend supports a checkpoint-confirmed restart. Independent of the protocol version. |
| `fc_locations` | true | The backend accepts `open-location` routing. |

FC itself never reads these fields; the Fresh client enforces them and FC
interprets the exit code:

- `open-location` requires `fc_locations` and the requested session name.
  Otherwise it fails with a message telling the user to run **Restart editor
  backend**.
- A client that has `FC_EDITOR_SWITCH_KEY` set (every client FC starts) refuses
  a backend with `fc_integration` other than 1, and any protocol mismatch, and
  asks the user to save and quit the old editor. This keeps an old or upstream
  backend from silently ignoring FC's switch key.
- When a backend fails to restore its state on first connection, including a
  failed legacy import, it sends an error instead of the hello. FC never
  mistakes a failed restore for a successful open or attach.

FC never kills an incompatible backend or removes its sockets.

## Timeouts

| Bound | Enforced by | On expiry |
| --- | --- | --- |
| 25 s for each noninteractive command, including all of Fresh's waits below | FC | `SIGKILL` to the command's process group; exit 124 |
| 2 s for the identity lock | FC | `Editor identity is busy; try again` |
| 10 s for the backend startup lock (`<id>.start.lock` in Fresh's socket directory) | Fresh client | Error |
| 10 s for a backend this client spawned to become ready | Fresh client | `SIGKILL` to that spawned backend only, so a late start cannot replace a retry's sockets; error naming its log |
| 10 s for each handshake or acknowledgement read | Fresh client | Error |
| 10 s for the old backend to exit after `prepare-restart` | Fresh client | Error; the backend is never force-killed |
| None for interactive editing (`-a`) | | |

## Session data isolation

When a Fresh client with `FC_EDITOR_SWITCH_KEY` in its environment starts a
backend for a named session (`server/daemon/unix.rs` in Fresh), it:

1. creates `<Fresh data dir>/fc-daemons/<id>` with mode `0700`;
2. sets `FRESH_FC_DATA_DIR` to that directory in the backend's environment;
3. sets `FC_LEGACY_CHECKPOINT` to `<Fresh data dir>/sessions/<id>.json` (see
   [Legacy checkpoint import](#legacy-checkpoint-import)).

`<Fresh data dir>` is Fresh's normal data directory: `$XDG_DATA_HOME/fresh` or
`~/.local/share/fresh` on Linux, `~/Library/Application Support/fresh` on
macOS. `FRESH_FC_DATA_DIR` must be absolute. Fresh returns it from its single
data-directory lookup, so every native store (workspaces, recovery) moves
there on every platform. Setting `XDG_DATA_HOME` alone would not do this on
macOS. Fresh configuration and runtime sockets stay in their normal locations.
The effect is that two FC profiles, or FC and a standalone Fresh, editing the
same project do not share workspace state.

With `FRESH_FC_DATA_DIR` set, Fresh also changes two recovery rules:

- Recovery data for large files is a complete snapshot rather than changed
  chunks relative to the file on disk, so unsaved text survives replacement or
  deletion of the source. The memory and I/O cost is that of a full copy.
- A snapshot is restored as unsaved text even when the file changed on disk.
  The disk version is left alone and Fresh logs a warning; the user reviews
  before saving.

Both variables are internal. Do not set them by hand.

The backend checkpoints recovery data for dirty and untitled buffers, plus
workspace state, every two seconds and whenever a client detaches. It never
writes source files while checkpointing.

## Idle shutdown

The backend reads `FRESH_SESSION_IDLE_TIMEOUT_SECS` from its environment when
it starts. It inherits the variable from the client that started it, which
inherits FC's environment. The value is whole seconds; a missing, zero or
unparsable value means 3600. Changing it affects only backends started
afterwards.

A backend shuts down when no client is attached (a browser on Fresh's web
bridge counts as one), no buffer is modified, no client has been active for
longer than the timeout, and a final checkpoint succeeds. If that checkpoint
fails, it keeps running and tries again after another full timeout.

## Switch key

FC sets `FC_EDITOR_SWITCH_KEY` on every Fresh command to its own key token for
the `switch_to_file_commander` command (`f10` by default; set again whenever
key bindings change). The Fresh client forwards it in its hello, and the
backend compares each key press from that client against it. A match detaches
only that client. Other clients and the global Fresh keymap are unaffected.

The backend accepts these tokens: `f1` to `f12`; `<-`, `->`, `up`,
`down`, `back`, `del`, `esc`, `ret`, `tab`, `stab`; `c<-`, `c->`, `cup`,
`cdown` (Ctrl+arrow); `cX` (Ctrl+letter) and `aX` (Alt+letter) with an
uppercase letter; and single characters. An unknown token leaves the client
with no switch key. The parser is `fc_switch_key` in Fresh's
`server/editor_server.rs`.

## Backend restart

The palette command **Restart editor backend** (`restart_editor_backend`, no
default key) replaces a running backend with one started from the binary FC
resolves now. Its dialog starts with Cancel focused.

1. FC runs `prepare-restart <id>`.
2. The client takes the startup lock and probes the backend. If it is not
   running, the client removes stale sockets and exits 0. If its socket exists
   but cannot be reached, it fails.
3. **Current backend** (protocol 4, `fc_integration` 1, `fc_restart`): the
   client asks it to restart. The backend refuses, and keeps running, unless
   this client is the only one attached and workspace persistence,
   `restore_previous_session` and recovery are all enabled. Otherwise it
   rewrites every unsaved and untitled snapshot, saves workspace state,
   confirms with `Restart checkpoint saved`, and exits.
4. **Older backend** that cannot confirm a checkpoint (a protocol-4 backend
   with FC integration but without `fc_restart`, or the earlier 0.2.3-based
   integration, which answers protocol 4 with a version mismatch): the client
   exits 20 without stopping it. FC shows a second confirmation warning that
   recent edits may be lost. Only if the user agrees does FC rerun the command
   with `--allow-legacy-checkpoint`, which sends a plain quit (over protocol 2
   for 0.2.3) and relies on that backend's last checkpoint. Consent applies to
   that dialog only and is reset when it reopens.
5. A backend without FC integration is refused: the user must save and quit
   it.
6. After a quit or restart request, the client waits up to 10 seconds for the
   backend to exit, and fails if the PID changes meanwhile. It never signals a
   live backend or removes its sockets.
7. On exit 0, FC closes the dialog and runs `fresh -a <id>`. That starts a new
   backend, which restores the workspace and unsaved text from the private
   data directory.

Undo history is not checkpointed, and processes running in Fresh's embedded
terminals are not carried over. Restart never saves unsaved text to source
files.

## Legacy checkpoint import

The earlier FC integration (based on Fresh 0.2.3) kept its own checkpoint at
`<Fresh data dir>/sessions/<id>.json`. When a backend initializes on its first
client connection, it reads `FC_LEGACY_CHECKPOINT` (or, if that is unset, the
same name under its own data directory). If the file exists:

1. It must be checkpoint version 1, and Fresh recovery must be enabled.
2. Fresh restores the tabs and their order, the active tab, cursors, dirty file
   text and untitled text.
3. It writes native recovery and workspace state.
4. Only then does it rename the file to `<id>.json.imported`, keeping the
   original bytes as a backup.

Any failure is reported to the client in place of the handshake, and the
original file stays where it was. Later starts use native state only, so the
backup cannot bring back tabs closed after the upgrade. The old binary cannot
read the native store; `.json.imported` is a one-time pre-upgrade backup, not a
downgrade path.

## Environment variables

| Variable | Set by | Read by | Purpose |
| --- | --- | --- | --- |
| `FC_FRESH_BIN` | User | FC | Binary override; see [Finding the binary](#finding-the-binary). |
| `FC_EDITOR_SWITCH_KEY` | FC, on every Fresh command | Fresh client and backend | Per-client switch key; also marks clients started by FC. |
| `FRESH_SESSION_IDLE_TIMEOUT_SECS` | User, in FC's environment | Fresh backend | Idle shutdown for clean sessions. |
| `FRESH_FC_DATA_DIR` | Fresh client starting an FC backend | Fresh backend | Private data directory. Internal. |
| `FC_LEGACY_CHECKPOINT` | Fresh client starting an FC backend | Fresh backend | Legacy checkpoint path. Internal. |

## Upgrading the Fresh pin

1. Commit the Fresh change on `fc-editor-workflow`, regenerate the bundle and
   update `dependencies.json` as described in
   [dependencies/README.md](../../dependencies/README.md). Update the revision
   named at the top of this page.
2. Keep the new client compatible with the previous pin's backend:
   - `prepare-restart` must still be able to stop it. Otherwise users cannot
     move a running editor to the new build without quitting it. If you raise
     the protocol version, teach `prepare-restart` the previous one, as it
     already handles 0.2.3 over protocol 2.
   - Keep the `fc_integration`, `fc_restart` and `fc_locations` hello fields,
     and the switch-key token syntax.
   - Keep `open-location` arguments and exit codes, or change
     `editor_manager.cpp` in the same FC commit.
3. If the upstream base moved, check `rust-toolchain.toml` and update the Rust
   version wherever it is documented.
4. Rebuild and run the Fresh-labeled tests with
   `ctest --preset release -L fresh`. They include `fc.harness.fresh_bundle`, which rebuilds the pinned
   revision from the upstream base and the bundle alone, and the terminal,
   recovery, restart, workspace-recovery and SSH editor tests that drive the
   real binary.
5. A running backend keeps using the old binary until the user runs **Restart
   editor backend**.
