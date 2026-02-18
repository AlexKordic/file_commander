# Fresh CLI Contract for File Commander Integration

This document fixes the runtime contract used by File Commander when integrating with Fresh from local source.

## Binary Resolution Order
1. `fresh_binary_path` from FC settings (if set)
2. `FC_FRESH_BIN` environment variable (if set)
3. Compile-time default `FC_FRESH_DEFAULT_BIN` (staged by CMake when `FC_BUILD_FRESH=ON`)

## Commands Used by File Commander
1. Open directory in a new editor session:
   - Run in target directory `cwd`
   - `fresh -a <session_id>`
2. Open file(s) in last-used editor session:
   - Run in session `cwd`
   - `fresh --cmd session open-file <session_id> <abs_file_1> [abs_file_n...]`
   - Then attach:
   - `fresh -a <session_id>`
3. Switch to previous/next tracked editor session:
   - `fresh -a <session_id>`

## Exit Code Expectations
1. `0` means success.
2. For `session open-file`, `2` is accepted as success (Fresh uses it when the command starts a new session and caller should attach).
3. Any other non-zero code is treated as failure and surfaced in FC errors.

## Important Behavior
1. `session open-file` ignores/skips directory arguments in Fresh, so FC must not use it for directory-open flows.
2. Return path from Fresh to FC is based on Fresh `detach` behavior in attached session mode (`-a`).
3. FC remains the parent process and runs attach commands with restored terminal IO.

## Build Integration
1. CMake option `FC_BUILD_FRESH` controls local Fresh build (default `ON`).
2. `FC_FRESH_SOURCE_DIR` defaults to:
   - `${CMAKE_CURRENT_SOURCE_DIR}/../editor-fresh`
3. Build command executed by CMake target:
   - `cargo build --release --manifest-path <FC_FRESH_SOURCE_DIR>/Cargo.toml`
4. Staged binary output:
   - `build/third_party/fresh/bin/fresh`
