# Building File Commander

This page is for contributors and packagers who build FC from source. For a
short version, see the [README](../../README.md). How to run the tests is in
[testing.md](testing.md), and how the libraries fit together is in
[architecture.md](architecture.md).

FC builds on macOS and Linux. It uses FSEvents (CoreServices) on macOS and
inotify on Linux for directory notifications. Windows is not supported.

## Requirements

| Tool | Why it is needed |
| --- | --- |
| C++20 compiler whose standard library has `std::format` | FC itself. |
| CMake 3.21 or later | The presets in `CMakePresets.json`. Plain `cmake -S . -B` configuration works from 3.19. |
| Ninja | The generator used by every preset. |
| Make and a C compiler | LuaJIT and the LZMA SDK's `7zr` are built with their own makefiles. |
| Git | Dependency bootstrap, dependency validation and the LuaJIT version stamp. |
| Python 3.12 or later | Bootstrap, the dependency check that runs at configure and build time, and every test driver. |
| Cargo, with the Rust toolchain from Fresh's `rust-toolchain.toml` (currently 1.95) | Builds the bundled Fresh editor. rustup selects this toolchain when Cargo runs in the Fresh checkout; install it with `rustup toolchain install 1.95` if it is missing. |
| Clang and libclang | Some of Fresh's native dependencies generate bindings with `bindgen`. |
| Network access on the first build | Bootstrap clones, the Boost archive and Rust crates. |

Optional tools:

