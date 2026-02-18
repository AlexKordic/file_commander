# Fresh Editor Integration Plan

## Summary
Integrate local Fresh source from `/Users/alexkordic/code/editor-fresh` into File Commander build/runtime and implement full-session switching between File Commander and Fresh.

This plan is execution-ready and includes findings from direct source inspection (February 17, 2026), especially around shortcut-triggered custom commands for returning to File Commander.

## Investigation Findings (Local Fresh Source)
Question: Can Fresh execute a custom command directly from a shortcut so we can signal return to File Commander?

Answer:
1. Not via standard user keybindings today.
2. Yes via plugin actions, but not directly bindable in normal keymap without Fresh changes.
3. Built-in `detach` action is the reliable return mechanism now.

Evidence:
1. Standard keybinding load path only accepts built-in actions (`Action::from_str(...)`):
   - `/Users/alexkordic/code/editor-fresh/crates/fresh-editor/src/input/keybindings.rs:1126`
   - `/Users/alexkordic/code/editor-fresh/crates/fresh-editor/src/input/keybindings.rs:1218`
2. Unknown actions are rejected by parser tests:
   - `/Users/alexkordic/code/editor-fresh/crates/fresh-editor/src/input/keybindings.rs:2226`
3. Keybinding editor also restricts actions to built-in action list and fails unknown action names:
   - `/Users/alexkordic/code/editor-fresh/crates/fresh-editor/src/app/keybinding_editor/editor.rs:229`
   - `/Users/alexkordic/code/editor-fresh/crates/fresh-editor/src/app/keybinding_editor/editor.rs:642`
4. Plugin commands are represented as `Action::PluginAction(...)` and executable:
   - `/Users/alexkordic/code/editor-fresh/crates/fresh-editor/src/services/plugins/bridge.rs:66`
   - `/Users/alexkordic/code/editor-fresh/crates/fresh-editor/src/app/input.rs:999`
5. Plugin API can spawn external processes (usable for signaling):
   - `/Users/alexkordic/code/editor-fresh/crates/fresh-core/src/api.rs:833`
   - `/Users/alexkordic/code/editor-fresh/crates/fresh-editor/src/app/mod.rs:4751`
   - `/Users/alexkordic/code/editor-fresh/crates/fresh-plugin-runtime/src/backend/quickjs_backend.rs:2473`
6. Built-in detach behavior is implemented and exits attached client while keeping session alive:
   - `/Users/alexkordic/code/editor-fresh/crates/fresh-editor/src/app/input.rs:240`
   - `/Users/alexkordic/code/editor-fresh/crates/fresh-editor/src/server/editor_server.rs:263`
   - `/Users/alexkordic/code/editor-fresh/crates/fresh-editor/src/main.rs:2360`
7. Fresh CLI supports session operations required for FC integration:
   - `session attach/open-file/list/new/kill`
   - `/Users/alexkordic/code/editor-fresh/crates/fresh-editor/src/main.rs:50`
   - `/Users/alexkordic/code/editor-fresh/crates/fresh-editor/src/main.rs:185`
8. `session open-file` skips directories by design, so dir-open must use session create/attach flow:
   - `/Users/alexkordic/code/editor-fresh/crates/fresh-editor/src/main.rs:2117`
9. Fresh source build command is `cargo build --release` (not `make`):
   - `/Users/alexkordic/code/editor-fresh/README.md:231`

## Decisions for Implementation
1. Return-to-File-Commander signal will use Fresh `detach` action in session mode (`fresh -a` attach flow).
2. We will not block integration on Fresh patching for custom shortcut-command execution.
3. We keep an optional follow-up patch track for Fresh to allow plugin-action keybindings in normal keymaps.
4. Build integration uses local source path `/Users/alexkordic/code/editor-fresh` (no network fetch).

## Goals
1. Fresh is built with File Commander and staged in build output.
2. Opening behavior:
   - Focused dir -> new Fresh session.
   - Focused file(s) -> open in last-used session.
