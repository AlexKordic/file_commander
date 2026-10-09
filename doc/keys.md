# Keys and commands

Every action in FC is a *command* with an ID. A command can have a key, and
every command is also available from the command palette (`F1`). The palette is
where you change keys; see [Rebinding keys](#rebinding-keys).

Lua scripts call commands by their ID with `fc.command("<id>")`; see
[scripting](scripting.md).

## Always available

| Key | Action |
| --- | --- |
| `F1` | Command palette: search and run any command, or rebind its key. `F1` itself cannot be rebound. |
| `Ctrl+C` | Quit FC. The workspace is saved. An unfinished copy or move is paused and offered for Resume on the next start. |
| Arrow keys | Move the focus in the panel or dialog. |
| `Esc` | Close a dialog. In a panel, clear the selection. |
| `Esc` `Esc` `Esc` | Pressed three times within a second: clear the error messages. |
| Any printable key | Type into the panel's filter (see [the user guide](user_guide.md#filter-the-listing)). |

## Panel commands

These act on the focused panel.

| Default key | Command ID | Action |
| --- | --- | --- |
| `Enter` | `enter_dir` | Open the focused directory, or open a `.7z` archive as a read-only folder. |
| `?` | `leave_dir` | Go to the parent directory. |
| `Space` | `select_toggle` | Select or deselect the focused item and move down. |
| `Esc` | `clear_selection` | Clear the selection. |
| `Ctrl+A` | `select_all` | Select all items that match the current filter. |
| `+` | `glob_select` | Select items matching a pattern such as `*.jpg`. |
| `-` | `glob_deselect` | Deselect items matching a pattern. |
| `F2` | `rename` | Rename the focused item. |
| `F3` | `find` | Find files by name below a directory. |
| `F5` | `copy` | Copy the selection (or the focused item). The destination defaults to the other panel. |
| `F6` | `move` | Move the selection to the other panel's directory. |
| `F7` | `mkdir` | Create a directory. |
| `F8` | `delete` | Delete the selection. There is no trash; deleted files are gone. |
| `Ctrl+N` | `names_to_clipboard` | Copy the selected file names to the system clipboard. |
| `Ctrl+P` | `paths_to_clipboard` | Copy the selected full paths to the system clipboard. |
| `Ctrl+L` | `toggle_permissions_column` | Show or hide the permissions column. |
| `Ctrl+G` | `toggle_owner_group_column` | Show or hide the owner:group column. |

## Global commands

| Default key | Command ID | Action |
| --- | --- | --- |
| `Tab` | `switch_panel` | Move the focus to the other panel. |
| `Ctrl+T` | `tab_new` | Open a new tab in the focused panel. |
| `Ctrl+W` | `tab_close` | Close the active tab in the focused panel. |
| `F12` | `tab_next` | Next tab in the focused panel. |
| `F11` | `tab_prev` | Previous tab in the focused panel. |
| `Ctrl+O` | `toggle_single_panel_mode` | Show only the focused panel, full width. Press again to restore both panels. |
| `Ctrl+R` | `refresh_dir` | Re-read the directory. |
| `Ctrl+→` | `target_right` | Show the focused directory (or the focused file's directory) in the right panel. |
| `Ctrl+←` | `target_left` | The same for the left panel. |
| `F9` | `toggle_job_list` | Job list: progress, pause, resume and cancel background jobs. |
| `Ctrl+E` | `toggle_errors` | List of errors from file operations. |
| `Ctrl+B` | `open_bookmarks` | Bookmarks: save and reopen local, SSH and archive locations. |
| `Ctrl+K` | `edit_theme_colors` | Edit the theme colors. |
| `F4` | `open_in_editor` | Open the selected files (or the focused directory) in the editor. |
| `F10` | `switch_to_file_commander` | Switch to the editor. The same key in the editor returns to FC. |
| `Ctrl+Y` | `switch_editor_prev` | Alternative key for switching to the editor. |
| `Ctrl+U` | `switch_editor_next` | Alternative key for switching to the editor. |
| – | `connect_ssh` | Open an SSH location in a new tab. Run it from the palette. |
| – | `restart_editor_backend` | Restart the editor after upgrading Fresh. Run it from the palette. |

Mouse: click a panel tab to activate it. Click the **Name**, **Size** and
**Date** headers to sort; sorting has no keyboard command yet.

## Keys inside dialogs

| Dialog | Keys |
| --- | --- |
| Command palette (`F1`) | Type to search, `Enter` runs the command, `Ctrl+K` rebinds the selected command. |
| Copy (`F5`) | Arrow keys move between fields. With the conflict options focused, `1` Replace, `2` Update if newer, `3` Skip. `F5` again starts the copy. |
| Job list (`F9`) | `Enter` shows details, `r` resume, `p` pause, `c` cancel, `d` dismiss a finished job. `Esc` goes back or closes. |
| Bookmarks (`Ctrl+B`) | `a` adds the current directory, `d` or `Del` removes, `Enter` opens. |

## Rebinding keys

1. Press `F1` and type part of the command name.
2. Select the command and press `Ctrl+K` (or choose **Rebind**).
3. Press the new key. `Esc` cancels.

FC refuses a key that another command already uses. Your bindings are saved in
`settings.json` under `key_bindings` (see
[configuration files](user_guide.md#configuration-files)). If you rebind
`switch_to_file_commander`, the editor uses the new key to switch back too.

## Things to know

- Panel commands are handled before the filter. Keys bound to panel commands
  (`?`, `+`, `-`, `Space`) therefore can't be typed into the filter. Rebind a
  command if you need its key for filtering.
- `Ctrl+P` copies paths; it does not open the palette. The palette is `F1`.
- Terminals send some keys differently. If a key such as `F11` or `Ctrl+→` is
  taken by your terminal or window manager, rebind the command.
