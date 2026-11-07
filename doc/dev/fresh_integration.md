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
  side closes it; an app that stops reading is dropped when queued output
  exceeds the producer's cap. The packaged Fresh pin uses 8 MiB; the current
  development producer allows two 16 MiB protocol messages plus TLV headers.

A connected scene client counts as attached: the session does not shut down
idle, and `prepare-restart` refuses while one is connected, so the app
disconnects its window before Restart Editor Backend and reconnects after.

### Experimental rich Compose

The native development path can request rich Compose with
`FC_NATIVE_RICH_COMPOSE=1`. It requires a matching development backend and
consumer; the packaged Fresh pin has not been advanced for this experiment.
Grid Compose remains the default. Terminal clients keep their cell layout.
Measured native table cells have a separate development switch:
`FC_NATIVE_MEASURED_TABLES=1`. It takes effect only alongside
`FC_NATIVE_RICH_COMPOSE=1`; a rich client without it keeps editable table
source. The two switches are captured when the native editor is created.
Neither switch changes terminal Markdown formatting or forces native columns.

The production native controller has an opt-in backend contract. From the FC
checkout, with the matching Fresh development binary built with `web`, run:

```sh
FC_COMPOSE_TEST_FRESH="$PWD/../editor-fresh/target/debug/fresh" \
  swift test --package-path macos --filter ComposeBackendTests
```

It starts foreground Fresh processes with private HOME/config/data/state/runtime
folders and source fixtures, uses an in-memory native clipboard and disables
Fresh's system clipboard. It covers measured-cell editing, local image reads
and decode, nested code, resize, undo/redo, exact CRLF saves, editor switching,
missing-cell source reveal through a font change and page selection/replacement
across a large source window. Without the variable these backend checks skip;
ordinary native unit/scene-peer checks still run.

For fixture and server-log artifacts, set `FC_COMPOSE_ARTIFACT_DIR` to a private
output directory. `FC_COMPOSE_TEST_LOG` optionally overrides the backend's
default `warn` tracing filter. Detached backend logs are captured from its
private state directory; the launcher log alone does not contain server output.

The consecutive-composition regression now requires the accepted prefix to
remain visible with correct source UTF-16 positions; it has no expected-failure
exemption. Further backend checks replace an initial selection only once when
two commits are queued, preserve all original carets, undo each phrase/batch
separately and follow Fresh's CRLF normalization. These tests are not full
system input-method, SSH or interactive qualification.

The experimental client hello opts into source-preserving Compose projections.
The server hello advertises `compose_region_probes`. Native rich Compose
requires that capability before accepting any scene. An older running backend
is disconnected with an explanation directing the user to Restart editor
backend; its process, tabs and checkpoint remain under the existing restart
workflow. Grid clients retain scene protocol version 1 and can still use
servers without the new capability. Wrong protocol versions, frames preceding
the initial hello and repeated hellos terminate the connection explicitly.
Fresh owns source buffers, selections, undo, saving, and filesystem authority;
the native consumer measures text and images with Core Text. Source coordinates
are UTF-8 bytes, and native layout feedback is scoped to a window, split,
buffer, source revision, projection revision, and selection revision.

Development popup scenes also carry a lifetime (`instance`), an event-time
`version`, stable list-row IDs, and an optional `source_anchor`. The anchor
names the exact window, split, buffer lifetime and source revision. It carries
the caret byte for vertical placement and line height, a horizontal source
byte (the completion word start where applicable), and an explicit over,
below-with-flip, or above placement rule. Fixed, centered and status popups
retain their cell placement. Replacing or reshowing a popup starts a new
lifetime; owner, content, scroll and action-payload changes invalidate its
version. A byte fixture is independently checked by Fresh's encoder, the
generated Rust decoder, `protoc`, and FC's `SceneWireTests`.
The version fingerprints retained geometry and actual scroll offsets: a
component can scroll without updating the popup model's legacy offset.
Hover and selection colors alone leave the target usable. `ScenePopup.grid`
carries the retained popup picture, including wrapped rows, styles, selection,
scrollbars and close affordances. Native scenes omit popup cells from their
underlying grid; ordinary terminal rendering still paints them.

On the development branches, rich clients negotiate `native_popup_projection`
in `ClientHello` (field 6) and require its `ServerHello` capability (field 4).
`ComposePopupPlacement` supplies one measured placement and clip for both
native painting and pointer routing. Source ownership and caret visibility
must match before a source-relative popup is displayed. Popup contents keep
their retained cell sizes; the anchor follows proportional text and heading
line height. Fixed, centered and status popups retain cell placement.

Translated `PopupPointer` input (message 30) names the issued popup lifetime
and version, with signed local coordinates for captured motion outside its
bounds. Fresh validates the target and routes it only to that retained
subtree; it never falls through into a document click. Ordinary native mouse
input excludes moved popup regions at their old coordinates. Keyboard focus,
disabled rows, scrolling, links, selection and modal ownership remain with
Fresh. Popup text selection uses logical byte offsets from actual wrapping,
so copying soft-wrapped text preserves its source and combined emoji.
Capture binds the original source owner. A changed owner, closed popup or
disconnected client retires its retained capture, scrollbar grab and drag
state without sending a synthetic release or drop into another surface.

Popup gestures use the ordered `ComposeInput` path. An accepted action returns
its captured source result; following text waits for that result. A cancelled
action retains dependent text in Uninserted Text recovery without writing the
clipboard. These development changes require a matching Fresh build; the
packaged pin and default rich-Compose gate remain unchanged.

The semantic spans distinguish heading levels, inline and fenced code,
tables, quotes, lists, items, and paragraphs. Overlapping spans retain nested
structure, emphasis, link, underline, and strikethrough information; the
native client does not parse Markdown. Core Text measures indentation and
spacing before producing caret, selection, and navigation geometry. Font
and spacing changes replace that client's style revision and preserve its
source scroll anchor. Code and raw table source use a monospace font; measured
table cells use proportional body text unless inline markup selects code.

Development scenes also supply `ComposeSpan.link_target` (field 6). Fresh's
parser resolves destinations, including references, escaped paths, entities,
email autolinks and empty self-links. An absent field means the peer supplied
no destination; an explicitly empty field identifies the current document.
The client retains the parsed UTF-8 spelling without Unicode normalization.
Prefix measurement samples retain link styling but omit document destinations.
Native `ComposeLink` records map these spans into the displayed UTF-16 text,
including concealed syntax and cropped source windows. Tooltips resolve the
actual measured glyph under the pointer and use an index for link lookup;
they do not build selection rectangles for every link. A provisional edit
inside a link suppresses its old destination while unrelated links remain
available. Metadata updates survive reuse of unchanged glyph geometry.
Receiving or inspecting a destination never follows it or fetches a resource.
Tooltip metadata is limited to 2 KiB per destination and 64 KiB across a scene's
panes and input replies. A destination exceeding either budget omits the
complete target and supplies its full UTF-8 byte size (`link_target_bytes`,
field 7), plus an optional incomplete prefix (`link_target_preview`, field 8).
Native tooltips clearly distinguish that preview and direct the user to edit
the link to inspect its full destination. A preview never populates
`ComposeLink.target` or authorizes opening a shortened URI. Fresh retains the
complete parsed destination and all Markdown source bytes, independently of
these tooltip limits. Native scene queues allow two protocol-sized frames;
they do not inherit the browser bridge's smaller queue limit.
Semantic accessibility navigation remains a separate unfinished requirement.

