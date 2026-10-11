# Changelog

## Unreleased

- Two-panel terminal file management with panel tabs, filtering, selection,
  background operations, archive browsing and Lua automation.
- A shared Fresh backend for editor tabs, attach/detach, checkpoint recovery
  and confirmed backend restart.
- SSH filesystem tabs, local/remote transfers, remote editing, and paused
  transfer recovery requiring an explicit Resume after startup.
- MIT licensing for FC, preserved third-party notices, public pinned dependency
  sources, and contributor/build/release documentation.
- `transfer_rate_limit` in `settings.json` limits the speed of copies, moves and
  SSH transfers.
- A scripted promo storyboard and player under `tools/promo/`.
- Fixed: the command palette ranks a typed word above letters scattered across
  other commands ("ssh" finds Connect SSH first).
- Fixed: the Connect SSH dialog works from the keyboard (`Enter` moves to the
  path, then connects), and typing no longer lands in front of a pre-filled `/`.
- Fixed: a trailing `/` no longer shows as `/.` in panel paths.
- Fixed: Names to Clipboard and Paths to Clipboard list items in the order the
  panel shows them, under any sort order; they came out reversed.
- Fixed: the click that closes a dialog no longer moves focus or the file cursor
  in the panel beneath it.
- Fixed: in narrow panels the selection summary and the progress bar clip their
  text instead of overprinting it; the summary shows sizes as KB/MB/GB, and the
  progress bar keeps its job type and buttons whole. Delete progress gauges now
  show their own measure.
- Panels no longer spend a row on a status line: a slow directory read shows a
  **Stop** button after the sort buttons, and SSH failures appear only in the
  error lines at the bottom. The progress bar is one row high, with dark yellow
  **Pause/Resume** and dark red **Cancel** buttons (theme colours
  `pause_button_bg` and `stop_button_bg`).
- Documentation reorganized into a user guide, key reference, SSH, editor and
  Lua scripting guides, and contributor guides under `doc/dev/`.
- A native macOS app (`macos/`, built with `macos/build_app.sh`) with the
  terminal interface's features: menus, a sidebar, sheets, Activity, Errors and
  Find windows, Commander and Mac key presets, Commander and Finder selection
  styles, Fresh in the main window, SSH password prompts in sheets, and light
  and dark themes with a color and a font for every element. See
  [doc/macos_app.md](doc/macos_app.md).
- Help explains every feature with an explainer that runs real operations on
  demo files, with captions, highlights, a pointer and key badges; **Entire
  tutorial** runs all 27. ExplainerKit, the annotation engine, also records
  explainers to video, captions and Markdown pages.
- The macOS app draws Fresh natively in its main window: `F4` shows the editor
  in place of the panes and `F10` (or the toolbar's Files | Editor switch)
  brings them back as they were. Fresh's menus fill the menu bar, its tabs,
  sidebar, command palette, popups and status bar are native, and Mac
  shortcuts (`⌘S`, `⌘Z`, `⇧⌘P`, ...), the Mac clipboard, input methods and
  VoiceOver work, about 10 ms from key to screen. Files of SSH tabs open there
  too, and Fresh edits them on the server. The app talks to the same Fresh
  session over an owner-only Unix socket (the Fresh fork's new scene channel);
  the terminal interface is unchanged.
- **Transfer Speed** in the palette changes the speed limit while a copy runs;
  the new limit applies within the running file.
- The application model shared by both interfaces is now its own library,
  `fc_model`, under the terminal interface.

This is a release candidate. It is built from source; there are no binary
releases yet.
