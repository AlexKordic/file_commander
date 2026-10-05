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

`native` uses the pinned sibling dependency directories by default. Override `FC_FTXUI_SOURCE_DIR`, `FC_LUAJIT_SOURCE_DIR`, `FC_FRESH_SOURCE_DIR` and `FC_LZMA_SOURCE_DIR` at configure time for another layout. Core-only builds require repository sources and checksum-verified Boost, with no FTXUI, LuaJIT, Fresh or 7zr checkout.

For an existing build:

```sh
cmake -S . -B build -G Ninja
cmake --build build -j6
ctest --test-dir build -LE 'slow|extended|benchmark' --output-on-failure -j6
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

The extended lane includes resource cycles, measurement-only benchmarks, real Fresh handoff and real EXDEV. EXDEV verifies different `st_dev` values, using `FC_TEST_EXDEV_ROOT` or `/dev/shm`. On macOS, `python3 tools/test_exdev_volume.py --binary build/fc_file_fault_tests` creates and tears down a disposable APFS volume for this case. An unavailable capability reports a skip; `FC_REQUIRE_EXDEV=1` makes it fail. Resource tests check live descriptors/threads and owned history/detail/event bounds. Benchmarks report timings without percentage gates; compare results only on a named Release-build machine.

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

The native macOS arm64 Release lane passed **178/178 tests with zero skips** at
revision `fa65328` on October 5, 2026. The user ran it from a normal Terminal with
a disposable APFS volume for EXDEV; saved JUnit, lane status and package hashes
were verified afterward. [Qualification record](qualification/macos-arm64-2026-10-05.json).
Linux and earlier macOS versions remain unqualified; this build's deployment
target is macOS 26.7.1.

```sh
cmake --build build --target package_static_dist
ctest --test-dir build -R '^fc.package$' --output-on-failure
```

The relocated package runs from an unrelated directory with isolated HOME/XDG settings. A sandbox denies source/dependency reads: `sandbox-exec` on macOS, `bwrap` on Linux. Read probes prove the restriction. The test verifies archive contents and actual bundled helper paths, plus the real Fresh version command. Separate Fresh PTY tests cover actual attach/quit and failed invocation with restored input/modes. Missing optional helper/isolation capabilities are explicit skips.

```sh
cmake --preset release
cmake --build --preset release
FC_TEST_EXDEV_ROOT=/path/on/second/filesystem \
  python3 tools/run_test_lane.py release --build build-release --expect-os Darwin --expect-arch arm64
```

Release requires a native `Release` build of this checkout with tests, pinned
dependencies, Fresh, 7zr and source-timestamp rebuild checks enabled. Before
running tests it compares CTest discovery against the independent qualification
contract in `test/release_required.json` and the command, regression, Lua and
negative-control registries. Missing, extra, duplicate, disabled or unbuilt tests
fail qualification. Add new standalone tests to the qualification contract when
registering them in CMake.

The final JUnit report must contain the entire expected suite without failures
or skips. The package must contain executable fc, Fresh and 7zr files whose
SHA-256 hashes match the build outputs; those hashes are recorded in the lane
metadata. A core-only build, an unrelated CTest project or a stale package cannot
qualify. Release rejects every absent required capability. A macOS release runner must provision a writable second volume; a Linux runner normally uses `/dev/shm`. The slow rebuild check only touches timestamps and restores them; it runs serially with packaging. The dependency self-test mutates disposable copies, never developer checkouts.

## Repository CI

`.github/workflows/tests.yml` defines native macOS arm64, Linux x86-64 and Linux arm64 jobs, plus separate native macOS/Linux sanitizer jobs. Actions are pinned to commits. It runs on pushes/manual dispatch, with extended work nightly and strict release on manual request. It does not run untrusted fork PR code on the private runners.

Provision self-hosted runners labelled `fc-pinned`, with the matching OS/architecture labels, the build tools above, a pinned-compatible Rust toolchain, Linux bubblewrap, and these environment variables:

- `FC_FTXUI_MIRROR`: reachable mirror containing the exact FTXUI revision. The manifest's localhost/private URL is not a hosted-runner dependency source.
- `FC_LZMA_SDK`: provisioned SDK 26.00 source directory, verified by the manifest fingerprint.
- `FC_TEST_EXDEV_ROOT`: second-filesystem fixture parent when `/dev/shm` is unavailable.

`tools/bootstrap_dependencies.py --root build-ci-deps --ftxui-url "$FC_FTXUI_MIRROR" --lzma-source "$FC_LZMA_SDK"` creates isolated checkouts at the declared revisions and validates them. It refuses mismatched existing inputs instead of resetting them. CI builds from this isolated root and uploads JUnit/logs/distributions even after failures. Defining the workflow does not constitute a native Linux run; qualification status is recorded separately.
