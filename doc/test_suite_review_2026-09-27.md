# Test suite review and expansion proposal — 2026-09-27

Reviewed revision: `5ef288fb9e9a215f1697f1c206fbd606e42d197f`, including R01–R37, AR01–AR09 and the archive cache identity follow-up. Status: **proposal; additions below are not implemented**.

The existing suite is a useful regression baseline. Its strongest coverage is copy/link behavior, previous destructive-operation failures, and specific UI lifetime bugs. The next investment should first make test results trustworthy, then systematically cover failure boundaries, asynchronous ordering and supported platforms. More successful UI workflows alone would leave the most consequential gaps open.

## Evidence and current baseline

Read the registered CMake test entry points, every active first-party C++/Lua/Python test and its helpers, the fake editor, and the corresponding core/UI/scripting/platform mechanisms. Compared these against the specification, testing/build documents and architecture implementation records. Dependency projects' own suites were not audited. No line or branch coverage percentage was measured.

| Entry point | Actual coverage today | Limits |
| --- | --- | --- |
| `fc.core` | One headless scenario: typed copy planning/execution, independent job-manager errors, detached event sink, injected clipboard | One process and scenario; no explicit CTest timeout; copy assertion checks existence/state rather than bytes |
| `fc.regressions` | 41 named C++ cases: 32 R cases, eight AR cases and archive identity follow-up | One CTest result; shared process/global state; first exception stops remaining cases; many operations still exercise the legacy plan adapter |
| `fc.lua` | 14 scripts, including 34 numbered copy cases and `review_events.lua` | One CTest result; any PASS marker suffices; scripts generally drive C++ input dispatch rather than terminal bytes |
| `fc.lua_negative` | Five deliberately broken behaviors: rebind, editor invocation, two missing links and suppressed cycle errors | Valuable checks, but a narrow subset of assertions |
| `fc.process_exit` | Seven syntax/runtime/return/watchdog/long-wait cases | Failures generally checked by exit sign and elapsed time; no expected diagnostic category check |
| `fc.package` | Build/unpack distribution; execute embedded Lua from an unrelated directory | Does not exercise packaged 7zr/Fresh or prove independence from reachable build-time helper paths |
| `fc.dependency_rebuild` | LuaJIT, 7zr and optional Fresh source-timestamp rebuild checks | Opt-in by default; not a clean bootstrap or dependency-integrity test |

This review reran `ctest --test-dir build -E fc.dependency_rebuild --output-on-failure -j3`: **6/6 groups passed in 29.31 seconds** on the existing macOS arm64 build. CTest discovers seven groups. The unchanged slow dependency rebuild suite was not repeated; its previous passing result is recorded in [architecture progress](architecture_progress_2026-09-27.md). Earlier UBSan/core-only/Linux compilation results remain historical evidence; they were not rerun for this documentation review.

Log: `build/architecture-validation/test-suite-review-2026-09-27.log`.

### Controlled checks of the test harness

All probes used temporary scripts, disposable fixtures and existing test binaries. Production code and committed tests were unchanged.

| Probe | Observed result | Interpretation |
| --- | --- | --- |
| Run `test_find.lua` through the runner with `/usr/bin/true` as the binary | Normal Python rejects exit 0 with zero markers | The normal marker check works |
| Repeat with `PYTHONOPTIMIZE=1` | **Runner exits 0 and prints PASS with zero markers** | Python removes the runner's `assert` statements; this is a demonstrated false pass |
| Run a temporary copy-script variant defining and invoking only `test_basic_single_file()` | **Runner exits 0 with one marker**, without the final suite marker or other 33 cases | Partial execution can be reported as suite success |
| Wrap `fc.wait_for_jobs` to overwrite `alpha.txt` with `CORRUPT` after archive copy-out | **Archive script still passes** | Existence-only output assertions miss wrong bytes |
| Remove `sub/ext_link.txt` from the copy destination after job completion | **All 34 copy cases and final marker still pass** | Case 28 only checks link contents if the link exists; absence bypasses the assertion |
| Suppress bookmark deletion's `d` key | Script fails waiting for the subsequent dialog close | The existing workflow catches this mutation; it is not counted as a false pass |

