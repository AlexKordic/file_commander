# SSH tabs and editing

FC can browse an SSH filesystem in either panel, copy files between local and
SSH tabs, copy within an SSH host, relay between SSH hosts, move, rename, make
directories, delete, search, and open remote files in the same Fresh editor
backend as local files.

Choose **Connect SSH** in the command palette. Enter an SSH config alias (for
example `box`) or `user@host`, and an absolute remote directory. SSH handles its
normal authentication and host-key prompts in the foreground terminal. FC then
opens a new tab on the focused panel. SSH config supplies ports, identities,
jump hosts and other connection options. Background connections use BatchMode
and strict host-key checks. An authenticated private ControlMaster connection
can be reused for ten minutes.

A remote location can also be supplied at startup:

```sh
./build-release/fc 'ssh://box/tmp' /tmp
```

Remote hosts require Python 3; FC requires OpenSSH locally. FC sends a small Python helper
through SSH stdin. It installs no executable and starts no persistent remote
daemon. Listings and bulk transfers use separate channels; listings arrive in
batches. The active SSH tab requests a background refresh every three seconds.
Inactive tabs refresh when activated. An unavailable host leaves its tab and
host identity intact, with a disconnected message; it never substitutes a
local filesystem. Tabs, selected/focused paths, and bookmarks retain their host
through restart. Durable locations use `fc-ssh:<escaped target>:<absolute path>`;
the UI displays `ssh://target/path`.

## File operations and recovery

Regular files, directories and symlinks are supported. Final symlinks are not
followed by rename/delete or staging writes. Copy preserves symlink text unless
Follow links was selected. Native exclusive rename protects occupied move and
rename destinations. Unsupported atomic rename fails before replacement.

Copies use private staging directories beside their destinations and publish
with rename after verifying SHA-256 and source/destination metadata. A copy
within one SSH host streams entirely on that host; chunk acknowledgements honor
Pause and the configured rate limit. Uploads, downloads and transfers between
SSH hosts relay bounded chunks through FC. A cross-filesystem move removes its
source only after its staged destination is committed and the journal verifies
both trees. A same-filesystem move uses native rename.

Interrupted transfers are **always paused on startup**. Only explicit Resume
initiates remote validation and queues work. Startup reads local journal data;
it performs no transfer or source cleanup. Resume verifies filesystem anchors,
source metadata and destination conflicts. A lost commit acknowledgement is
reconciled from the recorded staging/output identity before any replay or move
cleanup. A connection failure pauses journaled work. Completed steps are not
repeated; an incomplete file restarts from its beginning after the owned staging
tree is checked and removed. This version does not resume at a byte offset.
Interrupted delete, rename and mkdir cannot be replayed safely: review the files,
then cancel recovery and start a new operation. Cancel retains committed files;
private `.fc-copy-*` / `.fc-move-*` staging may remain after cancellation or an
unreachable host. Retain that staging while deciding how to recover; do not
remove somebody else's staging directory.

Copies preserve mode, modification time and supported extended attributes.
Entries created across hosts belong to the receiving login account; numeric
UID/GID values are not translated. Extended ACLs and extended attributes that
cannot be translated between platforms cause a pause before a staged file or
move is published; the source remains. Apple's managed `com.apple.provenance`
attribute is omitted when crossing platforms. A recursive copy can have already
published earlier files when it encounters unsupported directory metadata.
Remote archive browsing/creation is not implemented: copy archives to a local
tab first. Special files such as device nodes and FIFOs are rejected.

## One editor, several filesystem workspaces

F4 routes each selected file with its explicit SSH target to the profile's one
Fresh backend. Local paths explicitly route to a local workspace. Endpoint and
workspace root jointly identify an editor workspace: identical paths on two
hosts do not share a buffer. Remote file opens use a workspace rooted at `/`;
opening a remote directory uses that directory as its workspace root. Existing
workspaces are reused, so Fresh keeps tabs, unsaved text, cursor state and tab
closure decisions. F10 switches to Fresh and detaches back to FC. Fresh's own
workspace controls switch among local and remote workspaces in that editor.
The connected editor uses Fresh's native SSH agent for reads and saves, without
local download/upload shadow files. Opening a remote editing workspace does not
automatically launch a remote shell. A failed initial connection retains a
placeholder and pending opens; opening that location again retries.
The remote agent evaluates write access under the SSH login, including its
groups and ACLs; local user IDs do not determine whether remote buffers are editable.

