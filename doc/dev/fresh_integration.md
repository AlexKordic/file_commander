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

FC builds Fresh from revision `84814897b187ab8ccd19dca0fc012e7480229b14` on
the `fc-editor-workflow` branch of the FC fork. Its upstream base is
`b10f9084f5eae571e9b8dac1a0f3694384bcb53d`, which is Fresh 0.5.2 plus 40
upstream commits; FC's integration commits sit on top. The pinned Rust
toolchain is 1.95 (`rust-toolchain.toml` in the Fresh checkout).
`dependencies.json` holds the authoritative values. The fork's changes, the
bundle and the source-reconstruction steps are described in
[dependencies/README.md](../../dependencies/README.md); licensing is in
[THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md).

A backend at this revision reports IPC protocol 4, FC integration level 1, the
`fc_restart` and `fc_locations` capabilities, and, for an FC session, its scene
socket in `fc_scene` (see [Handshake and capabilities](#handshake-and-capabilities)
and [Scene channel](#scene-channel)).

## Building and packaging

With `FC_BUILD_FRESH=ON` (the default), CMake builds Fresh from
`FC_FRESH_SOURCE_DIR` with:

```sh
cargo build --locked -p fresh-editor --bin fresh --features web \
  --profile fc-release --config 'profile.fc-release.inherits="release"' \
  --config 'profile.fc-release.opt-level=3'
```

The `web` feature builds Fresh's scene bridge, which an FC session serves to the
macOS app's native editor ([Scene channel](#scene-channel)). A Fresh
built without it still works with FC: the app then runs `fresh -a` in a
terminal view.

`fc-release` is FC's own Cargo profile, defined on the command line: Fresh's
release profile (fat LTO, one codegen unit) with `opt-level` 3 in place of
Fresh's `"z"`, which optimizes for size. Building a scroll frame for the
native editor takes 2–3 ms instead of 5–6 ms, and a frame reaches the app in
5–7 ms instead of 10–12 ms; the binary is about 45 MB instead of 34 MB. The
output goes to `target/fc-release/fresh`, so FC's builds and a plain
`cargo build --release` in the same checkout don't rebuild each other's
output.

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
fresh --cmd session ensure <id>
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
The terminal interface uses it for every switch to the editor and after each
successful `open-location` or restart.

`ensure` starts the backend if it is not running, routes nothing, and prints one
JSON line: `{"scene":"<socket path>","pid":N}`, or `"scene":null` when the
backend serves no scene. The macOS app runs it where the terminal interface
attaches, and connects its native editor to the socket; with no scene it falls
back to `-a` in a terminal view.

The commands FC runs to completion (`open-location`, `ensure`,
`prepare-restart`) say `fc_control` in their hello. Such a client never becomes
the terminal that sizes the shared grid, so opening a file doesn't briefly
shrink the editor someone is looking at.

`prepare-restart` is described under [Backend restart](#backend-restart).

### Exit codes

| Code | Source | Meaning to FC |
| --- | --- | --- |
| 0 | `open-location` | Location routed and opens queued. |
| 0 | `prepare-restart` | The old backend has stopped, or was not running. |
| 0 | `ensure` | The backend runs; stdout names its scene socket or `null`. |
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
| `fc_scene` | socket path, or absent | The Unix socket this session serves its scene on. Only sessions an FC client started have one, and only in builds with the `web` feature. |

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

## Scene channel

A session an FC client started (`FC_EDITOR_SWITCH_KEY` set, so the backend has
`FRESH_FC_DATA_DIR`) also serves its scene to the macOS app's native editor,
on a Unix socket: `<socket dir>/<id>.scene.sock`, next to the session's own
sockets, in the owner-only socket directory, with the socket itself at mode
`0600`. Nothing listens on the network. The backend binds it during the first
handshake, once that handshake has built the editor (so a failed restore is
still reported in place of the hello), replaces a stale file, and removes it on
exit. Its path is `fc_scene` in every handshake and what `ensure` prints.

The socket carries protobuf messages in a type-length-value stream; there is
no HTTP, no WebSocket and no JSON (`SceneBridge`,
`crates/fresh-editor/src/webui/scene_bridge.rs`). Fresh's browser front end
keeps its own JSON protocol over TCP and is not affected.

- **Framing**: each message is `type | length | payload`. Type and length
  are varints (protobuf's unsigned LEB128, minimally encoded, at most ten
  bytes); the payload, at most 16 MiB, is a message of
  `crates/fresh-editor/src/webui/scene.proto` (package `fresh.scene.v1`).
  Fresh writes its messages with a hand-written encoder
  (`crates/fresh-editor/src/webui/wire.rs`), and a test keeps the schema
  equal to it. The app's types are generated from the schema
  (`macos/tools/gen_scene_proto.sh`, SwiftProtobuf).

  | Type | Message | Direction | Carries |
  | --- | --- | --- | --- |
  | 1 | `ServerHello` | to the app | The protocol version and the whole scene, as a `Frame` |
  | 2 | `Frame` | to the app | What changed since the app's previous frame |
  | 3 | `Error` | to the app | Why Fresh is closing the connection |
  | 16 | `ClientHello` | to Fresh | The protocol version; `telemetry` asks for frame timing |
  | 17 | `Key` | to Fresh | A browser key name (`key`), the physical key (`code`), `ctrl`, `alt`, `meta`, `shift` |
  | 18 | `Mouse` | to Fresh | `kind`, `button`, the cell (`col`, `row`), `n` wheel notches, the click `count`, modifiers |
  | 19 | `Resize` | to Fresh | The grid size the app wants (`cols`, `rows`) |
  | 20 | `Paste` | to Fresh | Text to paste |
  | 21 | `Action` | to Fresh | A Fresh action by name, with a menu item's arguments (`args_json`) |
  | 22 | `Widget` | to Fresh | A click on a surface's widget |
  | 23 | `SettingsClick` | to Fresh | A click in the Settings modal |
  | 24 | `KbEditClick` | to Fresh | A click on a row of the key binding editor |
  | 25 | `Configure` | to Fresh | Frame timing on or off |
  | 26 | `Applied` | to Fresh | The last frame the app applied (`seq`) |

- **Hello**: the app sends `ClientHello` first. Fresh answers with
  `ServerHello`, or, for another protocol version, with `Error` and closes the
  connection. There is one version (1) and no negotiation: the app speaks
  what the Fresh it is pinned to speaks.
- **Frames**: a field is present only when it changed: `width`, `height`,
  `window_id`, `theme`, `clipboard`, `cursor`, `grid_len`, `copies` and
  `rows`, `pane_len` and `panes` (by index), and one update per region
  (menus, status bar, file explorer, separators, popups, palette, trust
  dialog, context menu, key binding editor, Settings): present when the
  region changed, without its `value` when the region is gone. The frame is
  the grid of cells, chrome included; panes carry their geometry and tab bar,
  not cells, and the menu row is left out while no menu is open (the app has
  the menus in the menu bar). A `GridRow` has its `text` once and its runs as
  byte lengths into it (`run_bytes`), each with a packed style (`run_styles`:
  `fg | bg << 25 | flags << 50`, a color being `0x1RRGGBB` and 0 the
  terminal default, the flags bold 1, italic 2, underline 4, reverse 8); a
  wide character is followed by the blank cell it covers. `copies` names rows
  the app already has, as `[to, from, count]` triples: rows `to..to+count`
  become its previous rows `from..from+count`, applied before the rows sent
  in full, so a scroll sends only the rows that came into view.
- **JSON**: the only JSON is a menu action's `args_json`, the keymap's
  arguments for the action, which the app hands back untouched in `Action`.
- **Encoding**: each push encodes every region, pane, the theme and the
  clipboard once and hashes them; a client's frame takes the bytes of what
  changed since its previous frame. Rows are written from the cells. Once the
  buffers have grown, encoding a push allocates nothing (`scene_golden` checks
  this in a build with `alloc-stats`).
- **Timing**: with telemetry, each frame carries `timing`: `ack` (how many
  of this client's messages were applied before it was built), `build_ms`
  (of it `render_ms`, rendering the editor, and `grid_ms`, hashing the grid's
  rows), `encode_ms`, `queued` (bytes of earlier frames still waiting for the
  socket ahead of it), `ahead` (earlier frames the client had not applied),
  `owed` (wheel lines smooth scrolling still owes), `top` (the active view's
  top line, 0-based) and `cpu_ms` (Fresh's CPU time so far). A Fresh built
  with the `alloc-stats` feature, which counts heap allocations per thread,
  also reports `prev_allocs` and `prev_alloc_bytes`: those of the previous
  push, from building its scene to queueing its frames.
- **Keys**: a `meta` (`⌘`) chord resolves through Fresh's `macos-gui` keymap
  in the current key context, so `⌘S` saves and `⇧⌘P` opens the palette, while
  the user's keymap keeps every other key for this client and the terminals.
- **Pacing**: a frame answering the client's own input is pushed in the same
  pass (about 10 ms from key to frame); time-driven frames go at most every
  40 ms. While a client is connected the loop polls every 3 ms. The socket
  has 4 MiB buffers each way (macOS's 8 KiB default made frames queue up). The
  app reports every frame it applies, and Fresh keeps at most two frames
  unapplied: while the app is behind, Fresh builds nothing, and when it
  catches up it gets one frame with the newest scene. An app that stops
  reporting gets a frame again after 500 ms (see
  [macos_app.md](macos_app.md#frames-and-the-app)).
- **Sizing and liveness**: the shared grid fits the smallest viewport among
  the primary terminal and the scene clients. A connection ends when either
  side closes it; an app that stops reading with 8 MiB of frames waiting is
  dropped.

A connected scene client counts as attached: the session does not shut down
idle, and `prepare-restart` refuses while one is connected, so the app
disconnects its window before Restart Editor Backend and reconnects after.

### Experimental rich Compose

The native development path can request rich Compose with
`FC_NATIVE_RICH_COMPOSE=1`. It requires a matching development backend and
consumer; the packaged Fresh pin has not been advanced for this experiment.
Grid Compose remains the default. Terminal clients keep their cell layout.

The experimental client hello opts into source-preserving Compose projections.
Fresh owns source buffers, selections, undo, saving, and filesystem authority;
the native consumer measures text and images with Core Text. Source coordinates
are UTF-8 bytes, and native layout feedback is scoped to a window, split,
buffer, source revision, projection revision, and selection revision.

The semantic spans distinguish heading levels, inline and fenced code,
tables, quotes, lists, items, and paragraphs. Overlapping spans retain nested
structure, emphasis, link, underline, and strikethrough information; the
native client does not parse Markdown. Core Text measures indentation and
spacing before producing caret, selection, and navigation geometry. Font
and spacing changes replace that client's style revision and preserve its
source scroll anchor. Code and table fonts remain monospaced.

`ComposePane.ready` distinguishes a coherent projection from formatting still
being applied. Readiness correlates the source revision, window, buffer
lifetime, and a token assigned by the host to each batch of lines. Commands
may span several editor ticks; offering lines or receiving a hook-name-only
acknowledgment is not enough. Tracked source decorations apply to their
original owner even after workspace focus changes. Edits invalidate the
affected ranges and shift unaffected completed ranges without rebuilding them.

Pending snapshots contain a raw copy map, never partially applied conceals.
The native pane holds its previous presentation with its source map and
revisions, and queues document input until the current projection is ready.
An accepted edit's caret reveal can wait for readiness; a later physical
scroll still takes precedence.
Offscreen measurements remain demanded until their completion can wake the
pending input. Failed formatting, missing coverage, or the prototype's
formatting deadline of five seconds produces an explained, editable source
fallback.
Fallback editing does not restart that wait on every character. A successful
new formatting batch can restore rich presentation. These timing and resource
bounds still need validation against representative documents before release.

- Type 27, `ComposeInput`, serializes document commands and returns an
  `InputReply`. Accepted and cancelled requests are terminal and consume their
  sequential id; a nonterminal rejection retains its id for refreshed geometry.
  A cancelled request includes an explanation and cannot run later. A buffer
  lifetime token prevents queued input from addressing a replacement buffer
  with the same numeric id. Modal UI input remains separate from a deferred
  document command.
- Pointer input captures a source position, affinity, and source revision when
  the event occurs. Fresh rebases that position through its edit history. The
  consumer never hit-tests a queued screen point against a newer layout.
  Unmappable positions, changed image annotations, and retired targets terminate
  explicitly rather than selecting unrelated text or holding up later input.
- Type 29, `ComposeViewportRequest`, updates a per-client source marker and
  pixel offset. Its acknowledgments and coalescing are independent of the text
  input queue. It changes neither the source cursor nor the terminal viewport.
  Geometry needed outside the visible region travels in a separate Compose
  projection in the input reply, so measuring a pending command does not move
  the reading position.
- Type 28, `ComposeAssetRequest`, identifies a parsed image annotation rather
  than accepting a client-supplied path. Fresh reads it through the document's
  local or SSH filesystem and sends bounded binary chunks. The native consumer
  bounds assembly, decoding and cache use. `known_version` and `known_digest`
  carry binary validators. The final successful chunk supplies its version and SHA-256
  digest; an `unchanged` reply contains no image payload. Partial chunks cannot
  carry those final validators. An unchanged reply must name the requested
  digest and cannot follow partial data.

Image annotations distinguish `rendered` attachments from `source_preview`.
Entering image-source editing reveals the entire original markup, including
nested emphasis or table-cell conceals. Its preview occupies measured space
below that text without inserting characters or caret positions. Preview
clicks address the same image source range. Selection, copy, cut, paste and
undo use Fresh's Markdown source, including reference syntax; they do not
copy the graphical object or relocate its asset. Pending/fallback projections
set neither image presentation flag. Invalid markup remains editable source
and may no longer have a parsed preview until it becomes a valid image again.

List-item spans carry optional `content_start`: the source-byte position of
the first body content on the opening line, after a list/task marker. It is
derived from Markdown parser events, including tight lists, quoted items,
parenthesized ordered markers and empty items. The native client maps that
anchor into the projection and measures the prefix with its actual styled
font and shaping context. Continuation text, caret/hit geometry, navigation
and image sizing use that same content measure. Existing indentation on a
physical continuation line is charged once. Source windows without the complete
prefix and multiline cell replacements still need block-context qualification;
the client never treats a partial prefix as the original marker.

The rich projection omits setext underline lines while their heading is being
read and reveals their exact source when a cursor enters the heading. Active
terminal quote-bar replacements are removed only within parsed quotes; source
editing and literal code remain source text. Existing quote-flow joins stay
intact, except that a parsed thematic rule receives its own native line.
Span role 14 identifies a thematic rule: its hidden source range reserves a
source-mapped line for native drawing, with no repeated ruler characters.
EOF rules reveal when the caret reaches their collapsed source end. These are
per-client projection overrides; terminal conceals and markers are unchanged.

Native text-service replacements use `ComposeInput.replacement_start` and
`replacement_end` as UTF-8 source bounds, with `source_revision`, `buffer_epoch`
and `replacement_cursor`. The range and cursor are captured before queued
input or reflow. Fresh rebases unaffected ranges and cancels replacements
whose contents changed, whose history expired, or whose cursor/view no longer
exists. Boundary insertions remain outside a nonempty replacement. Empty text
deletes its range. Read-only documents reject both replacements and literal
text input; terminal cancellations consume their request IDs.

Additional `ComposeInput.replacements` capture secondary cursor IDs and source
ranges, optionally overriding the common text. Fresh validates and rebases
every target before applying one undo transaction. A missing cursor, changed
range, duplicate cursor or overlapping target cancels the whole operation.
New carets created after capture do not join an existing composition.

`text_input` marks an ordinary committed phrase applied once to the current
selections in its captured view. It uses Fresh's normal event/undo machinery
and line-ending policy without clipboard column distribution. Plain clipboard
paste keeps that distribution.

`ComposePane.text_context` supplies raw Markdown near the primary caret for
unmarked native text services. `source_start` is a buffer-wide UTF-8 byte
offset; `utf16_start` and the selection bounds are buffer-wide source UTF-16
offsets. They remain independent of concealment, font layout and the visible
source window. A sparse UTF-16 index is built with each parsed source revision;
caret movement does not recount the complete document. The current context
is bounded to at most 8 KiB around the caret, even for a very large selection.
The native client can replace the complete captured primary selection using
its cursor's byte bounds; arbitrary ranges outside the known context are
refused. Context queries can return a bounded, grapheme-adjusted result or nil.
Secondary carets receive document-wide UTF-16 positions and coalesced raw
`text_chunks` around their source positions. Nearby carets share each chunk;
these additional windows together cannot exceed the parsed document size.
The accessibility value and its selection retain display-relative coordinates.
Native rich Compose keeps marked text as a provisional replacement over that
immutable source snapshot. Partial updates, marked/selected subranges and
context queries use provisional document UTF-16 positions. The same measured
layout draws the replacement, underline and selection and positions the caret
and candidates. Provisional geometry never travels back as Fresh navigation
feedback. A new source revision cannot relabel the captured replacement.
`insertText` or `unmarkText` commits once through the captured source range;
explicit cancellation leaves the source unchanged. Losing the target view,
buffer lifetime or cursor cancels the composition into native recovery text.
Modal UI can defer its committed replacement using the existing input ID.

`ComposeComposition` captures all current carets for the default marked-text
operation. An explicit initial replacement range addresses only the primary.
Each target retains its own source range and surrounding context. Provisional
document positions include length changes from earlier carets, even offscreen.
Partial updates validate every target on copies; intersecting expansions are
refused without changing any draft. Commit sends one replacement batch;
retiring any captured cursor recovers the composition without editing a subset.
Recovery retains distinct draft variants when surrounding source differs.

Uninserted text is retained in FC memory for the application session and can
be copied explicitly from **Edit > Copy Uninserted Text**, including after
disconnection. Failure never overwrites the system clipboard, and copying
does not erase the retained text. This is not a persistent crash checkpoint.
Consecutive compositions while edits await replies,
interactive input-method behavior and recovery qualification remain open;
this development implementation does not establish full IME support. Context
sizing and scene traffic still need performance qualification before release.

Native Compose must wrap using measured fonts and available pixel width.
Terminal Markdown column counts, padded or truncated table replacements and
character-sized frames are not a native layout contract. Parsed tables
currently bypass those terminal conceals, retaining editable source, semantic
fonts and image overrides. Native list prefixes also bypass terminal indent
expansion. Measured native table cells remain unfinished. The native default
uses all available pane width; a reading limit is optional and measured in points.

For native code blocks, Fresh records the source ranges owned by the Markdown
parser's code-text events. Gaps identify fences and container prefixes; these
hide while reading and reveal on the edited source line. Hidden delimiter
lines do not add empty header/footer rows. All parser-owned code content,
including its original CR/LF bytes, remains copied and individually
addressable. An empty fence without a terminator uses a native
line placeholder without editing the buffer. Terminal decorations are unchanged.
FC draws code frames from measured fragments, with native insets and wrapping,
separate from inline code backgrounds. Code within a list uses its block
inset instead of the list's hanging marker. A first-line list marker stays
outside the frame, and clipped blocks retain open boundary edges. Selection,
navigation and provisional text share the inset font geometry. The real-plugin
`compose-code.pb` fixture covers nested quotes/lists, empty and unclosed fences.

The table transport is a separate, experimental capability:
`ClientHello.measured_tables` requires `rich_compose` and defaults to false.
Opted-in clients receive `ComposePane.tables` with parser-owned table/row/cell
source ranges, column alignments and cell/structural-source reveal state.
Rows can be a bounded subset of a table. Real empty cells retain their source
anchor; missing cells from a short row are explicitly marked and cannot be
treated as editable source. Cell text uses the parser's text/code events,
preserving escaped pipes, entities and opaque image ranges. Tabs separate
present cells in the projected text; no column padding or forced wrapping is
serialized. Image objects and exact image-source previews remain disjoint.
Edits and undo still use Fresh's original Markdown source coordinates.

The native editor has not opted into table cells yet. `ComposeTableModel`
validates the new data and resolves its source/display ranges, including
Unicode and malformed-input checks. The shared Core Text renderer now measures
column constraints from fonts/content and available pixel width, wraps complete
cell text, draws native rules and constrains images/previews to cells. Caret,
selection, hit testing and text-service rectangles share those fragments.
Short cells keep a full-height click region beside taller cells; real empty
cells retain their own anchor, while missing-cell clicks enter structural
source. Provisional text reflows within its cell; a draft crossing cells uses
one shared projected flow until commit. Structural source rows span the table.
Two-dimensional navigation, horizontal scrolling when complete clusters exceed
the pane, and stable column measures across source windows remain prerequisites
for enabling and qualifying the capability. Legacy rich clients keep table source and
can share the same backend with a table-capable client without exchanging
their per-client projections. `compose-tables.pb` records that real-plugin
source contract; `compose-table-image-source.pb` adds edited image markup and
its preview. Renderer/model checks do not prove complete table ergonomics.

Visible images are checked on a five-second prototype interval and when the
editor is shown again. POSIX local/SSH stats include file identity plus
nanosecond modification/change times. Metadata shortcuts are supplemented by
content verification on a sixty-second prototype threshold; filesystems without a useful
stamp use content verification directly. Hashing is bounded and runs through
the authority's filesystem; the SSH helper computes the hash on the host, so
verification does not download unchanged image bytes. The native client skips
decoding unchanged responses and retains previews while refresh is in flight.

Transient errors carry `retryable` and retain the last valid preview with an
explanation. Missing, denied or invalid resources use an editable fallback.
Retry scheduling survives source-edit cancellation and temporary formatting
frames, preventing a new image read for every character typed. Duplicate
visible references share work even if their order changes between splits.
These intervals and resource budgets still need interactive/performance
qualification; full GUI/SSH qualification remains open.

These additive prototype messages retain the current scene version during
development. Audit the final protocol version and update the dependency pin,
bundle, consumer, and recovery qualification together before enabling the
feature for users. Native queue checks are described in
[macOS app tests](macos_app.md#tests).

## Timeouts

| Bound | Enforced by | On expiry |
| --- | --- | --- |
| 25 s for each noninteractive command, including all of Fresh's waits below | FC | `SIGKILL` to the command's process group; exit 124 |
| 2 s for the identity lock | FC | `Editor identity is busy; try again` |
| 10 s for the backend startup lock (`<id>.start.lock` in Fresh's socket directory) | Fresh client | Error |
| 10 s for a backend this client spawned to become ready | Fresh client | `SIGKILL` to that spawned backend only, so a late start cannot replace a retry's sockets; error naming its log |
| 10 s for each handshake or acknowledgement read | Fresh client | Error |
| 10 s for the old backend to exit after `prepare-restart` | Fresh client | Error; the backend is never force-killed |
| None for interactive editing (`-a`) or a connected scene client | | |

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
   - The scene channel is not kept compatible: the native editor connects
     only to a backend on the same pin. With a backend from an older pin the
     connection ends at the hello until the user runs **Restart editor
     backend**.
3. If the upstream base moved, check `rust-toolchain.toml` and update the Rust
   version wherever it is documented.
4. Rebuild and run the Fresh-labeled tests with
   `ctest --preset release -L fresh`. They include `fc.harness.fresh_bundle`, which rebuilds the pinned
   revision from the upstream base and the bundle alone, and the terminal,
   recovery, restart, workspace-recovery and SSH editor tests that drive the
   real binary.
5. A running backend keeps using the old binary until the user runs **Restart
   editor backend**.
