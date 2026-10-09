# File Commander

File Commander (FC) is a keyboard-driven, two-panel file manager for the
terminal, in the tradition of Midnight Commander and Total Commander. It is
built so that the interface never waits for the disk or the network.

- **File operations run in the background.** Copies, moves and deletes are
  queued as jobs you can pause, resume or cancel while you keep working.
- **Transfers survive crashes.** If FC quits or the machine goes down in the
  middle of a copy, the transfer is back, paused, the next time you start FC.
  One key resumes it from the last finished file.
- **SSH is just another panel.** Open any host from your `~/.ssh/config`,
  browse it, copy between local and remote tabs or between two hosts. The
  remote side only needs Python 3.
- **An editor one key away.** `F4` opens files in a built-in
  [Fresh](https://github.com/sinelaw/fresh) editor session, `F10` switches back
  and forth. Tabs and unsaved text stay in the editor, even across restarts.
- **Picks up where you left off.** Tabs, paths, selections and filters are
  restored on the next start.
- **Search, don't memorize.** `F1` opens a command palette with every command;
  rebind any key from there. Also: bookmarks, tabs, glob selection,
  find, 7z archive browsing and Lua scripting.

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
│budget.xlsx                     0│Oct  9 21:49 │║│                                                │
│todo.txt                        0│Oct  9 21:49 │║│                                                │
```

**Status:** release candidate, built from source. It is tested on macOS on
Apple silicon. Linux builds are supported but not yet fully tested. There are no
binary downloads yet, and Windows is not supported.

## Build

You need Git, CMake 3.21 or later, Ninja, Make, Python 3.12 or later, and a
C++20 compiler whose standard library has `std::format`. The bundled editor is
written in Rust, so you also need Cargo with the toolchain from Fresh's
`rust-toolchain.toml` (currently 1.95) and Clang/libclang. On Linux, install the
usual C/C++ development libraries as well.

```sh
git clone https://github.com/AlexKordic/file_commander.git
cd file_commander
python3 tools/bootstrap_dependencies.py --root build-deps
cmake --preset release \
  -DFC_FTXUI_SOURCE_DIR="$PWD/build-deps/ftxui" \
  -DFC_LUAJIT_SOURCE_DIR="$PWD/build-deps/luajit" \
  -DFC_FRESH_SOURCE_DIR="$PWD/build-deps/fresh" \
  -DFC_LZMA_SOURCE_DIR="$PWD/build-deps/lzma"
cmake --build --preset release
./build-release/fc
```

The bootstrap script downloads the exact dependency versions FC is tested with
(listed in [`dependencies.json`](dependencies.json)) into `build-deps/`. The
first build also downloads Boost and Rust crates, so it needs network access.

There is no install step yet. Run `build-release/fc` directly, or symlink it into
a directory on your `PATH`. To move FC to another machine, build the
self-contained package (`fc`, `fresh`, `7zr` and the license notices) described
in [building FC](doc/dev/building.md).

More build options, such as debug and sanitizer builds or using local
dependency checkouts, are in [building FC](doc/dev/building.md).

## First steps

```sh
./build-release/fc                  # restore the last session
./build-release/fc ~/src ~/backup   # open two directories
```

| Key | Action |
| --- | --- |
| `Tab` | Switch panel |
| `Enter` / `?` | Open directory / go to the parent |
| *type text* | Filter the listing |
| `Space`, `+` | Select an item, select by pattern |
| `F5` / `F6` / `F8` | Copy / move / delete |
| `F7` / `F2` | New directory / rename |
| `F3` | Find files |
| `F9` | Job list: pause, resume, cancel |
| `F4` / `F10` | Edit files / switch to the editor and back |
| `Ctrl+T` / `Ctrl+W` | New / close tab |
| `Ctrl+B` | Bookmarks |
| `F1` | Command palette (every command, and key rebinding) |
| `Ctrl+C` | Quit |

To open a remote directory, press `F1`, run **Connect SSH**, and enter a host
alias and a path.

## Documentation

For users:

- [User guide](doc/user_guide.md): panels, selection, file operations, jobs
  and recovery, find, archives, bookmarks, configuration.
- [Keys and commands](doc/keys.md): every key and command ID, and how to
  rebind them.
- [SSH locations](doc/ssh.md): connecting, transfers, limitations.
- [The editor](doc/editor.md): working with the built-in Fresh editor.
- [Lua scripting](doc/scripting.md): automating FC with `fc run script.lua`.

For contributors:

- [CONTRIBUTING.md](CONTRIBUTING.md)
- [Building](doc/dev/building.md), [testing](doc/dev/testing.md) and
  [architecture](doc/dev/architecture.md).
- [Fresh integration](doc/dev/fresh_integration.md) and
  [pinned dependencies](dependencies/README.md).

## Feedback

Report bugs and suggest features in
[GitHub Issues](https://github.com/AlexKordic/file_commander/issues). Report
security problems privately as described in [SECURITY.md](SECURITY.md).

## License

FC is [MIT licensed](LICENSE), copyright Alex Kordic. Its dependencies keep
their own licenses. In particular, the bundled Fresh editor is a separate
GPL-3.0-or-later program. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
