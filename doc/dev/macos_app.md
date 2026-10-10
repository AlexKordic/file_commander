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
                                                   key router, themes, editor window, tutorial
ExplainerKit         macos/Sources/ExplainerKit    anchors, annotation window, runner, recorder
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
- **The editor.** `EditorManager` hands the attach command to the app
  (`set_attach_handler`), which runs it in a SwiftTerm view in its own window.
  Fresh detaches on its switch key; the app watches the client's PID.
- **SSH prompts.** The app starts a Unix-socket server and sets `SSH_ASKPASS`
  to the bundled `fc-askpass` with `SSH_ASKPASS_REQUIRE=force`; each prompt
  becomes a sheet.
- **The profile.** The app shares the TUI's profile. Its own settings are in
  `app_settings.json`; it writes `settings.json` back with the TUI's key
  bindings untouched.

## Build

```sh
macos/build_app.sh            # release build: build-macos/File Commander.app
macos/build_app.sh --debug    # faster Swift compile
macos/build_app.sh --open     # build, then open the app
```

The script configures the `macos-app` CMake preset once (deployment target
macOS 14, reusing the dependency checkouts from `build-release` if there is
one), builds `libfc_engine_bundle.a`, `fc`, `fresh` and `7zr`, builds the
Swift package in `macos/`, and assembles the bundle:

| In the bundle | Comes from |
| --- | --- |
| `Contents/MacOS/FileCommander` | Swift package, product `FileCommander` |
| `Contents/MacOS/fc-relaunch`, `fc-askpass` | Swift package helpers |
| `Contents/MacOS/fc`, `fresh`, `7zr` | CMake (`build-macos/`); found next to the app as for `fc` |
| `Contents/Resources/FileCommander_FileCommander.bundle` | explainers and themes |
| `Contents/Resources/AppIcon.icns` | drawn by `macos/tools/make_icon.swift` |

The bundle is signed ad hoc. The Swift package links the engine with
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
| `fc.macos.explainers` | `macos/tools/check_explainers.py`: every step, key, command and anchor in the explainers exists, and every visible command is covered |
| `swift test --package-path macos` | FCKit drives the real engine; ExplainerKit decodes every explainer and builds captions |

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
  `command`, `set_transfer_speed`, `set_preference`, `open_window`,
  `close_window`, `front`, `touch`, `remember`, `crash`, `relaunch`,
  `editor_type`, `editor_keys`, `run_script`, `remove_bookmark`, `notice`.
- **Conditions**: `rows`, `selected`, `cursor`, `path`, `filter`, `loaded`,
  `tabs`, `focused`, `single`, `sort`, `columns`, `sheet`, `palette`, `glob`,
  `text_focus`, `anchor`, `job` (by `as_job` name, `running` or `paused`),
  `running_job`, `queued_at_least`, `event`, `clipboard`, `hud`,
  `errors_at_least`, `no_errors`, `window`, `editor`, `bookmark`,
  `transfer_rate`, `file`, `theme`, `font_size`, and `all`, `any`, `not`.
- **Needs**: `idle_queue` refuses to start while the user's own job runs;
  `editor` gives the explainer a new Fresh session; `restart` and `crash` keep
  the tutorial tabs in the workspace checkpoint; `crash` asks first.

**Anchors** are declared in the views with `.explainerAnchor("id")`, optionally
with the action a scripted click runs (the same closure as a real click).
Table rows (`pane.left.row[name=…]`) and the editor's text
(`editor.text[<regex>]`) are found by resolvers. `pane.focused` and
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

## ExplainerKit in other projects

ExplainerKit (`macos/Package.swift`, library product `ExplainerKit`) has no
File Commander code. A host implements `ExplainerHost`: the window to cover,
pressing keys and typing, conditions on its state, its own steps, and setup
and cleanup; views name themselves with `.explainerAnchor`. The runner, the
annotation window, the recorder and the exporter come with the package, so
another app gets explainers, videos and GitHub pages from JSON scripts.
