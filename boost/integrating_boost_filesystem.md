# Integrating Boost.Filesystem as a Git subtree

## Why

FC modifies Boost.Filesystem (see [changes.md](changes.md)) and tracks those
changes in its own repository. A Git subtree gives us:

- the full source in our tree, editable like any other file;
- changes visible in normal `git log` and `git diff`;
- upstream updates through `git subtree pull`.

## Layout

```text
file_commander/
  boost/
    filesystem/           <-- subtree of boostorg/filesystem (tag boost-1.90.0)
      include/boost/      <-- headers: filesystem.hpp, filesystem/
      src/                <-- compiled sources: operations.cpp, path.cpp, ...
      CMakeLists.txt      <-- builds the Boost::filesystem target
      cmake/              <-- BoostLibraryIncludes.cmake (configure-check helper)
  <build dir>/
    _deps/boost-src/      <-- Boost 1.90.0 from FetchContent (all other libraries)
  CMakeLists.txt          <-- wires both together
```

`<build dir>` is the preset's binary directory, for example `build-release`
for the `release` preset, so FetchContent sources land in
`build-release/_deps/`.

## The problem: Boost.Filesystem is not self-contained

`boostorg/filesystem` depends on about 15 other Boost libraries, directly or
transitively:

- **Public dependencies** (propagated to consumers through
  `target_link_libraries(... PUBLIC ...)`): assert, config, container_hash,
  detail, io, iterator, smart_ptr, system, type_traits.
- **Private dependencies** (build time only): core, predef, scope, and atomic
  when the compiler lacks C++20 `std::atomic_ref`.
- **Transitive dependencies** (pulled in by the above): align, preprocessor,
  mp11, describe, throw_exception, concept_check, fusion, mpl, optional,
  utility, compat, variant2, function_types, functional, function, bind,
  tuple, typeof.

Each is a separate `boostorg/<name>` repository. Fetching them one by one
would take about 30 `FetchContent_Declare` blocks with consistent version
pins.

## The solution: subtree plus FetchContent

1. **Git subtree** for `boostorg/filesystem` only, the one library we modify.
2. **FetchContent** for the full Boost 1.90.0 CMake tarball, which provides
   every dependency target.
3. **Leave `filesystem` out of `BOOST_INCLUDE_LIBRARIES`**, so FetchContent
   does not build a second copy.
4. **`add_subdirectory(boost/filesystem)`** builds our modified copy.

### Key CMake details

**`BOOST_INCLUDE_LIBRARIES`** selects the libraries FetchContent builds
(top-level `CMakeLists.txt`):

```cmake
set(BOOST_INCLUDE_LIBRARIES
  json thread system smart_ptr                                                  # project deps (ftxui uses smart_ptr, thread)
  assert config container_hash core detail io iterator predef scope type_traits # filesystem deps
)
```

FC uses Boost.JSON (`fc_core` links `Boost::json`); the FTXUI fork uses
`smart_ptr` and `thread`. `filesystem` is deliberately absent: FetchContent
creates its dependency targets (`Boost::system`, `Boost::config` and so on),
and our `add_subdirectory(boost/filesystem)` consumes them.

**`BOOST_LIBRARY_INCLUDES`** makes the configure checks work. Filesystem's
`cmake/BoostLibraryIncludes.cmake` normally discovers Boost headers by
scanning `../../../libs/*/include` relative to itself. Outside the Boost source
tree that finds nothing, but the script skips discovery when the variable is
already set:

```cmake
if (NOT DEFINED BOOST_LIBRARY_INCLUDES)
    generate_boost_include_paths(...)
```

We set it to the FetchContent headers first:

```cmake
file(GLOB _boost_lib_include_dirs "${boost_SOURCE_DIR}/libs/*/include")
set(BOOST_LIBRARY_INCLUDES ${_boost_lib_include_dirs} CACHE INTERNAL "...")
```

That lets filesystem's `check_cxx_source_compiles()` checks (statx,
st_blksize and others) find the headers they need.

