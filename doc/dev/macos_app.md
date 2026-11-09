# The macOS app: development

How the macOS app is built, how it uses the core, how to test it, and how to
write explainers. User-facing behavior is in [../macos_app.md](../macos_app.md);
the layers below the app are in [architecture.md](architecture.md).

- [Layers](#layers)
- [Build](#build)
- [Tests](#tests)
- [Explainers](#explainers)
- [ExplainerKit in other projects](#explainerkit-in-other-projects)

## Layers

```
File Commander.app   macos/Sources/FileCommander   SwiftUI views, menus, sheets, settings,
                                                   key router, themes, native editor, tutorial
ExplainerKit         macos/Sources/ExplainerKit    anchors, annotation window, runner, recorder
FreshKit             macos/Sources/FreshKit        client of a Fresh session's scene: socket, store, keys
FCKit                macos/Sources/FCKit           Engine: Swift values, drain on the main actor
fc_engine            fc_engine.hpp/.cpp            the facade Swift imports (value types only)
fc_model             pane_model, app_model,        panes, tabs, commands, dialogs' workers,
                     dialog_models, editor_manager, watchers, editor; shared with the TUI
                     file_change_funnel
fc_core              unchanged                     locations, plans, jobs, journal, SSH, archives
```

- **Threads.** Workers never call Swift. They queue closures in the engine's
  mailbox and call the wake function once; Swift then calls `fce::drain()` on
  the main actor, which runs the closures, ticks housekeeping (workspace
  checkpoint, settings save) and returns revisions plus dialog requests,
  notices and editor attaches. Design rules 1 and 2 of the architecture hold.
- **Rows.** Listings are never copied whole: the table asks `row_count` and
  `row(side, index)` for visible rows only.
- **Commands.** `app_commands()` in `app_model.cpp` is the app's catalog: ID,
  title, menu, scope, dialog and a key for each preset. `AppModel::execute` is
  the one dispatch path for keys, menus, the palette and explainers. Commands
  that need UI return a `DialogRequest`, which the app turns into a sheet,
  popover or window.
- **Keys.** `KeyRouter` (an `NSEvent` local monitor) runs bound commands and
  types into the filter while a list has the focus. Menus show the same chords;
  `AppController.run` ignores a second run of one key press, so a command runs
  once even when a menu sees the key too. Menu items skip chords without `⌘`,
  `⌃` or an F-key, and the standard text-editing chords.
- **The editor.** Before attaching, `EditorManager` asks the session for its
  scene socket (`fresh --cmd session ensure`) and hands the app an attach with
  `scene_socket` set; the app connects and draws the editor natively (below).
  When the session serves no scene (an older Fresh), the attach is the
  `fresh -a` command instead, run in a SwiftTerm view (`TerminalEditor`); Fresh
  detaches on its switch key and the app watches the client's PID.
- **SSH prompts.** The app starts a Unix-socket server and sets `SSH_ASKPASS`
  to the bundled `fc-askpass` with `SSH_ASKPASS_REQUIRE=force`; each prompt
  becomes a sheet.
- **The native editor.** `FreshKit` speaks the scene protocol described in
  [fresh_integration.md](fresh_integration.md#scene-channel): `SceneWire`
  frames protobuf messages by type and length, `SceneSocket` is the
  connection over the Unix socket (messages decoded on a thread of their own,
  delivered in order on the main actor), `SceneInput` names the messages the
  app sends, `SceneStore` applies the hello and the frames into typed views of
  the scene (the `Wire…` types generated from Fresh's `scene.proto`), and
  `SceneKeys` maps Mac keys to Fresh's key names. In
  the app, `NativeEditor` owns the connection and one `EditorHostView` for
  the life of the app (the grid, the chrome and the panels);
  `CellGridView` draws the frame's cells with Core Text (every glyph on its
  cell, box-drawing lines as lines) and turns keys, mouse, scrolling and
  `NSTextInputClient` text into messages; `ChromeView` draws Fresh's tabs,
  status bar, dividers, scrollbars, sidebar, palette, popups, context menus and
  trust dialog natively over the exact cells Fresh laid them out on, and
  passes clicks through to the grid, so Fresh's own hit-testing answers them;
  `FreshMenus` builds Fresh's menus into the menu bar while the editor is
  shown and the main window is key;
  `FreshModals` shows Fresh's Settings and key binding editor as SwiftUI panels
  that never take the keyboard and send clicks as `SettingsClick` and
  `KbEditClick` messages, and steps aside for Fresh's own small dialogs (unsaved-changes
  confirmation, the binding edit dialog).
  `EditorController` is the one interface explainers use for either editor.
  Restart Editor Backend disconnects first, because Fresh restarts only with
  no client.
- **One window.** `MainWindow` keeps the panes and `EditorPane` (which places
  `EditorController.view`, the native editor's or the terminal's) on top of
  each other and shows one; both stay in the hierarchy, so the panes keep
  their scroll position and selection and Fresh keeps its grid size. While
  `AppController.editorShown`, `KeyRouter` leaves the main window's keys to the
  editor, focus requests don't move the keyboard to a pane, the sidebar folds
  (restored afterwards) and the toolbar trims to the Files | Editor switch,
  Activity and Errors. Switching back hides the editor and keeps the
  connection.
- **Menu bar ownership.** SwiftUI writes changes to the app's commands into
  whatever `NSApp.mainMenu` is installed, including Fresh's. So the commands
  read nothing that changes while Fresh's menus are up: the Transfers menu
  follows `AppController.menuJob` (the running job's identity and paused
  state, not its progress), held still while `menusHeld`. Should a change get
  through anyway, `FreshMenus` sees items added to or removed from its bar and
  rebuilds it.
- **The profile.** The app shares the TUI's profile. Its own settings are in
  `app_settings.json`; it writes `settings.json` back with the TUI's key
  bindings untouched.

## Build

### Xcode and signing

Copy `macos/Xcode/Signing.local.xcconfig.example` to
`macos/Xcode/Signing.local.xcconfig` and set your team ID there. The local file
is ignored by Git; keep certificate hashes and provisioning choices there too.
The app's bundle ID is `me.h264.filecommander`.
Open `macos/FileCommander.xcodeproj`; the shared **FileCommander** scheme
builds and runs the complete app. Use **Product › Archive** for the
Release configuration. For public releases, use Organizer's Developer ID
distribution workflow to sign and submit the app for notarization.

```sh
open macos/FileCommander.xcodeproj
```

The app target calls the existing CMake and Swift package build through
`tools/xcode_build_app.sh`; it does not maintain a second list of app sources.
It copies the app's executables and resources into Xcode's product directory,
signs the embedded code with Xcode's selected identity, and leaves the final
app signature to Xcode. Missing signing credentials stop the Xcode build rather
than falling back to ad hoc. The intermediate bundle in `build-macos` is still
signed ad hoc explicitly; use the app in Xcode's Products directory or its
archive for the Xcode-signed result.

Debug builds use the Swift package's debug configuration. Release builds enable
hardened runtime, including the JIT exceptions needed by the `fc` and `fresh`
helpers. The project builds for the current Mac's architecture. CMake, Ninja,
Rust and the pinned dependency checkouts are required as for the script build
below. User-specific Xcode workspace files are ignored by Git.

You can still open `macos/Package.swift` for Swift package development and tests;
that package alone does not assemble or sign the final app bundle.

### Script build

```sh
macos/build_app.sh            # release build: build-macos/File Commander.app
macos/build_app.sh --debug    # faster Swift compile
macos/build_app.sh --open     # build, then open the app
macos/build_app.sh --install  # build, verify signing and replace the installed app
macos/build_app.sh --install --open  # install, then open the installed copy
macos/tools/update_app.sh     # after Swift-only changes: update the bundle in seconds
```

The script configures the `macos-app` CMake preset once (deployment target macOS 14, reusing the dependency checkouts from `build-release` if there is one), builds `libfc_engine_bundle.a`, `fc`, `fresh` and 7-Zip's `7z.so`, builds the Swift package in `macos/`, and assembles the bundle:

| In the bundle | Comes from |
| --- | --- |
| `Contents/MacOS/FileCommander` | Swift package, product `FileCommander` |
| `Contents/MacOS/fc-relaunch`, `fc-askpass` | Swift package helpers |
| `Contents/MacOS/fc`, `fresh`, `7z.so` | CMake (`build-macos/`, Fresh with its `web` feature); found next to the app as for `fc`, and `7z.so` loaded by the engine |
| `Contents/Resources/FileCommander_FileCommander.bundle` | explainers and themes |
| `Contents/Resources/AppIcon.icns` | drawn by `macos/tools/make_icon.swift` |

`--install` updates an existing copy in `~/Applications` or `/Applications`
(preferring the user copy when both exist); a first install goes to
`~/Applications`. Set `FC_APP_INSTALL_DIR` to choose another directory, for
example `FC_APP_INSTALL_DIR="$HOME/Applications" macos/build_app.sh --install`.
Quit File Commander before installing. The installer verifies the built app's
signature, copies the full bundle to a temporary directory on the destination
volume, verifies that copy, then atomically replaces the installed bundle.
Build, copy or verification failures leave the installed app intact. It never
merges new files into an old bundle. `--open --install` opens the installed copy.
Replacing a certificate-signed installation requires the same signing team;
an ad hoc build cannot replace it. The standalone installer also accepts
`--expected-team` to enforce a team for a first install without storing it in Git.

`macos/tools/sign_app.sh` signs the bundle, inside out (helpers and resource
bundles, then the app). It uses `FC_CODESIGN_IDENTITY` when that is set (`-`
for ad hoc), else the first valid Apple Development identity in the keychain,
else an ad hoc signature. A real identity keeps the app's code identity the
same across builds, so macOS asks for a permission (such as files on network
volumes) once; an ad hoc signature changes with every build, and macOS asks
again each time.

Installation uses `codesign --verify --deep --strict`; a trust or signature
failure stops installation. For a local ad hoc build, explicitly select
`FC_CODESIGN_IDENTITY=-`.

`macos/tools/update_app.sh` rebuilds only the Swift products (debug unless
`--release`), puts them into the existing bundle, installs `fc`, `fresh` and `7z.so` from `build-macos` when they are newer than the bundle's, and signs
again; `--fresh <path>` installs another Fresh build, such as one from the
fork's checkout (`target/fc-release/fresh` when built with FC's profile, see
[fresh_integration.md](fresh_integration.md#building-and-packaging)). Executables are copied next to the old file and moved over
it: macOS kills a signed program whose file was changed in place ("Code
Signature Invalid") at its next launch. A failed Swift build leaves the bundle
as it was.

The Swift package links the engine with
`-L build-macos`, so build the CMake side first; `swift build --package-path
macos` alone works once `build-macos/libfc_engine_bundle.a` exists. SwiftTerm
is pinned to 1.11.2, the last release without Metal shaders, so the build
needs no Metal toolchain.

## Tests

| Test | What it checks |
| --- | --- |
| `python3 test/test_macos_install.py` | Disposable signed apps: first install, replacement, failure preservation, running-app checks, and build failures with stale outputs. Never installs into your Applications folders. |
| `fc.model.panes`, `fc.model.commands` | `PaneModel` and `AppModel`: listing, filter, glob, cursor, sort, tutorial tabs, the command catalog, palette ranking, dialog requests, settings |
| `fc.model.rate` | A raised transfer limit applies within a running file |
| `fc.model.engine` | The facade end to end: start, rows, glob, jobs, profile lock |
| `fc.model.editor` | Attaching hands the app the session's scene socket, or the terminal command when there is none |
| `fc.macos.explainers` | `macos/tools/check_explainers.py`: every step, key, command and anchor in the explainers exists, and every visible command is covered |
| `fc.macos.native_harness` | Negative controls for native test discovery, complete results, skipped cases, input hashes and process timeouts; runs without Swift or an app on both supported platforms |
| `fc.macos.native_editor` | macOS integration/release gate: every compiled FreshKit and NativeEditor case, including real private Fresh backends; refuses missing/duplicate/skipped results |
| `swift test --package-path macos` | FCKit drives the real engine; ExplainerKit decodes every explainer and builds captions; FreshKit checks the scene protocol, source maps, measured typography, images, and scrolling; NativeEditorTests drives the production native editor against a private scene peer |

`Tests/NativeEditorTests` imports the application target and controls scene
timing over a disposable Unix socket. It verifies captured click positions
through reflow, queued typing bound to its original buffer lifetime, terminal
cancellation, modal input while a document command waits for geometry, and
formatting readiness. Readiness checks cover holding the previous source map,
waiting input, delayed caret reveal, and editable source fallback on failure.
Typography checks cover profile persistence and font fallback, retaining the
source reading anchor when fonts or spacing change, and invalidating obsolete
navigation measurements.
The tests create their own editor view, including a real-backend check of rich
Compose defaults without environment flags. They do not attach to an existing Fresh session or
open the installed app. To run the affected editor checks:

```sh
swift test --package-path macos --filter 'NativeEditorTests|FreshKitTests'
```

The complete automatic editor gate is registered in non-core macOS builds
with `FC_TEST_MACOS_NATIVE=ON` (the default). Build first, then run:

```sh
ctest --test-dir build-release -R '^fc.macos.native_editor$' --output-on-failure
```

It uses that build's `libfc_engine_bundle.a` and staged Fresh, rather than an
archive or backend from another app build. `FC_ENGINE_LIBRARY_DIR` supplies
the selected archive directory to the Swift package; ordinary app builds keep
their default `build-macos` directory. The gate uses an isolated Swift scratch
directory, locked package versions and the matching build configuration.
The first run may fetch the Swift dependencies in `Package.resolved`.
Compiled discovery must include every suite in
`macos/Tests/required_editor_suites.json`, and every discovered method must
finish exactly once without a skip. Logs, discovery, per-case XML and input
hashes live under `<build>/test-logs/native-editor-*` (inside a lane's artifact
directory when run through the lane). A developer can disable the gate, but
macOS release preflight rejects `FC_TEST_MACOS_NATIVE=OFF`.

Direct `swift test` still allows real-backend cases to skip when
`FC_COMPOSE_TEST_FRESH` is absent. The CTest gate always supplies it and rejects
skips. These private offscreen checks do not qualify actual input methods,
candidate windows, VoiceOver or live SSH; use the isolated
[interactive qualification workflow](testing.md#interactive-compose-qualification)
for those checks.

**Settings › Editor › Markdown Compose** is available by default.
`ComposePreferences` stores body/code font families, body
size, six heading scales, line and paragraph spacing, list/quote indentation,
and page width under `compose` in `app_settings.json`. Missing fields retain
defaults; numerical values are bounded and missing fonts fall back to system
fonts. Code and the current table source fallback use a monospace font;
that does not impose a column count. Defaults are 16 pt body
text, heading scales of 1.8/1.5/1.25/1.15/1.05/1, 3 pt additional line spacing,
6 pt paragraph spacing and 24 pt indentation. Compose uses the available pane
width by default (`pageWidth: 0`). **Limit reading width** enables an optional
maximum in points; existing explicitly saved positive limits are preserved. The
app's zoom scales native Compose fonts and spacing as well.

Terminal Markdown's fixed column measure does not govern native wrapping.
Parsed tables use measured native cells by default, with editing and navigation
mapped to the Markdown source. `FC_NATIVE_MEASURED_TABLES=0` requests editable
table source for compatibility troubleshooting.
Code blocks use parser-owned content ranges and measured native frames;
character-sized terminal frames do not enter the native projection.

`ComposeTextLayout` measures indentation, block spacing, image attachments,
and styled fonts together. Drawing, hit testing, selection and navigation use
those fragments. Link colors, quote text/rules and code backgrounds follow
Fresh's theme; underline and strikethrough are drawn from Fresh's semantic
flags. The same rendering path produces the checked bitmap previews. These
controls are available with rich Compose. Interactive input-method, VoiceOver
and live SSH qualification remains separate from the automatic editor gate.

`ComposeImageController` revalidates visible images in the background and checks
them when the editor is shown again. It retains the decoded image until a
replacement is ready. Unchanged binary replies update freshness without
decoding or reflow. A transient failure shows the last preview with a warning;
small inline images use a badge rather than a footer that would cover them.
Hovering an image shows its alt text/title and any loading or failure details.
When image markup is revealed for editing, `ComposeTextLayout` keeps the
source as text and reserves a separate preview below its last measured line.
That preview shares image loading, tooltips and source-range hit testing with
rendered attachments. It adds no document characters or navigation stops.
List/task continuation alignment uses Fresh's parsed body anchor and a Core
Text prefix measured in its shaping context, including the first body character.
The same measure constrains images and previews within a list. The recorded
`compose-lists.pb` fixture comes from the real Compose plugin/socket contract;
FreshKit checks it at several widths alongside raw-source and font-size cases.
Native quote rails are continuous block rectangles, including through
monospace-only text, nested quotes and image preview gaps. Thematic rules draw
once within their measured source line; revealed or fallback source is not
painted over. `compose-ornaments.pb` records the real-plugin projection for
these checks. Protobuf fixtures are marked binary in `.gitattributes` so Git
does not treat embedded Markdown line endings as source-file whitespace.

`compose-code.pb` records real-plugin code blocks in quotes and lists, including
an item whose first line is a code fence, empty blocks and an unclosed fence.
Fresh conceals fence/container syntax while preserving code bytes and source
line endings; the edited line reveals its exact source. Native code frames
wrap to the pixel measure, and their insets govern caret, selection, navigation
and marked-text layout. List markers stay outside the code frame. Partial
content windows draw open frame edges. Code uses the configured monospace font
without a fixed column count; its background and border follow the theme.

FreshKit also decodes and validates the experimental parser-owned table model
in `compose-tables.pb`: alignments, Unicode, images, real empty cells, missing
cells, bounded rows and source reveal. Shared Core Text layout now renders
measured cells and native rules, with proportional text, wrapping, alignment,
full-height click targets and image/preview constraints. Selection, caret and
text-service geometry use those same cell fragments. Real empty cells retain
an anchor; missing cells enter source flow. Marked text reflows within a cell;
a cross-cell draft temporarily uses one shared projected flow. The additional
`compose-table-image-source.pb` fixture exercises edited image markup/previews.
Cell navigation now exports source-ordered line/part ordinals, complete cell
edges around sparse regions and full row bounds. Missing-cell regions target
real structural source; empty cells keep their explicit anchor. Fresh validates
ownership and routes Up/Down, Home/End and Page actions through its keybindings.
Logical column intent survives source reveal and pixel-goal resets. Native
column geometry changes reset the pixel goal. The scene socket test replays
Core Text geometry through source reveal and selection; the additional
`compose-tables-missing-source.pb` fixture covers the revealed row.
The native editor still requests table source while cross-window retries,
horizontal scrolling and stable measures across source windows are qualified.
`SceneSocket.open(measuredTables:)` defaults to false. These renderer tests do
not establish complete interactive table qualification.
Native clipboard access is injectable; scene/input tests use memory storage
instead of reading or overwriting the user's system pasteboard.

For unmarked [AppKit text input](https://developer.apple.com/documentation/appkit/nstextinputclient),
the native view exposes document-wide source UTF-16 selection/context ranges
and measured first-line rectangles. Fresh's bounded `ComposeTextContext`
retains raw Markdown independently of the displayed source window and concealed
syntax. Requests outside that context can return nil; a complete captured
primary selection remains replaceable even when larger than the context.
Accessibility keeps the separate displayed value and matching display selection.
The view invalidates input-method geometry after presentation changes and
notifies selection changes where the platform API is available.
`ComposeReplacement` captures the corresponding source-byte range,
revision, view lifetime and cursor ID before queueing it. Fresh owns validation,
conflict cancellation and the atomic edit/undo operation. Committed phrases
use `SceneInput.text`; clipboard paste retains its separate column-paste
semantics.

Large documents can temporarily show proportional raw source while Fresh's
bounded semantic parser worker runs. Accepted source/cursor receipts still
allow typing to continue; measured navigation waits for a usable current
projection. This path has no 2 MiB source cutoff. Source snapshot/index work,
large-block payload bounds and full interactive latency remain release
qualification work; see [the integration contract](fresh_integration.md).

`ComposeComposition` coordinates `ComposeMarkedText` snapshots at the captured
carets. Default composition broadcasts to all original carets; an explicit
initial replacement range addresses only the primary. It supports partial
replacements and selected subranges without
changing Fresh's buffer. `ComposePaneLayout` lays out that provisional text
with the paragraph's typography, wrapping, images and shared caret/selection
geometry. Marked text is underlined; accessibility selections address the
provisional displayed value. The projection retains its original source
revision while unrelated source replies arrive and never supplies navigation
feedback to Fresh. Unmarking commits once; explicit cancellation restores the
original presentation. A retired source target or failed commit retains text
for explicit copying rather than inserting into a replacement view.
Each caret keeps its own source range; all targets commit as one Fresh undo
transaction. Overlapping expansions are refused together. Text-service indices
include provisional length changes at earlier carets, including offscreen ones.

**Edit > Copy Uninserted Text** is available in the editor's menu and FC's
menu after disconnection. Text stays in memory for the application session;
copying neither clears it nor happens automatically. Application restart
does not preserve this native recovery list. Private backend checks cover
repeated compositions during pending edits. Live IME and interactive recovery
qualification remains separate from those checks.
Tooltip rectangles share the attachment geometry and are replaced only when
their positions or descriptions change.

The experimental rich view exposes measured accessibility text, character and
visual-line ranges, font sizes, visible ranges and screen bounds. Primary and
secondary provisional selections address that displayed value. Inline images
have labeled accessibility elements and attachment attributes; an image action
selects its Markdown source through Fresh's ordinary pointer queue. Retained
image objects cannot act after their source ownership or connection changes.
Direct accessibility text/selection setters, semantic heading/link navigation
and actual VoiceOver interaction still require qualification and completion.

FreshKit tests cover the refresh timer, conditional replies, source-edit
throttling, duplicate references across splits, bounded caches/decodes,
temporary failure recovery, missing images, and negative caching of invalid
content. The production-native socket tests additionally verify revalidation
after switching back from the panels, keeping the previous image until decode
finishes, and the tooltip for a stale preview. The test peer does not establish
live SSH or interactive GUI qualification.

`Tests/FreshKitTests/Fixtures/scene.tlv` comes from
`macos/tools/record_scene.py`, which starts a throwaway Fresh session, connects
to its scene socket as the app does, types a few keys, opens the palette and
scrolls, and saves the messages as they came off the socket. Rerun it after
bumping the Fresh pin, then run the tests. After a change to Fresh's
`scene.proto`, regenerate the app's types with `macos/tools/gen_scene_proto.sh`.

The explainers are end-to-end tests of the app. Run one, or all of them, in a
throwaway profile; the app quits with status 0 when the explainer finished and
1 with the failing step on stderr:

```sh
APP="build-macos/File Commander.app"
open -n "$APP" --args --profile /tmp/fc-test --run-explainer copy --trace /tmp/fc-test.log
open -n "$APP" --args --profile /tmp/fc-test --run-explainer entire --speed 2
```

`--trace FILE` logs every step, key, command and editor screen. Use `open` so
the app is activated: keys only reach an active app, and an inactive one (a
locked screen, another app in front) makes keyboard steps time out.

## Explainers

Explainers live in `macos/Sources/FileCommander/Explainers/`, one JSON file
each plus `chapters.json`. They are written with
`macos/tools/explainers.py` (run it after editing) and checked with
`check_explainers.py`.

```json
{
  "id": "pause_resume", "title": "Pause and resume", "chapter": "jobs", "order": 15, "duration": 70,
  "summary": "Pausing holds the whole queue; resume continues; cancel keeps what was copied.",
  "needs": { "idle_queue": true },
  "covers": { "commands": ["toggle_job_list"], "anchors": ["jobs.bar.pause"] },
  "steps": [
    { "open_tabs": { "left": "{home}/music", "right": "{home}/backup", "focus": "left" } },
    { "set_transfer_speed": "4 MiB" },
    { "cursor": { "side": "left", "name": "Night Drive" } },
    { "keys": ["@copy"] },
    { "wait": { "sheet": "copy" } },
    { "click": "sheet.copy.start", "as_job": "music" },
    { "caption": "Pause", "sub": "Pause holds the job between two reads" },
    { "click": "jobs.bar.pause" },
    { "wait": { "job": { "name": "music", "state": "paused" } } }
  ]
}
```

- **Keys**: `"@copy"` presses whatever key the user's preset binds to `copy`
  (or runs it when nothing is bound), so explainers teach the user's own keys.
  Plain chords (`"Enter"`, `"Cmd+A"`, `"Ctrl+Opt+S"`) are pressed as written.
  Keys are posted as real key events, through menus, the key router and text
  fields.
- **Placeholders**: `{home}`, `{server}`, `{world}` in paths, typed text and
  anchor IDs.
- **Runner steps** (ExplainerKit): `caption`, `uncaption`, `chapter`,
  `highlight`, `unhighlight`, `spotlight`, `stamp`, `point`, `click`, `drag`,
  `keys`, `type`, `pause`, `wait`, `wait_not`, `expect`, `try` (Guided mode).
  Options: `hold`, `timeout`, `gap`, `ms`, `as_job`.
- **Host steps** (the app): `open_tabs`, `navigate`, `focus`, `cursor`,
  `command`, `set_transfer_speed`, `set_preference` (`selection`, `keys`,
  `appearance`, `theme`, `zoom`, `terminal_editor`; restored when the
  explainer ends), `open_window`,
  `close_window`, `front`, `touch`, `remember`, `crash`, `relaunch`,
  `editor_type`, `editor_keys`, `run_script`, `remove_bookmark`, `notice`.
- **Conditions**: `rows`, `selected`, `cursor`, `path`, `filter`, `loaded`,
  `tabs`, `focused`, `single`, `sort`, `columns`, `sheet`, `palette`, `glob`,
  `text_focus`, `anchor`, `job` (by `as_job` name, `running` or `paused`),
  `running_job`, `queued_at_least`, `event`, `clipboard`, `hud`,
  `errors_at_least`, `no_errors`, `window`, `editor` (`running`, `contains` a
  regex, `shows` or `hides` a native surface, `window`: the editor has the
  keyboard in that window), `bookmark`, `transfer_rate`,
  `file` (`exists`, `missing`, or `path` with `contains`), `theme`,
  `font_size`, `menubar` (a top-level menu of that title is in the menu bar),
  and `all`, `any`, `not`. A `wait` passes as soon as its condition holds, so
  a check for something that could go wrong later (the menu bar after a job
  ends) comes after a pause, or again later in the explainer.
- **Needs**: `idle_queue` refuses to start while the user's own job runs;
  `editor` gives the explainer a new Fresh session; `restart` and `crash` keep
  the tutorial tabs in the workspace checkpoint; `crash` asks first.

**Anchors** are declared in the views with `.explainerAnchor("id")`, optionally
with the action a scripted click runs (the same closure as a real click).
Table rows (`pane.left.row[name=…]`), the editor's text
(`editor.text[<regex>]`) and its native surfaces (`editor.tabs`,
`editor.status`, `editor.palette`, `editor.popup`, `editor.explorer`) are found
by resolvers. `pane.focused` and
`pane.other` resolve to the left or right pane. The checker reads the anchor
IDs from the Swift sources, so a renamed anchor fails the test.

**Safety**: the host refuses `touch` outside the demo files, explainers open
their own tutorial tabs, and when the tutorial ends it cancels and dismisses
the jobs it started, restores the transfer speed, preferences, theme and
bookmarks it found, closes its tabs, removes the demo files and stops its Fresh
session.

**Recording**: `--export-explainer <id|all> --out DIR [--appearance
light|dark|both] [--speed N]` records each explainer (except those that
restart the app) at 1280×800 with ScreenCaptureKit and writes a movie, SRT
and VTT captions, a still per caption, a preview GIF and a `README.md`, plus
`DIR/index.md`. With `both`, the pages use `<picture>` so GitHub shows the
reader's appearance. Recording asks for the Screen Recording permission.

## Editor timing

Settings › Editor › **Record editor timing** writes the native editor's timing
to `<profile>/telemetry/editor-<date>.jsonl` (`EditorTelemetry`), one JSON
object per line, times in milliseconds of system uptime (the clock of
`NSEvent.timestamp`):

| Record | When | Fields |
| --- | --- | --- |
| `wheel` | A scroll event reaches the editor | `et` (the event's own time), deltas, phases, `steps` sent, `at` (cell) |
| `send` | A message to Fresh is written | `n` (its number, what a frame's `ack` counts), `type`, `kind` |
| `frame` | The main thread applies a frame | `t` (read off the socket), `parse`, `applied`, `apply`, `rows` sent and `copied`, and Fresh's `ack`, `build` (of it `render` and `grid`), `diff`, `queued`, `ahead`, `owed`, `top`, `cpu` (Fresh's CPU time so far), `pallocs` and `pbytes` (allocations and bytes of Fresh's previous push, from an `alloc-stats` build), and `appcpu` (the app's CPU time so far) |
| `draw` | The cells are drawn | `ms`, `rows`, `seq` (the last frame shown) |
| `keys` | A benchmark key run starts and ends | `label`, `phase`, `key`, `interval`; at the end `presses`, `unanswered`, `seconds` |
| `bench` | A benchmark mark | `mark`: `<name>-start` when armed, `<name>` when the first frame showing the watched text was applied |

The app asks Fresh for its part with `telemetry` in its hello, or `Configure`
when the setting changes
([fresh_integration.md](fresh_integration.md#scene-channel)).

`macos/tools/editor_telemetry.py <file>` summarizes a recording per scroll
gesture: how long input waited for the main thread, the round trip from a
scroll message to the frame that applied it (by `ack`) and to its draw,
Fresh's build and queue, the app's parse, apply and draw, how far the shown
line trails the asked one, and how long the view keeps moving after the input
stops. `--timeline N` prints gesture N event by event. A benchmark key run
gets the same round trip per key press, frame and press rates, Fresh's and
the app's CPU per frame and Fresh's allocations per frame; a watch mark gets
how long a file took to show after the key that opened it.

**Benchmark.** `macos/bench/scroll_flicks.json` plays six trackpad flicks
(`ScrollGesture`: a finger phase, then decaying momentum, at 120 events a
second) into the editor showing `file_io_jobs.cpp`, then into a plain AppKit
text view of the same file, with timing recorded:

```sh
open -n "build-macos/File Commander.app" --args --profile /tmp/fc-bench \
  --run-explainer "$PWD/macos/bench/scroll_flicks.json" --speed 1
macos/tools/editor_telemetry.py /tmp/fc-bench/telemetry/editor-*.jsonl
```

`macos/bench/scroll_slow_app.json` scrolls an editor whose frames each take
25 ms longer on the main thread, as a slow redraw would: Fresh holds newer
frames back and sends the newest scene once the app catches up (see
[Frames and the app](#frames-and-the-app)).

`macos/bench/page_down_large.json` opens a small file first, so the timed
opens find the editor running, then `file_io_jobs.cpp` repeated 40 times
(about 61,000 lines), and pages down to its end twice: at key-repeat speed
(every 33 ms), and as fast as frames come back (the next press when the frame
answering the last one is applied). Then it times opening the file repeated
200 times (about 304,000 lines, 12 MB).

Allocations are counted only by a Fresh built with the `alloc-stats` feature
([fresh_integration.md](fresh_integration.md#building-and-packaging)), so a
benchmark run for timing uses the normal build and a second run counts:

```sh
cargo build --locked -p fresh-editor --bin fresh --features web,alloc-stats \
  --profile fc-release --config 'profile.fc-release.inherits="release"' \
  --config 'profile.fc-release.opt-level=3' --target-dir target-alloc
macos/tools/update_app.sh --release --fresh ../editor-fresh/target-alloc/fc-release/fresh
```

`--run-explainer` takes a script file as well as an explainer ID. Bench steps
are host steps like the explainers': `scroll` (`target` `editor` or
`textview`, `speed` in points per second, negative scrolling down, optional
`finger_ms` and `decay`), `textview_open` and `textview_close`,
`window_frame` (`w`, `h`), `editor_bench` (`apply_ms`, extra main-thread time
for each frame), `generate_file`
(`from`, `copies`, `to`: a large file whose first line names it and whose last
is `// END OF LARGE FILE`), `editor_watch` (`contains`, `mark`: marks when a
frame first shows the text), `editor_trust` (answers Fresh's prompt to trust a
new folder with Enter, if it shows within `timeout` ms), `editor_key_repeat`
(`key`, `until` a condition, `interval_ms`, 0 for the next press as soon as a
frame shows the last, `max`, `label`), and `{repo}` in paths for the checkout
the build lives in. Gestures go to the view on the main
queue from a timer of their own, so a busy main thread delays them as it would
a trackpad's.

### Frames and the app

The scene socket has 4 MiB buffers on both ends; macOS's default of 8 KiB per
direction is a fraction of one frame, and frames queued up behind it in
Fresh while scrolling, up to 1.4 s behind the trackpad. The app reports each
frame it applied (`Applied` with its `seq`) and Fresh keeps at most two frames
unapplied: while the app is behind, Fresh builds nothing, and once it catches
up it gets one frame with the newest scene. With frames slowed by 25 ms, that
keeps a frame from input to screen at p50 64 ms instead of 142 ms without
reports.

A frame names grid rows the app already has by where they were in its
previous frame (`copies`, `[to, from, count]` triples, applied to the
previous rows before the rows sent in full), so a scroll sends only the rows
that came into view and the scrollbar's. On the JSON channel this replaced,
that took a scroll frame from 55–88 KiB to 4–10 KiB, the app's parse from
1.5–2 ms to 0.3 ms, and Fresh's build from 7–8 ms to 5–6 ms.

FC builds Fresh with its own `fc-release` profile, at `opt-level` 3 where
Fresh's release profile has `"z"`
([fresh_integration.md](fresh_integration.md#building-and-packaging)): a
scroll frame then builds in 2–3 ms, reaches the app 5–6 ms after the wheel
event (p50) and is on screen after 10–15 ms (p95 under 20 ms).

The scene channel's protobuf messages
([fresh_integration.md](fresh_integration.md#scene-channel)) replaced JSON
and halved a page-down frame (18.6 KiB instead of 40.6). Fresh encodes a
frame in 0.1 ms instead of 1.6–2.2 ms, and the app decodes it in 0.1 ms
instead of 0.9–1.1 ms. Paging down through a 61,000-line file
(`page_down_large.json`) at key-repeat speed, a frame reaches the app 7.1 ms
after the key instead of 9.8 ms (p50) and is drawn after 15.2 ms instead of
19.3 ms. Pressing as fast as frames come back, the editor answers 172 presses a
second instead of 110. Fresh allocates 10,700–14,700 times per frame instead of
76,000–80,000, all of it while rendering the editor and building its views;
encoding allocates nothing. Opening a large file takes 120–140 ms either way.

Fresh's render keeps what frames repeat: a buffer's rows are reused while
what they are drawn from is unchanged, so a scroll draws the rows that came
into view; the menu model is rebuilt only when the menus, the keymap or the
menu context change; the app's grid rows are hashed with foldhash. Measured
on the app's scene path at 200×60 in the same 61,000-line file, a wheel step
renders in 0.86 ms instead of 1.02 (p50; p95 1.11 instead of 1.27) with 4,950
allocations instead of 6,570, and paging into new text stays at 2.9–3.0 ms,
more than half of it spent highlighting the new lines. Plugins' `lines_changed`
batches are built only for buffers a plugin asked for (Markdown compose and
live diff ask only for the ones they decorate), so a code buffer's frame no
longer copies its visible lines for them: about 200 fewer allocations per
frame and 2.5–3.5% less CPU, with frame times unchanged.

## ExplainerKit in other projects

ExplainerKit (`macos/Package.swift`, library product `ExplainerKit`) has no
File Commander code. A host implements `ExplainerHost`: the window to cover,
pressing keys and typing, conditions on its state, its own steps, and setup
and cleanup; views name themselves with `.explainerAnchor`. The runner, the
annotation window, the recorder and the exporter come with the package, so
another app gets explainers, videos and GitHub pages from JSON scripts.
