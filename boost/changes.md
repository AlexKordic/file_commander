# Boost.Filesystem local modifications

`boost/filesystem/` is a Git subtree of
[boostorg/filesystem](https://github.com/boostorg/filesystem) at tag
`boost-1.90.0` (upstream commit `868dc76bb6dd09923a0f4b90f2f2aad25d9f51d6`),
imported with `--squash`. This page lists every local change. How the subtree
is built and updated is in
[integrating_boost_filesystem.md](integrating_boost_filesystem.md).

To see the exact difference from the last upstream import:

```sh
base=$(git log --format=%H --grep='git-subtree-dir: boost/filesystem' -1)
git diff "$base" HEAD:boost/filesystem
```

| File | Change |
| --- | --- |
| `include/boost/filesystem/operations.hpp` | Adds `copy_file_io_hooks`, `copy_file_options` and the `copy_file` overloads that take them. Includes `<atomic>`, `<cstdint>` and `<cstddef>`. |
| `src/operations.cpp` | Adds the thread-local copy context, hooks in the read/write copy loop, the sendfile and copy_file_range fallback, fault points in the stock `copy_file`, and the staged `copy_file` overload. Includes `<atomic>`, `<chrono>` and `<thread>`. |
| `LICENSE_1_0.txt` | Added. Identical to `licenses/boost/LICENSE_1_0.txt`. |

## Why

Stock `copy_file` cannot throttle, cancel, pause or report progress, and it
writes straight into the destination. FC's copy and move jobs need all of that,
plus an atomic commit that leaves an existing destination intact on failure,
hooks for the transfer journal that lets an interrupted job resume, and a seam
for tests to inject I/O failures.

## API

All additions are in namespace `boost::filesystem`:

```cpp
struct copy_file_io_hooks
{
    void* context = nullptr;
    std::ptrdiff_t (*read)(void*, int, void*, std::size_t) = nullptr;
    std::ptrdiff_t (*write)(void*, int, const void*, std::size_t) = nullptr;
    int (*fault)(void*, const char*) = nullptr;
};

struct copy_file_options
{
    copy_options options = copy_options::none;
    const copy_file_io_hooks* io = nullptr;
    uint64_t bytes_per_second = 0;
    std::atomic<bool>* cancel_requested = nullptr;
    std::atomic<uint64_t>* bytes_copied = nullptr;
    bool (*checkpoint)(void*) = nullptr;
    void* checkpoint_context = nullptr;
    int (*transaction)(void*, const char*, const path&, const path&) = nullptr;
    int (*remove_source)(void*, const path&, const path&) = nullptr;
    void* transaction_context = nullptr;
};

bool copy_file(path const& from, path const& to, copy_file_options const& opts);
bool copy_file(path const& from, path const& to, copy_file_options const& opts,
               system::error_code& ec) noexcept;
// detail::copy_file(from, to, opts, system::error_code* ec = nullptr) is the
// exported implementation behind both.
```

Without `ec`, errors throw `filesystem_error`. Like stock `copy_file`, the
result is `false` when nothing was copied because of `skip_existing` or
`update_existing`.

### copy_file_io_hooks

An optional per-call I/O seam. A null callback means the native call. The
caller owns `context` for the whole synchronous copy.

| Field | Meaning |
| --- | --- |
| `context` | Passed as the first argument to every callback. |
| `read` | Replaces `::read` in the read/write loop. Same contract: byte count, or -1 with `errno` set (`EINTR` is retried). |
| `write` | Replaces `::write` in the read/write loop. Same contract. |
| `fault` | Called at named phases; a nonzero return is an `errno` value that fails the copy, zero continues. |

Boost calls `fault` with these phases: `open` (before the data copy),
`flush` (before `fsync`/`fdatasync`, only with `synchronize` or
`synchronize_data`), `close` (before closing the output), `commit` (before the
rename or link) and `committed` (after it). FC's own `move_by_copy` in
`file_io_jobs.cpp` uses the same hook with its own phases (`move_metadata`,
`move_metadata_verify`, `move_commit`, `source_remove`). FC also reuses the
struct outside Boost, for example in `SettingsStore::atomic_write`, so a
layout change affects FC code too.

### copy_file_options

| Field | Meaning |
| --- | --- |
| `options` | Stock `copy_options`. With `overwrite_existing` or `update_existing` the commit is an atomic replace; otherwise it never replaces. `synchronize` and `synchronize_data` sync the private output before commit. |
| `io` | Optional `copy_file_io_hooks`. |
| `bytes_per_second` | Rate limit; 0 means unlimited. |
| `cancel_requested` | When it becomes true, the copy fails with `ECANCELED`. |
| `bytes_copied` | Set to 0 at the start, then increased after each chunk is written to the private output. It counts staged bytes, not committed ones. |
| `checkpoint` | Called with `checkpoint_context` before each read and while throttling. Returning `false` fails the copy with `ECANCELED`. It may block; FC holds a paused job here. |
| `checkpoint_context` | Argument for `checkpoint`. |
| `transaction` | Called with `transaction_context`, a phase name, the private output path and `to`, at phases `staging`, `commit_ready` and `committed`. A nonzero return is an `errno` value that fails the copy. FC records these phases in its transfer journal. |
| `remove_source` | Never called by Boost. It travels with the options so FC's `move_by_copy` can remove the source through the journal after the commit. |
| `transaction_context` | Argument for `transaction` and `remove_source`. |

## Behavior

### Fast path

If `bytes_per_second` is 0 and `io`, `cancel_requested`, `bytes_copied`,
`checkpoint` and `transaction` are all null, the overload calls stock
`copy_file(from, to, opts.options, ec)`. That writes directly into `to`, with
no private output and no atomic commit. `remove_source` and the two context
pointers do not affect this choice, because Boost never calls
`remove_source`.

### Staged copy (POSIX)

Otherwise the copy goes through a private output:

1. Reset `bytes_copied`. `stat` the source and the destination, following
   symlinks. If both are the same file, fail with `EEXIST`.
2. If the destination exists and neither `overwrite_existing` nor
   `update_existing` is set, return `false` with `skip_existing`, else fail
   with `EEXIST`. With `update_existing`, return `false` unless the source's
   `st_mtime` is newer (whole seconds; stock `copy_file` compares nanoseconds
   where available).
3. Check `cancel_requested`.
4. Create a private directory `<parent of to>/.fc-copy-XXXXXX` with `mkdtemp`.
   The output file is `<that directory>/data`. The temporary name does not
   depend on the destination's name, so a name of the maximum allowed length
   still copies.
5. Call `transaction("staging")`.
6. Install the thread-local context, call `fault("open")`, then run stock
   `copy_file(from, <output>, opts.options)`. The data goes through the
   read/write loop with all hooks (see below). The stock function calls
   `fault("flush")` and `fault("close")`.
7. Check `cancel_requested`, call `transaction("commit_ready")`, then
   `fault("commit")`.
8. Commit. With `overwrite_existing` or `update_existing`, `rename()` the
   output over `to`, which replaces it atomically. Otherwise `link()` it to
   `to`. `link()` never replaces anything, so it is an atomic no-replace commit
   that also loses cleanly to a competing creator or a dangling symlink at
   `to`. If it fails with `EEXIST` and `skip_existing` is set, return `false`.
9. Call `fault("committed")`, then `transaction("committed")`.
10. On every exit, unlink the output and remove the private directory. After a
    `link()` commit the destination keeps the data through its own link.

Failures before step 8 leave an existing destination untouched; only the
private directory is removed. An error from step 9 is reported even though the
destination has already been committed.

The context lives in a `thread_local` pointer (`tls_copy_ctx`, type
`copy_file_context`, in an anonymous namespace in `operations.cpp`). That
passes the hooks through Boost's function-pointer dispatch without changing
any internal signatures. The previous value is restored on exit, so nested
calls work. Code that runs without the context, including stock `copy_file`
calls, behaves as upstream except for the zero-byte write rule below.

On non-POSIX platforms the overload calls stock `copy_file` and ignores every
hook. FC does not support Windows.

### Data-copy backends

Boost picks a data-copy function at startup. The read/write loop is the
default everywhere and the only one on macOS. On Linux, depending on the kernel
version, it may pick `sendfile` or `copy_file_range`.

`copy_file_data_read_write_impl`, the read/write loop:

- Before each read: call `checkpoint`, then check `cancel_requested`.
- Read and write through the `io` hooks when they are set.
- A write that returns 0 fails with `EIO` instead of looping forever. This
  applies to every caller, including stock `copy_file`.
- After each chunk: add it to `bytes_copied`, then throttle. The loop sleeps
  in steps of at most 50 ms until the bytes written match the target rate,
  checking `cancel_requested` and `checkpoint` between steps. The measuring
  window restarts after every `bytes_per_second` bytes, so long transfers do
  not drift.

`copy_file_data_sendfile::impl` and `copy_file_data_copy_file_range::impl`
hand the copy to the read/write loop as soon as a context is installed. They
therefore never throttle, report progress or call hooks themselves. Both still
contain throttle and cancel code from an earlier version of this patch. It is
guarded by the context pointer, which is always null at that point, so it never
runs and can be dropped when the patch is reapplied.

## Reapplying on a new Boost release

After a `git subtree pull`, check that each item still holds:

- `copy_file_io_hooks`, `copy_file_options` and both public overloads exist in
  `operations.hpp`, with the includes listed above.
- The read/write loop has the checkpoint, cancel, hook, zero-write,
  progress and throttle code.
- `sendfile` and `copy_file_range` fall back to the read/write loop when a
  context is installed.
- Stock `copy_file` calls `fault("flush")` and `fault("close")`.
- The staged overload's fast-path condition lists every hook that Boost calls.
- `LICENSE_1_0.txt` is still present.

Then build and run FC's tests: `test/file_faults.cpp` and
`test/review_regressions.cpp` use these options directly.
