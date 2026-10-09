# File Commander

File Commander (FC) is a terminal file manager with two panels, background file
operations, panel tabs, Lua automation, and a shared Fresh editor backend.
Local and SSH locations can be opened in separate panels and tabs.

The current release candidate has been qualified on macOS arm64. Linux code and
build configurations are present; full native Linux release qualification is
still required. Windows is not supported by this release. See the
[publication review and release plan](doc/open_source_release.md) for the
remaining work and the scope of existing evidence.

## Build from source

Requirements: Git, CMake 3.21+ for presets, Ninja, a C++20 compiler and standard
library with `std::format`, Python 3.12+, and Make. The bundled Fresh editor
requires Cargo and the Rust toolchain pinned by its `rust-toolchain.toml`
(currently 1.95); its native dependencies also require Clang/libclang. On Linux,
install the C/C++ development libraries required by the Fresh build. SSH
locations require OpenSSH locally and Python 3 on the remote host.

Once the pinned FTXUI fork branch has been published:

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

Bootstrap creates isolated checkouts at the revisions in
[`dependencies.json`](dependencies.json), reconstructs the Fresh integration
from its verified Git bundle, and unpacks the verified LZMA source snapshot.
It validates existing inputs and does not reset them. Boost is downloaded and
checksum-verified by CMake. The first build requires network access for Git,
Boost and Rust crates; no private mirror is required.

For a headless build without FTXUI, LuaJIT, Fresh or LZMA:

```sh
cmake --preset core
cmake --build --preset core
ctest --preset core
```

The detailed [build and test guide](doc/build_test_setup.md) covers toolchain
overrides, sanitizers, packages and native qualification.

## Use FC

Start with `fc`, or `fc /left/path /right/path`. Explicit paths override restored
panel locations. A normal start restores the last checkpointed workspace.

| Key | Action |
| --- | --- |
| Tab | Switch panel |
| Enter / `?` | Enter / leave directory |
| Space / Ctrl+A | Toggle selection / select visible items |
| F1 | Command palette, including Connect SSH and Restart editor backend |
| F2 / F3 | Rename / find |
| F4 | Open the focused file in the shared editor |
| F5 / F6 / F7 / F8 | Copy / move / mkdir / delete |
| F9 | Job list |
| F10 | Switch between FC and the attached editor |
| Ctrl+T / Ctrl+W | New / close panel tab |
| Ctrl+R | Refresh directory |

Fresh owns its editor tabs and unsaved buffers. Returning to FC detaches the
client; it does not close the backend or its tabs. See the
[editor workflow](doc/editor_workflow.md) and
[Fresh CLI contract](doc/fresh_cli_contract.md).

Use Connect SSH in the palette to open a configured OpenSSH host alias.
Transfers can cross local and remote tabs; remote files open in the same Fresh
backend as local files. See [SSH setup, limitations and tests](doc/ssh_workflow.md).

**Interrupted transfers always start paused and require an explicit Resume.**
Workspace and editor recovery use completed checkpoints; keystrokes or state
changes after the last successful checkpoint are not guaranteed to survive a
forced termination. Recovery data is stored under
`$XDG_CONFIG_HOME/file_commander`, or `~/.config/file_commander` when unset.

For automation, run `fc run script.lua`. See the
[Lua testing framework](doc/testing_framework.md). Lua scripts are executable
code and should only be run when trusted.

## Test and contribute

Run `python3 tools/run_test_lane.py fast --build build-release` for fast checks,
or `python3 tools/run_test_lane.py release --build build-release` for all
automatic release checks. Native watcher, relocation and second-filesystem
checks are in the separate manual lane. A passing automatic lane does not claim
manual checks passed.

Read [CONTRIBUTING.md](CONTRIBUTING.md) before sending a change. Report bugs in
[GitHub Issues](https://github.com/AlexKordic/file_commander/issues); report
vulnerabilities using [SECURITY.md](SECURITY.md).

GitHub-hosted core checks run on pushes to `main` and pull requests. Full native
and sanitizer qualification uses explicit maintainer dispatch on provisioned
runners. Hosted core checks are useful contributor feedback and do not qualify
the full binary package.

## License

FC's original code is [MIT licensed](LICENSE), copyright Alex Kordic.
Dependencies retain their own terms. In particular, Fresh is a separate
GPL-3.0-or-later program. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
and the [binary-release source requirements](doc/open_source_release.md).
