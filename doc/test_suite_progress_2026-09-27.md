# Test suite implementation progress — 2026-09-27

Accepted plan: [test suite review](test_suite_review_2026-09-27.md). Each row was planned before implementation in that document's ledger, then updated with applied behavior, evidence and differences. Earlier review evidence remains historical.

## Current qualification — 2026-10-05

Implementation revision `fa65328836906cee1c74a908afc4a91e52862973` passes the full
native macOS 26.7.1 arm64 Release lane: **178/178 tests, no failures or skips**, in
77.65 seconds of CTest execution. The run includes real APFS EXDEV, FSEvents
lifecycle/recovery, real Fresh handoff, package relocation, dependency rebuilds,
and the new archive-name, rename, directory-access, long-name and move-metadata
regressions. The user launched the run from a normal Terminal; its saved JUnit,
status 0 metadata and packaged executable hashes were independently checked.

ASan+UBSan passes **21/21** selected tests and TSan passes **5/5** lifetime tests
at the same revision. The earlier sanitizer startup failures below are historical.

The assistant execution environment failed to start FSEvents even in a standalone
probe and could not provision the EXDEV volume. The same probe and all affected
tests pass in the user's normal Terminal. Those environment failures no longer
block native macOS qualification; the underlying environment restriction was
not diagnosed.

[Machine-readable qualification record](qualification/macos-arm64-2026-10-05.json)
records the tested revision, platform, local evidence paths and hashes, sanitizer
results, package checksum and executable checksums. Full release evidence is in
`build-release/test-logs/lane-release-74167aa617/`.

Remaining platform qualification: native Linux x86-64/arm64 and earlier macOS
versions. The current build targets macOS 26.7.1. Passing this suite does not
establish release signing, distribution or license-material readiness.

## Completed improvements

| Commit | Improvement | Evidence |
| --- | --- | --- |
| `fa8212c` | Explicit Python pass/fail decisions under optimization | Runner negative-result controls, normal/`-O`/environment optimization, Lua and process-exit tests |
| `699a37b` | Exact registered Lua completion protocol | Missing/duplicate/unknown/partial/malformed controls and real premature-return rejection |
| `7f0d842` | Content manifests and mandatory raw link targets | Archive corruption and missing-link controls now fail for their intended reason |
| `d06ab24` | Independent native/Lua/copy/negative CTest discovery | 101/101 then-registered non-rebuild cases passed with parallel JUnit output |
| `6f59587` | PTY supervision, safe fixtures and diagnostic artifacts | Spawn/signal/deadline/noisy-output/descendant/concurrency checks and quoted/newline/Unicode fixture workflow |
| `50885d7` | Real-file fault/commit matrix | Copy/settings open/read/write/flush/close/commit failures, short writes/EINTR, move source removal and partial completion; zero writes now fail instead of looping |
| `96a646b` | Deterministic lifecycle schedules and monotonic deadlines | Latest-work/mailbox/queue/jobs/scheduler cases; real archive completion during suspension; affected watchdog and pause/cancel workflows |
| `5112d70` | Core models, boundaries and resource lifetimes | Seven core contracts, archive byte limits, Lua event overflow and queued archive leases |
| `5b1285c` | Real commands through three adapters | All 34 commands have behavior and busy-dialog availability expectations; copy/move/delete now honor panel job services |
| `8535855` | Tiny-screen rendering and actual terminal decoding | 36/36 command/render/PTY cases; fixed negative clipped menu height without changing the pinned FTXUI tree |
| `f56fd59` | Isolated relocation and real Fresh terminal handoff | Source/dependency reads denied, exact real archive output and helper provenance; Fresh attach/quit and failure restore input/modes |
| `08623af` | Native CI/presets, strict lanes, bootstrap controls and resource/performance evidence | 23/23 fast; 17/17 headless and UBSan; real APFS EXDEV; stable resources; real render/allocation measurements; visible sanitizer infrastructure failures |

## Historical validation — 2026-09-27

Native macOS arm64 is the available execution host. Final CTest discovery contains **173 cases**. At implementation revision `08623af`, the regular integration lane passes **166/166 with no skips** in 35.26 seconds. The extended lane passes its five runnable cases; its unconfigured EXDEV entry skips, and the same real EXDEV case passes separately on a disposable APFS volume. The slow dependency rebuild case also passes separately for LuaJIT, 7zr and Fresh. Thus every registered native case has passing execution evidence across these runs; instrumented/platform qualification has the limits below.

