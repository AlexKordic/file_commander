# Boost.Filesystem Local Modifications

Changes made to the `boost/filesystem/` subtree (base: boost-1.90.0).

---

## copy_file: Transfer Rate Limiting and Cancellation Support

**Files changed:**
- `boost/filesystem/include/boost/filesystem/operations.hpp`
- `boost/filesystem/src/operations.cpp`

### Motivation

The stock `boost::filesystem::copy_file` provides no mechanism to limit transfer
speed or abort a copy in progress. File Commander needs both: a per-job
`bytes_per_second` cap for bandwidth control and a `cancel_requested` flag that
stops the copy and removes the partial destination file.

### API Addition

New struct and `copy_file` overload added alongside the existing ones:

```cpp
// operations.hpp — boost::filesystem namespace
struct copy_file_options
{
    copy_options options = copy_options::none;
    uint64_t bytes_per_second = 0;              // 0 = unlimited
    std::atomic<bool>* cancel_requested = nullptr; // null = no cancel support
};

bool copy_file(path const& from, path const& to,
               copy_file_options const& opts);
bool copy_file(path const& from, path const& to,
               copy_file_options const& opts, system::error_code& ec) noexcept;
```

When `bytes_per_second == 0` and `cancel_requested == nullptr`, the overload
delegates directly to the original `copy_file(from, to, options, ec)` with zero
overhead.

### Implementation (POSIX path — operations.cpp)

A **thread-local context** passes throttle/cancel parameters through the
existing function-pointer dispatch system without changing any signatures:

```
copy_file(copy_file_options)        ← sets thread-local, calls existing copy_file
  └─ copy_file(copy_options)        ← unchanged, calls copy_file_data function pointer
       └─ copy_file_data(...)       ← dispatched at runtime (read/write, sendfile, copy_file_range)
            └─ reads thread-local   ← applies cancel check + rate limiting
```

**`copy_file_context`** struct and `thread_local copy_file_context* tls_copy_ctx`:
- Declared in the POSIX anonymous namespace inside `namespace detail`
- Null by default → all existing code paths are unaffected

#### Modified data-copy implementations

All three POSIX copy backends were modified:

1. **`copy_file_data_read_write_impl`** (used on macOS, universal fallback):
   - Cancel check (`ECANCELED`) at the top of each read/write iteration
   - After each buffer write: calculates expected vs. elapsed time, sleeps
     to maintain `bytes_per_second`
   - Throttle window resets every `bytes_per_second` bytes to avoid precision
     drift on large transfers

2. **`copy_file_data_sendfile::impl`** (Linux sendfile):
   - Cancel check before each sendfile batch
   - Batch size capped to ~1 second of data at the target rate (min 64 KB) for
     responsive cancellation
   - Post-batch sleep based on cumulative offset vs. elapsed time
   - Fallback paths to read/write automatically inherit TLS context

3. **`copy_file_data_copy_file_range::impl`** (Linux copy_file_range):
   - Same cancel + batch-limit + throttle pattern as sendfile
   - Fallback paths (sendfile, read/write) automatically inherit TLS context

#### New `copy_file` overload

- Sets `tls_copy_ctx`, delegates to existing `copy_file(path, path, copy_options, error_code*)`
- On error with `ECANCELED` (or `cancel_requested` flag set): removes partial
  destination via `detail::remove(to)`
- Restores previous TLS context (supports nested calls)
- Windows path: delegates to standard `copy_file` (throttle/cancel not yet
  implemented on Windows)

### Includes added to operations.cpp

```cpp
#include <atomic>   // std::atomic
#include <chrono>   // std::chrono::steady_clock, duration
#include <thread>   // std::this_thread::sleep_for
```

### Includes added to operations.hpp

```cpp
#include <atomic>   // std::atomic<bool>* in copy_file_options
#include <cstdint>  // uint64_t in copy_file_options
```