Native text, list-prefix, table-sample and presentation-label shaping first
use Core Text's bounded typesetter factory. If that factory refuses a complex
input, the consumer explicitly requests complete shaping. The legacy
nonnullable factory can silently split joined emoji in long strings. Source
text, semantic font runs and contextual shaping remain intact; a failure of
both factories rejects the layout rather than asserting. This fallback permits
work beyond Core Text's default limit. Long-document CPU, memory and
input-to-paint budgets still require qualification before enabling the feature
by default.

Within one layout, hanging markers and table cells share a typesetter for
the complete projection and its current font runs. Tables with complete fixed
column inputs skip that measurement unless a draft needs adaptive minima.
Installing inline-image run delegates still creates a new final typesetter;
otherwise the text layout can reuse the measurement typesetter. Sharing never
uses cell-only strings, another pane's fonts or a prior source revision.

Fresh's bundled Markdown grammar rejects impossible reference definitions
before its original reference-link search. The precheck retains the original
leftmost match and capture positions, including nested/escaped labels; it does
not shorten lines or change Markdown source. This avoids a quadratic failed
regex search on long lines containing many ordinary image links. Runtime and
precompiled grammar sets use the same optimization, with their local context
references rebound to the copied definition. User grammar overrides still load
after the bundled definitions.

A queued native event can retain its already measured source layout while the
visible pane shows pending text. Input measurement may reuse that pane's immutable
geometry only when complete source/projection inputs, fonts, width, typography,
image sizes and composition agree, within the same pane identity and lifetime.
Split panes keep separate text layouts. The current scene and presentation still
govern input ownership, held-source fallback and viewport state; a retained
layout never makes old source coordinates current.

Validated source/display maps use ordered coordinate queries, preserving both
sides of hidden and inserted boundaries without scanning the entire map for
each image, caret or span. Object substitution visits only intersecting map
segments and still refuses partial atomic replacements or copied UTF-8 scalars.
Native paragraph, hanging-item and text-style queries use immutable interval
indexes. Equal ranges retain their original style precedence. Font objects
are reused within one layout by face, point size and traits; a changed font,
width or source still invalidates the appropriate layout. These are measured
layout optimizations, independent of terminal columns.

Long paragraphs in the projected text reuse a native Unicode line-break
index instead of repeating Core Text's contextual break search at every wrapped
row. Core Text still measures the current font runs and image delegates and
shapes the full attributed text, preserving its bidi context. Short paragraphs, special
whitespace/format controls, forced word splits and contextual punctuation units
retain the original Core Text break path. The index is scoped to one layout
construction; it supplies no fixed column count and does not bound source
windows or payloads.

Native formatter offers assemble complete physical lines across frames. Each
reader call requests at most 64 KiB, within the existing per-poll offer budget
(at most 128 KiB). Incomplete UTF-8 suffixes are retried exactly; partial lines
are never certified as complete formatting. Each tracked buffer retains at
most one unfinished offer. Edits, ownership changes, invalidation and withdrawn
demands discard it. Completion still requires the existing formatter receipt.

The Markdown plugin indexes UTF-8 byte offsets lazily for long source lines
during one formatting hook, avoiding repeated encoding of growing prefixes.
This index supplies source coordinates, not visual widths. The real-backend
200 KB list-paragraph regression now verifies readiness, hanging indentation,
offscreen movement, document-wide UTF-16 positions, resize, Unicode editing,
exact save and undo. Prose remains proportional and wraps to available pixels.

Parser-owned hanging-prefix samples now travel in `ComposePane.hanging_contexts`
(field 25). Each sample contains the projected marker and one complete body
grapheme, with relative display-byte font spans and the source item/body
anchors. It contains no column count. The native client validates ownership
and UTF-8 boundaries, then measures it in the current fonts if the marker is
outside a supplied source slice. It charges physical continuation whitespace
only once and invalidates reused geometry when the sample changes. Sample
text contributes neither editable characters nor caret stops.

The experimental native client also announces
`ClientHello.paragraph_windows` (field 5), which requires `rich_compose`.
Complete parser-owned paragraphs then define window boundaries. Direct inline
flows in tight list items are tracked from the same parser's block tree, which
omits explicit Paragraph tags there. Nested tight lists can therefore omit
preceding siblings without slicing a joined paragraph. Lists retain
source-owned leading whitespace and blank-line navigation pivots. An offscreen opening line is
requested separately through the same grammar/plugin formatter. The backend
prepares a current projected prefix after that line's completion receipt; it
does not certify measured input while this required context is pending.
If a visible body finishes before its required marker, the interim pane uses
complete source text with image/table presentation disabled. It cannot expose
a partially certified rich map while claiming that its projection is unavailable.
Rendering, deferred navigation
and editing receipts use the same negotiated policy. Clients omitting the
capability keep the previous marker-bearing window policy.

Repeated offscreen marker requests reuse a semantic sample only when its source
range, item/body anchors and exact resolved conceal/replacement inputs match.
Cursor-driven reveal therefore remains current without invalidating the cache
for unrelated formatting elsewhere. Formatter readiness is checked before any
reuse, including refresh failures. The cache belongs to one parsed document;
source revision, marker-owner or authority replacement discards it. It retains
at most 16 samples and 1 MiB of owned allocation capacity per cached document,
including keys and entry storage. Oversized samples render without retention.
This accounts for cache allocations, not allocator overhead or total process
memory. It retains neither whole projections nor native font geometry, and
the current pane's physical-line-start flag is recomputed on every request.

The 64 KiB window size remains a target, not a content limit. A complete parsed
paragraph or atomic replacement can extend it. Structural bytes outside known
paragraphs and blank boundaries of single-paragraph items retain their existing
item context. Arbitrary soft-wrap clipping is not a paragraph boundary. Preparing a
marker can also require a whole initial physical line
or a multiline image. Long-paragraph shaping, repeatable soft-wrap anchors
and general hard resource bounds remain separate requirements.

These changes bound the continuation reader's requests, not whole-window
payloads, retained logical batches or subsequent grammar/formatter work. A long
physical paragraph can still occupy a complete native source window. Source
window and memory budgets, continuation context and interactive performance
qualification remain release work.

Complete table-input measurement reuses each derived body/code font variant
within its pass, including bold and italic combinations. Each validated
measurement retains one immutable aggregate for its current body/code font
pair: glyph minima, uncapped wrapping and natural-width preferences, and image
flags. Resolving another available width uses only column-count arithmetic;
visible text still needs layout. Font or measurement-content changes rebuild
the aggregate. It retains no shaped lines, attributed sample strings or
tokenizers. Complete grapheme minima remain uncapped, allowing horizontal
overflow when a pane is too narrow for a glyph.
Pane construction can share these validated measurements with other live panes
of the same document and filesystem authority. An equal ID also requires equal
complete input data. Each pane still validates and builds its own source rows,
projection, geometry, cursor and viewport; peer layouts are not retained by the
new layout. The rebuild uses a temporary candidate set, without a process-wide
measurement registry. A peer cannot supply metadata missing from the receiving
pane's delivered contract.
Preferred minimum widths follow native line-break units rather than linguistic
dictionary words. A shared line-break tokenizer handles the pass, allowing CJK
character breaks while keeping nonbreaking phrases together. Whitespace still
draws and retains its source positions; trimming it from a minimum preference
does not change the document or the displayed text.

