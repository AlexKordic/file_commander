# File Commander user guide

This guide covers everyday use of File Commander (FC). If you haven't built
FC yet, start with the [README](../README.md). For all keys on one page, see
[keys and commands](keys.md).

- [Start FC](#start-fc)
- [The screen](#the-screen)
- [Move around](#move-around)
- [Filter the listing](#filter-the-listing)
- [Select files](#select-files)
- [Copy, move, rename, create, delete](#copy-move-rename-create-delete)
- [Background jobs](#background-jobs)
- [After a crash or quit](#after-a-crash-or-quit)
- [Find files](#find-files)
- [Archives](#archives)
- [Tabs, layout and columns](#tabs-layout-and-columns)
- [Bookmarks](#bookmarks)
- [Command palette and keys](#command-palette-and-keys)
- [Colors](#colors)
- [Clipboard](#clipboard)
- [Workspace restore](#workspace-restore)
- [Configuration files](#configuration-files)
- [What copy and move preserve](#what-copy-and-move-preserve)
- [Limitations](#limitations)

Related guides: [SSH locations](ssh.md), [the editor](editor.md),
[Lua scripting](scripting.md), [the macOS app](macos_app.md).

## Start FC

```sh
fc                       # restore the last workspace
fc ~/src ~/backup        # left and right panel paths
fc 'ssh://myserver/var/log' .
fc run script.lua        # run a Lua script (see scripting.md)
```

`fc` is the binary built at `build-release/fc`; there is no install step yet.
With one path, the right panel opens in the current directory. Quit with
`Ctrl+C`.

Starting with paths skips [workspace restore](#workspace-restore), and the new
layout becomes your saved workspace.

FC allows one running instance per configuration profile. A second `fc` exits
with an error instead of fighting over the same saved state. To run another
independent instance, give it its own profile:

```sh
XDG_CONFIG_HOME=/tmp/fc-second fc
```

## The screen

FC shows two panels side by side. Each panel has its own tabs, path, selection
and sort order. The focused panel receives your keys; `Tab` switches panels.

```text
 Tabs  1:demo     cT:new cW:close f11/f12:switch ║ Tabs  1:2026      cT:new cW:close f11/f12:switch
                                                 ║
 ~/demo                                      5ms ║ ~/demo/photos/2026
 Sel 2 byte9216/9216 |↑↑ Nam   Siz   Da cols:name║ Sel 0/ bytes0/0 | ↑↑ Name   Siz   Dat cols:name,s
╭─────────────────────────────────┬─────────────╮║╭──────────────────────────────────┬─────────────╮
│/music                           │Oct  9 21:49 │║│beach.jpg                        0│Oct  9 21:49 │
│/photos                          │Oct  9 21:49 │║│city.jpg                         0│Oct  9 21:49 │
│/projects                        │Oct  9 21:49 │║│                                                │
│README.md                       0│Oct  9 21:49 │║│                                                │
│backup.7z                  921600│Oct  9 21:49 │║│                                                │
```

From the top, each panel shows:

1. **Tabs** of that panel.
2. **Path line**. It doubles as the filter box: when you type, the filter
   replaces the path. The number on the right is how long the last directory
   read took.
3. **Summary line**: the number of selected items, selected bytes / total
   bytes, the sort order, the **Name**, **Size** and **Date** sort buttons
   (click them), and the visible columns. While a directory is still being
   read, a **Stop** button follows them; it cancels the read, as `Esc` does.
4. **Listing**. Directories start with `/`.

Messages from failed operations appear at the bottom of the screen. A running
job shows a one-row progress bar there, with **Pause/Resume** and **Cancel**
buttons.

## Move around

| Key | Action |
| --- | --- |
| Arrow keys | Move the focus. |
| `Enter` | Open the focused directory, or browse an archive. On a compressed tar or compressed file, offer to extract it (see [Archives](#archives)). |
| `Ctrl+PageDown` | Browse the focused file as an archive, whatever its name. |
| `?` | Go to the parent directory. |
| `Ctrl+R` | Re-read the directory. |
| `Ctrl+→` / `Ctrl+←` | Show the focused directory in the right / left panel. |

Listings update by themselves when files change: FC watches local directories
(FSEvents on macOS, inotify on Linux) and polls the active SSH tab every three
seconds. Symbolic links are listed as links, including links whose target is
missing.

## Filter the listing

Start typing in a panel to show only the items whose names contain the text.
Matching ignores case. `Backspace` edits the filter, and opening another
directory clears it.

Keys that belong to panel commands are not typed into the filter. By default
these are `?`, `+`, `-` and `Space`. To filter on one of these characters,
rebind its command (see [keys](keys.md#rebinding-keys)).

## Select files

| Key | Action |
| --- | --- |
| `Space` | Select or deselect the focused item and move down. |
| `Ctrl+A` | Select every item that matches the current filter. |
| `+` | Select by pattern, such as `*.jpg` (ignores case). |
| `-` | Deselect by pattern. |
| `Esc` | Clear the selection. |

Commands act on the selection. With nothing selected, they act on the focused
item.

## Copy, move, rename, create, delete

All file operations run as [background jobs](#background-jobs), so the UI stays
responsive however large the operation is.

**Copy (`F5`).** The dialog shows the files about to be copied and these
options:

- **Destination path**: defaults to the other panel's directory; edit it to
  copy somewhere else.
- **Follow Links in Source**: copy what symbolic links point to instead of the
  links themselves.
- **Keep relative links**: keep relative link targets as written instead of
  converting them to absolute paths.
- **When the destination exists**: *Replace existing*, *Update if newer* or
  *Skip existing*. With the option list focused, press `1`, `2` or `3`.

Press **COPY** or `F5` again to start. A destination whose name ends in an archive suffix FC writes (`.zip`, `.7z`, `.tar.gz`, ...) creates that archive from the selection instead; the dialog says what it will create. See [Archives](#archives).

FC refuses to copy a directory into itself. Copies are written to a private
temporary name next to the destination and renamed into place when complete,
so you never see half-written files under the final name.

**Move (`F6`)** moves the selection into the other panel's directory. Within
one filesystem it is a rename. Across filesystems FC copies first and removes
the source only after the destination is complete.

**Rename (`F2`)**, **Make directory (`F7`)** and **Delete (`F8`)** work on the
focused panel. Delete asks for confirmation and removes files permanently;
there is no trash. Delete never follows symbolic links: it removes the link,
not what it points to.

## Background jobs

Jobs run one at a time in the order you start them; later jobs wait in a queue.

- The progress bar at the bottom shows the running job, with **Pause** and
  **Cancel** buttons.
- **Job list (`F9`)** shows running, queued and finished jobs. Select a job
  and press `Enter` for details, `p` to pause, `r` to resume, `c` to cancel,
  or `d` to dismiss a finished job.
- Errors don't stop a job: the failed item is skipped and recorded, and the
  job continues. `Ctrl+E` lists the errors. Press `Esc` three times within a
  second to clear them.
- Cancelling keeps the files that were already copied; it is not an undo.

### Limit transfer speed

To keep a large copy from saturating a disk or network link, run **Transfer
Speed** from the palette (`F1`, type `speed`). Choose a preset or enter MiB/s;
`0` or *Unlimited* means no limit. The limit applies to copies, moves between
filesystems and SSH transfers, and a change applies to a running copy at once,
even in the middle of a file. With **Keep for future sessions** on, it is saved
as `transfer_rate_limit` (bytes per second) in `settings.json`:

```json
"transfer_rate_limit": 10485760
```

To edit the file by hand, do it while FC isn't running: FC rewrites
`settings.json` when it exits. See [configuration files](#configuration-files).

## After a crash or quit

FC records copy and move jobs on disk before they start. If FC quits, crashes
or loses power during a transfer, the next start shows that transfer as
**paused**. Nothing resumes on its own.

To continue, open the job list (`F9`), select the transfer and press `r`.
FC first checks that the source and destination haven't changed. If they have,
the transfer stays paused and the details explain why. Fix the cause and press
`r` again, or press `c` to cancel and start a fresh copy.

- Resume works per file. Finished files are kept; a partly copied file is
  copied again from the start.
- Interrupted delete, rename and make-directory jobs are never replayed.
  Review the files, cancel the old job and start a new one.
- Staging folders named `.fc-copy-*` or `.fc-move-*` can remain next to the
  destination after a cancelled or failed transfer. They hold FC's partial
  data; delete them once you no longer need to recover that transfer.

FC also saves the panels every half second, so a crash loses at most the last
half second of navigation. The editor keeps its own recovery data; see
[the editor guide](editor.md#what-survives-a-crash).

## Find files

`F3` searches below a directory for file names that match a pattern.

- **Search path** defaults to the current directory.
- **Pattern** accepts `*` and `?` and ignores case.
- The search is recursive, doesn't follow directory links, and stops after
  100,000 entries.
- **Open** shows the selected result in the panel.

Find works in local and SSH locations. It searches names only, not file
contents.

## Archives

FC browses, extracts and creates archives with 7-Zip's library (`7z.so`, built with FC). What `Enter` does depends on the file's name:

| Files | `Enter` | FC creates them |
| --- | --- | --- |
| `.zip`, `.7z`, `.tar` | Browses it as a read-only folder | Yes |
| `.zipx`, `.cpio`, `.iso`, `.cab`, `.wim`, `.swm`, `.esd`, `.xar`, `.rpm`, `.deb`, `.ar`, `.arj`, `.lzh`, `.lha` | Browses it | No |
| `.tar.gz`, `.tgz`, `.tar.bz2`, `.tbz`, `.tbz2`, `.tar.xz`, `.txz` | Offers to extract it | Yes |
| `.tar.zst`, `.tzst`, `.tar.lzma`, `.tlz`, `.tar.Z`, `.taz` | Offers to extract it | No |
| `.gz`, `.bz2`, `.xz` | Offers to extract its one file | Yes, from one file |
| `.zst`, `.lzma`, `.Z` | Offers to extract its one file | No |
| Disk images and files that are archives inside: `.dmg`, `.img`, `.vhd`, `.vhdx`, `.vmdk`, `.vdi`, `.qcow2`, `.squashfs`, `.pkg`, `.msi`, `.chm`, `.jar`, `.war`, `.apk`, `.ipa`, `.whl`, `.epub`, `.docx`, `.xlsx`, `.pptx`, `.odt`, ... | Opens it as any other file | No |
| `.rar` | Refuses: FC doesn't support RAR | No |

### Browse and copy out

`Enter` on an archive shows it as a read-only folder; copy files out of it with `F5`, as from any folder. Browsing reads only the archive's index, and copying out extracts only the files you copy. An archive inside an archive opens the same way.

**Open as Archive** (`Ctrl+PageDown`) browses the focused file as an archive whatever its name; 7-Zip decides the format from the file's contents. Use it for disk images, packages and documents that are zips inside.

### Extract a compressed tar

A compressed tar has no index, so listing it means decompressing all of it. `Enter` on one (or on a compressed file such as `.gz`) therefore offers to extract it instead, whatever its size:

- **Extract** writes everything in one pass into a folder: by default the other panel's folder, into a folder named after the archive (`release-1.2.tar.gz` goes to `release-1.2/`). Choose what happens to files that exist: *Replace existing*, *Update if newer* or *Skip existing*. The extraction runs as a background job.
- **Browse anyway** lists it as a folder. Listing takes one pass over the whole archive, and each copy out another.

Extraction never writes outside the folder you chose. It skips entries with absolute paths or `..`, links that point outside the folder, links that together lead out of it, and devices, pipes and sockets; each skipped entry is reported. Hard links inside the archive are recreated as hard links.

### Create an archive

Copy a selection (`F5`) to a destination whose name ends in a suffix FC creates (see the table): `backup.zip`, `photos.tar.gz`, `notes.7z`. The copy dialog says what the name will create, or why it can't:

- `.gz`, `.bz2` and `.xz` hold exactly one file. For more, use `.tar.gz`, `.tar.bz2` or `.tar.xz`.
- `.tar.zst` and the formats FC only reads are refused.
- A compressed tar is written in one pass, without a temporary `.tar`.

Archives keep symbolic links as links, Unix permissions and modification times, and empty folders. Devices, pipes and sockets can't be put in an archive. The archive is written to a temporary name next to the destination and renamed into place when it is complete.

### Passwords

An encrypted archive asks for its password when it is needed: on opening when its names are encrypted (7z can do that), otherwise when you copy or extract files. A wrong password asks again, and nothing is written with one. FC remembers a password that worked until it quits. FC doesn't create encrypted archives.

### Names

Zip entries whose names aren't marked as UTF-8 are read as code page 437, as the zip format specifies; names written in another code page, such as Cyrillic cp866, show as code page 437 characters. Other names that aren't UTF-8 keep their bytes, as local file names do.

### Limits

- Archives with more than 1,000,000 entries are refused.
- Before an extraction or a copy out of an archive, FC checks the free space where the files go and refuses when they won't fit.
- Opening a large archive or listing a compressed tar shows its progress next to the panel's **Stop** button.
- Archives on SSH tabs can't be opened; copy the archive to a local folder first.

## Tabs, layout and columns

| Key | Action |
| --- | --- |
| `Ctrl+T` / `Ctrl+W` | New tab / close tab in the focused panel. |
| `F11` / `F12` | Previous / next tab. You can also click a tab. |
| `Ctrl+O` | Show only the focused panel, full width. Press again for two panels. |
| `Ctrl+L` | Show or hide the permissions column. |
| `Ctrl+G` | Show or hide the owner:group column. |

Each tab can be a local directory, an SSH location or an archive. Drag the
double line between the panels with the mouse to resize them.

## Bookmarks

`Ctrl+B` opens your bookmarks. Press `a` to bookmark the current directory,
`Enter` to open a bookmark, and `d` or `Del` to remove one. Bookmarks work for
local, SSH and archive locations.

## Command palette and keys

`F1` opens the command palette. Type part of a command name, then press
`Enter` to run it. Among equally good matches, the commands you use most come
first. The palette is
also where you change keys: select a command and press `Ctrl+K`. See
[keys and commands](keys.md) for the full list.

## Colors

`Ctrl+K` opens the theme color editor. Pick a UI element, choose one of 256
terminal colors, and choose **Save**. **Reset Defaults** restores the built-in
theme. Colors are saved in `theme_colors.json`.

## Clipboard

`Ctrl+N` copies the selected file names and `Ctrl+P` copies their full paths
to the system clipboard. macOS uses `pbcopy`. Linux needs one of `wl-copy`,
`xclip` or `xsel`.

## Workspace restore

When you start `fc` without paths, FC restores where you left off: both panels'
tabs, paths, focus, selections, filters, sort order, columns and single-panel
mode. If a saved directory no longer exists, FC opens its nearest existing
parent.

## Configuration files

FC keeps its files in `$XDG_CONFIG_HOME/file_commander`, or
`~/.config/file_commander` when `XDG_CONFIG_HOME` is not set. Each directory
is a separate profile.

| File | Contents |
| --- | --- |
| `settings.json` | Panel paths and options, bookmarks, key bindings, palette usage counts, editor path, transfer speed limit. |
| `theme_colors.json` | Colors saved from the theme editor. |
| `workspace.json` | Tabs, selections and filters for workspace restore. |
| `editor_session.json` | The identity of FC's editor session. |
| `transfers/` | Records of copy and move jobs, used for recovery. |
| `workspace.lock` | Prevents two FC instances from using the same profile. |

`settings.json` is written when FC exits normally, so bookmarks and key changes
from a session that crashes are lost. `workspace.json` is saved continuously,
and colors are saved when you choose **Save**.

FC writes these files atomically, so a crash never leaves a half-written file.
If `workspace.json` or a transfer record is damaged, FC reports it and leaves
the file untouched for you to inspect.

Environment variables:

| Variable | Effect |
| --- | --- |
| `XDG_CONFIG_HOME` | Selects the configuration profile. |
| `FC_FRESH_BIN` | Fresh editor binary to use instead of the bundled one. See [the editor guide](editor.md#using-another-fresh-binary). |
| `FC_SSH_BIN` | `ssh` binary to use. |
| `FC_LUA_DEBUG_LOG` | File for the Lua scripting debug log. |

## What copy and move preserve

| | Local copy | Local move, other filesystem | Copy or move over SSH |
| --- | --- | --- | --- |
| File contents | Yes | Yes | Yes, checked with SHA-256 |
| Permissions | Yes | Yes | Yes |
| Modification time | No | Yes | Yes |
| Owner and group | Become yours | Yes, or the move fails | Become the receiving account's |
| Extended attributes, ACLs | No | Yes, or the move fails | Supported attributes; others pause the job |
| Symbolic links | Copied as links unless **Follow Links** is on | Moved as links | Copied as links unless **Follow Links** is on |

A move within one filesystem is a rename and keeps everything.

## Limitations

- No trash: delete is permanent.
- Device files, named pipes and sockets aren't supported. Hard links are
  copied as separate files.
- Resuming an interrupted transfer restarts a partly copied file from its
  beginning.
- Pausing a job pauses the whole queue; queued jobs wait until it is resumed
  or cancelled.
- Find matches names only.
- Archives can't be opened over SSH, RAR isn't supported, and FC doesn't create encrypted archives.
- Sorting is changed with the mouse; it has no key.
- Bookmarks and key bindings are saved on a normal exit only.
- Windows is not supported.