3. Multiple Fresh sessions are tracked and switchable from File Commander.
4. Switching is full control handoff between TUIs.
5. When Fresh detaches/exits, File Commander is restored immediately.

## Scope
In scope:
1. CMake build integration for local Fresh source.
2. Runtime session/process manager in File Commander.
3. Four runtime shortcuts and palette commands.
4. Lua/E2E coverage with fake Fresh binary and manual real Fresh validation.

Out of scope:
1. Deep plugin/LSP/theme integration with Fresh.
2. Windows-specific support in first implementation pass.
3. Mandatory Fresh upstream changes.

## Shortcut Plan (Runtime)
File Commander side:
1. `F9` -> `open_in_editor`
2. `Ctrl+Y` -> `switch_editor_prev`
3. `Ctrl+U` -> `switch_editor_next`
4. `F10` -> `switch_to_file_commander` (mostly no-op while already in FC; included for command parity)

Fresh side:
1. Configure one keybinding for action `detach` (default in docs is `Ctrl+Shift+D`, but actual keymap should be explicitly set by us during integration).
2. Pressing that key detaches attached Fresh client and returns control to FC.

## Confirmed CLI Contract (Local Fresh)
1. Attach/create session:
   - `fresh -a [NAME]`
2. Open files in running session without attaching:
   - `fresh --cmd session open-file <NAME|.> <file...>`
3. List sessions:
   - `fresh --cmd session list`
4. Kill sessions:
   - `fresh --cmd session kill [NAME|--all]`
5. Important behavior:
   - `session open-file` skips directory paths.
   - If `open-file` starts a new server, process exits with code `2` (`EXIT_NEW_SESSION`), which FC can treat specially if needed.

## Architecture Plan

### 1) Build Integration (Local Fresh Repo)
Files:
1. `/Users/alexkordic/code/file_commander/CMakeLists.txt`
2. Optional helper: `/Users/alexkordic/code/file_commander/cmake/Fresh.cmake`

Steps:
1. Add `FC_BUILD_FRESH` option (default `ON`).
2. Add `FC_FRESH_SOURCE_DIR` cache path (default `/Users/alexkordic/code/editor-fresh`).
3. Add custom target invoking `cargo build --release` in `FC_FRESH_SOURCE_DIR`.
4. Stage binary to `${CMAKE_BINARY_DIR}/third_party/fresh/bin/fresh`.
5. Expose staged path to FC runtime (compile definition + runtime override support).

### 2) Editor Session Manager
Files:
1. New: `/Users/alexkordic/code/file_commander/editor_manager.hpp`
2. New: `/Users/alexkordic/code/file_commander/editor_manager.cpp`
3. `/Users/alexkordic/code/file_commander/app.hpp`

Responsibilities:
1. Resolve Fresh binary.
2. Manage session metadata (id, cwd, MRU, alive).
3. Open directory targets as new sessions (attach flow).
4. Open file targets via `session open-file` into last-used session.
5. Attach/detach orchestration and status reporting.

### 3) Foreground Handoff and Return Path
Files:
1. `/Users/alexkordic/code/file_commander/app.hpp`
2. `/Users/alexkordic/code/file_commander/main.cpp` (if loop-level hooks are needed)

Execution model:
1. FC remains parent process.
2. FC suspends/restores terminal around attached Fresh run.
3. Fresh `detach` or exit returns to FC.
4. Session remains attachable for future switches.

### 4) Command + Shortcut Integration
Files:
1. `/Users/alexkordic/code/file_commander/theme.hpp`
2. `/Users/alexkordic/code/file_commander/theme.cpp`
3. `/Users/alexkordic/code/file_commander/dialogs.cpp`
4. `/Users/alexkordic/code/file_commander/app.hpp`

Add IDs:
1. `open_in_editor`
2. `switch_to_file_commander`
3. `switch_editor_prev`
4. `switch_editor_next`

