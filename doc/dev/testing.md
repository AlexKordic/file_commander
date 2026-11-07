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
| Model contracts | `test/model_contracts.cpp` | `fc.model.*` | `fc_model` and the `fc_engine` facade the macOS app uses: panes, tabs, commands, live transfer speed, the engine end to end, scene attaches. |
| macOS app | `macos/tools/`, `macos/Tests/`, the explainers | `fc.macos.explainers`, `fc.macos.compose_fixtures`, `fc.macos.native_harness`, macOS-only `fc.macos.native_editor`; `swift test --package-path macos`; `--run-explainer` | Explainer/fixture/gate contracts; required native scene, Compose layout, asset/input and private real-backend checks; separate FCKit/ExplainerKit tests and app explainers. See [macos_app.md](macos_app.md#tests). |
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
first compares the package's `fc`, `fresh` and `7z.so` with the build outputs and fails if they differ, so rerun `fc.package_build` after rebuilding. The manual
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

- The build directory was configured from this checkout with `CMAKE_BUILD_TYPE=Release`, `BUILD_TESTING=ON`, `FC_CORE_ONLY=OFF`, `FC_ALLOW_UNPINNED_DEPENDENCIES=OFF`, `FC_BUILD_FRESH=ON`, `FC_BUILD_SEVENZIP=ON` and `FC_TEST_DEPENDENCY_REBUILDS=ON`, and without a Boost source override. The `release` preset sets all of these.
- macOS also requires `FC_TEST_MACOS_NATIVE=ON`, enabled by default for native
  builds. Its `fc.macos.native_editor` test runs FreshKit and NativeEditor
  against the selected build's engine archive and staged Fresh, with compiled
  method discovery, complete per-case results and no skips.
- The build is native for the current OS and architecture.
- `fc`, `fresh` and `7z.so` exist and are executable.
- CTest's test list matches the expected list exactly. The expected list comes
  from `test/release_required.json`, including its current-OS `platforms`
  entries, plus the registries
  `test/command_cases.inc`, `test/review_cases.inc`, `test/lua_suites.json`
  and `test/negative_controls.json`, minus the manual tests. A missing, extra,
  duplicate, disabled or unbuilt test fails, as does a `manual` label that
  disagrees with the registry.

After the tests, the lane fails if any expected test is missing from the
results, failed or was skipped. It also checks that the package contains the
required license files and executables with the same SHA-256 as the build
outputs, and records those hashes.

The release lane does not run the manual tests; its metadata lists them as not
run. A release candidate's automatic and registered manual checks are qualified
when both lanes pass for the same revision and build, on that operating system
and architecture. Interactive GUI/input-method/VoiceOver and live SSH results
remain separate evidence; neither lane implies those checks passed.

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

The binary protocol and stream contracts additionally cover raw byte paths and
digests, bounded framing, corruption, disk-full failures, live pause/rate
controls, blocked fsyncs, source read-ahead starvation, consecutive directory
transfers and interrupted move cleanup. Gates deliberately hold the first
file's fsync until the next file has arrived, detecting an accidental EOF or
publication barrier without relying on timing thresholds.

To qualify throughput with independently generated, incompressible files:

```sh
python3 tools/benchmark_ssh_copy.py --host myhost --build build-macos --gib 1 --files 2
```

This creates and removes its own local and remote temporary directories. It
measures complete FC upload, download and same-host jobs, raw SSH and SFTP
baselines, local storage, process CPU, peak RSS, data-fsync count and plaintext
FC protocol byte counts. Protocol counts exclude SSH/TCP framing. Each job
includes destination readback, syncing and publication; generating the source
files is outside the timed interval. Use `--gib 10 --files 1` for a larger file.
Results and per-job metrics go under the build's `test-logs/ssh-copy-*` folder,
or `--output PATH`.

For software qualification without an SSH host, add `--fixture`. That mode runs
the exact helper over local pipes and reports a local-process baseline; it
does not measure encryption, a network or SFTP. It cannot establish network
link saturation. The benchmark is an explicit command, not a CTest release
timing requirement.

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
| 7-Zip's library: loading, formats, listing, extracting chosen entries, writing 7z | `fc.sevenzip.*` | fast; sanitizer |
| Archives as a read-only filesystem: browsing without extracting, copy-out, cancellation, nested archives, identity of open archives; every readable format, the one-pass extraction and hostile entries, legacy names, passwords, damaged entries, limits, and creating every writable format | `fc.archive.*` (fixtures from `test/fixtures/archives/make_archives.py`, with bsdtar for the formats Python can't write); `fc.sevenzip.*`; `fc.contract.retention`; `fc.regression.{archive_cache_identity,archive_byte_limits,archive_locations,archive_password_dialog}`; `fc.lua.test_archive`; the `archives` explainer | fast; sanitizer; integration; manual |
| Command effects, availability, events and use counts | `fc.command.*`; `fc.regression.{command_routing,archive_readonly,binding_transactions,single_panel_focus}` | integration |
| Rendering, terminal decoding and resize | `fc.regression.tiny_unicode_rendering`, `fc.terminal.input_resize` | integration |
| Editor handoff, backend lifetime, recovery and restart; workspace recovery | `fc.lua.test_editor_integration` (fake editor), `fc.regression.editor_sessions`; `fc.extended.{fresh_success,fresh_failure,editor_recovery,editor_restart,workspace_recovery}` | integration; extended |
| SSH locations | `fc.remote.filesystem`; `fc.remote.{transfers,panels}`; `fc.extended.ssh_editor` | fast; integration; extended |
| Dependency pinning, rebuilds, packaging and relocation | `fc.harness.{dependencies,fresh_bundle}`; `fc.package_build`; `fc.dependency_rebuild`; `fc.package` | fast; integration; release; manual |
| Resource bounds and performance | `fc.extended.resources`, `fc.benchmark.{publication,render}` | extended |

The index covers FC's own code, not the vendored libraries, and does not claim
a line or branch coverage percentage. Benchmarks report timings without
thresholds; compare them only between Release builds on the same machine.

### Rich Compose resource profiles

The experimental native Compose path has an explicit, reproducible resource
profile. Use a matching development Fresh checkout containing the profile
module:

```sh
python3 macos/tools/profile_compose.py --fresh ../editor-fresh \
  --profile release --output build-xcode-evidence/compose-resources-release
```

The default `--window-policy paragraph` uses the complete-paragraph contract
negotiated by capable native clients. Use `--window-policy legacy` for an explicit
older-client comparison. The requested and exported policy must agree; both are
recorded in the artifacts. Each run needs a new artifact directory so old binary
panes cannot be mixed with new results.

The tool runs an ignored Fresh parser/projection profile, exports actual binary
Compose panes, then measures protobuf decoding and Core Text layout with the
native consumer. Fixtures cover small and large prose, nested quotes/lists/code,
single-line and multiline image-heavy paragraphs, and a large table with unique
cells. The multiline paragraph checks that capable windows contain all 4,000
images rather than ending at an intermediate physical line. Each records
three samples, unchanged-layout reuse and four simultaneous pane layouts.
It also records a resize from 960 to 640 points and a return to 960, retaining
the preceding pane so complete table measurements can be reused. Returning
to the original width must restore its fragment count and table columns.
Two four-pane modes compare independent construction with measurement sharing
across the same document. Each pane has a distinct protobuf decode, and the
first shared pane starts without a provider. The resulting fragment ranges,
rectangles and table columns must match. Timing excludes those extra decodes
and geometry comparisons; process peak memory includes both retained sets.
Construction and first reuse are timed separately; reuse can also materialize
lazy quote/code ornament geometry that the fresh layout has not requested yet.
Artifacts include hardware/compiler/repository metadata, source and fixture SHA-256s,
source/window/payload sizes, timings and process peak RSS. RSS is a cumulative
process high-water mark, not the allocation cost of an individual case.

`ComposeShapingTests` compare joined-emoji glyphs in long prose, semantic font
runs, complete table samples and presentation labels with independently shaped
short text. They also verify source coordinates and unchanged UTF-8 bytes.
`ComposeTests` checks that retained long Unicode prose avoids per-scalar
coordinate maps, still resolves exact scalar endpoints across sparse intervals,
rejects UTF-8/surrogate interiors, and preserves construction-boundary admission.
The real-backend page-selection fixture exports its initial binary pane beside
the JSON and image artifacts, allowing the exact input to be replayed by
`fc-compose-profile`. These correctness checks do not qualify the resource
cost of complete shaping when Core Text refuses its default bounded policy.

The dense inline-image backend workflows cover single-line and multiline CRLF
source with 4,000 references to the same decoded image. They check whole-paragraph
delivery, native soft-break joining, paging, resize, exact Unicode save/undo and
complete accessibility elements. With `FC_COMPOSE_ARTIFACT_DIR` set, each exports
its actual initial pane and a source/projection report. `FC_COMPOSE_TEST_TIMING=1`
also records phase timings in separate directories. These observe editor/source
states; the fixtures open no GUI and do not measure painted frames. The formatter
can join source line breaks, so compare exported projections before attributing
a standalone raw-projection cost to the app.

Set `FC_COMPOSE_PROFILE_GEOMETRY=1` when running `fc-compose-profile` to export
each final layout beside the report as `REPORT-CASE.geometry.json`. Its hash
is recorded in the case result. The artifact includes projection text, source bounds,
fragment and cell ranges, glyph IDs, positions and fonts, table geometry and
attachments. Export happens after timing and RSS capture. Compare artifacts
from the same binary pane and font environment before and after a layout
optimization; faster construction must preserve that geometry. This option
does not measure drawing or image decoding.

Use `fc-compose-profile --preview INPUT.pb OUTPUT.json` to compare the actual
immutable request capture, detached preparation and exact-request handoff.
Three serial samples prepare a cold pane at 960 points, then independent
640-point previews with and without opaque measurement hints. Each input is
decoded separately; control order alternates. Full glyph/font/position, table,
attachment and source-map artifacts must agree outside the timing regions.
For lifetime optimizations, compare matching Release test builds in separate
scratch directories and keep compilation out of the measurement interval.
The preview worker interval includes its outer autorelease-pool drain; a
construction-only timer can exclude cleanup deferred by the control.
Native table-measurement tests also cancel cold and changed-font passes at
controlled checkpoints, verify that retry recomputes complete widths without
losing a prior valid aggregate, and check the default policy inside a cancelled
Swift task. They establish cooperative cancellation, not a time deadline for an
individual Core Text call or the entire preview pipeline.
The report separates main-actor capture from worker/handoff intervals. This is
a same-binary control, excluding parser formatting, GUI paint and interactive
latency. Its RSS high-water mark includes geometry JSON comparisons.

The same compiled executable accepts `--memory INPUT.pb OUTPUT.json` for a
separate live-allocation probe. It constructs one pane, four equal-width panes
and four differing-width panes in three cycles. Each batch stays alive across
an autorelease-pool drain and is then explicitly released. Samples record
current resident memory, physical footprint, live malloc bytes/blocks summed
across all zones, and process peak RSS before draining, while live afterward,
and after release. They are outside layout timing. This mode creates no views,
backend, decoded images or geometry JSON. Compare identical inputs, fonts and
Release builds in both process orders; resident/high-water memory and live
malloc allocation measure different things. Stable post-release allocation
does not by itself establish a total memory budget.

The private backend's many-table regression exports `many-tables.pb` for the
same profiler. It opens 128 separate tables with Unicode, emphasis, code,
an image and a hanging marker; checks first/middle/last table source hits and
caret geometry through a font/width change; and verifies insertion, undo and
exact CRLF saves. This exercises per-table work separately from the single
large-table profile.
The companion `many-tables-local.pb` removes only the complete font inputs,
exercising cell measurement from delivered rows with the same source and styles.

For the dense-image backend workflow, set `FC_COMPOSE_TEST_TIMING=1` together
with `FC_COMPOSE_ARTIFACT_DIR` and select
`ComposeBackendTests.testRealBackendDenseInlineImagesKeepMeasuredPagingResizeAndEditSaveUndo`.
Use a matching optimized Fresh binary and Swift's Release configuration for
performance conclusions. The workflow writes `dense-images.pb` for the native
profiler and a private `dense-image-timing/editor-*.jsonl` recording. Run
`python3 macos/tools/editor_telemetry.py RECORDING` to summarize its phases.
The report distinguishes synchronous invocation, observation of the requested
source state, Fresh rendering, native application and layout/terminal replies.
Frame costs are grouped by native application time; server work may have begun
before the phase, so these costs are not an exclusive breakdown of its latency.
Missing observations remain explicitly incomplete. These offscreen observations
do not measure physical keyboard input or a frame being painted.

Use `--profile debug` for diagnosing algorithms; compare the same fixtures and
configuration on the same machine. `--profile release` uses FC's `fc-release`
Cargo profile at optimization level 3 and Swift's Release configuration,
matching the bundled backend rather than Fresh's size-optimized upstream
Release profile. The environment artifact records the exact build arguments.
Backend results separate source-snapshot and UTF-16-index preparation from
semantic parsing of that prepared snapshot, and report the 64 KiB background
worker threshold. Pane encoding is timed separately. Older results without
`parse_scope` also included index construction in `parse_ms`; do not compare
those timings as a semantic-parser speedup. These profiles exclude engine file
IO, plugin formatting, image reads/decode, painting and typing-to-paint latency. They
neither create a backend session nor qualify GUI/SSH/recovery behavior.
Exporting a pane alone does not qualify the asynchronous cache path.
Fresh parser-cache unit suite additionally checks document retention weights:
LRU eviction below eight entries, index capacity at the
64 MiB boundary, exact Unicode/CRLF for an oversized current document, and an
evicted parser job whose real slot and source remain owned until completion.
The requested document and visible Compose working set are exempt from the soft
retention targets within the active scene's workspace. A split pressure test
checks stable snapshot identities across repeated gathering, then retirement
during polling after a pane leaves Compose. An inactive-workspace test verifies
that saved PageView mode does not pin history, actual open buffers survive
eviction, and source/heading metadata restores when returning. Additional cases exercise complete table samples,
formatter strings, shared versus separate link allocations, previous/rebased
formatter ownership and immediate admission of completed parser metadata.
The opt-in parser profile reports retained-capacity components and a batch of
10,000 cached weight queries separately from parsing/projection/encoding. Those
weights and query intervals are not resident memory or interactive latency.
Table-sample tests force fingerprint collisions and compare randomized
deduplication with the previous full-value set, including byte-distinct Unicode,
style, image and minimum-only differences and first-occurrence storage. The
opt-in parser profile also reconstructs both deduplication indexes over complete
parser samples and reports their element/string/style capacity weights. These
exclude final samples, allocator/hash bookkeeping and construction temporaries;
they do not measure live or peak memory. Compare binary panes separately to
check that deduplication preserves complete measurement contents and identities.
Table-finalization cancellation tests start with two parser-built tables,
interrupt work during the larger second table, refuse its completed measurement
and compare an uninterrupted retry's complete samples and identities. Another
case cancels before any font inputs are built. The existing worker/cache tests
separately verify slot ownership, source retirement and stale-result rejection;
these checks do not establish a cancellation latency deadline.
These checks do not bound editor buffers, protected working sets, external
snapshot owners, parser transients or native input history.

The private native/backend suite separately opens a document above 2 MiB, checks
proportional text, headings and decoded images, and verifies exact source
selection, Unicode insertion, save and undo beyond the old cutoff. Controlled
scene-peer checks require receipt-bound typing to proceed during parsing while
measured navigation waits for usable geometry.

The same private backend suite keeps a 200 KB single physical list paragraph
with emphasis, accented text, emoji and CJK. It checks formatter
readiness and hanging indentation through offscreen movement, resize, Unicode
insertion, exact save and undo. Formatter source assembly must make progress
through bounded reader calls without certifying an incomplete line. This does
not assert a bound on complete native source windows or retained batches.
Fresh's pure plugin tests separately compare the long-line UTF-8 offset index
against native encoding, including malformed-string and surrogate-interior
fallback. That index changes source lookup cost, not native wrapping width.

Hanging-prefix contract tests compare clipped list indentation with complete
Core Text layouts at multiple font sizes and pane widths, including styled
Latin, Arabic, Hebrew, CJK and emoji. They check physical continuation
whitespace, unchanged source/caret ownership, malformed or foreign samples,
and geometry reuse after prefix-font changes. The real-plugin/socket contract
checks parser-owned prefix samples for nested, task and quoted lists. These
checks do not qualify clipping a whole bidi paragraph or soft-wrap paging.

The paragraph-window socket contract starts near EOF before an opening marker
has been requested by a native client. It requires that marker's certified
sample, verifies the smaller window and keeps an older client on its original
window policy. The private native backend workflow checks source indentation,
cross-window Page Up, document-wide UTF-16 positions, resize, Unicode editing,
exact CRLF save and undo in large loose and nested tight lists. Tight-flow tests
include task markers, joined physical lines, hard breaks, Unicode/bidi text and
atomic inline images, and exclude headings, code, quotes and tables from direct
item prose. The native nested-list workflow checks the item's measured body
origin after paging; entering a link can reveal its source and reshape the
caret's line. A controlled readiness regression holds an offscreen marker
pending after the visible body completes, then certifies it. Whole parsed paragraphs and
atomic marker resources must remain complete; these are fixture-specific
window checks, not a global byte or latency budget.

Fresh's prefix tests also cover reuse across viewport/cursor changes, exact
header replacement and reveal inputs, unrelated metadata, formatter refresh
failure/recovery, document replacement, LRU eviction and allocation bounds.
An oversized prefix must produce the complete presentation without retention.
The ignored `profile_offscreen_prefix_reuse` test compares interleaved empty
and warm caches in the same build, using a long formatted opening line. Run
it in the Fresh checkout with the bundled backend's optimization profile:

```sh
FC_COMPOSE_PREFIX_PROFILE_OUTPUT=/tmp/fc-compose-prefix-profile.json \
cargo test --locked -p fresh-editor --features web --lib --profile fc-release \
  --config 'profile.fc-release.inherits="release"' \
  --config 'profile.fc-release.opt-level=3' \
  profile_offscreen_prefix_reuse -- --ignored --nocapture
```

This measures prefix preparation with supplied completed decorations. It
excludes parser/plugin work, scene traffic, native shaping and input latency;
its retained-allocation count is not a total memory budget.

Virtual-line ownership tests compare indexed range clears against live marker
positions after insertions/deletions, preserving half-open bounds, other
namespaces, inline texts and foreign markers. All removal paths must retire
their index entries. The dense tight-list socket fixture also requires the
older client's full-item formatter to complete under the existing deadline.

Image decode-lifetime checks hold a worker after bytes arrive, then vary source
revisions, attachment offsets, splits and document identities. A pending
presentation may finish received bytes but cannot start a stale source read;
late pixels retain their original target and cannot cross documents or hosts.
A private real-backend workflow types Unicode into a document larger than the
background-parser threshold while its first inline PNG decode is held, then
checks native image geometry, exact save and one undo. These checks do not
qualify a remote connection or an actual input method.

Image-identity checks keep canonically equivalent but byte-distinct targets
separate through out-of-order decodes, validation and cancellation. Identical
bytes from bridged strings still share work, while mutating a destination
selects its current literal identity. A controlled native scene receives two
real PNGs for those names, checks distinct preview geometry, then retargets one
reference to the already cached second resource. This exercises the native
protocol/controller/view path; it does not prove live SSH filesystem behavior.

Image-cache pressure checks preserve known geometry after evicting pixels,
including inline/block selection, hit testing, caret placement and accessible
explanations at narrow and wide measures. They vary nearby demands, ordering
and provisional gaps without allowing repeated source reads; free competing
capacity, request smaller thumbnails and explicitly reload to exercise
recovery. A 160-resource fixture checks that bitmap-free metadata stays at
128 entries without cycling visible resources, then admits a new resource
once the old entries are offscreen. These are decoded-cache bounds, not total
process-memory or interactive latency qualification.

Dense-image break checks compare every resulting break with Core Text's native
suggestion through changes in font, image widths and very narrow measures,
including ligatures, accents and emoji. They require the measured-advance path
to run and reuse one index across different typesetters; reordered/RTL runs
must retain the native contextual path. A private real-backend workflow keeps
4,000 inline PNG attachments in a complete 175 KB paragraph, pages both ways,
resizes, checks document-wide text-service coordinates, inserts Unicode, saves
exact CRLF source and undoes once. This does not establish a latency budget for
the complete workflow or qualify arbitrary soft-wrap clipping.
The native break oracles also cover NUL, U+001F, DEL and paragraph/line
separators alongside tabs, nonbreaking spaces, formatting controls and ZWJ
emoji. Printable-ASCII preparation must preserve those contextual fallbacks.

Geometry-reuse regressions vary marked-clause selection independently of its
draft, then replace the draft or raw reveal context. Empty-window relocation
and canonically equivalent but byte-distinct projections must retain current
source coordinates and exact bytes. Virtual insertions must display their
current text and cannot supply backend navigation. Native sample checks keep
nearby measured carets, resample a distant caret, and retire geometry exchanges
when source or rendering ownership changes. These complement the real-backend
typing/save/undo workflows; they do not qualify actual input methods.
A raw-context regression changes canonically equivalent source of equal byte
length, checking literal substrings, grapheme ranges and both directions of
the current UTF-16/source mapping.
`ComposeInputSnapshotTests` is required by the native lane. It checks raw
receipt ownership without ready formatting, release of prior glyph geometry,
measurement-candidate lifetime boundaries, literal Unicode context reuse and
invalid headers. Its held-geometry cases advance the authoritative raw scene
while retaining the old view, then check current text queries and IME capture.
Pixel requests cannot use that old source/context owner for a new raw range.
`ComposePreviewTests` is also required. Controlled workers verify one actual
worker through cancellation/reset, latest-request coalescing, exact source/draft/
font/width/image ownership, failure recovery and rejection after numeric lifetime
reuse. Prepared glyphs, attachments and ornaments match synchronous construction;
a reuse-only miss cannot shape. Arbitrary attributed objects stay on the main
actor. A held-preview grid checks immediate raw/IME queries, stale pixel refusal
and latest-only publication across draft, source and environment changes.
A pending-formatting case reflows the frozen old frame, verifies its source
namespace and stale-geometry refusal, then publishes a usable current-source
replacement. Accepted text and received-image completion retain their separate
fallback coverage.
The production resize case verifies that preview admission actually carries
measurement hints while creating new geometry. Table measurement tests also
release the old pane before worker preparation, compare disjoint source windows
and font changes with fresh geometry, and reject foreign lifetimes, changed
inputs, absent metadata and UTF-8-invalid styles. Canonically equal strings with
different literal bytes cannot reuse validation or stale span boundaries.
A separate preview-identity regression covers fresh decodes, canonical Unicode
aliases, sample/image/minimum/style changes, column counts, measurement IDs,
absent versus present-empty metadata and unknown protocol fields. Each changed
input must fail both geometry equivalence and prepared-result ownership.
The private-backend held-preview workflow exercises complete accessibility text,
selection/replacement, IME input, exact CRLF save and undo before any visible
preview is published. Render-dependent tests await matching geometry; pending
pointer workflows deliberately hold backend acknowledgments while the preview
worker prepares their draft, preserving the unacknowledged-input contract.
The native source-action regression sends Save while the raw owner is valid
but its projection is unusable, checking that it dispatches without a layout.
A queued Save follows an opaque preceding source update and cancels when its
buffer lifetime or displayed buffer changes, without needing visible geometry.
The real Fresh socket workflow sends Save/Undo/Redo with an obsolete projection
and no geometry; each must succeed on its first reply and preserve exact CRLF
source. It also preserves issued caret affinity across Save and checks duplicate
Undo, stale source/selection, retired lifetimes, modal deferral/retry and the
unchanged geometry requirement for navigation.
Viewport regressions keep the durable source/pixel anchor separate from an
adjacent-region probe. Wire checks cover explicit byte-zero presence, invalid
types/ranges, marker rebasing beyond retained coordinate history, opaque resets,
client ownership and cleanup. The socket fixture loads forward and backward
around a table with a 90 KB image destination while retaining its visible
context. The native workflow waits for the filled initial view, selects pages
until it crosses that captured source window, replaces once, undoes and saves
the exact original bytes. Changing the loaded region cannot move the reading
anchor or lose its table.
Selection-only context checks compare fresh and reused maps at every UTF-16
position and source byte across emoji, combining text, CJK and CRLF. Relocated
contexts and changed document lengths must acquire current coordinates and
bounds; malformed incoming metadata cannot reuse a previous valid snapshot.
A native selection frame keeps unchanged geometry while exposing the new
text-service selection. The Release profiler reports cold and selection-only
context preparation separately, using independently decoded message strings;
these timings exclude input-to-paint latency.

Sparse UTF-16 source-index tests compare the block constructor with an
independent scalar reference at every byte alignment around a checkpoint,
including empty/ASCII/CRLF/combining/ZWJ input and every Unicode scalar. They
require exact checkpoint and allocated-capacity equality, validate nearby
lookups and EOF, and retain the existing raw-context/caret-window contracts.
All six parser profile panes also remain byte-identical to their prior controls.
Constructor timings exclude buffer extraction, parsing, transport and GUI paint.

Scene-frame validation tests exercise signed-native/unsigned-wire counter
boundaries for hellos and frames, including optional timing values. A private
socket peer sends an unrepresentable window counter while text awaits a reply;
the client must close, retain the text and leave its last scene unpublished.
The required native-suite registry includes these decoder cases.
Collection tests reject oversized declarations/update lists and malformed or
over-budget copy instructions. They apply the largest admitted collections,
check their final entries and shrinking, and compare clipped copies against
the original frame. Socket cases also require pending-text recovery when an
unadmitted collection count closes the connection. Oversized before-controls
decode the declaration only; they never attempt the requested allocation.

Pending-input admission tests use a private scene peer that withholds receipts.
They distinguish the admitted preview from overflow recovery, enforce aggregate
payload bytes, drain accepted edits in order without replaying rejected text,
and exercise final IME commits and cancellation/disconnect recovery ordering.
The default-policy case submits 1,024 text events while one is in flight; only
128 remain in the admitted preview and all 896 overflow characters are
available verbatim through the recovery clipboard action. These checks do not
establish interactive latency, total app memory or a durable recovery journal.

### Interactive Compose qualification

For interactive development qualification, prepare a separate app from the
built Swift products and an explicitly supplied matching Fresh binary:

```sh
python3 macos/tools/qualify_compose.py prepare \
  --products macos/.build/out/Products/Debug \
  --fresh ../editor-fresh/target/debug/fresh
```

The helper prints a private `/tmp/fc-cq-*` directory with a verified ad hoc
signed app, exact-byte Markdown/image fixtures, executable hashes, private
profile/recovery/log directories and an
[interactive checklist](../../macos/tools/compose_manual_checklist.md).
It uses existing built products; source commit metadata does not attest to
their build provenance. Preparation does not launch an app or contact SSH.
From a normal macOS Terminal, run its `launch.command` for local checks or
`launch-dev.command` for an owned remote `/tmp` fixture on `dev`. The installed
app and its backend are separate. App quit retains the private backend for
recovery checks; the checklist includes explicit checkpoint/stop and remote
cleanup commands. Human results remain pending until recorded. Run
`python3 macos/tools/test_qualify_compose.py` for fixture, environment, launch
lock and remote ownership/cleanup contracts, also registered as the required
automatic CTest `fc.macos.compose_fixtures`. These tests make no SSH connection
and do not qualify GUI, actual input methods, VoiceOver or live remote editing.

## CI

`.github/workflows/tests.yml` is the repository's only workflow. It runs on
pushes to `main` and `pack_release`, nightly, and on manual dispatch. It has
no pull request trigger, so pull requests are not tested automatically: run
the lanes yourself and list them in the pull request.

Both jobs run on self-hosted runners labelled `fc-pinned` plus the OS and
architecture:

| Job | Platforms | What it does |
| --- | --- | --- |
| `native` | macOS arm64, Linux x86-64, Linux arm64 | Bootstraps dependencies into `build-ci-deps`, configures a Release build in `build-ci` with `FC_TEST_DEPENDENCY_REBUILDS=ON`, builds it, and runs the `fast` and `integration` lanes with `--expect-os` and `--expect-arch`. The nightly run and the `release` dispatch option add the `extended` lane; the `release` option also adds the `release` lane. The `manual_tests` dispatch option adds the `manual` lane. |
| `sanitizers` | macOS arm64 and Linux x86-64, each with `asan-ubsan` and `tsan` | Configures and builds the preset, then runs the `sanitizer` lane (`asan-ubsan`) or the `thread` lane (`tsan`). Runs on every trigger. |

Both jobs upload `test-logs/` and `Testing/` from their build directory, and
`native` also uploads `dist/`, even when a step fails.

A runner needs the build requirements from [building.md](building.md),
including the Rust toolchain, plus bubblewrap on Linux, and these environment
variables:

| Variable | Purpose |
| --- | --- |
| `FC_FTXUI_MIRROR`, `FC_FRESH_MIRROR` | Optional mirrors for the FTXUI and upstream Fresh clones. When empty, bootstrap uses the URLs in `dependencies.json`. |
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
