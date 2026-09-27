# Architecture implementation progress — 2026-09-27

Accepted scope: [architecture review](architecture_review_2026-09-27.md), AR01–AR09.

Each improvement records its plan before implementation, applied changes, validation and deviations in a separate progress document. Changes are committed after each verified improvement. The pre-existing untracked `old_fc` is excluded.

| Order | Finding | Improvement | Status |
| --- | --- | --- | --- |
| 1 | [AR01](architecture_progress/AR01.md) | Retain UI messages across terminal suspension | Implemented |
| 2 | [AR02](architecture_progress/AR02.md) | Separate view state and settings publication | Implemented |
| 3 | [AR03](architecture_progress/AR03.md) | Share explicit traversal policies | Planned |
| 4 | [AR07](architecture_progress/AR07.md) | Persist logical archive locations | Planned |
| 5 | [AR04](architecture_progress/AR04.md) | Bound UI publication and observation costs | Planned |
| 6 | [AR05](architecture_progress/AR05.md) | Bound retained resources | Planned |
| 7 | [AR06](architecture_progress/AR06.md) | Separate operation services from UI | Planned |
| 8 | [AR08](architecture_progress/AR08.md) | Unify commands and application events | Planned |
| 9 | [AR09](architecture_progress/AR09.md) | Enforce module, build and test boundaries | Planned |

## Validation policy

Add a regression for each reproduced failure and focused contract tests for extracted services. Run affected native/Lua tests after each change, then the combined native, UBSan, Lua/negative-control, process-exit, package and cross-build checks at completion. Record unavailable platform/sanitizer execution explicitly. Preserve existing staging and cancellation guarantees throughout the refactoring.