Behavior:
1. `open_in_editor`: dir -> new session attach; file(s) -> open in last session then attach.
2. `switch_to_file_commander`: local no-op in FC UI; semantic counterpart of Fresh detach.
3. `switch_editor_prev/next`: cycle MRU list and attach selected session.

### 5) Session Picker UX
Files:
1. `/Users/alexkordic/code/file_commander/dialogs.hpp`
2. `/Users/alexkordic/code/file_commander/dialogs.cpp`

Plan:
1. Keep prev/next shortcuts.
2. Add optional explicit chooser dialog (palette command) listing all tracked sessions.

### 6) Settings Persistence
Files:
1. `/Users/alexkordic/code/file_commander/app.hpp`

Persist:
1. `fresh_binary_path` override.
2. Last-used session id.
3. Optional session aliases.

Do not persist:
1. PIDs/attached runtime state.

## Detailed Execution Phases

### Phase 0: Integrate Confirmed Contract into FC Docs
1. Add `doc/fresh_cli_contract.md` with command templates and expected exit behaviors.
2. Include note that directories cannot be passed through `session open-file`.

Exit criteria:
1. Runtime command templates are fixed and reviewed.

### Phase 1: Build Plumbing
1. Implement CMake options and local-path Fresh build target.
2. Stage binary and plumb runtime lookup.

Exit criteria:
1. One build produces `fc` and staged `fresh` binary.

### Phase 2: Editor Manager Core
1. Implement session registry + MRU.
2. Implement dir/file opening policy.
3. Implement attach and return flow.

Exit criteria:
1. Manual flow works: open -> edit -> detach -> FC restored.

### Phase 3: Shortcut and Command Wiring
1. Add theme keys and command IDs.
2. Wire handlers and palette entries.

Exit criteria:
1. Four shortcuts functional from FC side.

### Phase 4: Fresh Detach Key Configuration
1. Ensure Fresh config used in integration has explicit keybinding for `detach`.
2. Document chosen key to avoid terminal conflicts.

Exit criteria:
1. Return-to-FC from Fresh works via single shortcut.

### Phase 5: Tests
1. Add `/Users/alexkordic/code/file_commander/test/test_editor_integration.lua`.
2. Add helper fake editor behavior in `/Users/alexkordic/code/file_commander/test/helpers.lua`.
3. Cover:
   - dir -> new session
   - files -> last-used session
   - prev/next switching
   - return to FC on detach/exit

Exit criteria:
1. Tests pass with deterministic fake editor.
2. Manual real-Fresh smoke test passes.

## Optional Follow-Up: Fresh Patch for True Custom Shortcut Command
Implement only if we require arbitrary plugin command execution directly from standard keybindings.

Patch candidates in Fresh:
1. Allow unknown action names in keybinding resolver to map to `Action::PluginAction(name)`:
   - `/Users/alexkordic/code/editor-fresh/crates/fresh-editor/src/input/keybindings.rs`
2. Extend keybinding editor validation/autocomplete to include plugin-registered commands:
   - `/Users/alexkordic/code/editor-fresh/crates/fresh-editor/src/app/keybinding_editor/editor.rs`

## Risks and Mitigations
1. Risk: Fresh key conflicts in user terminal.
   - Mitigation: explicitly set detach key in integration profile and document fallback.
2. Risk: FC terminal state corruption after child TUI.
   - Mitigation: enforce restored-IO wrapper and add regression smoke tests.
3. Risk: Session registry drift.
   - Mitigation: validate via `session list` before attach and prune stale entries.
4. Risk: Future Fresh CLI behavior changes.
   - Mitigation: pin to local repo commit and keep contract doc under version control.

## Acceptance Criteria
1. Local Fresh repo is built and staged by FC build.
2. `open_in_editor` obeys dir/new-session vs file(s)/last-session policy.
3. Four FC shortcuts are wired and usable.
4. Fresh detach shortcut reliably returns control to FC.
5. Switching among multiple sessions preserves FC state and focus.
