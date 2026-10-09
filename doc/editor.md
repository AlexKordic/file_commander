# The editor

FC comes with [Fresh](https://github.com/sinelaw/fresh), a terminal text
editor, and keeps one Fresh session running in the background for you. Files
open as tabs in that session. You switch between FC and the editor with one key,
and the editor keeps its tabs and unsaved text until you close them yourself.

Fresh is a separate program with its own license (GPL-3.0-or-later). FC builds
it from source with a few integration changes; see
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

## Open files and switch

| Key | Action |
| --- | --- |
| `F4` | Open the selected files (or the focused file) as editor tabs. A file that is already open gets its existing tab. On a directory, `F4` opens it as the editor's workspace folder. |
| `F10` | Switch to the editor. Press `F10` in the editor to come back to FC. |
| `Ctrl+Y`, `Ctrl+U` | Alternative keys for switching to the editor. |

Coming back to FC only hides the editor. Its tabs, unsaved changes, cursor
positions and undo history stay as they are, and they are there again on the
next `F10`. In the editor, `Alt+F` opens Fresh's File menu.

Closing tabs, saving and discarding changes all happen in Fresh. FC never
closes an editor tab. To stop the editor, quit Fresh from its own menu.

If you rebind the switch command in FC's palette, the editor uses the same key
to switch back. See [rebinding keys](keys.md#rebinding-keys).

Remote files from [SSH tabs](ssh.md) open in the same editor. The same path
on two different hosts opens as two different tabs. Files inside 7z archives
can't be opened; copy them out of the archive first.

## One editor per profile

Each FC configuration profile has exactly one editor session. When you restart
FC, it reconnects to that session. If the editor stopped in the meantime, FC
starts it again and Fresh restores its tabs and unsaved text.

An editor session with no unsaved changes stops by itself after an hour without
a connected FC. Sessions with unsaved changes keep running.
`FRESH_SESSION_IDLE_TIMEOUT_SECS` changes the idle time.

## What survives a crash

Fresh saves recovery data every two seconds and whenever you switch back to FC.
If the editor or the computer crashes, at most the last two seconds of typing
are lost. Undo history does not survive a crash or restart.

Recovered text is kept apart from your files: Fresh never writes it to the file
until you save. If the file changed on disk in the meantime, Fresh warns you.
Review the text before saving.

## Restart after upgrading Fresh

A running editor keeps using the old Fresh version until it restarts. After
rebuilding or upgrading Fresh:

1. Press `F1` and run **Restart editor backend**.
2. Confirm. Fresh saves its recovery data, stops, and starts again with the new
   version, with the same tabs and unsaved text.

The dialog defaults to **Cancel**. If the running editor is an older version
that can't confirm it saved everything, FC asks a second time and warns that
recent edits may be lost; you can cancel, save in the editor, and try again.
FC never force-kills the editor. Other attached editor windows must be closed
first.

## Using another Fresh binary

FC looks for the editor in this order:

1. `fresh_binary_path` in `settings.json`
   (see [configuration files](user_guide.md#configuration-files)).
2. The `FC_FRESH_BIN` environment variable.
3. The `fresh` binary built with FC.

Use an absolute path. The binary must be a Fresh build that includes FC's
integration changes; an unmodified upstream Fresh lacks the commands FC uses.
Details for developers are in [Fresh integration](dev/fresh_integration.md).
