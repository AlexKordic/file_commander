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
  [doc/macos_app.md](doc/dev/macos_app.md).
- Help explains every feature with an explainer that runs real operations on
  demo files, with captions, highlights, a pointer and key badges; **Entire
  tutorial** runs all 28. ExplainerKit, the annotation engine, also records
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
- Fixed: trackpad scrolling in the macOS editor no longer falls behind the
  fingers. Frames queued up behind macOS's 8 KiB socket buffer, up to 1.4 s
  behind a fast flick; now a frame reaches the screen in 10–15 ms, a scroll
  sends only the rows that came into view, and an editor that falls behind
  skips to the newest frame instead of playing every one. FC builds Fresh
  optimized for speed rather than size, which halves the time each frame
  takes to build.
- The macOS editor and Fresh exchange compact binary (protobuf) messages
  instead of JSON. Paging through a large file, a frame is on screen 15 ms
  after the key instead of 19, and the editor keeps up with 172 frames a
  second instead of 110; frames are half the size. After updating, run
  **Restart Editor Backend** once: the new app can't talk to a backend still
  running the previous build.
- **Transfer Speed** in the palette changes the speed limit while a copy runs;
  the new limit applies within the running file.
- The application model shared by both interfaces is now its own library,
  `fc_model`, under the terminal interface.
- **Archives in every common format.** `Enter` browses zip, 7z, tar, iso, cpio, cab, wim, xar, rpm, deb and more as read-only folders through 7-Zip 26.04's library, loaded in process: browsing reads only the archive's index, and copying out extracts only the files copied. FC no longer extracts a `.7z` into a cache to browse it, and the bundled `7zr` is gone.
- `Enter` on a compressed tar (`.tar.gz`, `.tgz`, `.tar.xz`, ...) or a compressed file (`.gz`, `.xz`, ...) opens an extraction popup, whatever its size: it extracts everything in one pass into a folder, or **Browse anyway** lists it. Extraction never writes outside the chosen folder, links that lead out of it included.
- **Open as Archive** (`Ctrl+PageDown`, `⌥⌘↓` in the app) browses any file as an archive, whatever its name: disk images, packages, and documents that are zips inside.
- Copying to a destination named `.zip`, `.7z`, `.tar`, `.tar.gz`, `.tar.bz2`, `.tar.xz` (and their short forms), or `.gz`, `.bz2`, `.xz` for one file, creates that archive; the copy dialogs say what the name will create. Archives keep symbolic links as links, Unix permissions and times, and empty folders. A compressed tar is written in one pass, without a temporary `.tar`.
- Encrypted archives (zip AES and ZipCrypto, 7z) ask for their password in a dialog or sheet, again after a wrong one, and FC remembers it until it quits. RAR isn't supported.
- Linux is built natively against the system's glibc instead of cross-compiled with Zig and musl; a Linux package holds `bin/fc`, `bin/fresh` and `lib/file-commander/7z.so`.
- Fixed: in the macOS editor, a font without some of the symbols Fresh draws (Monoid lacks the fold marker ▾ and ⌃, for example) no longer scrambles the text: every row after the first such symbol was drawn displaced, overlapping the top of the window.

This is a release candidate. It is built from source; there are no binary
releases yet.
