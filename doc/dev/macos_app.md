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
  [fresh_integration.md](fresh_integration.md#scene-channel): `SceneSocket` is
  a minimal WebSocket client over the Unix socket (frames parsed on a thread of
  its own, delivered in order on the main actor), `SceneStore` applies `hello`
  and `frame` messages, and `SceneKeys` maps Mac keys to Fresh's key names. In
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
  that never take the keyboard and send clicks as `settings` and `kbedit`
  messages, and steps aside for Fresh's own small dialogs (unsaved-changes
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

```sh
macos/build_app.sh            # release build: build-macos/File Commander.app
macos/build_app.sh --debug    # faster Swift compile
macos/build_app.sh --open     # build, then open the app
macos/tools/update_app.sh     # after Swift-only changes: update the bundle in seconds
```

The script configures the `macos-app` CMake preset once (deployment target
macOS 14, reusing the dependency checkouts from `build-release` if there is
one), builds `libfc_engine_bundle.a`, `fc`, `fresh` and `7zr`, builds the
Swift package in `macos/`, and assembles the bundle:

| In the bundle | Comes from |
| --- | --- |
| `Contents/MacOS/FileCommander` | Swift package, product `FileCommander` |
| `Contents/MacOS/fc-relaunch`, `fc-askpass` | Swift package helpers |
| `Contents/MacOS/fc`, `fresh`, `7zr` | CMake (`build-macos/`, Fresh with its `web` feature); found next to the app as for `fc` |
| `Contents/Resources/FileCommander_FileCommander.bundle` | explainers and themes |
| `Contents/Resources/AppIcon.icns` | drawn by `macos/tools/make_icon.swift` |

`macos/tools/sign_app.sh` signs the bundle, inside out (helpers and resource
bundles, then the app). It uses `FC_CODESIGN_IDENTITY` when that is set (`-`
for ad hoc), else the first valid Apple Development identity in the keychain,
else an ad hoc signature. A real identity keeps the app's code identity the
same across builds, so macOS asks for a permission (such as files on network
volumes) once; an ad hoc signature changes with every build, and macOS asks
again each time.

`macos/tools/update_app.sh` rebuilds only the Swift products (debug unless
`--release`), puts them into the existing bundle, installs `fc`, `fresh` and
`7zr` from `build-macos` when they are newer than the bundle's, and signs
again; `--fresh <path>` installs another Fresh build, such as one from the
fork's checkout. Executables are copied next to the old file and moved over
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
| `fc.model.panes`, `fc.model.commands` | `PaneModel` and `AppModel`: listing, filter, glob, cursor, sort, tutorial tabs, the command catalog, palette ranking, dialog requests, settings |
| `fc.model.rate` | A raised transfer limit applies within a running file |
| `fc.model.engine` | The facade end to end: start, rows, glob, jobs, profile lock |
| `fc.model.editor` | Attaching hands the app the session's scene socket, or the terminal command when there is none |
| `fc.macos.explainers` | `macos/tools/check_explainers.py`: every step, key, command and anchor in the explainers exists, and every visible command is covered |
| `swift test --package-path macos` | FCKit drives the real engine; ExplainerKit decodes every explainer and builds captions; FreshKit frames WebSocket messages, applies scenes, maps keys, and replays a scene recorded from a real Fresh session |

`Tests/FreshKitTests/Fixtures/scene.json` comes from
`macos/tools/record_scene.py`, which starts a throwaway Fresh session, connects
to its scene socket as the app does, types a few keys and opens the palette.
Rerun it after bumping the Fresh pin, then run the tests.

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
| `frame` | The main thread applies a frame | `t` (read off the socket), `parse`, `applied`, `apply`, `rows` changed, and Fresh's `ack`, `build`, `diff`, `queued`, `owed`, `top` |
| `draw` | The cells are drawn | `ms`, `rows`, `seq` (the last frame shown) |

The app asks Fresh for its part with the scene channel's `telemetry` option
([fresh_integration.md](fresh_integration.md#scene-channel)), so a session
started by an older Fresh records only the app's side.

`macos/tools/editor_telemetry.py <file>` summarizes a recording per scroll
gesture: how long input waited for the main thread, the round trip from a
scroll message to the frame that applied it (by `ack`) and to its draw,
Fresh's build and queue, the app's parse, apply and draw, how far the shown
line trails the asked one, and how long the view keeps moving after the input
stops. `--timeline N` prints gesture N event by event.

**Benchmark.** `macos/bench/scroll_flicks.json` plays six trackpad flicks
(`ScrollGesture`: a finger phase, then decaying momentum, at 120 events a
second) into the editor showing `file_io_jobs.cpp`, then into a plain AppKit
text view of the same file, with timing recorded:

```sh
open -n "build-macos/File Commander.app" --args --profile /tmp/fc-bench \
  --run-explainer "$PWD/macos/bench/scroll_flicks.json" --speed 1
macos/tools/editor_telemetry.py /tmp/fc-bench/telemetry/editor-*.jsonl
```

`--run-explainer` takes a script file as well as an explainer ID. Bench steps
are host steps like the explainers': `scroll` (`target` `editor` or
`textview`, `speed` in points per second, negative scrolling down, optional
`finger_ms` and `decay`), `textview_open` and `textview_close`,
`window_frame` (`w`, `h`), and `{repo}` in paths for the checkout the build
lives in. Gestures go to the view on the main queue from a timer of their own,
so a busy main thread delays them as it would a trackpad's.

## ExplainerKit in other projects

ExplainerKit (`macos/Package.swift`, library product `ExplainerKit`) has no
File Commander code. A host implements `ExplainerHost`: the window to cover,
pressing keys and typing, conditions on its state, its own steps, and setup
and cleanup; views name themselves with `.explainerAnchor`. The runner, the
annotation window, the recorder and the exporter come with the package, so
another app gets explainers, videos and GitHub pages from JSON scripts.
