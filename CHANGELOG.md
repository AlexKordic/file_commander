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
- Fixed: the click that closes a dialog no longer moves focus or the file cursor
  in the panel beneath it.
- Documentation reorganized into a user guide, key reference, SSH, editor and
  Lua scripting guides, and contributor guides under `doc/dev/`.

This is a release candidate. It is built from source; there are no binary
releases yet.