**Local tarball.** If `boost-1.90.0-cmake.tar.gz` exists in the repository
root, CMake uses it instead of downloading (about 135 MB). It is listed in
`.gitignore`. Both branches verify the same `URL_HASH`.

**Source overrides.** `FETCHCONTENT_SOURCE_DIR_BOOST` skips the download and
the hash check. Use it only for local experiments: `tools/release_gate.py`
rejects a release build that sets it.

## Common operations

### Modify Boost.Filesystem

Edit files under `boost/filesystem/` like any tracked file, then record the
change in [changes.md](changes.md) in the same commit:

```sh
git diff boost/filesystem/
git add boost/filesystem/src/operations.cpp boost/changes.md
git commit -m "fix: describe the Boost.Filesystem change"
```

### Update to a newer Boost release

Keep the FetchContent Boost version and the subtree version the same, to avoid
API and ABI mismatches between filesystem and its dependencies. For example,
for 1.91.0:

1. Pull the upstream subtree. `--squash` collapses upstream history into one
   commit:

   ```sh
   git subtree pull --prefix=boost/filesystem \
       https://github.com/boostorg/filesystem.git boost-1.91.0 --squash
   ```

2. Resolve conflicts in `operations.hpp` and `operations.cpp`, then go through
   the reapply checklist in [changes.md](changes.md). Update the base tag and
   upstream commit at the top of that file.
3. Download the new tarball and compute its SHA-256:

   ```sh
   curl -LO https://github.com/boostorg/boost/releases/download/boost-1.91.0/boost-1.91.0-cmake.tar.gz
   shasum -a 256 boost-1.91.0-cmake.tar.gz   # or sha256sum
   ```

4. In the top-level `CMakeLists.txt`, update the `curl` comment, the
   `_boost_local_tarball` file name, the download `URL`, and **both**
   `URL_HASH SHA256=` values (the local-tarball branch and the download
   branch).
5. In `dependencies.json`, update `boost.version`, `boost.url` and
   `boost.sha256`.
6. Update the tarball name in `.gitignore` and the Boost version in
   `THIRD_PARTY_NOTICES.md`.
7. Check that `BOOST_INCLUDE_LIBRARIES` still covers every library named in
   `target_link_libraries` in `boost/filesystem/CMakeLists.txt`.
8. Configure into a fresh build directory, build, and run the tests.

### View local changes against upstream

```sh
base=$(git log --format=%H --grep='git-subtree-dir: boost/filesystem' -1)
git diff "$base" HEAD:boost/filesystem
git log --oneline -- boost/filesystem/
```

`$base` is the most recent squashed upstream import. Commits after it that
touch `boost/filesystem/` are FC modifications.

### Initial subtree import (already done)

```sh
git subtree add --prefix=boost/filesystem \
    https://github.com/boostorg/filesystem.git boost-1.90.0 --squash
```

## Build verification

Configure output shows the libraries FetchContent includes:

```text
-- Boost: libraries included: json;thread;system;smart_ptr;assert;config;container_hash;core;detail;io;iterator;predef;scope;type_traits
```

`filesystem` is not in the list; it is built from the subtree. The build
compiles it from `boost/filesystem/` (Ninja prefixes each line with a
progress counter):

```text
Building CXX object boost/filesystem/CMakeFiles/boost_filesystem.dir/src/operations.cpp.o
Building CXX object boost/filesystem/CMakeFiles/boost_filesystem.dir/src/directory.cpp.o
...
Linking CXX static library boost/filesystem/libboost_filesystem.a
```

## Reference

- Boost.Filesystem repository: https://github.com/boostorg/filesystem
- Boost.Filesystem dependency report:
  https://pdimov.github.io/boostdep-report/master/filesystem.html
- Boost 1.90.0 release: https://github.com/boostorg/boost/releases/tag/boost-1.90.0
- Build instructions: [doc/dev/building.md](../doc/dev/building.md)
- Licenses: [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)
