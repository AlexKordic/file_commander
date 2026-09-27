# Build and application boundaries

The AR01–AR09 implementation replaces the former monolithic compilation with shared targets. The review and individual implementation records are linked from [architecture progress](architecture_progress_2026-09-27.md).

| Target | Sources and responsibility | Dependencies |
| --- | --- | --- |
| `fc_core` | Directory model, typed operation plans, copy planner, traversal, jobs, archive locations/leases, settings and platform file/process helpers | Boost.Filesystem, Boost.JSON, threads; no FTXUI, Lua or editor |
| `fc_ui` | `app.cpp` composition/panel controllers, file-operation dialogs, separate search/job/settings views, command catalog, theme, editor adapter and native watchers | `fc_core`, FTXUI; CoreServices on macOS |
| `fc_lua` | Coroutine/test adapter consuming application commands and events | `fc_ui`, LuaJIT |
| `fc` | Startup, terminal dispatch and shutdown in `main.cpp` | `fc_lua` |
| `fc_core_tests` | Headless typed planner/executor, independent managers and injected services | `fc_core` |
| `fc_review_tests` | Filesystem, controller, UI, lifecycle and Lua regression contracts | Shared application libraries; application sources are not recompiled into tests |

`app.hpp` contains declarations. The command catalog is in `commands.hpp/.cpp`; copy planning and settings serialization have independent headers/implementations. `dialogs.cpp`, `find_dialog.cpp`, `job_dialogs.cpp` and `settings_dialogs.cpp` contain their respective views. UI assembly still owns FTXUI components; this is not a claim that every controller can be instantiated without a UI library.

## Reproducible inputs

[dependencies.json](../dependencies.json) records Boost's archive checksum, exact FTXUI/LuaJIT/Fresh revisions, and a fingerprint of LZMA SDK 26.00 sources. The modified Boost.Filesystem subtree belongs to the File Commander revision itself. Configure checks dependency revisions and tracked-file cleanliness; builds validate them again. Boost downloads and local tarballs are checksum checked.

Provide the declared checkouts via `FC_FTXUI_SOURCE_DIR`, `FC_LUAJIT_SOURCE_DIR`, `FC_FRESH_SOURCE_DIR` and `FC_LZMA_SOURCE_DIR`. Clone the manifest's source and check out its exact revision; extract LZMA SDK 26.00 into its source directory. The FTXUI fork's recorded remote is a local server. Outside this environment, a reachable mirror of the same commit must be supplied; the manifest does not claim that this private fork is publicly downloadable. Validate with:

```sh
python3 tools/check_dependencies.py
cmake -S . -B build -G Ninja
cmake --build build -j8
ctest --test-dir build --output-on-failure -j3
```

For intentional dependency development, `-DFC_ALLOW_UNPINNED_DEPENDENCIES=ON` explicitly disables checkout validation and emits a configure warning. This does not disable Boost's checksum. Disabled Fresh/7zr builds do not require their source trees. Core-only builds need only repository sources and Boost:

```sh
cmake -S . -B build-core -G Ninja -DFC_CORE_ONLY=ON
cmake --build build-core -j8
ctest --test-dir build-core --output-on-failure
```

The core-only configuration was also verified with every UI/Lua/editor/LZMA source-directory option pointing to a nonexistent path. Full native validation used CMake 3.31.5, Apple Clang 17.0.0, Cargo 1.95.0 and Python 3.14. Linux x86-64 compilation uses Zig 0.16.0 with the checked-in musl toolchain. Zig builds target archives as well as target objects; LuaJIT's build generators still use the host compiler. Fresh cross-compilation requires a separately built target editor.

## Tests and logs

The [test suite review and expansion proposal](test_suite_review_2026-09-27.md) records demonstrated harness/assertion gaps, a mechanism coverage matrix and prioritized implementation batches. It distinguishes current tests from proposed additions.

CTest discovers individual `fc.contract.*`, `fc.fault.*`, `fc.lifetime.*`, `fc.regression.*`, `fc.command.*`, `fc.lua.*`, `fc.negative.*`, `fc.process_exit.*` and harness/terminal/package cases. Labels select fast, integration, platform, extended, benchmark and slow build checks. Current commands, presets and strict release gates are in [build and test setup](build_test_setup.md); the permanent coverage index and qualification limits are in [test progress](test_suite_progress_2026-09-27.md). Cross builds register compiled tests but do not execute target binaries on the host.

The dependency rebuild test is disabled by default because it temporarily changes dependency source timestamps and can rebuild Fresh. Enable it with `-DFC_TEST_DEPENDENCY_REBUILDS=ON`, or run `python3 test/test_dependency_rebuild.py build`. It restores timestamps in `finally` blocks and does not change source contents. Package and rebuild checks run serially under CTest.

`python3 test/run_lua_suite.py --binary /path/to/fc --logs /path/to/logs` selects the binary and log destination; `FC_TEST_BINARY` provides a default. Each invocation creates its own log directory, and each process uses disposable settings, fixtures and debug logs. `FC_LUA_DEBUG_LOG` enables a specific script debug log; there is no shared `/tmp/fc_lua_debug.log`. `smoke_lua_suite` now runs the complete PTY suite. Raw keys remain available through `fc.key`; semantic commands use `fc.command` or `fc.cmd`.

## Runtime contracts

- Worker delivery uses the application mailbox and survives terminal suspension. The UI drains it; closed/lifetime-invalidated recipients discard late work.
- Directory snapshots contain filesystem data. Publication retains current view preferences; small watcher batches produce worker-read deltas.
- Traversal is iterative with explicit link, cancellation, error, entry and depth policies. Find does not follow directory links. Copy and delete retain their operation-specific policies.
- Immutable typed plans name sources, destinations and link text. Jobs expose summaries and ID controls; legacy record/pointer adapters remain for compatibility. Small mutations return asynchronous results through the same service.
- Archive persistence stores logical identities, including nesting. Physical roots are protected by leases; only unpinned roots are eligible for cache eviction. Cache identity includes device/inode, size and nanosecond modification/change timestamps on macOS/Linux. Changes during extraction reject publication; timestamp precision is filesystem-dependent. Other platforms disable cache reuse when this identity is unavailable.
- Completed history defaults to 256 summaries, 32 detailed jobs / 32 MiB estimated detail payload, 4,096 transitions, 1,024 global errors and 256 pending jobs. Details may expire while counts remain available. Application/Lua event streams cap unconsumed events and signal expiry.
- Cache limits default to 16 roots / 256 MiB extracted file bytes. Active leases may temporarily exceed those soft limits; later cache activity or explicit trimming reclaims unpinned roots.
- Command handlers and availability predicates are shared by shortcuts, palette and semantic Lua. Domain workers publish request/job events. The application observes FTXUI-owned focus and panel view changes once per UI pass.
