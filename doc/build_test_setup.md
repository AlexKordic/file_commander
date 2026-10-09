# Build and test setup

Use the pinned inputs described in [build boundaries](build_boundaries.md). Full builds validate `dependencies.json`; intentional dependency development requires the explicit `FC_ALLOW_UNPINNED_DEPENDENCIES` override. C++20, Python 3.12+, Ninja and CMake 3.21+ are needed for the presets (manual CMake configuration still supports 3.19).

## Native and headless builds

```sh
cmake --preset native
cmake --build --preset native
ctest --preset native

cmake --preset core
cmake --build --preset core
ctest --preset core
```

`native` uses the pinned sibling dependency directories by default. For a fresh
checkout, use the public bootstrap and explicit paths in [the README](../README.md).
Override `FC_FTXUI_SOURCE_DIR`, `FC_LUAJIT_SOURCE_DIR`, `FC_FRESH_SOURCE_DIR` and
`FC_LZMA_SOURCE_DIR` at configure time for another layout. Core-only builds require
repository sources and checksum-verified Boost, with no FTXUI, LuaJIT, Fresh or
7zr checkout.

For an existing build:

```sh
cmake -S . -B build -G Ninja
cmake --build build -j6
ctest --test-dir build -LE 'slow|extended|benchmark|manual' --output-on-failure -j6
ctest --test-dir build -R 'fc.contract.locations|fc.fault.copy' --output-on-failure
ctest --test-dir build -N
```

CTest has independent native, core, command, Lua/copy, negative-control, process-exit and harness cases. Each blocking test has an external deadline. `test/review_cases.inc`, `test/command_cases.inc`, `test/lua_suites.json` and `test/negative_controls.json` are the case registries. Aggregate native and Lua smoke commands remain available.

## Lanes and evidence

```sh
python3 tools/run_test_lane.py fast --build build
python3 tools/run_test_lane.py integration --build build
python3 tools/run_test_lane.py extended --build build
```

The runner writes CTest output, JUnit and platform/revision/command metadata into a unique `BUILD/test-logs/lane-*` directory. `--expect-os Linux --expect-arch x86_64` prevents a cross build or a different host from being mistaken for native qualification. Per-test logs are under `BUILD/test-logs`; package evidence is under `BUILD/dist/test-logs`.

All automatic lanes and CTest presets exclude the `manual` category. The extended
lane includes resource cycles, measurement-only benchmarks and real Fresh handoff.
Resource tests check live descriptors/threads and owned history/detail/event bounds.
Benchmarks report timings without percentage gates; compare results only on a named
Release-build machine.

### Manual environment checks

The following seven tests require a working native service context or a second
filesystem. They have the `manual` CTest label, driven by the `manual` list in
`test/release_required.json`:

| Tests | Native requirement |
| --- | --- |
| `fc.regression.watcher_lifetime`, `fc.regression.late_panel_delivery`, `fc.regression.watcher_recovery` | Working native directory notifications (FSEvents on macOS). |
| `fc.lua.test_archive`, `fc.lua.test_pause_resume` | End-to-end workflows with no watcher startup errors. |
| `fc.package` | Relocated package workflow with native watchers and source-read isolation. |
| `fc.fault.exdev` | Writable destination on a different filesystem (`st_dev`). |

Build the distribution with `fc.package_build` in the configured build environment
first (see below). Manual tests consume that archive and do not require Cargo or
other compilers on the Terminal's PATH. Run them from a normal Terminal with the
second filesystem supplied:

```sh
FC_TEST_EXDEV_ROOT=/path/on/second/filesystem \
  python3 tools/run_test_lane.py manual --build build-release
```

On macOS, this helper provisions and cleans up a disposable APFS volume while
running the entire manual lane:

```sh
python3 tools/test_exdev_volume.py --manual-build build-release
```

Linux can normally use `FC_TEST_EXDEV_ROOT=/dev/shm`. The manual lane records its
own JUnit/logs and rejects missing, disabled, failed or skipped manual tests.
`ctest --preset manual` is also available once the required volume is supplied.
Use `ctest --test-dir build-release -N -L manual` to list the category. Bare
`ctest` includes all registered tests; use the presets or lane runner for the
automatic/manual split. The aggregate Lua smoke command likewise explicitly runs
all Lua cases, including the two manual workflows.

```sh
cmake --preset asan-ubsan
cmake --build --preset asan-ubsan
ctest --preset asan-ubsan

cmake --preset tsan
cmake --build --preset tsan
ctest --preset tsan
```