The installed Fresh must advertise `fc_locations` during its IPC handshake.
If an older editor is already running, use **Restart editor backend** in FC;
that command checkpoints unsaved text before restarting compatible versions.
A remote placeholder never processes pending file opens on a local authority.

## Automatic and native checks

The release suite includes these deterministic checks, which run the exact
embedded agents through a local SSH transport fixture:

- `fc.remote.filesystem`: byte paths/data, symlink identity, exclusive create,
  atomic rename and host identity.
- `fc.remote.transfers`: upload/download, same-host copy, cross-host relay,
  recursive copy, move cleanup, paused startup, source drift and a connection
  lost after commit.
- `fc.remote.panels`: polling, local/remote tab switching, restoration and
  disconnected identity.
- `fc.extended.ssh_editor`: real Fresh open/edit/save, one daemon across local
  and remote workspaces, and retention of dirty local text.

The Fresh bundle also contains endpoint-routing tests and the carrier keeps
background authentication noninteractive. Local transport tests do not prove
real OpenSSH authentication, host keys, network reachability or remote OS
behavior. For native qualification against the authorized `box` host:

```sh
cd /path/to/file_commander
env -u FC_SSH_BIN ./build-release/fc_remote_fs_tests box
env -u FC_SSH_BIN ./build-release/fc_remote_transfer_tests box
python3 test/test_ssh_editor.py ./build-release/third_party/fresh/bin/fresh --host box
```

These tests create uniquely named remote `/tmp` fixtures and clean them up. The
editor test uses an isolated local configuration and owns only its test daemon.
If a connection drops before cleanup, the printed failure may leave an owned
`/tmp/fc-ssh-*` or `/tmp/fc-transfer-*` fixture for inspection.

Native qualification on `box` was reported passing on 2026-10-07 for the
filesystem and transfer contracts, and for the editor contract using Fresh
`39a8f267c2b1934e8316923e025d035ecf5601f9`. The initial editor run exposed the
local/remote UID permission mismatch; the repeat after that fix passed SSH
edit/save, one backend across workspace switches, and retention of dirty local text.

Automatic qualification on 2026-10-07 used FC
`3d9e8e5d74d6a7ed04ed09a3887de863b7a939ee`, the pinned Fresh revision above, and
native macOS arm64 builds with unpinned dependencies disabled:

| Check | Result | Evidence directory |
| --- | --- | --- |
| Release lane, including package build and dependency rebuilds | 197/197 passed; no skips | `build-release/test-logs/lane-release-a26bc36a8e` |
| AddressSanitizer + UndefinedBehaviorSanitizer core lane | 38/38 passed; no skips | `build-asan-ubsan/test-logs/lane-sanitizer-b92f8e2dcf` |
| Fresh endpoint routing, IPC protocol, SSH carrier and remote permissions | 23 targeted tests passed | `build-review-evidence/remote-fresh-*.log` |
| Reconstruct Fresh from its upstream base and fingerprinted bundle | Passed | `build-review-evidence/remote-bundle-tests.log` |

The release gate also verified that packaged FC, Fresh and 7zr executable hashes
match their build outputs. The seven existing manual-category checks were
excluded from this automatic release run; native `box` checks above are separate
SSH qualification and do not replace that manual lane. The transfer fixture
also loses a move acknowledgement after publication: it verifies that the
source stays intact while paused and that explicit Resume reconciles the
destination, cleans the source and removes the owned empty staging directory.

For a manual UI check, open one panel at `ssh://box/tmp`, keep the other local,
and exercise upload/download, same-host copy, mkdir, rename and delete on your
own fixture. Open two remote text files with F4, edit and save one, detach with
F10, then open a local file. Verify one editor backend, distinct filesystem
workspaces, retained tabs and correct contents on each host. Leave a transfer
paused, close FC and restart it: it must stay paused until Resume. Disconnect
SSH during a copy: the destination must stay unpublished until verification;
if the disconnect occurs after rename, Resume must recognize the commit.