Logs: `build/architecture-validation/test-review-probes/`, including `normal_empty_binary.log`, `optimized_empty_binary.log`, `partial_copy.log`, `archive_payload_corrupted.log`, `external_link_missing.log` and `bookmark_delete_disabled.log`. These local logs are supplementary evidence, not permanent test inputs. The meaningful probes should become committed harness/negative-control cases.

## Findings and recommended changes

Priorities describe implementation order: **P1** undermines result trust or leaves a critical data/lifecycle boundary unverified; **P2** improves breadth, isolation and release confidence. Coverage gaps below are not claims of additional production defects.

### TS01 — Python optimization can disable pass/fail decisions — P1, reproduced

[run_lua_suite.py:48](../test/run_lua_suite.py#L48) uses Python `assert` for success, negative-control status and expected errors. The process-exit, packaged-script and dependency-rebuild runners use the same pattern. Inherited `PYTHONOPTIMIZE=1` disables these checks; explicitly running Python with `-O` has the same effect.

**Proposed change:** use explicit conditional failures for test-runner decisions. Add runner self-tests under normal Python, `-O` and `PYTHONOPTIMIZE=1`: empty binary, nonzero exit, signal termination, timeout, absent completion record and negative control failing for the wrong reason. Do not rely only on clearing an environment variable, since `-O` is also an entry point.

**Acceptance:** every intentionally invalid result is rejected in all three modes, with a diagnostic naming the case and failure category.

### TS02 — A subcase PASS marker is treated as suite completion — P1, reproduced

[run_lua_suite.py:46](../test/run_lua_suite.py#L46) accepts any nonempty marker list. [test_copy.lua:62](../test/test_copy.lua#L62) emits subcase markers long before the final marker at line 1184. A premature successful return after the first subcase passes the runner.

**Proposed change:** define explicit case IDs and expected completion records. Initially require each script's exact final marker; then register copy subcases independently and emit a structured result with suite ID, case ID and final status. Validate records separately from terminal display text. Preserve support for arbitrary user scripts by separating generic script execution from the test-suite completion contract.

**Acceptance:** an early return, duplicate case, missing case, unknown case or incomplete footer fails the suite. A legitimate one-case script succeeds only against its declared manifest.

### TS03 — Some workflow assertions do not check the promised result — P1, reproduced for archive content and missing links

[test_archive.lua:62](../test/test_archive.lua#L62) checks that copied-out files exist, not their contents or exact tree. [core_operations.cpp:45](../test/core_operations.cpp#L45) also checks existence/state. The standalone [pause test](../test/test_pause_resume.lua#L42) accepts `completed_with_errors` in a successful fixture and checks only output size. Other copy/native cases do check bytes; these weaknesses are specific to the cited scenarios.

[Copy case 28](../test/test_copy.lua#L846) checks the external link only inside `if h.is_symlink(...)`; a missing link passes. Removing that destination link during the controlled probe still produced all 35 markers (34 cases plus footer). [Case 8](../test/test_copy.lua#L246) checks that link text is non-nil without comparing it to the required target. Require presence/type first, then exact link text and contents where appropriate.

**Proposed change:** add a reusable tree-manifest comparison: relative name, entry type, exact bytes/hash, raw link text and contractual metadata. On successful fixtures assert zero unexpected errors and exact finalized/skipped/failed counters. Compare affected source/destination trees before and after failures. For archive round trips compare extracted manifests, not compressed bytes, since archive encodings need not be byte-identical.

**Acceptance:** corruption, truncation, a missing required link, an unexpected extra file, altered link text, false success state and spurious errors each make the relevant test fail. Keep the archive corruption and missing external-link probes as negative controls.

### TS04 — Destructive operations lack a systematic failure/commit matrix — P1, source-established gap

[R02/R13](../test/review_regressions.cpp#L102) cover cancellation and preservation of old destinations; R13 directly exercises `move_by_copy`; R03 covers failed archive tools. [AR02](../test/review_regressions.cpp#L874) injects a settings replacement failure. There are no equivalent deterministic checks at each read/write/flush/close/rename/source-removal boundary, and no test of `run_move` reaching its fallback through a real cross-device rename.

**Proposed change:** add narrow fault/checkpoint hooks at the owned file-operation boundaries. Keep real temporary files underneath. Exercise explicit short writes, EINTR, ENOSPC, EIO, EACCES, failed commit and failed source removal. Add a real two-filesystem test in a disposable Linux environment that verifies different `st_dev` values before expecting EXDEV.

**Acceptance:** before destination commit, existing output remains unchanged; a move never removes its source before a complete destination exists; errors/cancellation are truthful; only owned staging is cleaned up. After partial multi-item completion, verify the specified completed subset rather than demanding rollback of already committed files. Process termination tests establish process-crash behavior, not power-loss durability.

### TS05 — Async tests often select timing by sleeping, and one timeout uses CPU time — P1 for lifecycle coverage

[R02/R12/R13](../test/review_regressions.cpp#L102) use throttling and wall delays to reach operation states. [test_copy.lua:33](../test/test_copy.lua#L33) computes a timeout with `os.clock()`, which measures CPU time while the loop yields to event waits; its nominal duration is not a wall-clock bound. R25 and AR01 already show useful controlled-reader techniques, but suspended archive completion and complete mixed-worker shutdown schedules are not covered systematically.

**Proposed change:** use named barriers/checkpoints to reach exact states; use a monotonic elapsed-time helper for integration deadlines and an injectable clock for scheduler unit tests. Every barrier wait must have a diagnostic deadline and teardown must release blocked workers even after assertion failure.

**Acceptance:** deterministic schedules cover cancellation before start/during work/before publication, superseded requests, tab switch/panel destruction, terminal suspension, post-close delivery and paused shutdown. Repeat controlled schedules without enlarging sleeps; keep actual OS watcher/process tests alongside them.

### TS06 — New service contracts have only selective boundary coverage — P2

[AR05](../test/review_regressions.cpp#L1032) is a useful 1,000-job test, but uses `detail_count=0`, small count limits and paced empty jobs. It does not verify positive byte-budget eviction, a full pending queue, or application/Lua event expiry at their actual limits. [AR03](../test/review_regressions.cpp#L901) covers entry truncation and 120-level walking, but not the configured depth boundary. Settings and Location have a few targeted examples, without systematic malformed-input/round-trip coverage.

**Proposed change:** add table-driven core suites for typed plans, directory view state, traversal, settings, locations, retention and sequenced events. Test each limit at `limit-1`, `limit`, `limit+1`, plus zero where zero is a valid setting. Add bounded generated inputs for codecs and a small independent directory/job model for operation sequences.

**Acceptance:** each public policy has an explicit expected result and an error/limit case. Expired details retain accurate summaries; queue rejection is nonblocking and explicit; slow subscribers are told to resynchronize; no retained lease is invalidated by eviction.

### TS07 — Command routing coverage does not establish real command equivalence — P2

[AR08](../test/review_regressions.cpp#L1079) replaces handlers and availability predicates with counters. This correctly tests dispatch/accounting through three adapters. It cannot prove that actual handlers choose the right files, job type, dialog, state or events. Several Lua tests exercise real commands, but there is no full catalog-to-behavior matrix.

**Proposed change:** retain the routing contract test, then use fresh equivalent fixtures to execute real handlers through shortcut, palette and semantic API. Cover enabled/disabled contexts, archive read-only state, empty panels, selections/focus fallback, pending dialogs and rebound keys. Destructive paths operate only on fixture trees.

**Acceptance:** compare resulting state, typed operation/result, side effects, event identity and usage increments. Normalize generated IDs/timestamps rather than requiring unrelated executions to have identical numbers. Require a new catalog command to supply behavior and availability cases.

### TS08 — Test discovery and isolation are coarser than the test cases — P2

[CMakeLists.txt:301](../CMakeLists.txt#L301) registers all 41 native cases as one test; [the native main](../test/review_regressions.cpp#L1112) stops at the first exception. The executable already accepts one case ID, so per-case process isolation is readily available. Lua's 14 scripts are also one fail-fast group. `fc.core` has no explicit CTest timeout.

**Proposed change:** register each native case and Lua scenario with descriptive names and labels, keeping R/AR IDs as traceability labels. Provide one authoritative case registry, per-case deadlines and structured/JUnit output. Preserve the aggregate smoke command. Use an external deadline for tests that can block in a destructor or thread join.

**Acceptance:** CTest can discover/filter/run one mechanism; one failure does not prevent unrelated cases from executing. Each process gets disposable config/temp/log roots. Repeated and concurrent invocations cannot share fixtures or logs. Mark true shared resources explicitly rather than serializing the whole suite.

### TS09 — Platform, packaging and terminal coverage remain incomplete — P1 for release qualification

The Linux application/core binaries have been compiled, not executed. Native watcher and file-copy backend differences therefore remain untested on Linux. [test_packaged_script.py:18](../test/test_packaged_script.py#L18) verifies embedded Lua but never invokes packaged helpers. The editor fake records arguments; it does not establish real terminal handoff. [Lua key injection](../scripting.cpp#L380) calls `OnEvent` directly, bypassing terminal byte decoding; the PTY runner fixes one 140×40 geometry.

**Proposed change:** run native Linux x86-64 tests in addition to macOS arm64; qualify Linux arm64 if it is a shipped target. Add isolated relocation tests without access to build paths, actual packaged archive create/extract, helper resolution/error cases, real terminal-input/resize tests, and a small pinned-Fresh smoke lane.

**Acceptance:** package tests assert the executed helper path and correct output. Linux runs exercise the actual watcher/copy backend. Foreground attach success/failure returns usable terminal modes, focus and delivery of work completed during suspension. Missing platform capabilities produce explicit skips; required release capabilities cannot silently skip.

### TS10 — Harness resilience, diagnostics and reproducible execution need their own tests — P2

[lua_runner.py](../test/lua_runner.py#L14) has a monotonic timeout and process-group kill, but no self-tests, unbounded captured output and no assertion that helper descendants are gone. Some production helpers create their own process groups, so killing the top-level group alone is not proof of complete teardown. The Lua runner deletes fixtures before validating results, retaining logs but losing failed filesystem state. [helpers.lua](../test/helpers.lua#L73) embeds paths in shell strings and counts `ls` lines, which is unsuitable for quote/newline filename cases. These are source-established limits; no escaped descendant or memory exhaustion was reproduced.

**Proposed change:** self-test spawn failure, fast exit, signal, timeout, noisy output, child/grandchild teardown and simultaneous runs. Bound output with a diagnostic tail plus bounded artifacts. Use native fixture helpers or explicit argument arrays for filesystem setup and binary-safe manifests. Save failed-case manifests/logs before cleanup, with opt-in bounded fixture retention. Add repository-owned CI/presets; the vendored Boost workflow does not test this application.

**Acceptance:** harness failures are distinguishable from product failures; deadlines terminate fixture-owned process trees and leave no leaked descriptors/helpers. Failures include case/seed, platform, dependency revisions, last state/events, tree differences and replay command. Test setup failures fail immediately rather than being mistaken for application behavior.

## Proposed suite organization

Keep CTest as the common entry point and reuse the existing C++ checks and Python PTY runner. No wholesale test-framework migration is needed before expanding coverage. Extract common fixtures and use parameter tables where inputs differ; keep independent expected results rather than reconstructing the production algorithm in tests.

```text
test/
  support/       temporary roots, tree manifests, scoped environment, barriers,
                 fake clock, fault hooks, process supervisor, result protocol
  core/          directory views, typed plans, traversal, settings, locations,
                 job state/retention, events, scheduler and dispatcher contracts
  filesystem/    real copy/move/delete/rename/mkdir, metadata and fault boundaries
  application/   panel generations/tabs, watchers, real command handlers/dialogs
  lua/           script API, workflows, event consumers and failure controls
  terminal/      byte input, resize, rendering invariants and restored I/O
  platform/      Linux/macOS backends, two-filesystem moves, helper integration
  package/       relocation, helper provenance, clean builds and dependency checks
  stress/        seeded operation sequences, resource budgets, parser fuzzing
  performance/   repeatable reconciliation/render/poll measurements
```

Move existing cases gradually; their passing behavior and review IDs remain part of the registry. Core tests should continue building with absent FTXUI/Lua/editor source trees. Test helpers must not reintroduce those dependencies into the core target. Process-based integration tests own their fixture roots and manage real external tools; pure service tests use narrow injected boundaries.

## Mechanism coverage to add

| Mechanism | Existing useful checks | Required additions and independent expected results |
| --- | --- | --- |
| Directory enumeration, sorting, filtering, selection and focus | R15, R19–R23, AR02/04; glob/focus/tabs Lua | All six sort orders and ties; empty/all-hidden views; filter during refresh; selected/focused entry removed or renamed; full snapshot versus delta yields the same path/type/size set; selection statistics equal independently counted visible/selected entries |
| Navigation, tabs and watcher reconciliation | R07/08/20–22/25; one ordinary AR04 delta | Controlled create→modify→rename→delete bursts; duplicate/out-of-order notifications; tab close/switch during scan; root rename/delete/recreate; old-generation batch after new publication; dropped-event recovery produces a complete rescan; native Linux and macOS delivery |
| Traversal and Find | AR03; copy's cycle/link matrix; basic Find navigation | Empty and overlapping roots, multiple aliases, depth/entry exact limits, unreadable subtree, vanished entry, callback pruning/postorder, cancellation at every phase; `*`/`?`/case behavior; no-match, restart, close during search and visible truncation |
| Typed planner/executor | Headless contract; AR06; legacy-adapter regressions | Every operation kind has an explicit successful and failing plan; source/destination/link fields are unambiguous; plans remain immutable; UI and direct submissions agree; malformed plans are rejected or report specified errors rather than silently succeeding |
| Copy and conflict policies | 34 Lua cases; R02/04/05/11/12/15–18 | Empty/binary data; exact directory manifests; zero-byte and multi-chunk files; destination absent/file/directory/link; same inode via hard link; Replace/Skip/Update with equal and subsecond times; competing creator; source disappears/changes; write/commit failures; operation-specific metadata policy |
| Move/delete/mkdir/rename | R01/06/10/13/14/24 | Full successful UI→service→filesystem flows; actual EXDEV through job manager; destination conflicts; source-removal failure after move commit; partial delete/rename results and retry; readonly/vanished parent; cancellations and accurate counters |
| Job lifecycle and queue | R09/10/12/31, AR05/06; pause/copy Lua | Transition table across all operation kinds; pause/resume/cancel before pickup and at barriers; active/queued/unknown ID; enqueue concurrent with shutdown; queue saturation; terminal callback/event exactly once; summaries stable while details change; observer detach/destruction |
| Retention and archive leases | AR05 count/expiry and two leased roots | Positive count/byte detail eviction; boundary and zero limits; pending rejection; error count versus truncated detail; archive byte/count pressure; simultaneous panel/tab/planner/job leases; release in every order; canceled extraction and copy-out during eviction |
| Archives and logical locations | R03/13/26/27; AR07/identity; Lua archive | Manifest round trips, nested copy-out after restart, corrupt/truncated archive, missing/failing/noisy tool, option-like names, changed source while extracting; validate symlink/internal-path containment on disposable fixtures; codec reserved characters/malformed escapes/NUL/nesting boundary; metadata precision cases |
| Settings, theme and binding persistence | R29, AR02, AR07 | Round-trip every field and colors; absent/legacy/version/type/range/oversize/truncated input; invalid data leaves all live state unchanged; failures at temporary creation/write/fsync/close/rename; restart in a separate process; quoted/Unicode paths; swap/cycle bindings, reserved/unknown keys, invalid colors |
| Application/Lua events and timers | R31, AR08, events/review_events Lua | Exact request/job identities and allowed order; no replay; unmatched trailing events; two independent cursors; 4095/4096/4097 publication and expiry/resync; consumed-history pruning; wake an earlier newly scheduled deadline; cancellation/cleanup of pending waits; watchdog failure categories |
| Commands and dialogs | AR08 routing; palette/rebind; R06/18/23/24 | Real command matrix from TS07; disabled archive mutations; no selection/focus fallback; pending duplicate submission; close/reopen before old result; errors retain editable retry state; verify exact dialog/state rather than generic event presence |
| Rendering and terminal input | R23 render substrings; fixed-size PTYs | Empty/loading/error/paused/expired-detail views at narrow, short and normal sizes; focus visibility, clipping and input routing; wide/combining characters and escaping control bytes; resize during dialog/load; terminal-byte key/mouse decoding; avoid brittle full ANSI screenshots |
| Editor/clipboard/processes | R28/35; fake Fresh Lua | Full argument boundaries with quotes/newlines/leading dash; empty/large clipboard; helpers absent/non-executable/nonzero/signal/hang; real foreground handoff smoke; descendant termination and terminal restoration after each outcome |
| Build/distribution/dependencies | CTest, core-only validation, R33/R34 runners | Fresh clean configure/build; core-only with all non-core paths absent; wrong dependency revision/dirty source/checksum rejected; documented opt-out; no-op and implementation rebuilds; parallel build directories; relocation with original paths unavailable and with conflicting helpers present |

Apply capability rules to metadata tests: ownership, ACLs, extended attributes, hard links, case sensitivity and filesystem timestamp precision vary. Specify supported preservation semantics first; tests should not invent promises. Run permission-denial cases as an unprivileged user or use deterministic error injection; mode-000 fixtures alone are not reliable under root.

## Failure and lifecycle matrices

Do not take the full Cartesian product of every option. Use pairwise combinations for ordinary data variants, with explicit mandatory combinations for data-loss boundaries, read-only archives and cancellation.

| Axis | Cases |
| --- | --- |
| Operation | CopyFile, CreateDirectory, CreateSymlink, MoveEntry, DeleteEntry, RenameEntry, ClipboardText, ArchiveInput/creation, DiscoveryFailure |
| Input shape | Regular/empty/binary file; directory; preserved/followed/dangling/cyclic link; hidden entry; spaces, quote, newline, Unicode and leading dash; long paths within measured platform limits |
| Existing destination | Absent, file, directory, dangling/valid link, same inode/alias, concurrently created or removed |
| Policy | Replace, Skip, Update; follow/preserve link choices; archive read-only restriction |
| Failure/checkpoint | Before enumeration, after plan, before staging, mid-copy, before commit, after commit/before source removal, completion publication, teardown |
| Control/lifetime | Pause, resume, cancel, shutdown, late subscriber, closed dialog/panel, superseded request, suspended terminal |

Mandatory preservation assertions include original bytes/link text, exact committed subset, source survival until move commit, absence of out-of-root mutations, owned staging cleanup on handled failure, and truthful terminal result/counters. A killed process can leave private staging behind: record and specify recovery behavior separately from normal exception/cancellation cleanup. Likewise, settings atomic visibility and power-loss persistence are separate contracts.

Use a deterministic worker gate to reach these schedules:

1. Block request A, submit B then C, release A; only the surviving generation may publish and pending work stays bounded.
2. Complete a directory scan, archive extraction and job while the terminal is suspended; resume and verify surviving results exactly once, including observable job/request IDs.
3. Destroy/reopen a dialog or switch/close a tab before old completion delivery; late work cannot affect its replacement.
4. Fill a queue behind a gated worker, submit one more request, cancel a queued ID, then shut down with active work paused; no deadlock or unreported accepted job remains.
5. Hold archive leases from a panel and queued copy, exceed the cache budget, release the panel, then finish the job; the source survives until the final required lease is released.

## Generated tests, stress and performance

Start with small, bounded generators, fixed seeds in normal CI and additional recorded seeds nightly. Print/shrink a failing sequence into a committed regression. Good properties are `decode(encode(valid_location))` equality, settings round trips, selection-count consistency, full-refresh/delta agreement, and legal terminal job outcomes. Keep the expected state model smaller and independent of the implementation.

Fuzz the owned Location/settings/key-token boundaries with input-size/time limits and sanitizer builds. Generated filesystem trees belong only under disposable fixture roots. Extend the five existing negative controls with missing completion, archive corruption, false job success, wrong command handler, lost callback and changed conflict behavior; require the intended diagnostic, not just any failure.

AR04's existing timing checks are useful broad regression guards. They measure two selection sizes and summary copying, not complete frame latency or long-session memory. Add separate measurements at 1k/10k/100k entries, increasing selected fractions, job history/detail sizes and watcher-burst sizes. Report UI publication/render p50/p95/max, allocation counts, event polling cost and retained payload. Establish baselines on a named Release-build runner before gating percentages; keep noisy microbenchmarks out of shared-runner correctness gates.

Run mixed-job/tab/archive/event stress with deliberately small limits so eviction and rejection are exercised quickly. Measure live threads, descriptors, child processes, extraction roots, event/detail counts and retained bytes before/after repeated cycles. RSS alone is insufficient because allocators may retain freed memory. Compare repeated cycles after warm-up; assert exact owned-resource bounds where the API exposes them.

## Execution lanes and release gates

Times below are proposed warm-build budgets, not measurements of an implemented future suite.

| Lane | Trigger/platform | Contents | Initial budget |
| --- | --- | --- | --- |
| Fast | Every change; macOS arm64 and native Linux x86-64 | Harness self-tests, isolated core/service cases, deterministic filesystem/fault cases, routing/model checks | ≤2 minutes |
| Integration | Every pull request on both native platforms | All existing Lua workflows plus missing mutation workflows, native watcher/process tests, regression cases, terminal basics | ≤5 minutes |
| Sanitizer | Every pull request for core/fault cases; broader nightly | Separate ASan+UBSan and TSan builds; TSan starts with owned concurrent services and fixtures | ≤15 minutes for the PR subset |
| Extended | Nightly | Multiple seeded schedules/trees, parser fuzzing, resource stress, full sanitizer integration, actual EXDEV, pinned-Fresh handoff, controlled performance measurements | Separate bounded jobs, initially ≤30 minutes each |
| Release | Every candidate; every shipped OS/architecture | Clean dependencies/build, all required platform tests, self-contained relocation and real packaged helpers, distribution smoke | No silent skip of required capabilities |

The existing macOS ASan startup hang must remain a visible infrastructure failure, not a test pass or blanket sanitizer exemption. Establish a working Linux sanitizer lane and diagnose the macOS runtime separately. Run TSan separately from ASan. Treat sanitizer reports in the test harness as defects too.

There is no application CI workflow checked into this revision. Use the project's chosen CI service and publish the commands/presets in the repository. The pinned FTXUI remote is local/private, so hosted clean builds require an accessible mirror/artifact of the exact revision first. Retain revision validation and checksums; do not make unpinned builds the CI default. Test a clean environment without the developer's home-directory setup.

## Implementation sequence and completion criteria

| Batch | Concrete work | Ready when |
| --- | --- | --- |
| 1 — Trust results | TS01 explicit Python failures, TS02 completion manifest, TS03 tree/content assertions; commit the demonstrated negative controls | Empty/optimized/partial/corrupt probes all fail for the intended reason, existing legitimate suites pass |
| 2 — Isolate and diagnose | Per-case CTest registry, timeouts, result artifacts, fixture helpers and runner self-tests | Every case runs independently; parallel/repeated runs remain isolated; failed case replay is one command |
| 3 — Protect writes | Typed operation tables, fault checkpoints, move/delete/rename/mkdir UI flows, real EXDEV lane | Every write/commit/removal boundary has preservation, cleanup and result assertions |
| 4 — Control lifetimes | Barrier/clock fixtures, worker/mailbox/queue/job schedules, event cursors/expiry, lease pressure | Deterministic lifecycle matrix passes; sanitizer lane exercises the same contracts |
| 5 — Cover remaining state | Codec/property tables, view/delta model, real command equivalence, rendering/terminal inputs | Coverage matrix has both normal and failure/boundary cases for every public mechanism |
| 6 — Qualify delivery | Native Linux CI, real tools, isolated relocation, clean dependency/build checks, bounded stress/performance | Each shipped target runs release-critical tests with explicit capability and infrastructure reporting |

Keep a permanent coverage index mapping mechanism → contract → test IDs → platform/lane. Distinguish implemented tests, unimplemented proposals and explicit skips. Record coverage for owned core/UI/platform code separately from vendored libraries; measure a baseline before setting percentage gates. Require evidence for error/commit branches even if aggregate line coverage is high.

Update [build_test_setup.md](build_test_setup.md) and [testing_framework.md](testing_framework.md) as these batches land: they still describe older direct-script invocations, source structure and screen-post lifecycle. Preserve useful historical rationale, but point the primary test instructions at CTest and the current [build boundaries](build_boundaries.md).

Recommended first implementation: **Batch 1**, then isolated discovery and deterministic file-operation failures. This addresses demonstrated false assurance before expanding the number of passing scenarios.
