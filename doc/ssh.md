# SSH locations

FC can open a directory on another machine over SSH in any panel tab. You can
browse it, copy and move between local and remote tabs (or between two hosts),
rename, create directories, delete, search with `F3`, and edit remote files in
the same editor as local ones.

Nothing has to be installed on the remote machine except Python 3.

## Requirements

- OpenSSH (`ssh`) on your machine.
- `python3` on the remote machine, available in the login shell's `PATH`.

FC uses your normal SSH setup. Host aliases, ports, users, keys, jump hosts and
agents all come from `~/.ssh/config` and your SSH agent.

## Connect

1. Press `F1` and run **Connect SSH**.
2. Enter a host: an alias from `~/.ssh/config` or `user@host`.
3. Enter an absolute directory on that host, such as `/var/log`.

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
shows that it is disconnected. It never falls back to a local directory with
the same path.

## Copying and moving

All file operations from the [user guide](user_guide.md) work in SSH tabs:

- Local to remote, remote to local, and between two remote hosts. Data between
  two different hosts passes through your machine.
- A copy within one host runs entirely on that host.
- Each file is written under a temporary name, verified with SHA-256, then
  renamed into place.
- A move within one remote filesystem is a rename. Otherwise FC copies first
  and deletes the source only after the copy is complete and verified.

What is preserved:

- File mode, modification time and the extended attributes the target can
  store.
- Owner and group become those of the account you log in with on the
  receiving side. Numeric user and group IDs are not translated between
  machines.
- If an ACL or extended attribute can't be carried over, the job pauses before
  the file is published and the source stays in place.
- Symbolic links are copied as links unless you choose **Follow Links in
  Source**.

## Interruptions

A dropped connection pauses the transfer. As with local transfers, an
interrupted copy or move appears **paused** the next time you start FC, and
only continues when you press `r` in the job list (`F9`). FC checks both sides
before continuing; a partly copied file starts again from its beginning. See
[after a crash or quit](user_guide.md#after-a-crash-or-quit).

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
