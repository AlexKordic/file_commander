# Self-Contained Static Build Plan

## Goal
Produce a self-contained build pipeline for `fc` with:

1. **True static binary on Linux** (preferred, using Zig+musl toolchain).
2. **Self-contained distribution on macOS** (not fully static; system frameworks remain dynamic by platform design).

## Current Constraints (Observed)

1. `fc` currently links to macOS system libraries/frameworks (`CoreServices`, `CoreFoundation`, `libSystem`, `libc++`).
2. CMake has absolute local paths for dependencies (`/Users/alexkordic/code/alex_ftxui`, `/Users/alexkordic/code/luajit`).
3. LuaJIT is imported as a prebuilt static archive, not built by CMake.

## Target Outputs

1. `build-static-linux/fc` (single static executable).
2. `dist/fc-linux-<arch>.tar.gz` (contains `fc`, optional `fresh`, optional `7zr`).
3. `dist/fc-macos-<arch>.tar.gz` (self-contained app directory, no Homebrew runtime dependency).

## Phase Plan

## Phase 1: Build-System Refactor (portable and reproducible)

1. Replace absolute paths with cache variables:
   - `FC_FTXUI_SOURCE_DIR` default `../alex_ftxui`
   - `FC_LUAJIT_SOURCE_DIR` default `../luajit`
2. Add `FC_STATIC_MODE` option to drive static-link behavior.
3. In static mode:
   - set `BUILD_SHARED_LIBS=OFF`
   - prefer `.a` archives first (`CMAKE_FIND_LIBRARY_SUFFIXES=.a`)
4. Keep `FC_BUILD_FRESH` and `FC_BUILD_LZMA_TOOL` optional but stage outputs under build tree for packaging.

## Phase 2: Build LuaJIT from source inside CMake

1. Replace imported prebuilt `libluajit.a` with an `ExternalProject`/custom build step.
2. Pass compiler/linker env from CMake to LuaJIT build.
3. Emit deterministic output archive path (e.g. `build/third_party/luajit/lib/libluajit.a`).

## Phase 3: Linux Static Pipeline with Zig (primary static target)

1. Add a toolchain file:
   - `cmake/toolchains/zig-musl-x86_64.cmake`
   - compilers: `zig cc` / `zig c++`
   - target: `x86_64-linux-musl` (and later `aarch64-linux-musl`)
2. Configure static build:
   - `-DCMAKE_BUILD_TYPE=Release`
   - `-DFC_STATIC_MODE=ON`
   - `-DFC_BUILD_FRESH=OFF` (first pass)
   - `-DFC_BUILD_LZMA_TOOL=OFF` (first pass)
3. Link flags for fully static binary:
   - `-static -static-libstdc++ -static-libgcc` (as applicable for toolchain)
4. Validate:
   - `file fc` shows statically linked ELF
   - `ldd fc` prints `not a dynamic executable`

## Phase 4: Integrate sidecar tools into dist package

1. Build/stage `fresh` and `7zr` for target platform.
2. Set runtime defaults (`FC_FRESH_DEFAULT_BIN`, `FC_ARCHIVE_TOOL_DEFAULT`) to relative paths inside package layout.
3. Add packaging target:
   - `cmake --build ... --target package_static_dist`
   - produce tarball with:
     - `bin/fc`
     - `bin/fresh` (optional)
     - `bin/7zr` (optional)

## Phase 5: macOS self-contained mode (platform-accurate fallback)

1. Keep system framework linking dynamic (required on macOS).
2. Remove dependence on external non-system dynamic libs.
3. Ship app directory tarball containing:
   - `fc`
   - `fresh`
   - `7zr`
   - default config/templates as needed
4. Validate on clean macOS host with no Homebrew libs.

## Test and Verification Matrix

1. Smoke tests:
   - run `test/test_events.lua`
   - run `test/test_palette.lua`
   - run `test/test_archive.lua`
2. Static checks:
   - Linux: `ldd`, `readelf -d`
   - macOS: `otool -L`
3. Runtime checks:
   - `F1` palette
   - archive create/extract
   - editor handoff if packaged

## Risks and Mitigations

1. LuaJIT cross-build fragility:
   - Mitigation: isolate as dedicated phase; fallback option to plain Lua for static profile.
2. Boost/thread static quirks with musl:
   - Mitigation: pin toolchain flags and validate early with minimal test suite.
3. macOS “fully static” not feasible:
   - Mitigation: define mac target explicitly as “self-contained dynamic against system libs only.”

## Acceptance Criteria

1. Linux static artifact exists and runs on a clean same-arch Linux machine.
2. Linux artifact has no dynamic library dependencies.
3. macOS distribution runs without Homebrew runtime dependencies.
4. Core Lua smoke suite passes on produced artifacts.
