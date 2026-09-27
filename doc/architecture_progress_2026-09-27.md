# Architecture implementation progress — 2026-09-27

Accepted scope: [architecture review](architecture_review_2026-09-27.md), AR01–AR09.

Each improvement records its plan before implementation, applied changes, validation and deviations in a separate progress document. Changes are committed after each verified improvement. The pre-existing untracked `old_fc` is excluded.

| Order | Finding | Improvement | Status |
| --- | --- | --- | --- |
| 1 | [AR01](architecture_progress/AR01.md) | Retain UI messages across terminal suspension | Implemented |
| 2 | [AR02](architecture_progress/AR02.md) | Separate view state and settings publication | Implemented |
| 3 | [AR03](architecture_progress/AR03.md) | Share explicit traversal policies | Implemented |
| 4 | [AR07](architecture_progress/AR07.md) | Persist logical archive locations | Implemented |
| 5 | [AR04](architecture_progress/AR04.md) | Bound UI publication and observation costs | Implemented |
| 6 | [AR05](architecture_progress/AR05.md) | Bound retained resources | Implemented |
| 7 | [AR06](architecture_progress/AR06.md) | Separate operation services from UI | Implemented |
| 8 | [AR08](architecture_progress/AR08.md) | Unify commands and application events | Implemented |
| 9 | [AR09](architecture_progress/AR09.md) | Enforce module, build and test boundaries | Implemented |

## Validation policy

Add a regression for each reproduced failure and focused contract tests for extracted services. Run affected native/Lua tests after each change, then the combined native, UBSan, Lua/negative-control, process-exit, package and cross-build checks at completion. Record unavailable platform/sanitizer execution explicitly. Preserve existing staging and cancellation guarantees throughout the refactoring.

## Combined validation

All nine accepted improvements are implemented, with a separate verified implementation commit per improvement and the planned/applied differences above. The resulting targets and runtime contracts are described in [build boundaries](build_boundaries.md).

- Native CTest: all seven suites passed, including 40 regression cases, headless services, 14 Lua scripts, five negative controls, seven process-exit cases, package execution and all three dependency rebuild checks.
- UBSan: headless services and all native regressions passed.
- Core-only: configure, build and CTest passed without terminal/Lua/editor/LZMA checkouts.
- Linux x86-64: clean cross-build produced static ELF application and core-test binaries; runtime execution was unavailable.
- Dependency manifest validation, compilation-boundary checks and `git diff --check` passed.

Logs are under `build/architecture-validation/`. ASan is not counted as a pass: the earlier Apple runtime startup hang precedes `main` (sample: `build/review-validation/asan-startup-sample.txt`). Real Fresh terminal interaction and a real cross-device move remain untested; controlled editor/lifecycle and staged-move regressions passed. Cache limits are soft while active leases pin roots, and detailed job memory limits estimate record/string payload rather than allocator overhead.