ASan+UBSan and TSan are separate configurations. `ubsan` is also available. At revision `fa65328` on macOS 26.7.1 arm64, ASan+UBSan passes all 21 selected tests and TSan passes all five lifetime tests. These results supersede the sanitizer startup failures recorded on September 27. See [test progress](test_suite_progress_2026-09-27.md#current-qualification--2026-10-05).

## Lua cases and replay

```sh
python3 test/run_lua_suite.py --binary build/fc
python3 test/run_lua_suite.py --binary build/fc --suite test_copy --case 1_basic_single_file test/test_copy.lua
python3 test/run_lua_suite.py --binary build/fc --negative-case archive_payload_corrupted
python3 test/run_lua_suite.py --binary build/fc --retain-failures test/test_archive.lua
```

Every invocation owns a config/fixture directory and unique logs. Committed tests must emit their exact declared JSON-lines case/completion sequence, exit successfully and print a PASS marker. Python optimization cannot remove runner failures. Direct `fc run your_script.lua` remains supported for arbitrary scripts without the registered-suite protocol.

Failure evidence includes bounded terminal/debug tails, protocol records, revision/replay metadata and a fixture manifest before cleanup. Optional fixture retention is capped at 16 MiB. The supervisor tracks descendant ancestry, including separate process groups; immediate double-fork daemonization before observation needs OS isolation. Lua fixtures use quoted native helper operations and binary-safe manifests, including filenames containing quotes/newlines.

## Packages and release qualification

After the manual-category split, the automatic macOS arm64 Release lane passed
**190/190 tests with zero skips** at revision `ed62486`. Package creation and
executable integrity checks passed. The seven manual tests were not run in that
lane and remain a separate qualification step.
[Automatic qualification record](qualification/macos-arm64-automatic-2026-10-05.json).

The native macOS arm64 Release lane passed **178/178 tests with zero skips** at
revision `fa65328` on October 5, 2026. The user ran it from a normal Terminal with
a disposable APFS volume for EXDEV; saved JUnit, lane status and package hashes
were verified afterward. [Qualification record](qualification/macos-arm64-2026-10-05.json).
Linux and earlier macOS versions remain unqualified; this build's deployment
target is macOS 26.7.1.

```sh
cmake --build build --target package_static_dist
ctest --test-dir build -R '^fc.package_build$' --output-on-failure
# Manual relocation check, from a healthy native session:
ctest --test-dir build -R '^fc.package$' --output-on-failure
```

The relocated package runs from an unrelated directory with isolated HOME/XDG settings. A sandbox denies source/dependency reads: `sandbox-exec` on macOS, `bwrap` on Linux. Read probes prove the restriction. The test verifies archive contents and actual bundled helper paths, plus the real Fresh version command. Separate automatic Fresh PTY tests cover attach/detach, recovery and failed invocation with restored input/modes. Missing optional helper/isolation capabilities are explicit skips.

`fc.package` first compares the archive's fc, Fresh and 7zr executable hashes with
the build outputs, then runs relocation without rebuilding. Missing, corrupt or
stale packages fail before relocation; rerun `fc.package_build` in the configured
build environment to refresh them. To retry only relocation from a normal Terminal:

```sh
ctest --test-dir build-release -R '^fc.package$' --output-on-failure
```

```sh
cmake --preset release
cmake --build --preset release
python3 tools/run_test_lane.py release --build build-release --expect-os Darwin --expect-arch arm64
```

Release requires a native `Release` build of this checkout with tests, pinned
dependencies, Fresh, 7zr and source-timestamp rebuild checks enabled. Before
running tests it compares CTest discovery against the independent qualification
contract in `test/release_required.json` and the command, regression, Lua and
negative-control registries. Missing, extra, duplicate, disabled or unbuilt tests
fail qualification. Add new standalone tests to the qualification contract when
registering them in CMake.

The automatic release JUnit report must contain every non-manual test without
failures or skips. Its metadata explicitly lists the manual tests not run; an
automatic pass does not claim those checks passed. Full native qualification
combines successful automatic release and manual evidence for the same source
revision/build. Manual checks stay registered and enabled, and an unexpected
`manual` label fails release preflight rather than silently removing coverage.

`fc.package_build` keeps distribution creation in automatic testing. The package
must contain executable fc, Fresh and 7zr files whose
SHA-256 hashes match the build outputs; those hashes are recorded in the lane
metadata. A core-only build, an unrelated CTest project or a stale package cannot
qualify. Manual checks reject absent required capabilities; only that lane needs
the second filesystem and a healthy native watcher service. The slow rebuild
check only touches timestamps and restores them; it runs serially with packaging.
The dependency self-test mutates disposable copies, never developer checkouts.

## Repository CI

`.github/workflows/public-core.yml` runs an isolated headless build and core
contracts on GitHub-hosted Ubuntu 24.04/GCC 14 for pushes to `main` and pull
requests. It needs only public Boost and the repository sources; it is not a
full FC/Fresh release qualification.

`.github/workflows/tests.yml` defines native macOS arm64, Linux x86-64 and Linux
arm64 jobs, plus separate native macOS/Linux sanitizer jobs. It is invoked only
by explicit maintainer dispatch with trusted source. Actions are pinned to
commits. The `release` input selects extended and automatic release checks; the
separate `manual_tests` input selects manual environment checks. Neither public
pushes nor fork PRs select private runners. A public repository must not use its
internal runners to execute untrusted PR code.

Provision self-hosted runners labelled `fc-pinned`, with the matching OS/architecture labels, the build tools above, a pinned-compatible Rust toolchain, Linux bubblewrap, and these environment variables:

- `FC_FTXUI_MIRROR`: optional reachable mirror containing the exact FTXUI revision;
  the manifest now defaults to the public FC fork.
- SDK sources come from the committed snapshot. An optional `--lzma-source`
  override can provision the same verified source set for local runs.
- `FC_TEST_EXDEV_ROOT`: second-filesystem fixture parent when `/dev/shm` is unavailable.

`tools/bootstrap_dependencies.py --root build-ci-deps` creates isolated checkouts
at the declared revisions and validates them. It refuses mismatched existing
inputs instead of resetting them. CI builds from this isolated root and uploads
JUnit/logs/distributions even after failures. Defining a workflow does not
constitute a passing GitHub or native Linux run; qualification status is recorded
separately.