Final integration JUnit and metadata: `build/test-logs/lane-integration-a539ecf946/`. Summary log: `build/architecture-validation/final-integration.log`. Fast/extended logs: `final-fast-lane.log`, `final-extended.log` in the same validation directory. Slow rebuild evidence: `TS09-dependency-rebuild.log`; dependency revisions/fingerprints remain clean after the checks.

- Core-only: **17/17** cases pass with all UI/Lua/editor/LZMA source-directory options pointing to a nonexistent path; log: `build/architecture-validation/final-core-only.log`.
- UBSan: **17/17** core/fault/lifetime tests pass; artifacts under `build-ubsan/test-logs/lane-sanitizer-*`.
- Resource stress: **30 cycles pass**, with stable descriptor/thread counts and bounded job history/details/events.
- Benchmarks: 1k/10k/100k publication/selection/delta, event polling, and real UI rendering at 0/1/10/100% selection pass as non-gating measurements. Render records include p50/p95/max and median C++ allocation-call counts (direct library malloc calls are excluded). Current local measurements are Debug, not a Release performance baseline.
- ASan+UBSan: tests time out before main. TSan: all five lifetime tests terminate before main. A minimal program that only writes `entered main` reproduces an ASan timeout and TSan signal 11; the unsanitized program succeeds. Evidence: `build/architecture-validation/sanitizer-startup/results.json`, plus each sanitizer build's CTest/JUnit artifacts.
- Real EXDEV: **passed on a disposable APFS disk image**, with verified different `st_dev`, complete destination bytes and source removal through the real worker fallback. `tools/test_exdev_volume.py` detaches/removes the owned volume in teardown; log: `build/architecture-validation/TS09-exdev-volume.log`. Ordinary CTest still skips when no second filesystem is configured; strict release rejects that skip.
- Native Linux x86-64/arm64: full native qualification requires provisioned runners and the public pinned dependency inputs. The GitHub repository provides hosted core checks and separate maintainer-dispatched native workflows. No full native Linux runtime pass is recorded here.

## Coverage index

| Mechanism / contract | Test IDs or registry | Lane |
| --- | --- | --- |
| Harness decisions, protocol, binary-safe manifests, process ownership | `fc.harness.*`, `fc.negative.*`, `fc.process_exit.*`, `fc.lua.test_fixture_paths` | Fast/integration |
| Typed planning/execution, bytes/counters, commit preservation | `fc.core`, `fc.contract.typed`, `fc.fault.*`, copy case registry | Fast/integration; EXDEV extended |
| Settings/location syntax, fields, size/depth limits | `fc.contract.settings`, `fc.contract.locations`, `fc.fault.settings`, `settings_publication` | Fast |
| Directory delta/selection/sort model and watcher behavior | `fc.contract.directory`, R07/R15/R19–R22/R25 registrations | Fast/integration |
| Traversal depth/entry/link/overlap/cancel/postorder | `fc.contract.traversal`, `traversal_policies`, copy link cases | Fast/integration |
| Owned workers, mailbox, queues, scheduler, paused shutdown | `fc.lifetime.*`, `terminal_mailbox`, `suspended_archive_delivery`, `paused_shutdown` | Fast/integration/sanitizer |
| Jobs, retention, event cursors and expiry | `fc.contract.retention`, `fc.contract.events`, `lua_event_expiry`, `resource_retention`, `lua_job_events` | Fast/integration |
| Archive identity, byte budgets, active/queued leases | `archive_cache_identity`, `archive_byte_limits`, `archive_locations`, `fc.contract.retention` | Integration |
| Actual command effects, availability, event identity/usage | `test/command_cases.inc` → `fc.command.*`; archive-readonly, rebind, tab/focus regressions | Integration |
| Rendering/terminal decoding, resize and Fresh handoff | `tiny_unicode_rendering`, `fc.terminal.input_resize`, `fc.extended.fresh_*` | Integration/extended |
| Dependency identity/build propagation and relocation | `fc.harness.dependencies`, `fc.dependency_rebuild`, `fc.package` | Integration/release |
| Resource bounds and performance evidence | `fc.extended.resources`, `fc.benchmark.publication`, `fc.benchmark.render` | Extended, measurement only |

This index describes owned code contracts. It does not claim exhaustive vendored-library coverage or a measured line/branch percentage. Named failures/commit boundaries are checked independently of aggregate coverage. Current platform limits are recorded above. Strict release runners must provision their second filesystem. Performance percentage gates require a named Release-runner baseline.
