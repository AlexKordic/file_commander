# AR07 follow-up — Detect archive replacement with preserved metadata

Status: Implemented.

## Finding

The final acceptance audit found that archive cache lookup compares canonical path, size and whole-second modification time. Replacing an archive with the same size and preserved modification time can therefore reuse stale extracted contents. The existing replacement tests change the size and do not cover this case.

## Planned solution

Add a regression for same-size atomic replacement with preserved modification time, retaining a lease on the old extraction. On supported POSIX platforms, compare file identity and nanosecond modification/change timestamps as well as size. Recheck the fingerprint after extraction and reject publication if the source changed during extraction. Treat metadata failures as errors; avoid caching on platforms where a sufficiently precise identity cannot be obtained.

## Applied solution

Cache identities now include device, inode, size, and nanosecond modification/change timestamps on macOS/Linux. Unchanged archives still reuse their extraction; atomic replacements and in-place writes with preserved size/mtime obtain a new root. Existing leases preserve the old contents. The source is inspected again after extraction/accounting; errors or changes reject publication and the owned temporary root is cleaned up. The non-POSIX fallback retains root ownership but disables cache reuse.

## Validation

The new regression failed before the fix with `same-size replacement with preserved mtime reused stale cache` (log: `build/architecture-validation/AR07-cache-before.log`). After the fix it covers unchanged reuse, atomic replacement, in-place replacement, old-lease survival, source mutation during extraction, non-publication and temporary-root cleanup. A controlled extractor makes these identity cases independent of compressed sizes; the existing real 7zr archive tests remain in the same suite.

All 41 native regressions and the headless core passed under both the native build and UBSan; all 14 Lua scripts, five negative controls, seven process-exit cases and outside-checkout package execution passed. Core-only build/test and Linux x86-64 application/core-test compilation passed. Post-fix logs: `build/architecture-validation/AR07-cache-*.log`.

## Differences from the plan

No functional deviation. This is an additional acceptance case for AR07 found during final review, committed separately after the nine planned improvements. Metadata identity follows filesystem timestamp precision; it is not a content hash or a filesystem snapshot. Linux was compiled, not run.
