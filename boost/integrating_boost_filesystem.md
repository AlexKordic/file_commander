# Integrating Boost.Filesystem as a Git Subtree

## Why

We need to modify Boost.Filesystem source code and track those changes in our repo.
A git subtree gives us:
- Full source in our tree, editable like any other file
- Changes visible in normal `git log` / `git diff`
- Ability to merge upstream updates with `git subtree pull`

## Architecture

```
file_commander/
  boost/
    filesystem/           <-- git subtree of boostorg/filesystem (tag boost-1.90.0)
      include/boost/      <-- headers: filesystem.hpp, filesystem/
      src/                <-- compiled sources: operations.cpp, path.cpp, etc.
      CMakeLists.txt      <-- builds Boost::filesystem target
      cmake/              <-- BoostLibraryIncludes.cmake (config check helper)
  build/
    _deps/boost-src/      <-- FetchContent'd Boost 1.90.0 (all other libs, headers only deps)
  CMakeLists.txt          <-- orchestrates both
```

## The Problem: Boost.Filesystem Is Not Self-Contained

`boostorg/filesystem` depends on ~15 other Boost libraries (primary + transitive):

**Public dependencies** (propagated to consumers via `target_link_libraries PUBLIC`):
- assert, config, container_hash, detail, io, iterator, smart_ptr, system, type_traits

**Private dependencies** (build-time only):
- core, predef, scope, atomic (conditional, only if no C++20 `std::atomic_ref`)

**Transitive dependencies** (pulled in by the above):
- align, preprocessor, mp11, describe, throw_exception, concept_check, fusion, mpl,
  optional, utility, compat, variant2, function_types, functional, function, bind, tuple, typeof

Each of these is a separate GitHub repo (`boostorg/<name>`). Managing them individually
would require ~30 `FetchContent_Declare` blocks with coherent version pinning.

## The Solution: Subtree + FetchContent Hybrid

1. **Git subtree** only `boostorg/filesystem` -- the one library we modify
2. **FetchContent** the full Boost 1.90.0 cmake tarball -- provides all dependency targets
3. **Exclude filesystem** from `BOOST_INCLUDE_LIBRARIES` so FetchContent doesn't build a second copy
4. **`add_subdirectory(boost/filesystem)`** builds our local modifiable copy

### Key CMake Details

**BOOST_INCLUDE_LIBRARIES** -- controls which libs FetchContent builds:
```cmake
set(BOOST_INCLUDE_LIBRARIES
  thread system smart_ptr                                                      # project deps
  assert config container_hash core detail io iterator predef scope type_traits # filesystem deps
)
```
Note: `filesystem` is deliberately absent. Its dependency targets (Boost::system, Boost::config,
etc.) are created by FetchContent, then consumed by our local `add_subdirectory(boost/filesystem)`.

**BOOST_LIBRARY_INCLUDES** -- the escape hatch that makes this work:

Filesystem's `cmake/BoostLibraryIncludes.cmake` auto-discovers Boost header paths by scanning
`../../../libs/*/include` relative to itself. When filesystem is a subtree (not inside the Boost
source tree), this discovery fails. The script has a guard:
```cmake
if (NOT DEFINED BOOST_LIBRARY_INCLUDES)
    generate_boost_include_paths(...)
```
We pre-set it to point at the FetchContent'd Boost headers, bypassing auto-discovery:
```cmake
file(GLOB _boost_lib_include_dirs "${boost_SOURCE_DIR}/libs/*/include")
set(BOOST_LIBRARY_INCLUDES ${_boost_lib_include_dirs} CACHE INTERNAL "...")
```
This lets filesystem's `check_cxx_source_compiles()` configure checks (statx, st_blksize, etc.)
find all Boost headers they need.

## How To: Common Operations

### Modify Boost.Filesystem

Just edit files under `boost/filesystem/`. They're regular tracked files:
```bash
# Edit a source file
vim boost/filesystem/src/operations.cpp

# Your changes show up in git
git diff boost/filesystem/
git add boost/filesystem/src/operations.cpp
git commit -m "Customize filesystem copy behavior"
```

### Update to a Newer Boost.Filesystem Release

```bash
# Pull upstream changes (e.g. boost-1.91.0)
git subtree pull --prefix=boost/filesystem \
    https://github.com/boostorg/filesystem.git boost-1.91.0 --squash

# Also update the FetchContent URL in CMakeLists.txt to match:
# boost-1.90.0-cmake.tar.gz  ->  boost-1.91.0-cmake.tar.gz
```
The `--squash` flag collapses upstream history into a single merge commit.
After pulling, rebuild to check for any breakage with your modifications.

**Important:** Keep the FetchContent Boost version in sync with the filesystem subtree version
to avoid ABI/API mismatches between filesystem and its dependencies.

### View Upstream vs. Local Differences

```bash
# See what you've changed vs. upstream
git log --oneline boost/filesystem/

# The squash merge commit marks the upstream baseline.
# All commits after it are your modifications.
```

### Add the Subtree to a Fresh Clone (Already Done)

This was the initial setup command:
```bash
git subtree add --prefix=boost/filesystem \
    https://github.com/boostorg/filesystem.git boost-1.90.0 --squash
```

## Build Verification

The cmake configure output should show:
```
-- Boost: libraries included: thread;system;smart_ptr;assert;config;container_hash;core;detail;io;iterator;predef;scope;type_traits
```
Note: `filesystem` is NOT in this list (it's built separately from the subtree).

The build output should show filesystem being compiled from `boost/filesystem/`:
```
Building CXX object boost/filesystem/CMakeFiles/boost_filesystem.dir/src/operations.cpp.o
Building CXX object boost/filesystem/CMakeFiles/boost_filesystem.dir/src/directory.cpp.o
...
Linking CXX static library libboost_filesystem.a
```

## Reference

- Boost.Filesystem repo: https://github.com/boostorg/filesystem
- Boost.Filesystem dependency report: https://pdimov.github.io/boostdep-report/master/filesystem.html
- Boost 1.90.0 release: https://github.com/boostorg/boost/releases/tag/boost-1.90.0
- CMake tarball (~131 MB): `boost-1.90.0-cmake.tar.gz`