The [resource profile](testing.md#rich-compose-resource-profiles) records real
parser-generated panes, native construction/reuse costs, payload sizes and
process peak memory. It does not qualify interactive latency. Sources above
64 KiB use one semantic parser worker with at most one additional queued job;
there is no longer a 2 MiB native-source cutoff. Jobs own immutable source and
UTF-16-index snapshots. Edits coalesce to the newest wanted snapshot and cancel
obsolete work. Acceptance checks the source revision, buffer lifetime,
filesystem authority and snapshot identity. Closing the last rich client
cancels work and releases the cache.

While semantics are pending, the backend supplies current raw source with
proportional presentation, exact source context and accepted edit receipts;
both `ready` and `current_projection` are false. Source-bound committed text
can continue from those receipts. Measured navigation waits for a usable
projection. A completed parse replaces this temporary presentation, and a
request captured against its obsolete projection explicitly requests fresh
layout. Image clicks validate surviving source ranges before waiting for
metadata, so deleting an image still cancels its queued click. Transient image
discovery errors remain retryable.

Source extraction, flattening, UTF-16 indexing and decoration reconciliation
still run on the editor thread. The worker still parses a whole document;
moving that parse does not make all input work asynchronous. The cache retains
up to eight documents by count, without a qualified total byte budget. Its
64 KiB source-window target can expand for line/block context. Large-block
payload bounds, complete-table measurement costs, incremental style continuity
and interactive latency remain experimental release work.

`ComposePane.ready` reports formatter completion. Readiness correlates the
source revision, window, buffer lifetime, and a host-assigned token for each
batch of lines. Commands may span several editor ticks; offering lines or
receiving a hook-name-only acknowledgment is not enough. Tracked source
decorations apply to their original owner after workspace focus changes.
Edits invalidate affected ranges and shift unaffected completed ranges.

Fresh retains a marker-free snapshot of completed decorations, including
cursor-dependent alternatives. Source and activation scopes must both have
completed coverage. During formatting it projects the current source using
only this snapshot, never the formatter's partially cleared/rebuilt conceal
stream. Across edits, retained source and activation ranges must survive
unchanged, including their boundaries. Changed parser-owned semantic context
invalidates decorations in the affected old/new regions. Expired edit history
or buffer replacement discards them. Cursor activation is evaluated afresh.
The existing Markdown parser supplies current heading, code, table and image
structure; the native client has no second parser or editable source buffer.

`ComposePane.current_projection` (field 24) identifies this certified
current-source rich projection. Once semantics are available, it remains
usable for measured input, headings and images even when formatting has not
completed and `ready` is false. It does not certify the temporary raw source
shown during semantic parsing. The native client uses its current source map
rather than drawing a previous revision. An older peer without this field
retains the previous coherent presentation while formatting completes, subject to
accepted source/cursor bounds. Automatic viewport continuation waits for
completed formatting, because replacing retained decorations can change the
measured height. A physical scroll still takes precedence over an accepted
edit's caret reveal. Offscreen measurements remain demanded until their
completion can wake pending input.

Failed formatting, missing coverage, or the prototype's five-second deadline
produces an explained, editable source fallback. Fallback editing does not
restart that wait on every character. A successful current batch can restore
rich presentation. These timing and resource bounds still need representative
document qualification before release. Prose remains proportional, headings
are larger, and wrapping uses available pixels; terminal columns, padding and
fixed-width formatting do not constrain native layout.

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
- A source click, drag or single image selection can preview its primary
  selection before the reply when its source/UTF-16 endpoints are present in
  the captured raw context. Drawing, selected-range queries and a following
  composition share that selection. This is a presentation overlay; the scene
  store and captured pointer input remain unchanged. Current secondary carets
  are preserved. A source/lifetime change, retired primary or cancellation
  removes the preview. Fresh's correlated result can correct it, and supplies
  the real coordinates for a following composition or queued commit. Native
  command measurements always use the backend snapshot. Word/line selection,
  points outside raw context and opaque actions still await authoritative
  results; their full interaction workflow remains part of release qualification.
- A point within a provisional insert records the draft owner, its UTF-16
  offset and expected text, and depends on that prefix's queue token. No
  virtual source position travels on the wire. The matching native edit
  receipt must prove the edited or preserved caret owner. For a point inside
  that transaction's insertion, a verified binary edit anchor proves its exact
  normalized bytes and resulting source range, including points outside the
  bounded raw context. Otherwise the receipt must supply source/UTF-16
  coordinates and the exact text between the point and caret. A nearby
  point can be proved without echoing the whole paste in the receipt. Only then
  can the click become a source pointer at that receipt's revision. The point survives font
  reflow, secondary-caret inserts and chained prefix replacements. Captured
  offsets follow the declared native newline normalization. Following text
  depends on the click's own result. A cancelled predecessor, changed text or
  insufficient bounded source context cancels the click explicitly and
  recovers dependent text. Native selection, caret, substring and candidate
  geometry can follow that point immediately in the provisional document.
  Drag selection may cross into known source. Confirmed prefix replies rebind
  derived source points and carry prediction forward in queue order; a later
  click result remains authoritative. Broader interaction qualification remains
  in progress.
- Type 29, `ComposeViewportRequest`, updates a per-client source marker and
  vertical pixel offset plus a horizontal translation in points. Its acknowledgments and coalescing are independent of the text
  input queue. It changes neither the source cursor nor the terminal viewport.
  An optional `region` probes adjacent source without replacing the visible
  anchor. Fresh retains complete context around that anchor while gathering
  the requested region. Both points use owned markers and rebase through edits;
  a region probe within a UTF-8 scalar selects its containing scalar. Missing
  `region` keeps the ordinary scroll policy. All requested coordinates validate
  before applying the anchor/probe update. User scrolling or caret
  reveal can retire the probe when choosing a new measured anchor.
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
copy the graphical object or relocate its asset. Current-source pending
projections retain their parser-owned image presentation flags; failed raw
fallbacks set neither flag. Invalid markup remains editable source
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

Successful native phrase/replacement replies include `InputReply.edit`
(field 10), a `ComposeEditReceipt`. It identifies the window, split, buffer and
buffer lifetime, the edited cursor IDs, and an immutable `ComposePane` captured
immediately after the transaction. It includes raw source context and each
cursor's source/UTF-16 position, with the client's viewport epoch. The source
may still owe its formatting projection. Retries of the current accepted input
repeat that receipt; later edits cannot rewrite it.

Successful scoped non-text actions also supply `InputReply.result` (field 11).
It uses the same source envelope, with empty edited/preserved ID lists; its
`pane.cursors` is the action's resulting group. Fresh captures it immediately
after navigation, pointer placement, clipboard paste or an editor action,
using the view and buffer lifetime captured before execution. A changed tab,
view or lifetime cannot supply a result in the original Compose owner. Current
input-ID retries repeat the immutable result instead of executing again.

A new composition can record a dependency on the preceding queued native edit
that owns its captured carets. The native controller uses
only that edit's matching receipt to rebase active drafts and already queued
commits. A newer scene's cursor cannot replace the captured owner. The rebase
retains attributed draft text, marked/selected subranges and every cursor ID;
expanded surrounding ranges must still agree with the accepted source context.
Invalid lifetime, retired/foreign carets, conflicting context or a missing
receipt recovers the dependent text without partially inserting its group.
Rejecting a predecessor recovers queued and still-marked descendants as well.

An explicit primary-only edit can be followed immediately by a default
conversion at every original caret. `ComposeInput.observed_cursors` (field 21)
captures source positions and selection anchors with the input's source
revision, or its scope revision for ordinary text input. Fresh maps each
unchanged range through retained edit history and compares both ends and
selection direction to the live cursor before applying the transaction.
The immutable receipt lists matching IDs in `preserved_cursors` (field 7),
separately from its actually edited `cursors`. A later composition can use
those proven unchanged selections, including selections outside the bounded
text-context chunk. Merely appearing in a receipt pane is insufficient.
Rebinding carries only proven owners forward; a later scene cannot silently
renew a previously failed witness. Missing proof rejects the entire following
group into recovery. Expansion outside a preserved selection still requires
exact surrounding source and consistent source-byte/UTF-16 caret coordinates.

For explicit native replacements and ordinary native text,
`ComposeEditReceipt.anchors` (field 8)
contains the entire disjoint batch in source order. Each `ComposeEditAnchor`
names a genuine edited `cursor`, its resulting UTF-8 `start`/`end`, a 32-byte
SHA-256 `digest`, and the rebased `before_start`/`before_end`. The optional
receipt `source_revision` and `source_length` (fields 9/10) own those before
coordinates; the resulting pane owns the after coordinates. Fresh verifies
the actual buffer bytes in bounded reads and compares actual cursor ends
before publishing. A subsequent formatter gather cannot relabel that proof
with another source revision. Immediate input retries repeat the same receipt.
The metadata does not echo inserted text or grow with insertion byte length.

`ComposeAcceptedEdits` validates the complete group, genuine cursor identities,
source/result lengths, ordering and actual receipt caret ends before using
an anchor. An inserted point also needs the exact normalized payload digest,
byte length and a scalar-valid UTF-16 offset. Original source endpoints can
rebase through that exact accepted batch; replaced interiors have no inferred
correspondence, and empty insertion boundaries respect affinity. Pending
pointer capture hashes its own delta, rather than a retained earlier prefix.
Older receipts retain the bounded-context proof path. Missing or inconsistent
evidence cannot produce a guessed pointer or source selection. Queue integration
binds the anchors to their exact input tokens and the captured complete value
before using them for public AX actions.

`ComposePendingText` keeps committed prefixes visible before their replies.
Drawing, selected ranges, substring queries and hit/candidate geometry use the
same provisional document. A committed prefix is unmarked; a following draft
can replace part of that prefix or expand into the captured surrounding source.
Each subsequent operation records its delta from the preceding committed
preview. That delta becomes a source replacement only after its predecessor's
receipt supplies real byte/UTF-16 coordinates and matching context. Virtual
source ranges never travel on the wire, and already submitted prefixes are
not inserted or recovered twice. This is a presentation overlay over Fresh's
snapshot, not a second Markdown parser or editable buffer.

A default-range conversion begun behind a queued action records that action's
local queue token. Both active drafts and already committed queued text bind
to its correlated result rather than the old cursor or a newer unrelated
scene. The entered text and partial marked/selected ranges survive; the
resulting selection becomes the replacement range. An action that creates
carets can supply the full new group. Previously submitted prefixes are
excluded from the new replacement. Expansions outside the initial conversion
still require exact surrounding source. An explicit initial source range
retains its captured target; a range in a pending text prefix depends on that
prefix's receipt, even if navigation is queued between them. Missing/cancelled
results recover dependent queued and marked text without inserting a subset.
Navigation measurement uses the actual source snapshot independently of
the provisional drawing overlay, so a key awaiting geometry can finish while
a following conversion is marked.

The native presentation separates actual caret IDs from the draft regions
that own provisional text. `ComposeVirtualSelections` keeps bounded immutable
attributed contexts, directional UTF-16 selections and caret affinity,
preserving secondary carets when the primary moves into another draft.
A primary-only prefix adds unchanged context witnesses for the other carets;
these provide positions and raw context without editing the projection.
Conflicting contexts and unknown gaps cannot supply text. Per-caret conversions
can have partial marked/selected ranges and expand into captured surrounding
source. `ComposeVirtualInsertion` folds them back into disjoint real source
regions, merging drafts when several carets affect one region. The real source
map and separate draft/context display ranges feed one measured layout for
painting, caret, selection, hit testing and native text services. Synthetic
region IDs stay inside FreshKit. Code/table context and image suppression use
these real source regions; prose remains proportional and wraps to pixels.
Completed formatting can replace temporary visible markup without retiring an
active conversion. Zero-length candidate queries at the current selection use
the caret's visual affinity, including the two sides of a soft wrap.

Action-intent contexts derive correct provisional UTF-8 starts and global
UTF-16 starts. They retain native input while a click/result is pending; they
are not an editable buffer. A strict guard forbids turning those provisional
ranges into a replacement packet, including after commit or a following
conversion. Only the matching result can rebuild real source ranges. An
explicit primary-only conversion remains primary-only after binding and
retains observed secondary owners for a following broadcast. Queued previews
carry their prefix until that binding, then retire it without repeating already
accepted text. Navigation measurements always use the backend snapshot. No
second Markdown parser is introduced. System IME panels, arbitrary action
sequences and broader view/recovery timing still require release qualification.

`ComposePane.native_newline` (field 23) declares Fresh's insertion separator:
0 unknown, 1 LF, 2 CRLF. CR disk files use LF internally. The native preview
normalizes committed phrases using that policy, including surrogate characters
and attributed text; it does not infer line endings from rendered Markdown.
Unknown older peers cannot provide a reliable multiline composition preview;
the composition is retained as uninserted text. Ordinary text actions retain
Fresh's ordered-input fallback. Development tests require a matching backend.

Receipt source, byte ranges and UTF-16 context form one snapshot. While a
rebased draft is active, a pending formatting update cannot substitute an older
source projection. Completed formatting for the same source revision can
replace the raw projection while preserving the captured context. Input queue
completion also prevents reentrant callbacks from resending the accepted edit.

An accepted edit or action result is applied atomically with its scene update.
If the pane diff is omitted or older than that source, `SceneStore` uses the
receipt's self-contained pane. An explicitly updated same/newer pane can contain
a later cursor and remains authoritative. Only a matching in-flight input's
validated view/lifetime result can establish this accepted basis.
`ComposeAcceptance` records a small source/cursor basis per live view, preventing
the retained-formatting fallback from rolling back accepted text or selection.
Selection revisions are opaque hashes and are compared for identity, not
numeric order. Regressive accepted source revisions are refused within the same
owner/lifetime. Records retire with the view/buffer lifetime and reset on a new
server hello, which can reuse every numeric owner ID after a backend restart.
No additional full-document snapshot cache is retained.

During that formatting interval, drawing and text services use the current
editable Markdown source, including its actual UTF-16 selection. Further text
can be previewed immediately, but dispatch still waits for a coherent current
formatting projection. The completed rich projection replaces that source view;
this does not establish flicker-free formatted presentation or complete system
IME/candidate behavior throughout the interval.

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
The accessibility value and its selection use document-wide displayed UTF-16
coordinates when the complete-document capability is present.
Character, substring, font/style, visual-line, visible-range and screen-bounds
queries use that same measured projection, including provisional selections
at every known caret. An offscreen primary is unavailable rather than replaced
by a visible secondary. Raw-source text-service indices are a separate space.
Inline image characters carry an accessibility attachment pointing to a stable
image element with its alt text, loading/error description and measured bounds.
Each immutable native presentation indexes image metadata and placements by
source, so refreshing or querying all image elements does not repeatedly scan
the complete image list. Every attachment retains its accessibility element;
the indices do not replace source or connection ownership checks.
Source-edit previews remain ordinary source text and expose a separate image
element without adding a character. Pressing an image selects its exact Markdown
source through the normal captured input queue; it does not copy or edit by
itself. Source/buffer/authority/focus changes and disconnection invalidate the
object's action ownership; a new connection cannot revive a retained old object.
Value, selection, image-description and hierarchy changes post accessibility
notifications.

Development peers advertise `ServerHello.compose_source_selections` (field 5).
The native accessibility selection setters map displayed UTF-16 ranges into
absolute UTF-8 source targets (`ComposeInput.selection_targets`, field 22).
Fresh validates the entire nonoverlapping group before changing any cursor,
rebases unchanged ranges, keeps the primary identity and assigns secondary
IDs. Selection itself does not edit source and remains available in read-only
buffers. `ComposePane.editable` (optional field 26) separately enables the
primary selected-text setter. An accepted action receipt supplies real cursor
ownership for immediately following text, including text outside the current
raw context. Cancellation, missing ownership and disconnect retain dependent
text for explicit recovery. Deferred modal selections wait for keyboard focus
without repeated retries; retired targets consume cancellation instead.

Setter availability is explicit: complete-value setters require current source
ownership and the source-selection capability. A current provisional composition
can be selected or replaced through its accepted predecessor receipts. Older
peers retain their bounded presentation path and do not accept provisional
selection actions. An unconfirmed selection after a source change cannot
redirect a selected-text replacement. Replacing only the displayed part of a
larger selected range is refused. AXValue remains unwritable because displayed
text does not include every Markdown source byte.
Development peers also advertise `ServerHello.compose_semantic_index` (field
6). One parser-owned inventory covers every heading, link and image in the
document, including source outside the displayed window. Parsed labels retain
their full text for case/diacritic-insensitive filtering; destinations and
image bytes are not copied into this inventory. Image alt names use the same
parsed text for native attachments and navigation. Nested image alt links
are not separately actionable.

The complete inventory admits at most 262,144 entries and 32 MiB of UTF-8
labels. Exceeding either limit reports unavailable navigation while preserving
the complete editable source. It never advertises a prefix as complete.
`ComposeIndexRequest` (TLV 31) subscribes by window, leaf, buffer, lifetime,
revision, filesystem authority, document identity and source length. A separate
`ComposeIndexChunk` (TLV 4) sends at most 64 KiB of label text and 256 parts
per chunk, with each part at most 16 KiB on a UTF-8 scalar boundary; the
encoded chunk is bounded by 128 KiB. Only one chunk awaits its own sequence
acknowledgment. Render-frame Applied does not advance it, and index chunks
never enter SceneStore or change the render sequence. One retirement notice
can overtake a pending chunk when its source becomes obsolete.

The native client subscribes when assistive navigation is queried, validates
the entire generation and prepares full-label search away from the UI thread.
Prepared search metadata has a separate 64 MiB budget. Typed heading, heading
level, link and image rotors use AppKit APIs available on macOS 14. Menu labels
may show an explicit ellipsis; filtering still searches the full label.
Offscreen results use securely archivable loading tokens and source-owned
virtual elements. Selecting a result follows the ordinary Fresh source
selection queue and measured caret reveal. It does not open a link or rewrite
Markdown. Source, focus and connection changes retire tokens and elements,
even if a restarted backend reuses the same numeric IDs. Heading elements use
a group role with a heading-level description, avoiding newer OS-only roles.

These are direct AppKit and private-backend contracts. Actual VoiceOver,
macOS 14 runtime behavior, accessibility actions across provisional
composition and a complete document text model remain unqualified.

The native text-model foundation is `ComposeAccessibleDocument`. It accepts
only a complete source-owned projection, retaining source/selection lifetime
and document-wide displayed UTF-16 coordinates without measuring a whole
document in Core Text. It can certify the global range of a drawing crop only
when both literal UTF-8 content and conceal/replacement ownership agree.
Partial atomic replacements, canonically equal but differently spelled text,
changed source owners and changed selection/reveal revisions are refused.
Primary selections retain their full ranges rather than clipping to a crop.
This model is not yet the public AX value: measured line/geometry integration
and provisional actions remain required.

Development peers advertise `ServerHello.compose_document_text` (field 7).
`ComposeDocumentRequest` (TLV 32) captures the same eight source-owner fields
as navigation, plus the selection/reveal revision. Fresh prepares ordinary
formatter windows without moving either the requesting client's drawing
viewport or another client's viewport. Only a complete normal projection is
published. `ComposePane.decoration_revision` (optional field 27) also binds
the result to its formatter state; a formatter-only invalidation retires an
encoded read even when source and cursors have not changed.

`ComposeDocumentChunk` (TLV 5) carries binary pieces of one encoded
`ComposePane`, with no JSON, base64 or second Markdown parser. Its sequence
and explicit acknowledgments, including sequence zero, are independent of
render frames and navigation. Each piece is at most 64 KiB and each encoded
chunk at most 128 KiB. An error retirement can overtake an unacknowledged
piece; obsolete request IDs cannot restart a read. The native receiver checks
all ownership, sequence, length and formatter fields, then decodes and
validates the completed body away from the UI thread. It never exposes a
prefix as a document value.

Complete reads admit at most 16 MiB of source and 32 MiB of encoded projection.
Two reader permits are shared across the scene bridge. A one-shot read releases
its encoded body after the final chunk; preparation and acknowledgment timeouts
are 30 and 10 seconds. Admission failure preserves source editing.

`ServerHello.compose_document_updates` (field 8) negotiates retained baselines.
Presence of `ComposeDocumentRequest.base_id` (field 6) opts in: zero requests a
fresh baseline, otherwise it names the last completely received body. Only the
final chunk ACK promotes a new baseline. Updates retain at most the prior body
and one candidate, each at most 32 MiB: the two shared permits therefore bound
retained encoded bodies to 128 MiB across connections. Idle baselines expire
after 30 seconds; cancellation, disconnect and missing final ACKs also release
their owned storage. Expiration runs before new requests and under output
backpressure. An evicted or foreign-lifetime base falls back to a full read.

Updating chunks bind baseline/result SHA-256 digests and result length. Encoding
0 carries a complete body; encoding 1 carries at most 64 ordered, nonoverlapping
binary splices over the old encoded body. Each protobuf field group retains its
common byte prefix/suffix, so a changed header cannot resend unchanged prose.
Literal ranges borrow the candidate body rather than retaining a third encoded
copy. A delta no smaller than its complete result uses full delivery instead.
All hashes, lengths, source owners, selection/formatter revisions and the
complete map are verified on a worker before publication. Raw input-method
context remains in ordinary input frames and is omitted from value snapshots;
global cursor coordinates and full span/table/image semantics are retained.

The native coordinator activates on demand and coalesces target changes over
80 ms. Formatting preparation may change its own revision without canceling
the read. Source/selection changes cancel obsolete transport; hiding or a
connection/source replacement also releases its base. One decode worker lives
at a time, including across reset and noncooperative cancellation. A stale
success can seed a binary base only in the same live document; it cannot
publish a retired value. A 35-second inactivity timeout releases a silent read.
Unchanged complete text/maps share immutable scalar coordinates across new
selection generations, using literal UTF-8 and exact map comparisons.

These are transport and retention bounds, not total/peak-memory or input-latency
qualification. Fresh still constructs and encodes complete candidate projections;
edits that shift many absolute map positions can resend substantial metadata.

`ComposeFlowMeasurement` measures a complete verified snapshot through the same
`ComposePaneLayout`/`ComposeTextLayout` path as drawing. It retains numeric line,
font, style, table and image geometry plus immutable attributed-text context;
Core Text lines and typesetters remain temporary. Partial range bounds reshape
their boundary lines. Drawing and measurement retain coordinate maps only for
construction endpoints (font runs, paragraphs, images, markers and table cells).
Other source/display lookups use the projection's exact sparse index, including
UTF-8 and surrogate-interior rejection. Each preview no longer duplicates a
pair of per-scalar dictionaries. Measurement admission still limits the required
boundary count before shaping.

Both drawing and measurement shape groups of whole Unicode paragraphs, targeting
16,384 UTF-16 units. Boundaries preserve CRLF and bidirectional paragraph context;
U+2028 does not split that context. Longer paragraphs remain whole. Measurement
explicitly rejects a context over 65,536 units, more than 262,144 coordinate
boundaries, or more than 262,144 fragments/style runs, without publishing a
prefix. Admission also checks complete table samples and offscreen list-marker
contexts before their preliminary shaping or cache reuse. Drawing retains its
existing complete-paragraph fallback. These are
resource admission limits, not fixed columns or a Markdown page width: wrapping
continues to use the native pane's available point width.

A crop receives a translation into the complete flow only after its literal
projection/map, source/selection/formatter owner, fonts, image dimensions, actual
glyph runs, global indices and line geometry agree. A changed width or owner
retires the proof; no estimated prefix height is used.

`ComposeFlowTextIndex` defines complete text ownership over those measured
fragments. Table cells retain source reading order, with each fragment owning
the structural separators before the next fragment. Empty cells remain lines.
Soft-wrap boundaries respect upstream/downstream affinity; consumed Unicode
line endings and cell boundaries select the next line. EOF always belongs to an
existing measured line, including a trailing empty line when present. Table
separators without painted glyphs use the owning fragment's measured edge
caret for bounds. Indexed logical font/attachment spans cover the entire value,
including gaps; queries need not rebuild a complete attributed string.

The native `ComposeFlowController` measures complete snapshots on one worker,
including across cancellation and connection reset. Late successful work cannot
publish retired ownership. A caret/header update can reuse geometry only when
fonts, image dimensions, admission policy and a literal protobuf digest of all
layout inputs and source-bound local drafts agree. Canonically equal strings
cannot alias different table, marker or draft encodings. Clause selection can
reuse glyphs while publishing a new logical presentation. Reuse always
substitutes the current document owner. Source,
focus, font/width and image changes update or retire the candidate; hiding and
disconnect release it. Reading known image dimensions starts no offscreen I/O.

`ComposeDocumentPresentation` derives complete provisional text from that
verified baseline through the renderer's shared `ComposeProjectionPlan`.
Image replacements, image-source editing, captured composition and layered
virtual insertions use the same transformations for drawing and complete
measurement. The baseline remains unchanged. A text-only overlay capture
keeps arbitrary attributed values and AppKit objects outside the worker;
selection-only changes retain geometry without retaining retired ownership.
Complete selections remain primary-first, including offscreen secondaries.
Provisional endpoints identify a presentation and either an original source
byte or a local draft region/UTF-16 offset. Deletions still own their pending
boundary. Region keys cannot be sent as Fresh cursor IDs, and draft offsets
need accepted predecessor receipts before becoming wire action coordinates.
Superseded overlays cannot publish through a still-current transport baseline.

Public AX value, character/substrings, selection groups, setters, styles,
visual lines, visible ranges, bounds, point queries and image elements now use
one complete displayed coordinate space when `compose_document_updates` is
supported. The first text query demands a complete snapshot. While it loads,
the value is empty and help reports loading; the drawing crop is never passed
off as the complete value. The coordinator prepares logical text on its single
worker before shaping. Same-document refreshes retain that logical value with
its original source owner; hide, disconnect or another document retires it.
Selection-only local changes share the immutable projection immediately, so a
following selected-text setter sees the proposed group before its receipt.

Geometry publication uses that exact logical object. Pending or rejected
measurement does not replace its text. Certified visible crop geometry remains
usable; complete measured bounds need a verified crop-to-flow translation.
Unavailable geometry returns no range/frame rather than an estimated prefix
height. Font runs arrive with measurement; image attachment ownership and the
complete image inventory are available before it. Source-keyed image and
placement indices and one cached crop/geometry certificate per immutable view
generation avoid rescanning the complete inventory for every child. Offscreen
image elements load no pixels; pressing one selects its captured source.

The native action path queues complete-value selection and primary replacement
through the existing ordered input queue. Draft endpoints bind to their actual
predecessor's accepted insertion proof; copied endpoints rebase only through a
verified source transition. A proposed caret ordinal binds to the genuine
Fresh selection receipt before an edit is sent. Unknown source changes,
lifetime changes or replaced interiors cancel the whole action; a waiting
replacement is recovered once on disconnect. Backend regressions cover distant
source selection, consecutive pending edits, IME clause selection, primary-only
replacement with another caret, allocator history and recovery.

This development cutover still needs interactive and resource qualification.
Complete logical values retain action provenance across the snapshot refresh
interval. Each requested logical generation captures the queue's delta origins
and its normalization/composition context before a worker or an ACK can remove
them. A compact history retains 64 acknowledged transitions;
up to four published binding generations remain available, alongside the active
request/presentation. History contains verified edit anchors and scope/cursor
identities, not receipt pane text, source maps, layouts or bitmaps. Ordinary
native text uses the same insertion path and now supplies a proof only when its
actual resulting bytes and genuine caret ends verify. Empty native input does
not claim a deletion. Virtual raw contexts cannot become original source
coordinates merely because their byte length matches the source document.

An action against retained text replays those exact transitions before joining
the current queue. Draft positions retain their owning input token and literal
normalized payload proof, including after the original queue node is gone.
Unknown changes, overwritten interiors, changed draft payloads, expired history
or retired lifetimes refuse the whole action. Retaining the same owner numbers
after hide/show cannot revive an older logical object. A proposed selection is
published immediately in its original complete value; later preparation waits
for that selector's exact receipt. A following selected-text setter binds the
proposed group's actual primary identity. Cancellation also releases this
publication hold and recovers dependent replacement text once.

Successive pending conversions retain stable proposed caret identities until
their selector's receipt binds them to Fresh's genuine group. Each later
conversion replays only its captured delta over the rebound predecessor;
the active Cocoa clause follows the same path, including its marked subrange.
An action-created caret joins broadcast input; an explicit replacement still
uses the resulting primary. A pending secondary pointer binds its proven owner
without relabelling source regions or raw offsets. Source and virtual selectors,
advanced cursor allocators, different per-caret expansions, repeated commits,
active clauses and separate undo boundaries have private-backend coverage.

A distant selector can leave its proposed primary outside every raw context.
Native input retains the intent against its last real context until the receipt
supplies actual positions and chunks; it never invents a global raw coordinate.
Offscreen drafts do not prevent a visible crop adopting newer formatting, while
intersecting drafts must still fit that crop. Complete provisional selections
include added and retired local carets without treating them as wire identities.

When a preceding action changes the declared newline policy, explicit ranges
within its pending text follow that text's exact LF/CRLF normalization. This
includes replacements spanning the pending prefix's edges. Surrounding source
remains literal, and the rebound replacement must still match its actual raw
context before reaching Fresh. Model checks cover both directions, active and
committed input, and final receipt-bound replacement bytes.

Public range, character and line queries have private-backend coverage over
tabs, vertical/form-feed controls, NEL and Unicode line/paragraph separators.
Selected-text replacement and one undo preserve the surrounding Markdown and
separator bytes. EOF selection and immediate native conversion have the same
coverage in empty documents and heading-only documents with an absent, LF or
CRLF final line ending.

Other action/view interleavings and actual GUI/IME/VoiceOver/macOS 14/SSH
behavior still require qualification. Current certified formatting coverage
skips redundant source-window preparation;
formatter/parser caches, transient allocations and the full native flow still
require the general resource audit.

Fresh's semantic cache keeps at most eight composing documents and reuses live
tab snapshots. Gathering and parser polling release entries whose window,
buffer lifetime or filesystem authority has gone away. Obsolete parser jobs are
cancelled; a running slot remains owned until its completion is consumed, and
that completion cannot restore a closed document. Private cache tests verify
source/semantic ownership release, live-tab reuse and a late cancelled result.
Clearing the cache after the last rich client disconnects also preserves the
worker and its occupied slots until cancelled results are consumed. Reconnects
use that same queue: one parse runs and one waits, with each buffer's newer
snapshots coalesced before submission. A quiescent clear releases the worker,
allowing a later request to start it again; dropping the cache closes its
channels. Controlled regressions
cover repeated resets, stale results, source release and retry after a stopped
worker.
This entry-count policy still needs the general retained-byte and transient
allocation audit. Native pending-text literal checks compare UTF-16 sequences
without materializing a pair of temporary arrays; canonical equivalence cannot
authorize editing different source bytes.

Projection boundary validation and this model share a sparse UTF-8/UTF-16
index with checkpoints about every 1,024 bytes. It retains literal bytes and
rejects surrogate/UTF-8 interiors without a hash entry for every scalar.
Drawing keeps its measured glyph geometry and construction endpoint cache;
other source-range queries share this index with the document model. This
changes neither source nor wrapping.

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
Dependent active and queued conversions now use accepted source receipts.
Immediate presentation and explicit initial replacements during consecutive
queued text edits have automated coverage. Existing unchanged carets may join
through captured source witnesses; an action's correlated result can supply
its newly created carets. Navigation, selection, paste, caret creation and text
queued behind those actions have automated source/save/undo coverage. Until
an action's result arrives, the provisional draft remains in its captured
presentation; this is not complete local prediction of pending navigation.
Immediate input-method context/candidate behavior across arbitrary queued
actions, other action/view transitions and full recovery qualification remain
open. This development implementation does not establish full IME support.
Context sizing and scene traffic still need performance qualification before
release, including the new action-result snapshots.

Native Compose must wrap using measured fonts and available pixel width.
Terminal Markdown column counts, padded or truncated table replacements and
character-sized frames are not a native layout contract. Parsed tables
currently bypass those terminal conceals, retaining editable source, semantic
fonts and image overrides. Native list prefixes also bypass terminal indent
expansion. The native client keeps this source fallback unless its separate
measured-table development switch is enabled; product opt-in awaits workflow
qualification. The native default
uses all available pane width; a reading limit is optional and measured in points.

List continuation indentation is measured from the displayed marker with its
actual fonts. A left-to-right marker uses the shaped body caret so contextual
kerning is retained. When bidirectional layout reorders the marker, its own
logical glyph advances determine the inset; the visual caret can include the
right-to-left body and must not be used as marker width. This fixes excessive
hanging indentation without claiming full right-to-left paragraph alignment.
Prefix shaping uses the first visual line of a shared attributed typesetter,
including at least the first complete body grapheme for contextual spacing.
It avoids a separate whole-paragraph substring/line for each marker. An inline
image's run delegate still requires a final typesetter with its attachment
metrics. This reduces redundant marker shaping; the source window, attributed
typesetter and complete visible layout are not yet bounded by this change.

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

`ComposeTable.measurement_id` and `measurement` supply complete, deduplicated
font inputs for every column, including rows outside the displayed source
window. Samples contain parsed reading text, relative UTF-8 bold/italic/code
styles, image presence and minimum-only source syntax. The latter reserves
room for complete source glyphs without letting URI or markup length dictate
preferred widths. Core Text computes constraints from these inputs and the
available pixel width. Image preference is a scalable share of that width,
independent of which image dimensions have arrived. Source reveal and image
loading therefore do not resize columns. Font, measure or edited table content
can legitimately replace the constraints; a provisional wider cluster can
temporarily expand its edited column without splitting the cluster.

Visible-pane updates deliver measurement inputs once and then refer to their
ID. Scene comparison treats the full payload and its reference as the same
pane state. Held frames do not advance the delivered set. Sender bookkeeping
and receiver retention belong to the current window/pane/document/table;
leaving that table retires its reference, so returning sends a complete set.
Offscreen navigation replies remain self-contained. The consumer validates
style ranges and column counts and reuses validated inputs and measured widths
through source-window changes. These complete inputs still need large-table,
multiple-pane payload and latency qualification before enabling the capability.

The native editor opts out of table cells by default. Its separate development
switch enables qualification against a matching backend. `ComposeTableModel`
validates the new data and resolves its source/display ranges, including
Unicode and malformed-input checks. The shared Core Text renderer now measures
column constraints from fonts/content and available pixel width, wraps complete
cell text, draws native rules and constrains images/previews to cells. Caret,
selection, hit testing and text-service rectangles share those fragments.
Short cells keep a full-height click region beside taller cells; real empty
cells retain their own anchor, while missing-cell clicks enter structural
source. Provisional text reflows within its cell; a draft crossing cells uses
one shared projected flow until commit. Structural source rows span the table.

Navigation now carries optional `ComposeLine.cell` geometry. Source-order line
numbers and per-cell part/count ordinals expose gaps in sparse measurements.
Full row bounds permit side-by-side columns and padding/image space; cell
regions must remain disjoint. Fresh validates source ownership, UTF-8 bounds,
column IDs, part order and row geometry before using a layout. Parser-owned
row neighbors remain on the backend, including neighbors outside a published
source window. Up/Down retains a column across wraps and rows; Home/End uses
the cell's current visual line. Paging selects a real caret in the same column
when its shorter text ends above a taller neighbor. Unknown geometry requests
another measurement. Logical column intent is independent of the pixel goal,
so a style change can reset pixel positioning while retaining the column
through a full-width source row. Pointer input resets that intent.

Deferred Up/Down between table rows retains its parser-owned destination and
logical column when the next source window excludes the original cursor.
Another sparse measurement can refine that destination without restarting
the motion. The input reply retains the requested source anchor until a later
pixel request supersedes it. A source window must contain its requested byte,
including after an unrelated long paragraph. The visible viewport remains
independent of these offscreen measurements.

Already resolved cursors remain part of the pending action until all cursors
can be planned; Fresh then emits one complete event batch. Changed source
revisions, cursor positions, selections or actions invalidate their saved
destinations. Acceptance, cancellation and pointer input retire the pending
plans. The real-plugin socket regression covers a disjoint table-row retry
followed by a second pixel measurement without moving the cursor early.

Table entry and exit also retain a source-flow boundary when their origin is
absent from the next geometry. Complete parser-owned row ranges include pipes,
container prefixes and line endings; a request at those structural bytes must
choose the intended column's first or last part, rather than a sibling's text.
Prose intervals use the real line's source ownership. A cropped projection's
empty trailing drawing placeholder is excluded from native navigation until
the actual next line has been measured. A real document EOF line remains
addressable. These boundary requests preserve the pending selection anchor.

Pixel Page Up/Down now retains its remaining distance through source-window
changes. `ComposeLayout.environment_revision` identifies the fonts, available
measure, viewport height, typography and image-geometry generation; ordinary
scrolling and a different row subset preserve it. Optional flow anchors name
physical text starts, complete parser-owned table rows and document EOF, with
UTF-8 source context and measured y positions. Soft wraps and display-only
prefixes cannot invent source context. Fresh retains the pivot's paragraph or
list marker/complete row while measuring the next region, then resumes from
its new y plus the captured pixel offset. Further windows can rebase the pivot
without changing the intended distance. The original cursor need not be in
the next window, and the visible viewport does not move merely to measure.
Changed rendering environments, source or selections invalidate all cursor
plans before any moves are emitted. A page landing in line padding preserves
its pixel column instead of accidentally acting as Home.

The complete socket test replays actual Core Text geometry across a long image
URI, with selection and an offscreen original cursor. Unit checks cover
multiple forward windows, backwards continuation and rendering/selection
invalidation of resolved and deferred cursors. These are bounded functional
checks; complex nested entry/exit and native input/performance qualification
remain prerequisites for enabling the capability. Minimum-glyph measurement
collects logical caret edges once per shaped sample and combines them by
complete Unicode cluster. Repeated point queries previously scanned the whole
line for every cluster, making the 90 KB URI fixture take 29.67 seconds in
Debug; the same check takes about 0.10 seconds after the change. Logical edges
also avoid treating a primary insertion-point jump across an RTL run as one
glyph's width. The temporary edge buffer uses 16 bytes per UTF-16 unit of the
current sample. Large unique tables, allocations and multiple-pane scene
payload/latency still require qualification; this fixture is not that budget.
Legacy rich clients keep table source and
can share the same backend with a table-capable client without exchanging
their per-client projections. `compose-tables.pb` records that real-plugin
source contract; `compose-table-image-source.pb` adds edited image markup and
its preview. `compose-tables-missing-source.pb` records a missing-cell motion
revealing structural source. Core Text navigation fixtures are replayed by
Fresh's scene socket test, including source reveal and style changes.
These checks do not prove complete interactive table ergonomics.

Native wheel input moves both pixel axes. `ComposeViewport.horizontal_offset`
(field 6) and `ComposeViewportRequest.horizontal_offset` (field 7) carry a
nonnegative, finite translation; omitted values mean zero. The backend keeps
it per client/split/buffer, preserves it through ordinary source edits, and
resets it when the buffer lifetime or edit history becomes opaque. Horizontal
coordinates use the navigation geometry's prototype 100-million-point bound.
Duplicate requests cannot reapply a changed translation. Coalescing retains
the latest horizontal intent while an edit requires the backend's current
vertical source anchor. The consumer clamps drawing to the current content
extent without discarding intent merely because a source window is narrower.

The wrapping measure and content extent are distinct. Complete glyph advances,
ink, caret strokes, table borders and image rectangles can expose an extent
beyond the chosen measure. Horizontal scrolling changes the shared native
origin for drawing, hit testing, selections, images and text-service rectangles;
it does not change source coordinates or navigation's pixel goals. Accepted
caret moves and provisional marked-text updates can reveal both axes. A marked
caret reveal sends only a viewport request, and an acknowledgment keeps the
provisional text and pan intact. Interactive trackpad, source reveal and image
workflows still require the broader native qualification before table opt-in.

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
After image bytes arrive, decoding follows the resource's window, buffer,
filesystem authority, document identity and target, rather than the source
revision or attachment coordinates. Typing and moved references can reuse that
decode. Live Compose documents also retain received bytes through provisional
input and formatting frames without attachment geometry. These document
identities authorize no reads; new requests still need current source demands.
Results remain under their original resource key and normal cache limits.
Closing/hiding the last presentation or replacing its document/authority retires
the decode. Source reads retain their stricter revision/range cancellation and
retry behavior. The four outstanding slots, two decode workers, 64 MiB decoded
cache and 128 cache entries remain unchanged.
Image target identity uses its literal UTF-8 spelling. Canonically equivalent
Unicode names can identify distinct files on an SSH filesystem, so they keep
separate reads, pixels and validation tokens. Identical destination bytes share
work across source references and string representations; Fresh still resolves
the destination on the document's filesystem authority.
When the byte limit evicts an image, the bitmap-free entry retains its known
dimensions, so wrapping, selections and caret geometry do not change merely
because pixels left the cache. The placeholder explains the memory limit.
Reordering demands, nearby images and temporary missing geometry do not restart
that resource. It can retry after the normal backoff when competing visible
pixels leave, a smaller requested thumbnail may fit, or the user explicitly
reloads. Readmission uses known byte costs and checks actual decoded cost again;
the size estimate is not a global memory guarantee. Deferred geometry, failures
and ordinary previews share the same 128-entry metadata limit. Extra visible
resources wait with an explained fallback until an offscreen entry can retire.
These intervals and resource budgets still need interactive/performance
qualification; full GUI/SSH qualification remains open.

Dense inline-image paragraphs reuse advances from one complete Core Text
paragraph while choosing native Unicode break opportunities. This avoids
copying the remaining image delegate runs for each line-break query. The
optimization requires monotonic, untransformed left-to-right glyph runs;
bidirectional/reordered runs and unsupported positions retain native contextual
breaking. Font or image-metric changes create a new typesetter and invalidate
the temporary advances. Only the last measured paragraph is retained during
construction. No source context is clipped, and neither a character count nor
terminal columns determine the wrapping measure.
The long-paragraph preparation scan handles printable ASCII directly, avoiding
Unicode-category lookup for those scalars. Other scalars retain the existing
category checks and contextual break policy; source text remains unchanged.

Native geometry reuse compares literal UTF-8 projection bytes, source maps and
window bounds, document/authority identity, structure, measured image sizes,
fonts and width. Scene revisions and caret/marked-clause selections alone
can share the validated geometry while retaining current presentation metadata.
Draft text, source ranges and raw reveal context also belong to the reuse key.
Raw text-service snapshot reuse also requires literal UTF-8 bytes, preserving
the current UTF-16/source map when canonically equivalent source changes.
Selection-only frames share those immutable indices when the literal text,
source/UTF-16 origins and document length match. Incoming metadata is validated
before reuse, and the selection belongs to the new snapshot. Changed origins,
length or text rebuild the indices.
Virtual insertions use their complete placement path and cannot publish their
provisional geometry as backend navigation. Sparse navigation samples retain
their source/rendering ownership and must contain every current caret and
selection endpoint. Nearby measured carets can keep the existing sample;
distant carets or changed source/rendering ownership require a fresh sample.

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
