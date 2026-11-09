# SSH locations

FC can open a directory on another machine over SSH in any panel tab. You can
browse it, copy and move between local and remote tabs (or between two hosts),
rename, create directories, delete, search with `F3`, and edit remote files in
the same editor as local ones.

Nothing has to be installed on the remote machine except Python 3.8 or later.

## Requirements

- OpenSSH (`ssh`) on your machine.
- Python 3.8 or later as `python3` in the remote login shell's `PATH`.

FC uses your normal SSH setup. Host aliases, ports, users, keys, jump hosts and
agents all come from `~/.ssh/config` and your SSH agent.

## Connect

1. Press `F1`, type `ssh` and press `Enter` to run **Connect SSH**.
2. Type a host, an alias from `~/.ssh/config` or `user@host`, and press `Enter`.
3. Type an absolute directory on that host, such as `/var/log`, and press
   `Enter`. Leave it empty for `/`.

If SSH needs a password, a passphrase or a host-key confirmation, FC hands the
terminal to `ssh` so you can answer it. FC then opens the directory in a new tab
of the focused panel.

You can also open a remote directory at startup:

```sh
fc 'ssh://myserver/var/log' ~/Downloads
```

Remote tabs, bookmarks and selections keep their host when FC restarts. To use
a different `ssh` binary, set `FC_SSH_BIN`.

## How it works

FC starts a small Python helper through `ssh` and sends it the code over
standard input. It installs nothing on the remote machine and starts no
long-running service there.

After you authenticate once, FC keeps a shared SSH connection open for ten
minutes of inactivity, so later operations don't ask again. Background
connections never prompt; they use strict host-key checking and fail rather
than ask a question.

The active SSH tab refreshes every three seconds; other SSH tabs refresh when
you switch to them. If the host becomes unreachable, the tab stays open and
FC keeps retrying; the error lines at the bottom of the screen say why. It
never falls back to a local directory with the same path.

## Copying and moving

All file operations from the [user guide](user_guide.md) work in SSH tabs:

- Local to remote, remote to local, and between two remote hosts. Data between
  two different hosts passes through your machine.
- A copy within one host runs entirely on that host.
- Each file is written under a temporary name, verified with SHA-256, then
  renamed into place.
- File data travels as raw binary frames over persistent SSH channels. There
  is no JSON, base64, per-block acknowledgement or scheduled delay between
  blocks. Read-ahead prepares subsequent files, including files in the next
  selected directory, while the current file streams.
- Source hashing and independent destination readback run alongside copying.
  The next file can stream while earlier files are being verified and synced.
  Bounded buffers apply backpressure when storage or verification falls behind.
- File data is synced after approximately each GiB and at the end of a file;
  a GiB checkpoint at EOF counts once. Journal, metadata and directory syncs
  still protect publication and recovery.
- A move within one remote filesystem is a rename. Otherwise FC copies first
  and deletes the source only after the copy is complete and verified.

Transfer details show **written**, **verified** and **synced** bytes separately.
Reaching the written total does not finish the job: verification, durable
publication and any move source cleanup must also succeed. Independent files
stream ahead; operations that depend on an earlier rename or destination wait
for that dependency.

What is preserved:

- File mode, modification time and the extended attributes the target can
  store.
- Owner and group become those of the account you log in with on the
  receiving side. Numeric user and group IDs are not translated between
  machines.
- Extended attributes are preserved between matching platforms. Between
  different platforms, incompatible extended attributes are skipped with a
  **Transfer warning** in the error list; copying continues. This applies to
  files and directories, including moves that copy before deleting the source.
  A completed move does not retain a source copy of the skipped attributes.
- Unsupported ACLs and failures to read or apply same-platform attributes still
  pause the job. File content must pass verification before publication.
- Symbolic links are copied as links unless you choose **Follow Links in
  Source**.

## Interruptions

A dropped connection pauses the transfer. As with local transfers, an
interrupted copy or move appears **paused** the next time you start FC, and
only continues when you press `r` in the job list (`F9`). FC checks both sides
before continuing; a partly copied file starts again from its beginning. See
[after a crash or quit](user_guide.md#after-a-crash-or-quit).

The journal records a committed prefix and pending private staging roots.
Startup performs no remote cleanup or transfer. On explicit Resume, FC checks
ownership of all pending roots before discarding uncommitted output and
restarting those files. A published move resumes source cleanup rather than
copying its verified destination again.

Staging folders named `.fc-copy-*` or `.fc-move-*` can remain on the remote
side after a cancelled transfer or an unreachable host. Delete them once you no
longer need to recover that transfer.

## Editing remote files

`F4` on a remote file opens it in the same editor as your local files. The
editor reads and saves directly over SSH; there are no local temporary copies.
Whether you can save is decided by your remote account's permissions. See
[the editor guide](editor.md).

## Limitations

- 7z archives can't be browsed or created in SSH locations. Copy the archive
  to a local directory first.
- Device files and named pipes are rejected.
- Resume restarts a partly copied file from its beginning; there is no resume
  at a byte offset.
- Remote listings refresh by polling every three seconds, not instantly.