| Tool | Used for |
| --- | --- |
| bubblewrap (`bwrap`), Linux only | Isolating the `fc.package` relocation test. macOS uses the built-in `sandbox-exec`. |
| Zig | The static Linux build described [below](#static-linux-build-with-zig). |
| OpenSSH | SSH locations at run time only. The remote host needs Python 3. |

The [headless core build](#headless-core-build) needs only the compiler,
CMake, Ninja and the Boost download. Its SSH tests run a Python 3 fixture.

## Quick build

These commands work on a fresh clone:

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

Bootstrap puts checkouts of the pinned dependencies in `build-deps/`, which
Git ignores. Always pass the four `-D` paths when you configure a new build
directory: without them CMake looks for sibling checkouts (see
[existing checkouts](#existing-checkouts)) and fails on a fresh clone. CMake
stores the paths in the build directory's cache, so later configure and build
commands for the same directory don't need them again.

The build produces:

| Path | Contents |
| --- | --- |
| `build-release/fc` | The FC executable. |
| `build-release/third_party/fresh/bin/fresh` | Fresh, copied from Cargo's output in the Fresh checkout's `target/release/`. |
| `build-release/third_party/lzma/_o/7zr` | The 7z command-line tool used for archives. |
| `build-release/fc_*_tests`, `build-release/fc_render_benchmarks` | Test executables (the presets enable `BUILD_TESTING`). |
| `build-release/compile_commands.json` | Compile commands for clangd and similar tools. |

To check the build, run the fast tests:

```sh
python3 tools/run_test_lane.py fast --build build-release
```

### How fc finds Fresh and 7zr

There is no install step: FC defines no install rules, so `cmake --install`
does nothing useful. Instead, CMake compiles the absolute paths of the
build-tree Fresh and 7zr into `fc` as defaults.

FC looks for the editor in this order:

1. `fresh_binary_path` in `settings.json` (see
   [configuration files](../user_guide.md#configuration-files)).
2. The `FC_FRESH_BIN` environment variable.
3. A `fresh` file in the directory that contains the `fc` executable.
4. The build-tree Fresh, or `fresh` on `PATH` if this build did not build
   Fresh.

For archives, FC uses `7zr` from its own directory if present, then the
build-tree `7zr`, or `7zr` on `PATH` if this build did not build it.

FC resolves its own directory through symlinks, and resolves relative override
paths against that directory rather than the current one. So
`build-release/fc` works in place, a symlink to it works, and a copy works as
long as the build tree still exists. The [release package](#release-packages)
puts all three executables in one `bin/` directory.

## Presets

| Configure preset | Build directory | Build type | Builds |
| --- | --- | --- | --- |
| `native` | `build-native` | Debug | Everything, including FTXUI, LuaJIT, Fresh and 7zr. |
| `core` | `build-core` | Debug | `fc_core` and its tests only (`FC_CORE_ONLY=ON`). |
| `release` | `build-release` | Release | Everything, with the slow dependency rebuild test enabled (`FC_TEST_DEPENDENCY_REBUILDS=ON`). |
| `asan-ubsan` | `build-asan-ubsan` | Debug | `core` with AddressSanitizer and UndefinedBehaviorSanitizer. |
| `ubsan` | `build-ubsan` | Debug | `core` with UndefinedBehaviorSanitizer. |
| `tsan` | `build-tsan` | Debug | `core` with ThreadSanitizer. |

Every configure preset uses Ninja and sets `BUILD_TESTING=ON`. Each has a
build preset of the same name that runs 6 jobs, and a test preset of the same
name. There is also a `manual` test preset for the `release` build. The test
presets are described in [testing.md](testing.md#lanes).

`native` and `release` need the dependency paths on a fresh clone, as in the
quick build. The `core` and sanitizer presets need no dependency checkouts.

## Headless core build

```sh
cmake --preset core
cmake --build --preset core
ctest --preset core
```

This builds the UI-free `fc_core` library and the tests that link only
against it. There is no `fc` executable. The configure step doesn't validate
dependency checkouts and doesn't need them; it only downloads Boost. Use it for
work on file operations, planning, traversal, jobs, settings and remote
filesystems, or on machines without Rust.

## Debug build

```sh
cmake --preset native \
  -DFC_FTXUI_SOURCE_DIR="$PWD/build-deps/ftxui" \
  -DFC_LUAJIT_SOURCE_DIR="$PWD/build-deps/luajit" \
  -DFC_FRESH_SOURCE_DIR="$PWD/build-deps/fresh" \
  -DFC_LZMA_SOURCE_DIR="$PWD/build-deps/lzma"
cmake --build --preset native
ctest --preset native
```

`ctest --preset native` runs the same tests as the integration lane, without
the lane's logs and metadata.

Without presets, for example with CMake 3.19 or 3.20 or a different build
directory, pass the generator and build type yourself:

```sh
cmake -S . -B build-debug -G Ninja -DCMAKE_BUILD_TYPE=Debug \
  -DFC_FTXUI_SOURCE_DIR="$PWD/build-deps/ftxui" \
  -DFC_LUAJIT_SOURCE_DIR="$PWD/build-deps/luajit" \
  -DFC_FRESH_SOURCE_DIR="$PWD/build-deps/fresh" \
  -DFC_LZMA_SOURCE_DIR="$PWD/build-deps/lzma"
cmake --build build-debug
```

## Dependencies

[`dependencies.json`](../../dependencies.json) pins every input. Builds use
those exact revisions, never moving branch tips.

| Dependency | Source | Pinned by | How it is built |
| --- | --- | --- | --- |
| Boost 1.90.0 | Release archive, downloaded by CMake | SHA-256 | CMake `FetchContent`. Boost.Filesystem is built from the modified subtree in `boost/filesystem/`. |
| FTXUI | FC's fork | Git revision | Added as a CMake subdirectory. |
| LuaJIT | Upstream | Git revision | Copied into the build tree and built there as a static library with `make`, so the checkout stays clean. |
| Fresh | Upstream plus FC's changes in `dependencies/fresh-fc.bundle` | Git revision and bundle SHA-256 | `cargo build --release --locked` in the Fresh checkout, then copied into the build tree. |
| LZMA SDK 26.00 | Snapshot in `dependencies/lzma-sdk-26.00.tar.gz` | Archive SHA-256 and a fingerprint of the SDK's source files | The SDK's `makefile.gcc`, with objects in the build tree. |

How FC drives Fresh at run time is in
[fresh_integration.md](fresh_integration.md).

### Bootstrap

```sh
python3 tools/bootstrap_dependencies.py --root build-deps
```

Bootstrap creates `ftxui`, `luajit`, `fresh` and `lzma` under the root. It
clones each Git dependency and checks out the pinned revision. For Fresh, it
clones upstream, verifies the bundle's SHA-256, fetches FC's commits from the
bundle and checks out the pinned commit. It unpacks the LZMA snapshot after
checking its SHA-256. Finally it validates everything with
`tools/check_dependencies.py`.

| Option | Effect |
| --- | --- |
| `--root DIR` | Required. Where to create the checkouts. |
| `--ftxui-url URL` | Clone FTXUI from a mirror that contains the pinned revision. Defaults to `$FC_FTXUI_MIRROR`, then the manifest's URL. |
| `--fresh-url URL` | Clone upstream Fresh from a mirror. Defaults to `$FC_FRESH_MIRROR`, then the manifest's URL. |
| `--lzma-source DIR` | Copy an SDK 26.00 source folder instead of unpacking the bundled snapshot. It must match the pinned source fingerprint. |

Bootstrap never resets or edits a directory that already exists. It skips
the directory and then validates it, so a checkout at the wrong revision makes
bootstrap fail. Bootstrap into a new root, or move the old directory aside
yourself.

### Existing checkouts

Without `-D` overrides, CMake expects sibling checkouts next to the FC
repository:

| Variable | Default |
| --- | --- |
| `FC_FTXUI_SOURCE_DIR` | `../alex_ftxui` |
| `FC_LUAJIT_SOURCE_DIR` | `../luajit` |
| `FC_FRESH_SOURCE_DIR` | `../editor-fresh` |
| `FC_LZMA_SOURCE_DIR` | `../lzma2600` |

Any checkout works if it is at the pinned revision with no modified tracked
files. Untracked files are ignored, so Cargo's `target/` directory in the
Fresh checkout is fine. The LZMA directory is checked by fingerprint instead
of Git; object directories named `_o` are ignored. Check a set of checkouts
with:

```sh
python3 tools/check_dependencies.py \
  --ftxui build-deps/ftxui \
  --luajit build-deps/luajit \
  --fresh build-deps/fresh \
  --lzma build-deps/lzma
```

Without arguments it checks the sibling defaults. The same check runs when you
configure and again before every build. CMake also reconfigures when
`dependencies.json` changes, so switching to an FC commit with different pins
fails until the checkouts match. To move an existing Fresh checkout to the
pinned revision, follow [dependencies/README.md](../../dependencies/README.md).

### Developing a dependency

To build FC against a modified FTXUI, LuaJIT, Fresh or LZMA checkout,
configure with `-DFC_ALLOW_UNPINNED_DEPENDENCIES=ON`. CMake then skips the
checkout validation and prints a warning. Boost's checksum is still enforced.
Such a build does not register `fc.harness.dependencies`, and the release lane
refuses it.

### Building without Fresh or 7zr

`-DFC_BUILD_FRESH=OFF` and `-DFC_BUILD_LZMA_TOOL=OFF` skip those builds and
their validation. FC then looks for `fresh` or `7zr` next to `fc` and then on
`PATH`. Tests that need the real tool are not registered or skip, and the
release lane requires both options to be `ON`.

### Boost archive

Each new build directory downloads the Boost archive. To download it once,
save it in the repository root, where CMake picks it up and still checks its
SHA-256:

```sh
curl -LO https://github.com/boostorg/boost/releases/download/boost-1.90.0/boost-1.90.0-cmake.tar.gz
```

Git ignores this file. The release lane rejects builds that point
`FETCHCONTENT_SOURCE_DIR_BOOST` at an unchecked Boost tree.

## Sanitizer builds

```sh
cmake --preset asan-ubsan
cmake --build --preset asan-ubsan
python3 tools/run_test_lane.py sanitizer --build build-asan-ubsan

cmake --preset tsan
cmake --build --preset tsan
python3 tools/run_test_lane.py thread --build build-tsan
```

The `ubsan` preset works the same way as `asan-ubsan` and builds into
`build-ubsan`. All three sanitizer presets inherit `core`, so they instrument
only `fc_core` and its tests. The UI, Lua and editor code is never built with
sanitizers. See [testing.md](testing.md#sanitizers) for what each lane runs.

## Static Linux build with Zig

`cmake/toolchains/` contains toolchain files that compile with `zig cc` and
`zig c++` for `x86_64-linux-musl` and `aarch64-linux-musl` and link with
`-static`. For x86-64:

```sh
cmake -S . -B build-linux-x86_64 -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/zig-musl-x86_64.cmake \
  -DCMAKE_BUILD_TYPE=Release \
  -DFC_STATIC_MODE=ON \
  -DFC_BUILD_FRESH=OFF \
  -DFC_FTXUI_SOURCE_DIR="$PWD/build-deps/ftxui" \
  -DFC_LUAJIT_SOURCE_DIR="$PWD/build-deps/luajit" \
  -DFC_LZMA_SOURCE_DIR="$PWD/build-deps/lzma"
cmake --build build-linux-x86_64
```

- Fresh can't be cross-compiled by this build; configure fails unless
  `FC_BUILD_FRESH=OFF`. Build Fresh for the target separately.
- LuaJIT runs code generators on the build host, so a host C compiler (`cc`,
  `clang` or `gcc`) must be on `PATH`.
- The x86-64 toolchain file also uses Zig for `ar` and `ranlib`. The aarch64
  file uses the host's archive tools.
- Test executables are compiled, but the Python-driven tests are not
  registered and target binaries can't run on the host. Run the tests in a
  native build on the target.

To check the result, `file build-linux-x86_64/fc` should report a statically
linked ELF executable, and on Linux `ldd build-linux-x86_64/fc` prints
`not a dynamic executable`.

macOS binaries can't be fully static. `otool -L build-release/fc` should list
only system libraries and frameworks under `/usr/lib` and `/System/Library`.

## Updating a dependency

Change a dependency deliberately, in one commit that updates its pin in
`dependencies.json`:

- Git dependencies: the `revision`. For Fresh, also regenerate
  `dependencies/fresh-fc.bundle` and update `bundle_sha256`.
- LZMA SDK: the snapshot archive, its SHA-256, and the source file count and
  fingerprint.
- Boost: the URL and SHA-256 appear both in `dependencies.json` and in the
  `FetchContent` calls in `CMakeLists.txt`.

[dependencies/README.md](../../dependencies/README.md) describes each pinned
input, the LZMA snapshot, and how to update or change the Fresh fork and its
bundle. FC's changes to Boost.Filesystem are listed in
[boost/changes.md](../../boost/changes.md). Keep the license copies in
`licenses/` and [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md) in step
with the new version. Then run the release lane, which includes
`fc.harness.dependencies`, `fc.harness.fresh_bundle` and
`fc.dependency_rebuild`.

## Release packages

```sh
cmake --build build-release --target package_static_dist
```

This writes `build-release/dist/fc-<system>-<processor>.tar.gz`, for example
`fc-Darwin-arm64.tar.gz` or `fc-Linux-x86_64.tar.gz`, next to an unpacked
copy. The name comes from CMake's system name and processor, so 64-bit Arm
Linux gives `fc-Linux-aarch64`. The `fc.package_build` test runs the same
target and then checks that the archive's `fc`, `fresh` and `7zr` have the
same SHA-256 as the build outputs and that the required license files are
present.

| Path in the archive | Contents |
| --- | --- |
| `bin/fc` | FC. |
| `bin/fresh` | Fresh, when this build built it. |
| `bin/7zr` | 7zr, when this build built it. |
| `README.md` | FC's README. |
| `share/licenses/file-commander/LICENSE` | FC's MIT license. |
| `share/licenses/boost/`, `ftxui/`, `luajit/`, `lzma-sdk/` | Dependency licenses, copied from `licenses/`. |
| `share/licenses/fresh/` | Fresh's GPL license and the notices for its bundled assets. |
| `share/file-commander/THIRD_PARTY_NOTICES.md` | The third-party notice inventory. |
| `share/file-commander/dependencies.json` | The pinned dependency revisions. |
| `share/file-commander/fresh-fc.bundle`, `share/file-commander/README.md` | FC's Fresh changes and the dependency README that explains how to rebuild Fresh's source from them. Present when Fresh was built. |

The package is relocatable: unpack it anywhere and run `bin/fc`. FC finds
`fresh` and `7zr` next to itself. The manual `fc.package` test checks this: it
unpacks the archive in a temporary directory, creates and extracts a real 7z
archive and runs the bundled Fresh, while reads of the source tree and
dependency checkouts are denied.

A package built from a cross build does not contain Fresh, because
`package_static_dist` includes Fresh only when the same build built it.

On macOS, CMake sets the deployment target to the build machine's macOS
version, so binaries need that version or newer. To target older versions,
pass `-DCMAKE_OSX_DEPLOYMENT_TARGET=<version>` on the first configure. LuaJIT
receives the same value, but the 7zr and Fresh builds do not get it from
CMake. Export `MACOSX_DEPLOYMENT_TARGET` with the same version before building
so their compilers use it too.

Before publishing a package, run the release lane and the manual lane on each
target operating system and architecture; see
[release qualification](testing.md#release-qualification).

### Fresh source for binary releases

Fresh is GPL-3.0-or-later. Every binary release that includes `fresh` must
offer the complete corresponding source of that exact Fresh build
([GPLv3 section 6](https://www.gnu.org/licenses/gpl-3.0.html#section6)).
Create the archive from the pinned revision with
[Cargo's vendoring](https://doc.rust-lang.org/cargo/commands/cargo-vendor.html),
and prove it builds offline. From the FC root, after bootstrap:

```sh
fresh_rev=$(python3 -c 'import json; print(json.load(open("dependencies.json"))["git"]["fresh"]["revision"])')
mkdir build-fresh-source build-fresh-source/fresh-source  # fails if it exists
git -C build-deps/fresh archive "$fresh_rev" \
  | tar -x -C build-fresh-source/fresh-source
(
  cd build-fresh-source/fresh-source
  mkdir .cargo
  cargo vendor --locked --versioned-dirs vendor > .cargo/vendor-config.toml
  cargo --config .cargo/vendor-config.toml build --release --frozen \
    -p fresh-editor --bin fresh
  rm -rf target
)
tar -czf build-fresh-source/fresh-corresponding-source.tar.gz \
  -C build-fresh-source fresh-source
shasum -a 256 build-fresh-source/fresh-corresponding-source.tar.gz
```

On Linux, `sha256sum` works in place of `shasum -a 256`.

- Start from a new, empty export directory every time.
- Keep the upstream source, `Cargo.lock`, the toolchain file, native source
  dependencies, license and notice files, and any build configuration you
  added. Inspect build scripts for other downloads and include those inputs.
- Record FC's changes and the build options, including the default features
  FC uses.
- Publish the archive and its SHA-256 on the same release page as the binary,
  and make the package point to that exact download. A Git bundle, a branch,
  a license identifier, or a pointer to upstream does not meet this
  requirement.

### Published source repositories

| Repository | Branch | Contents |
| --- | --- | --- |
| [File Commander](https://github.com/AlexKordic/file_commander) | `main` | FC source, MIT license, documentation, dependency manifest and bootstrap |
| [FTXUI fork](https://github.com/AlexKordic/FTXUI/tree/fc-integration) | `fc-integration` | Modified FTXUI history containing FC's pinned revision |
| [Fresh fork](https://github.com/AlexKordic/fresh/tree/fc-editor-workflow) | `fc-editor-workflow` | Modified Fresh history containing FC's pinned revision |

The forks keep their upstream history and licenses. The upstream projects are
[ArthurSonzogni/FTXUI](https://github.com/ArthurSonzogni/FTXUI) and
[sinelaw/fresh](https://github.com/sinelaw/fresh).

## Troubleshooting

**`Dependency bootstrap requires Python 3.12 or newer`.** Bootstrap stops
before it creates anything. Run it with a newer interpreter, for example
`python3.12 tools/bootstrap_dependencies.py --root build-deps`. If CMake
reports that it could not find a suitable `Python3`, point it at one with
`-DPython3_EXECUTABLE=/path/to/python3.12`.

**`Dependency validation failed: ftxui: cannot read checkout at ...`.** The
build directory was configured without the dependency paths, so CMake looked
for the sibling defaults. Configure again with the four `-D` paths from the
[quick build](#quick-build).

**`... expected clean <revision>; found <revision>`** or
**`... with modified tracked files`.** A checkout is at the wrong revision or
has local edits. Bootstrap does not fix existing directories: bootstrap into a
new root, move the checkout to the pinned revision yourself, or configure with
`-DFC_ALLOW_UNPINNED_DEPENDENCIES=ON` if the change is intentional.

**`lzma: source set differs from SDK 26.00 manifest`.** The LZMA folder is not
the pinned SDK 26.00 source, or a source file in it was changed. Omit
`--lzma-source` to use the bundled snapshot.

**`fresh: dependency bundle fingerprint mismatch`.**
`dependencies/fresh-fc.bundle` does not match `dependencies.json`. Restore it
from Git.

**The Fresh step fails with `cargo` not found, a toolchain error, or a
libclang error.** Install Cargo through rustup, the toolchain named in
Fresh's `rust-toolchain.toml`, and Clang with libclang. To build FC without
the editor, configure with `-DFC_BUILD_FRESH=OFF`.

**`Fresh cross-compilation requires a separately configured Rust target`.**
Cross builds must use `-DFC_BUILD_FRESH=OFF`.

**The Boost download fails.** Save the archive in the repository root as shown
in [Boost archive](#boost-archive).

**`FC_BUILD_FRESH=ON but Fresh source is missing Cargo.toml`** (a warning).
`FC_FRESH_SOURCE_DIR` doesn't point to a Fresh checkout, and the build falls
back to `fresh` on `PATH`. You only see this when validation is off.

**Test lane failures** such as `release requires CMAKE_BUILD_TYPE=Release` are
covered in [testing.md](testing.md#common-failures).
