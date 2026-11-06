# Interactive Compose qualification

This is a disposable development app, named **File Commander Compose Check**.
Its profile, Fresh backend, recovery, cache and log directories live beside
this checklist. The installed File Commander app has a different identity.
Preparation and automated tests do not mark any manual check as passed.

Run `launch.command` from a normal macOS Terminal. To include SSH, run
`launch-dev.command` instead: it uploads small fixtures into its own marked
`/tmp/fc-compose-check-*` directory on `dev` and opens that directory in the
right panel. Authentication and host-key checking use normal SSH behavior.
The remote host needs Python 3. Never use personal documents for these checks.

Record macOS version, input method, display scale, appearance, source build
hashes from `manifest.json`, and pass/fail with symptoms for each item below.
Leave untested items pending. Keep screenshots and the `logs/`, `state/` and
`config/file_commander/telemetry/` directories as evidence. Do not infer
interactive latency or VoiceOver behavior from an offscreen test result.

1. **Open and switch.** In the left panel select `compose.md`, press `F4`,
   then press `Ctrl+P`, type `>` for commands and run **Markdown: Toggle
   Compose/Preview** if Compose is not active. `F10` returns to the panels;
   `F10` returns to the same editor. Open `second.md` with `F4`; retain an
   unsaved edit there while switching between its tab and `compose.md`.
2. **Typography and reflow.** Inspect all six heading levels, setext, emphasis,
   links, quotes, nested lists, code and tables. Prose must be proportional;
   `iiiiii` and `WWWWWW` should differ in width. Resize from narrow to wide,
   change body/code fonts and zoom in the app's Compose preferences, and try
   light/dark appearance. Wrapping follows available pixels without fixed
   columns, missing source, overlapping ornaments or a jumping reading anchor.
3. **Mapped editing.** Click and drag through styled text, wrapped lines,
   emoji, accents, CJK and right-to-left text. Type, delete, use arrows,
   Shift+arrows, Home/End and PageUp/PageDown. Enter and leave code/table cells
   and nested items. Save, undo and redo: the intended source changes once,
   with no added padding, duplicate characters or unrelated edits. An unchanged
   `compose.md` must retain its exact initial CRLF bytes.
4. **Images.** Inspect the inline PNG, block JPEG, nested image and table image.
   Edit alt text and destination: exact source stays editable and valid markup
   retains a preview. Test missing/invalid destinations, narrow/wide resizing,
   selecting/deleting an image, undo and redo. If testing copy/paste, use only
   these fixtures and verify that Markdown source is copied. This human action
   uses the system clipboard. Replace `sample.png` externally with a different
   image and confirm refresh; restore it and retry a failed image.
5. **Actual input methods.** With a macOS Japanese or Chinese input method,
   compose and convert text in a heading, wrapped paragraph and table cell.
   Confirm marked clauses and candidate-window placement, consecutive
   conversions, replacement of a selection, cancel, save and undo. Repeat while
   resizing and after switching editor tabs. The candidate follows the visible
   measured caret and committed text appears once.
6. **Splits and ownership.** Use Fresh's split commands to show the same buffer
   in two panes with different widths. Toggle Compose in one pane and keep
   Source in the other. Navigate, select, edit and scroll independently. Open
   menus/dialogs during marked input; queued text must not enter another buffer
   or a modal field. Switch to the panels and back while text is marked.
   Open a completion or hover after several large headings and wrapped prose.
   Its visible box must follow the measured caret, flip above when needed and
   remain usable near window edges. Click a completion and immediately type;
   the word and following text must appear once. Scroll a long popup, select
   wrapped documentation with emoji, and check the copied logical text. Drag
   outside its bounds and release; the document caret must not move. Dismiss
   it and click its former cell position to verify there is no invisible hit
   region. Repeat with splits showing the same buffer at different carets.
7. **Accessibility.** Turn on VoiceOver and inspect reading order, current
   selection, image alt/error descriptions, scrolling and caret reveal. Record
   limitations, including heading/link navigation and editable text setters;
   do not mark those implemented from basic reading coverage alone.
8. **Private restart.** Save `compose.md`, leave an unsaved edit in `second.md`,
   and quit the test app normally. From Terminal run
   `python3 qualify.py stop-backend .` in this fixture directory, then launch
   again. Verify tabs, exact saved bytes, dirty text and undo/recovery behavior.
   This checks the prepared backend; upgrading from the shipped backend is a
   separate gate. The private backend persists after an ordinary app quit.
9. **SSH on dev.** With `launch-dev.command`, select the remote `compose.md`
   in the right panel and press `F4`. Verify proportional text, PNG/JPEG images,
   save/undo, local/remote tab switching and retained dirty local text. Interrupt
   the connection during an image read, restore it and retry. A delayed image
   must never appear in a different document or host. Reopen the private app
   and verify recovery while remote files are temporarily unavailable.

After quitting the test app, use `python3 qualify.py stop-backend .` to
checkpoint and stop only its private editor. Use
`python3 qualify.py remove-remote .` to remove only this run's marked SSH
fixture. Cleanup refuses while the launch command still owns a running app.
Local files and evidence are retained. Results remain pending until recorded
by the operator; this checklist is not a release certificate.
