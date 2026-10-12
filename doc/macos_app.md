# The macOS app

File Commander for macOS is a native app with the same features as the
terminal interface: two panes with tabs, background jobs that survive crashes,
SSH and archive locations, the Fresh editor, bookmarks, the command palette and
key rebinding. It adds menus, a sidebar, sheets and windows in place of the
terminal dialogs, light and dark themes with a font for each element, and a
built-in tutorial that explains every feature by doing it.

It needs macOS 14 or later. To build it, see
[building the macOS app](dev/macos_app.md#build).

- [The window](#the-window)
- [Keys](#keys)
- [Selecting](#selecting)
- [File operations and jobs](#file-operations-and-jobs)
- [Transfer speed](#transfer-speed)
- [SSH](#ssh)
- [The editor](#the-editor)
- [Lua scripts](#lua-scripts)
- [Themes](#themes)
- [Help and the tutorial](#help-and-the-tutorial)
- [Settings and the profile](#settings-and-the-profile)
- [Differences from the terminal interface](#differences-from-the-terminal-interface)

## The window

```text
+--------------------------------------------------------------------------+
| ● ● ●   /path of the focused pane       Copy Move New Folder Delete Find |
+-----------+-----------------------------+--------------------------------+
| Bookmarks | [ camera ][ photos ][+]     | [ backup ][+]                  |
| Servers   | ~ › camera          Filter  | ~ › backup              Filter |
| Locations | Name          Size  Date    | Name           Size  Date      |
|           | lighthouse.jpg 3 MB Today   |                                |
|           | 8 of 14 selected, 36 MB     | 0 items, 0 B                   |
+-----------+-----------------------------+--------------------------------+
| ! error lines (most recent), All Errors…, clear                          |
| Copy +1 queued  ███████░░░  62 MB of 116 MB  12 MB/s  [Pause] [Cancel]   |
+--------------------------------------------------------------------------+
```

- **Toolbar**: Copy, Move, New Folder, Delete, Find, an activity ring that
  opens the Activity window, an error badge, the command palette and Help.
- **Sidebar**: your bookmarks, the SSH servers in your tabs, Home and the
  mounted volumes. A click opens the item in the focused pane; right-click a
  bookmark to open it elsewhere or remove it. Whether the sidebar is shown,
  and which of its sections are collapsed, is kept across launches.
- **Panes**: each has its own tabs, path bar, filter and list. The focused
  pane has an accent line at the top. Drag the line between the panes to
  resize them. A tab with a graduation cap belongs to the tutorial. In
  single-pane mode a bar above the path shows the hidden pane's folder, where
  copies and moves go; Switch Pane (`Tab`) shows that pane instead, still alone.
- **Path bar**: click a folder in the path to go there. The filter field at
  its right shows what you typed into the list.
- **List**: Name, Size and Date Modified, plus Permissions and Owner when you
  turn them on (right-click a column header, or the View menu). A thin bar
  under each file shows its size against the largest file in the folder.
  Sizes over 1 MB are yellow (bold over 50 MB), over 1 GB red (bold over
  10 GB).
- **Status line**: what is selected and how many bytes, how long the folder
  took to read, and a **Stop** button while a folder is still being read.
- **Error lines and job bar**: the latest errors, and the running job with
  its speed, **Pause/Resume** and **Cancel**.

## Keys

Every command is in the menu bar with its key, and in the command palette.
Choose a key preset in the welcome sheet or in Settings › Keys:

| | Commander preset | Mac preset |
| --- | --- | --- |
| Command palette | `F1` | `⇧⌘P` |
| Open / Enclosing folder | `Enter` / `?` | `⌘↓` / `⌘↑` |
| Open as Archive | `⌃PageDown` | `⌥⌘↓` |
| Rename, Find, Open in Editor | `F2`, `F3`, `F4` | `Return`, `⌘F`, `⌘O` |
| Copy, Move | `F5`, `F6` | `⇧⌘C`, `⇧⌘X` |
| New Folder, Delete | `F7`, `F8` | `⇧⌘N`, `⌥⌘⌫` |
| Activity, Switch to Editor | `F9`, `F10` | `⌥⌘L`, `⌃⌘E` |
| Previous / Next Tab | `F11` / `F12` | `⌃⇧⇥` / `⌃⇥` |
| New / Close Tab | `⌃T` / `⌃W` | `⌘T` / `⌘W` |
| Copy Names / Copy Paths | `⌃N` / `⌃P` | `⌘C` / `⌥⌘C` |
| Select All, Refresh, Single Pane | `⌃A`, `⌃R`, `⌃O` | `⌘A`, `⌘R`, `⌥⌘1` |
| Show in Left / Right Pane | `⌃←` / `⌃→` | `⌥⌘←` / `⌥⌘→` |
| Connect to Server | palette | `⌘K` |
| Sort by Name / Size / Date | View menu | `⌃⌥⌘1` / `2` / `3` |

Both presets: `Tab` switches panes, `Space` marks an item, `+` and `-` select
and deselect by pattern, `Esc` deselects, and `Esc` three times within a
second clears the error lines. `⌘Q` quits.

While a list has the focus, keys without `⌘` or `⌃` that run no command are
typed into the pane's filter; `Backspace` edits it.

Arrow keys, Page Up and Page Down (`fn`+`↑` `↓` on a laptop), Home and End
move the cursor. **Settings › General › Cursor margin** (0–10) sets how far
from the pane's edge the list keeps it while scrolling: 0 lets it reach the
edge, 10 keeps it in the middle, except near the start and end of the list.

To change a key, select the command in the palette and press `⌃K`, then the
new key; or use Settings › Keys. A key another command already uses, or one
macOS keeps for itself, is refused.

macOS takes some keys before any app sees them. With default settings, F-keys
control brightness and volume unless you hold `Fn`, `F11` shows the desktop,
and `⌃←` `⌃→` switch Spaces. Turn on **Use F1, F2, etc. keys as standard
function keys** in System Settings › Keyboard › Keyboard Shortcuts › Function
Keys, and turn off the Mission Control shortcuts you want for File Commander;
or use the Mac preset.

## Selecting

Settings › General › Selection style:

- **Commander** (the default): arrow keys move a cursor; `Space` marks the
  item under it and moves down. Marked items are shown in bold, tinted. With
  nothing marked, commands act on the item under the cursor.
- **Finder**: arrow keys select, `⇧`-click extends and `⌘`-click adds.
  Commands act on the selection.

## File operations and jobs

Copy, Move, Delete, Rename and New Folder open sheets:

- **Copy** lists everything it is about to copy while it scans, with the
  total size. Edit the destination, follow links or keep
  relative links, and choose *Replace existing*, *Update if newer* or *Skip
  existing* (`1`, `2`, `3`). A destination named like an archive FC writes (`.zip`, `.7z`, `.tar.gz`, ...) creates that archive; the sheet says what it will create, or why it can't.
- **Delete** is permanent; there is no trash. Links are deleted, not what they
  point to.
- **Rename** renames one item or every selected item.

You can also drag items onto the other pane to copy them, or hold `⌘` to move
them; the sheet still opens. Files dropped from Finder open the Copy sheet.

Archives work as in the terminal interface (see [Archives](user_guide.md#archives)). **Open** browses a zip, 7z or tar as a read-only folder, and on a compressed tar or compressed file it opens the **Extract** sheet: the folder to extract into, *Into a folder named after the archive*, what to do with existing files, and **Browse Anyway**. **Go › Open as Archive** (also in the context menu) browses any file as an archive. An encrypted archive asks for its password in a sheet.

Jobs run one at a time in the background. The job bar shows the running job;
the **Activity** window (`F9`) lists every job with its details and lets you
pause, resume, cancel or dismiss it. Errors don't stop a job: the item is
skipped and listed in the error lines and the **Errors** window.

If File Commander quits or crashes in the middle of a transfer, the transfer is
back, paused, in Activity the next time; **Resume** checks the files first and
continues file by file. See
[after a crash or quit](user_guide.md#after-a-crash-or-quit).

## Transfer speed

**Transfer Speed** (Transfers menu, the palette, or a click on the speed in the
job bar) limits copies, moves between disks and SSH transfers. A change applies
at once, even in the middle of a file. With **Keep for future sessions** off,
the limit lasts until you quit.

## SSH

File › Connect to Server (`⌘K` in the Mac preset) opens a folder on an SSH
host in a new tab. Hosts come from `~/.ssh/config`; the sheet lists your
aliases. When ssh asks for a password, a passphrase or whether to trust a host
key, File Commander asks in a sheet instead of a terminal. See
[SSH locations](ssh.md) for how it works.

## The editor

Open in Editor (`F4`) shows the files in [Fresh](editor.md), in the main window
in place of the panes. Fresh keeps running as its own program; the window draws
it with Mac controls:

- **One window**: while the editor is shown, the title names the file, the
  sidebar folds away and the toolbar keeps only the **Files | Editor** switch,
  Activity and Errors. The error lines and the job bar stay below the editor,
  so a copy's progress and its Pause and Cancel buttons stay in view. Sheets,
  such as an SSH password prompt, appear over the editor.
- **Menus**: while the editor is shown and the window is in front, the menu bar
  holds Fresh's menus (File, Edit, View, Selection, Go, LSP, Help and any a
  plugin adds), with their `⌘` shortcuts. File Commander's menus come back when
  you switch to the files or to another window.
- **Tabs, sidebar, status bar, palette and popups** are drawn natively over the
  places Fresh puts them; clicks on them go to Fresh. Fresh's Settings and its
  key binding editor open as native panels over the editor; keys still go to
  Fresh, so its keyboard shortcuts work in them. The text itself is
  Fresh's, in the theme's editor font (Settings › Appearance › Editor › Font),
  with Fresh's syntax colors.
- **Keys**: `⌘S`, `⌘Z`, `⇧⌘Z`, `⌘C`, `⌘X`, `⌘V`, `⌘A`, `⌘F`, `⌘P` (open by
  name), `⇧⌘P` (command palette), `⌘B` (sidebar), `⌘W` (close tab) and the
  other shortcuts of Fresh's Mac keymap work as in a Mac editor; Fresh's own
  keys work too. `⌘V` pastes the Mac clipboard, and what you copy in the editor
  goes to it. Option types its character (é, ü); turn on **Use Option as Alt**
  in Settings › Editor for Fresh's Alt shortcuts. Input methods such as
  Japanese work as usual.
- **Switching**: `F10` (or your switch key) in the editor, or **Files** in the
  toolbar, shows the panes again exactly as you left them; Switch to Editor
  (`F10` in the files) or **Editor** shows the editor again, instantly. The
  editor's tabs and unsaved text stay when you switch, quit or crash. The app
  starts with the editor shown when it was shown when you quit.
- **Server files**: a file in an [SSH tab](ssh.md) opens in the editor too.
  Fresh works on the server (saving, searching, language servers), and the
  status bar names it.

Window › Restart Editor Backend restarts Fresh after an upgrade. **Show the
editor as a terminal** (Settings › Editor) runs Fresh's terminal interface in a
terminal view in the same place instead; File Commander does that by itself for
a Fresh that can't be drawn natively, such as an older version set in
`fresh_binary_path`.

## Lua scripts

File › Run Lua Script… runs a script with `fc run`, the terminal interface
driven by the script, in a terminal window. Scripts work exactly as
[the scripting guide](scripting.md) describes. The app bundle includes the `fc`
program, so `File Commander.app/Contents/MacOS/fc run script.lua` works from a
terminal too.

## Themes

A theme has a color for light and one for dark appearance for every element,
and a font, size and weight for every element: names, sizes and dates in the
list, tabs, the path bar, the status line, the job bar, dialogs, the palette,
the editor's text and the tutorial's captions.

- **Appearance**: System, Light or Dark (Settings › General, or View).
- **Text size**: View › Bigger Text and Smaller Text (`⌘+`, `⌘-`, `⌘0`)
  scale every font.
- **Built-in themes**: *Default* uses system colors, so it follows your accent
  color and Increase Contrast. *Commander Classic* looks like the terminal
  interface. *High Contrast* has stronger colors.
- **Theme editor**: Settings › Appearance (or Edit Theme Colors). Pick an
  element, set its light and dark colors (or a system color) or its font, and
  watch the preview and the window change. **Save** keeps it as your own
  theme, **Revert** drops the edits, **Reset to Defaults** goes back to the
  theme it is based on. **More** imports, exports, duplicates and deletes
  themes, and imports the terminal interface's `theme_colors.json`.

Your themes are saved in the profile's `themes/` folder and store only what
differs from their base theme.

## Help and the tutorial

Help (the graduation cap, the Help menu, or `help` in the palette) lists the
feature explainers by chapter, and **Entire tutorial**, which runs all of
them in order and remembers where you stopped. An explainer:

- builds demo files in `~/Library/Application Support/File Commander/Tutorial`
  and opens its own tabs on them;
- runs real operations there, pressing the keys of your preset, while captions,
  highlights, a pointer and key badges explain each step;
- removes the demo files and its tabs when it ends, and puts back what it
  changed, such as the transfer speed, the theme or a key binding.

**Watch** plays every step. **Guided** stops where you can do a step yourself
and waits; **Show Me** does it for you. The controls at the top of the window
pause (`Space`), skip a step, or stop (`Esc`). While an explainer plays in
Watch mode, other keys are ignored so a stray key can't derail it, and it
pauses while File Commander is in the background.

Two explainers restart the app: *Quit and come back* quits normally, and
*Crash recovery* kills File Commander with `SIGKILL` in the middle of a copy,
after asking. Both continue by themselves after the restart. The *Copy names
and paths* and *Multiple cursors* explainers put demo paths on your
clipboard.

## Settings and the profile

The app uses the same profile as the terminal interface:
`$XDG_CONFIG_HOME/file_commander`, or `~/.config/file_commander`. Workspace,
bookmarks, palette usage, the editor session and paused transfers carry over
between the two; only one of them can use a profile at a time. Start the app
with `--profile DIR` to use another profile (`DIR/file_commander`).

App-only settings (key preset and bindings, selection style, theme, appearance,
text size and tutorial progress) are in `app_settings.json` in the profile,
so the terminal interface's `settings.json` key bindings stay its own.
Preferences are saved as soon as they change.

## Differences from the terminal interface

- Settings are saved immediately, not only on a normal exit.
- Sorting has keys (View › Sort By).
- The terminal interface's dialogs are sheets, popovers and windows; the
  palette's **Help** and **Transfer Speed** are new.
- Lua scripts run the terminal interface (`fc run`) in a window; they don't
  drive the app's own window yet.
