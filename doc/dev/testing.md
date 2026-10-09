# Testing File Commander

Every FC test is registered with CTest. Build FC first as described in
[building.md](building.md); the commands below use the `build-release`
directory from the quick build and run from the repository root. The Lua API
that the UI tests use is documented in [scripting.md](../scripting.md).

Before sending a pull request, run at least the fast lane, as
[CONTRIBUTING.md](../../CONTRIBUTING.md) asks:

```sh
python3 tools/run_test_lane.py fast --build build-release
```

## Test kinds

| Kind | Sources | CTest names | What they check |
| --- | --- | --- | --- |
| Core C++ tests | `test/core_operations.cpp`, `core_contracts.cpp`, `lifetime_contracts.cpp`, `file_faults.cpp`, `transfer_recovery.cpp` | `fc.core`, `fc.contract.*`, `fc.lifetime.*`, `fc.fault.*`, `fc.recovery.*` | `fc_core` without a UI: operation planning and execution, settings and locations, worker lifetimes, real-file fault injection and transfer recovery. The core and sanitizer presets build these too. |
| UI regressions and command contracts | `test/review_regressions.cpp`, `test/command_contracts.cpp` | `fc.regression.*`, `fc.command.*` | The application, panels, dialogs and Lua adapter, driven in-process without a terminal. Each command runs through its key binding, the command palette and Lua `fc.cmd`. |
| Lua UI suites | `test/*.lua`, registered in `test/lua_suites.json` | `fc.lua.*` | End-to-end workflows. `fc run` executes the script in a pseudo-terminal (PTY) against disposable fixtures, with a fake editor (`test/fakes/fresh_fake.sh`). |
| Negative controls | `test/negative_controls.json` | `fc.negative.*` | Sabotaged copies of Lua suites that must fail with a specific error, proving that the suites can fail. |
| PTY terminal tests | `test/test_terminal.py`, `test_script_exit.py`, `test_fresh_terminal.py`, `test_editor_recovery.py`, `test_editor_restart.py`, `test_workspace_recovery.py` | `fc.terminal.input_resize`, `fc.process_exit.*`, `fc.extended.fresh_*`, `fc.extended.editor_*`, `fc.extended.workspace_recovery` | Real terminal bytes and resizes, script errors and watchdogs, and the real Fresh editor: attach and detach, backend recovery, restart, and workspace recovery after signals. |
| Python harness tests | `test/test_result_checks.py`, `test_protocol.py`, `test_manifests.py`, `test_supervisor.py`, `test_lanes.py`, `test_docs.py`, `test_dependencies.py`, `test_fresh_bundle.py` | `fc.harness.*` | The test machinery and release gate, dependency pinning, Fresh source reconstruction from its bundle, and documentation links and coverage. |
| SSH tests | `test/remote_fs.cpp`, `remote_transfer.cpp`, `remote_ui.cpp`, `test_ssh_editor.py` | `fc.remote.*`, `fc.extended.ssh_editor` | Remote filesystems, transfers, panels and editing, through a local stand-in for `ssh` (see [SSH tests](#ssh-tests-against-a-real-host)). |
| Package and build checks | `test/test_package.py`, `test/test_dependency_rebuild.py` | `fc.package_build`, `fc.package`, `fc.dependency_rebuild` | Package contents, running from an unpacked package, and rebuilds after a dependency source changes. |
| Stress and benchmarks | `test/resource_stress.cpp`, `test/render_benchmarks.cpp` | `fc.extended.resources`, `fc.benchmark.*` | Thread, descriptor and history bounds over repeated cycles, and timings without pass/fail thresholds. |

Each test has a CTest timeout. The Python drivers run `fc` with its own
`HOME`, XDG directories and fixture directory, so tests never touch your real
settings. The shared PTY supervisor in `test/lua_runner.py`, used by the Lua,
terminal and package tests, also caps the captured output and kills the whole
process tree at the end.

`fc.key` in Lua delivers UI events directly, so it does not test how terminal
bytes are decoded; `fc.terminal.input_resize` covers that with real PTY input.

A test that needs a capability the machine lacks, such as the real Fresh
binary or a second filesystem, exits with code 77 and CTest reports it as
skipped. The release and manual lanes set `FC_REQUIRE_CAPABILITIES=1` and
`FC_REQUIRE_EXDEV=1`, which turn those skips into failures.

## Lanes

A *lane* is a named selection of tests. `tools/run_test_lane.py` runs a lane
through CTest and saves its results. Lanes select tests by CTest label:

| Lane | Runs | Use it |
| --- | --- | --- |
| `fast` | Tests labelled `unit`, `fault` or `harness`, except `extended`, `benchmark` and `manual` ones. | While you work, and before every pull request. Also works in the core build. |
| `integration` | Every test except `slow`, `extended`, `benchmark` and `manual` ones. Includes everything in `fast`. | Before sending a change to UI, Lua, file operations or packaging. |
| `sanitizer` | Tests labelled `core`, except `extended`, `benchmark` and `manual` ones. | In the `asan-ubsan` or `ubsan` build. |
| `thread` | Tests labelled `lifetime`, except `manual` ones. | In the `tsan` build. |
| `extended` | Tests labelled `extended` or `benchmark`, except `manual` ones. | Changes to the editor integration, SSH editing or resource use. |
| `release` | Every test except `manual` ones, with checks before and after; any skip fails. | Release qualification on `build-release`. See [release qualification](#release-qualification). |
| `manual` | Only tests labelled `manual`; any skip fails. | Tests that need native capabilities. See [manual tests](#manual-tests). |

```sh
python3 tools/run_test_lane.py fast --build build-release
python3 tools/run_test_lane.py integration --build build-release
python3 tools/run_test_lane.py extended --build build-release
python3 tools/run_test_lane.py release --build build-release
```

Always pass `--build`. Its default is `build`, which no preset creates. Other
options:

| Option | Effect |
| --- | --- |
| `--jobs N` | Parallel CTest jobs (default 6). |
| `--expect-os Darwin\|Linux` | Fail unless running on this OS, so that an emulated or cross-built run can't pass for a native one. |
| `--expect-arch arm64\|x86_64` | The same for the CPU architecture. |

A lane passes when CTest succeeds, at least one test ran and none failed. The
runner kills a lane that takes longer than 30 minutes. Each run writes a new
directory `<build>/test-logs/lane-<lane>-<id>/`:

| File | Contents |
| --- | --- |
| `results.xml` | JUnit results. |
| `ctest.log` | Full CTest output; the runner also prints its last part. |
| `metadata.json` | Lane, OS, architecture, Git revision, command, duration, status, and failed and skipped tests. The release and manual lanes add the expected test lists; the release lane adds the SHA-256 of the packaged executables and the manual tests it did not run. |
| `discovery.json` | Release and manual lanes: the test list CTest reported. |

Lua suites also write their own logs under `<build>/test-logs/lua/`, and the
package tests under `<build>/dist/test-logs/`. In a lane run, the terminal and
real-editor tests write theirs inside the lane directory.

### Labels

| Label | Meaning |
| --- | --- |
| `unit`, `fault`, `harness` | Quick, self-contained checks; selected by `fast`. |
| `core` | Links only `fc_core`; built by the core and sanitizer presets. |
| `lifetime` | Worker, queue and scheduler lifetime contracts; selected by `thread`. |
| `extended` | Long-running tests, the real Fresh editor and resource stress. |
| `benchmark` | Timing measurements without thresholds. |
| `slow` | `fc.dependency_rebuild`, which touches dependency source timestamps and rebuilds them. Only the release lane selects it, and it is disabled unless the build sets `FC_TEST_DEPENDENCY_REBUILDS=ON`. |
| `manual` | Added by CMake to every test listed under `manual` in `test/release_required.json`. |

Other labels, such as `integration`, `regression`, `lua`, `pty`, `remote` and
`posix`, describe a test but no lane selects by them.

### CTest presets

The CTest presets run similar selections without the lane's preflight checks
and saved metadata. `ctest --preset native` runs the integration selection in
`build-native`; `ctest --preset release` runs every automatic test in
`build-release`; `ctest --preset manual` runs the manual tests in
`build-release`. Plain `ctest --test-dir build-release` runs every test,
including the manual ones.

## Running tests directly

### One CTest test

```sh
ctest --test-dir build-release -N
ctest --test-dir build-release -N -L manual
ctest --test-dir build-release -R '^fc\.contract\.locations$' --output-on-failure
ctest --test-dir build-release -R '^fc\.fault\.' -V
```

`-N` lists tests without running them, `-L` selects by label and `-R` by a
regular expression. `-N -V` also prints each test's exact command line, which
you can run yourself. For example, the core contract executables take a case
name:

```sh
./build-release/fc_contract_tests locations
./build-release/fc_file_fault_tests copy
```

### Lua suites

`test/run_lua_suite.py` runs registered Lua suites the same way CTest does:

```sh
python3 test/run_lua_suite.py --binary build-release/fc \
  --logs build-release/test-logs/lua
python3 test/run_lua_suite.py --binary build-release/fc \
  --logs build-release/test-logs/lua test/test_tabs.lua
python3 test/run_lua_suite.py --binary build-release/fc \
  --logs build-release/test-logs/lua --case 1_basic_single_file test/test_copy.lua
python3 test/run_lua_suite.py --binary build-release/fc \
  --logs build-release/test-logs/lua --negative-case archive_payload_corrupted
python3 test/run_lua_suite.py --binary build-release/fc \
  --logs build-release/test-logs/lua --retain-failures test/test_archive.lua
```

With no script, it runs every suite in `test/lua_suites.json`, including the
two manual workflows. `--case` runs one declared case of a suite that lists
cases (currently `test_copy`). `--negative-case` runs one negative control,
and `--negative-only` runs all of them. The `smoke_lua_suite` build target
also runs every suite. Script paths are relative to the repository root.
Always pass `--binary` and `--logs`: their defaults are `$FC_TEST_BINARY` or
`build/fc`, and `build/review-lua`.

A suite passes when `fc` exits with status 0, prints a `[PASS]` line, and
records exactly the case and completion IDs declared in `test/lua_suites.json`,
in order. A negative control passes only when the script fails and the
expected error text appears in its debug log.

Each invocation creates a new `<logs>/run-<id>/` directory and prints its
path. It holds these files for each suite:

| File | Contents |
| --- | --- |
| `<suite>.log` | Terminal output (the last 2 MiB). |
| `<suite>.debug.log` | The script's debug log. |
| `<suite>.results.jsonl` | The case and completion records. |
| `<suite>.metadata.json` | Exit status, duration, binary, script, Git revision, and a `replay` command that reruns the same invocation. |
| `<suite>.fixture.json` | On failure: a manifest of the fixture tree, taken before cleanup. |
| `<suite>.fixtures/` | With `--retain-failures`: a copy of the fixtures, if they are 16 MiB or smaller. |

To try an arbitrary script, run `./build-release/fc run script.lua` and set
`FC_LUA_DEBUG_LOG` to a file path to get its debug log. Such a run doesn't load
your settings or saved workspace, but it works on your real files and does not
check the completion protocol. Point `HOME` and `XDG_CONFIG_HOME` at scratch
directories to isolate it. Run it from the repository root if it loads
`test/helpers.lua`.

`test/helpers.lua` is test-only. It holds fixture helpers such as
`tmpdir`, `create_file`, `cd` and `cleanup`, and suites load it with
`dofile("test/helpers.lua")`. It is not built into `fc`, not shipped in the
package, and not part of the scripting API. `check` and `test_pass` come from
`fc_framework.lua`, which is built into every `fc`.

## Manual tests

Seven tests need native capabilities that build machines and sandboxes often
lack. They are listed under `manual` in `test/release_required.json`, and CMake
labels them `manual`. No automatic lane or CTest preset runs them except
`manual`.

| Test | Needs |
| --- | --- |
| `fc.fault.exdev` | A writable directory on a different filesystem from the system temporary directory, given in `FC_TEST_EXDEV_ROOT` (on Linux the default is `/dev/shm`). It moves a file across filesystems through the real copy-and-delete fallback. |
| `fc.regression.watcher_lifetime` | Working native directory notifications (FSEvents on macOS, inotify on Linux). |
| `fc.regression.late_panel_delivery` | Working native directory notifications. |
| `fc.regression.watcher_recovery` | Working native directory notifications. |
| `fc.lua.test_archive` | Native directory notifications that start without errors. Runs the archive create, enter and extract workflow. |
| `fc.lua.test_pause_resume` | Native directory notifications that start without errors. Pauses and resumes a copy. |
| `fc.package` | An up-to-date package from `fc.package_build`, native directory notifications, and `sandbox-exec` (macOS) or `bwrap` (Linux) to deny reads of the source tree. |

Build the package first, then run the lane with a second filesystem:

```sh
ctest --test-dir build-release -R '^fc\.package_build$' --output-on-failure
FC_TEST_EXDEV_ROOT=/path/on/another/filesystem \
  python3 tools/run_test_lane.py manual --build build-release
```

On macOS, this helper creates a 128 MB APFS disk image, mounts it, runs the
whole manual lane with `FC_TEST_EXDEV_ROOT` pointing at it, and detaches it
afterwards:

```sh
python3 tools/test_exdev_volume.py --manual-build build-release
```

On Linux, `/dev/shm` usually is a separate filesystem, so the variable is
often unnecessary.

Run the manual lane from a normal terminal session; sandboxed environments may
not provide directory notifications. `fc.package` never rebuilds anything: it
first compares the package's `fc`, `fresh` and `7zr` with the build outputs and
fails if they differ, so rerun `fc.package_build` after rebuilding. The manual
tests don't need Cargo or a compiler. Before running, the lane checks that all
seven tests exist, are enabled and built, and carry the `manual` label exactly
when the registry lists them. It also works in a `native` build.

## Release qualification

```sh
python3 tools/run_test_lane.py release --build build-release \
  --expect-os Darwin --expect-arch arm64
```

Set `--expect-os` and `--expect-arch` to the platform you are qualifying.
Before running any test, the release lane checks that:

- The build directory was configured from this checkout with
  `CMAKE_BUILD_TYPE=Release`, `BUILD_TESTING=ON`, `FC_CORE_ONLY=OFF`,
  `FC_ALLOW_UNPINNED_DEPENDENCIES=OFF`, `FC_BUILD_FRESH=ON`,
  `FC_BUILD_LZMA_TOOL=ON` and `FC_TEST_DEPENDENCY_REBUILDS=ON`, and without a
  Boost source override. The `release` preset sets all of these.
- The build is native for the current OS and architecture.
- `fc`, `fresh` and `7zr` exist and are executable.
- CTest's test list matches the expected list exactly. The expected list comes
  from `test/release_required.json` plus the registries
  `test/command_cases.inc`, `test/review_cases.inc`, `test/lua_suites.json`
  and `test/negative_controls.json`, minus the manual tests. A missing, extra,
  duplicate, disabled or unbuilt test fails, as does a `manual` label that
  disagrees with the registry.

After the tests, the lane fails if any expected test is missing from the
results, failed or was skipped. It also checks that the package contains the
required license files and executables with the same SHA-256 as the build
outputs, and records those hashes.

The release lane does not run the manual tests; its metadata lists them as not
run. A release candidate is qualified on a platform when the release lane and
the manual lane pass for the same revision and build, on that operating system
and architecture.

## Sanitizers

```sh
cmake --preset asan-ubsan
cmake --build --preset asan-ubsan
python3 tools/run_test_lane.py sanitizer --build build-asan-ubsan

cmake --preset tsan
cmake --build --preset tsan
python3 tools/run_test_lane.py thread --build build-tsan
```

The `ubsan` preset builds into `build-ubsan` and also uses the `sanitizer`
lane. `ctest --preset asan-ubsan`, `ubsan` and `tsan` run the same selections.
The lanes and test presets set the sanitizers to stop at the first error.

All sanitizer presets inherit `core`, so only `fc_core` and the tests labelled
`core` are instrumented. ThreadSanitizer runs only the `lifetime` tests. The
UI, Lua and editor code is never built with sanitizers.

## SSH tests against a real host

In CTest, the `fc.remote.*` tests set `FC_SSH_BIN` to `test/ssh_fixture.py`.
This stand-in for `ssh` runs FC's real remote agent locally with `python3`, and
can drop a reply after a rename to test recovery. `fc.extended.ssh_editor`
also uses a local transport by default. None of them exercise OpenSSH
authentication, host keys, the network or the remote operating system.

To run the same contracts against a real host, use an alias from
`~/.ssh/config` that logs in without a password prompt and has Python 3
(`myhost` below):

```sh
env -u FC_SSH_BIN ./build-release/fc_remote_fs_tests myhost
env -u FC_SSH_BIN ./build-release/fc_remote_transfer_tests myhost
python3 test/test_ssh_editor.py build-release/third_party/fresh/bin/fresh --host myhost
```

The tests create uniquely named directories under `/tmp` on the host and
remove them. If the connection drops first, a `/tmp/fc-*` directory may be left
behind.

## Adding a test

Pick the cheapest kind of test that reaches the behavior. For every test:

- Set `LABELS` and a `TIMEOUT` in CMake. The labels decide which lanes run it.
- If it needs an optional capability, exit with 77 when it is missing
  (`SKIP_RETURN_CODE 77`), and fail instead when `FC_REQUIRE_CAPABILITIES` is
  set.
- Make sure the release lane expects it. The release lane fails on tests it
  does not expect. Registry-driven tests are expected automatically; other
  tests must be added to `test/release_required.json`.

| To add | Write it in | Register it in | Add to `test/release_required.json` |
| --- | --- | --- | --- |
| A core contract case | A function in `test/core_contracts.cpp`, `lifetime_contracts.cpp`, `file_faults.cpp` or `transfer_recovery.cpp`, plus its dispatch in `main` | The matching `foreach` case list in `CMakeLists.txt` | The group of the same kind (`contract`, `lifetime`, `fault`, `recovery`) |
| A UI or application regression | A function in `test/review_regressions.cpp` | `FC_REVIEW_CASE(function, "name")` in `test/review_cases.inc`, which creates `fc.regression.name` | Nothing |
| A new command | Its expected effect in `test/command_contracts.cpp` | `FC_COMMAND_CASE(id)` in `test/command_cases.inc`, which creates `fc.command.id` | Nothing |
| A Lua workflow | `test/test_<name>.lua` | An entry in `test/lua_suites.json` | Nothing |
| A negative control | A Lua prefix that breaks one step of an existing suite | An entry in `test/negative_controls.json` with `script`, `prefix` and the expected `error` text | Nothing |
| A Python harness check | `test/test_<name>.py` | The `fc.harness` `foreach` list in `cmake/tests.cmake` | The `harness` group |
| Any other test | Its own source or script | `add_test` in `CMakeLists.txt` (core-only tests, before the `FC_CORE_ONLY` return) or `cmake/tests.cmake` | The `standalone` list or a matching group |
| A manual test | A registered test that needs a native capability | Nothing else; CMake adds the label | The `manual` list, in addition to its normal entry |

`fc.command.*` compares the full command catalog with
`test/command_cases.inc`, so a new command without a case fails every command
test. `fc.harness.docs` also requires every command to appear in
[keys.md](../keys.md) and every Lua function in [scripting.md](../scripting.md).

A Lua suite entry names the script, the case IDs it reports in order (or an
empty list), and the final completion ID:

```json
"test_example": {
  "script": "test/test_example.lua",
  "cases": [],
  "completion": "example_glob_select"
}
```

The script calls `test_pass` with each case ID and then the completion ID, and
quits:

```lua
local h = dofile("test/helpers.lua")

local src = h.tmpdir("example_src")
local dst = h.tmpdir("example_dst")
h.mkdir(src)
h.mkdir(dst)
h.create_file(src .. "/a.txt", "a\n")
h.create_file(src .. "/b.log", "b\n")
h.cd(src, dst)

h.ensure_left_focus()
fc.key("esc")
fc.key("+")
check(fc.wait_event("dialog_opened", 2000), "glob dialog did not open")
fc.key({"*", ".", "t", "x", "t", "ret"})
check(fc.wait_event("dialog_closed", 2000), "glob dialog did not close")
check(#fc.selected() == 1, "expected 1 selected, got %d", #fc.selected())

h.cleanup(src, dst)
test_pass("example_glob_select")
fc.quit()
```

A suite with cases gets one CTest test per case, and the runner passes the
case ID in `FC_LUA_CASE`. The script must then run only that case; see the end
of `test/test_copy.lua`.

## Coverage index

This index maps FC's mechanisms to the tests that cover them. The lane column
names the first lane that runs each group: tests in `fast` also run in
`integration` and `release`, tests in `integration` or `extended` also run in
`release`, and tests labelled `core` also run in the `sanitizer` lane.

| Mechanism | Tests | Lane |
| --- | --- | --- |
| Test harness: pass/fail decisions, completion protocol, binary-safe tree manifests, process supervision, release gate, documentation | `fc.harness.{result_checks,protocol,manifests,supervisor,lanes,docs}` | fast |
| Suites fail for the intended reason; script errors and watchdogs; fixture names with quotes, newlines and Unicode | `fc.negative.*`, `fc.process_exit.*`, `fc.lua.test_fixture_paths` | integration |
| Typed operation planning and execution, byte counters, commit preservation | `fc.core`, `fc.contract.typed`, `fc.fault.*`; copy cases `fc.lua.test_copy.*`; cross-filesystem move `fc.fault.exdev` | fast; copy suite integration; `fc.fault.exdev` manual |
| Interrupted transfer recovery | `fc.recovery.*` | fast |
| Settings and location syntax, fields, size and depth limits | `fc.contract.{settings,locations}`, `fc.fault.settings`; `fc.regression.settings_publication` | fast; regression integration |
| Directory model: deltas, selection, sorting and watchers | `fc.contract.directory`; `fc.regression.{dangling_listing,filter_refresh,inactive_tabs,stale_watcher_batch,navigation_cancellation}`; `fc.regression.{watcher_lifetime,watcher_recovery}` | fast; integration; manual |
| Traversal: depth, entry and link policies, overlap, cancellation, post-order | `fc.contract.traversal`; `fc.regression.traversal_policies` and link cases in `fc.lua.test_copy.*` | fast; integration |
| Owned workers, mailbox, queues, scheduler, paused shutdown, late delivery | `fc.lifetime.*`; `fc.regression.{terminal_mailbox,suspended_archive_delivery,paused_shutdown}`; `fc.regression.late_panel_delivery` | fast and thread; integration; manual |
| Jobs, history retention, event cursors and expiry | `fc.contract.{retention,events}`; `fc.regression.{lua_event_expiry,resource_retention,lua_job_events}` | fast; integration |
| Archive identity, byte budgets and leases | `fc.contract.retention`; `fc.regression.{archive_cache_identity,archive_byte_limits,archive_locations}`; `fc.lua.test_archive` | fast; integration; manual |
| Command effects, availability, events and use counts | `fc.command.*`; `fc.regression.{command_routing,archive_readonly,binding_transactions,single_panel_focus}` | integration |
| Rendering, terminal decoding and resize | `fc.regression.tiny_unicode_rendering`, `fc.terminal.input_resize` | integration |
| Editor handoff, backend lifetime, recovery and restart; workspace recovery | `fc.lua.test_editor_integration` (fake editor), `fc.regression.editor_sessions`; `fc.extended.{fresh_success,fresh_failure,editor_recovery,editor_restart,workspace_recovery}` | integration; extended |
| SSH locations | `fc.remote.filesystem`; `fc.remote.{transfers,panels}`; `fc.extended.ssh_editor` | fast; integration; extended |
| Dependency pinning, rebuilds, packaging and relocation | `fc.harness.{dependencies,fresh_bundle}`; `fc.package_build`; `fc.dependency_rebuild`; `fc.package` | fast; integration; release; manual |
| Resource bounds and performance | `fc.extended.resources`, `fc.benchmark.{publication,render}` | extended |

The index covers FC's own code, not the vendored libraries, and does not claim
a line or branch coverage percentage. Benchmarks report timings without
thresholds; compare them only between Release builds on the same machine.

## CI

Two workflows live in `.github/workflows/`:

| Workflow | Runners | Triggers | What it does |
| --- | --- | --- | --- |
| `public-core.yml` | GitHub-hosted Ubuntu 24.04 with GCC 14 | Pushes to `main`, pull requests to `main`, manual dispatch | Headless core build (`FC_CORE_ONLY=ON`, Release), then `ctest -LE 'extended\|benchmark\|manual'`. Uploads the JUnit results. Needs no dependency checkouts. |
| `tests.yml` | Self-hosted, labelled `fc-pinned` plus the OS and architecture | Manual dispatch by a maintainer only | The full native and sanitizer jobs below. |

Pull requests get the hosted core checks only. They don't cover the UI, Lua,
Fresh or SSH tests, so run the relevant lanes yourself and list them in the
pull request. Pull request code never runs on the self-hosted runners.

`tests.yml` has two jobs:

| Job | Platforms | What it does |
| --- | --- | --- |
| `native` | macOS arm64, Linux x86-64, Linux arm64 | Bootstraps dependencies into `build-ci-deps`, configures a Release build in `build-ci` with `FC_TEST_DEPENDENCY_REBUILDS=ON`, builds it, and runs the `fast` and `integration` lanes with `--expect-os` and `--expect-arch`. The `release` dispatch option adds the `extended` and `release` lanes. The `manual_tests` dispatch option adds the `manual` lane. |
| `sanitizers` | macOS arm64 and Linux x86-64, each with `asan-ubsan` and `tsan` | Configures and builds the preset, then runs the `sanitizer` lane (`asan-ubsan`) or the `thread` lane (`tsan`). Runs on every dispatch. |

Both jobs upload `test-logs/` and `Testing/` from their build directory, and
`native` also uploads `dist/`, even when a step fails.

A self-hosted runner needs the build requirements from
[building.md](building.md), including the Rust toolchain, plus bubblewrap on
Linux. These environment variables are optional:

| Variable | Purpose |
| --- | --- |
| `FC_FTXUI_MIRROR`, `FC_FRESH_MIRROR` | Mirrors for the FTXUI and upstream Fresh clones. When unset, bootstrap uses the URLs in `dependencies.json`. |
| `FC_TEST_EXDEV_ROOT` | For the manual lane: a writable directory on a second filesystem. Needed on macOS, and on Linux wherever `/dev/shm` is not a separate filesystem. |

## Common failures

| Message | What to do |
| --- | --- |
| `release preflight failed: ... CMakeCache.txt`, or `release requires CMAKE_BUILD_TYPE=Release` | The lane used the wrong build directory. Pass `--build build-release`. |
| `release requires FC_TEST_DEPENDENCY_REBUILDS=ON` (or another option) | Configure with the `release` preset, or set the option yourself. |
| `incomplete release suite: missing=[...], unexpected=[...]` | A new test is not in `test/release_required.json`, or an expected test is not registered in this build. |
| `manual test label disagrees with qualification registry` | Rebuild or reconfigure so that CMake reapplies the `manual` labels from `test/release_required.json`. |
| `required release test disabled or not built` | Rebuild; for `fc.dependency_rebuild`, configure with `FC_TEST_DEPENDENCY_REBUILDS=ON`. |
| `native OS mismatch` or `native architecture mismatch` | `--expect-os` or `--expect-arch` does not match this machine. |
| `Package validation failed: ...` | The package is missing or older than the build. Run `fc.package_build` again. |
| `SKIP EXDEV: need writable FC_TEST_EXDEV_ROOT on a different st_dev` | Set `FC_TEST_EXDEV_ROOT`, or use `tools/test_exdev_volume.py` on macOS. |
| `required relocation isolation unavailable` | Install bubblewrap (Linux). |
| `SKIP real Fresh: packaged/pinned executable absent` | The build did not build Fresh. |
| `<suite>: completion marker missing` or `incomplete or duplicate case/completion records` | The script stopped early, or its `test_pass` IDs don't match `test/lua_suites.json`. |
| `Unknown test suite ...` | The script is not in `test/lua_suites.json`. Register it, or use `fc run` for an ad hoc script. |
