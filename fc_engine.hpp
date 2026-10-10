#pragma once

// The facade the macOS app imports through Swift's C++ interop. It exposes
// value types only (strings, vectors and plain structs) and keeps Boost and
// every FC header out of the importer. One engine exists per process.
//
// Threading: call every function on the main thread, except the ones marked
// "any thread". Workers never call Swift; they queue work and call the wake
// function, after which the app calls drain() on the main thread.

#include <cstdint>
#include <string>
#include <vector>

namespace fce {

// Swift can use a template specialization only when the header names it.
using StringList = std::vector<std::string>;
using IndexList  = std::vector<int64_t>;

struct StartOptions {
  std::string left, right;      // Initial pane paths; empty restores the workspace.
  bool        restore = true;   // Restore settings paths and the workspace.
  bool        recovery = true;  // Journal transfers and restore interrupted ones.
  std::string tool_dir;         // Folder holding fresh and 7zr; empty uses the defaults.
};
struct StartResult {
  bool        ok = false;
  std::string error;
};
StartResult start(const StartOptions& options);
// Graceful stop: checkpoint, save settings, stop jobs (interrupted transfers resume paused).
void stop();
bool started();
// any thread. Called (coalesced) whenever drain() has work. Set it before start().
void set_wake(void (*wake)(void*), void* context);
// Profile folder, as XDG_CONFIG_HOME/file_commander or ~/.config/file_commander.
std::string profile_dir();

struct DialogRequest {
  std::string              name;  // Copy, Move, Delete, Rename, Mkdir, Find, GlobSelect, ...
  int                      side = 0;
  std::vector<std::string> selected;
  std::string              focused, origin, target;
};
struct AttachRequest {
  std::string              cwd;
  std::vector<std::string> argv, environment;
  std::string              scene_socket;  // Set for a native editor window; argv is then empty.
};
struct Changes {
  uint64_t                   left_revision = 0, right_revision = 0, layout_revision = 0;
  uint64_t                   jobs_revision = 0, errors_revision = 0, bookmarks_revision = 0;
  std::vector<DialogRequest> dialogs;
  std::vector<std::string>   notices;
  std::vector<AttachRequest> attaches;
};
// Runs queued work and periodic housekeeping, then reports what changed.
Changes drain();
using DialogRequestList = std::vector<DialogRequest>;
using AttachRequestList = std::vector<AttachRequest>;

// Panes. Sides are 0 (left) and 1 (right). Rows are display rows (filtered, sorted).
enum class LocationKind : int { Local = 0, Remote = 1, Archive = 2 };
struct TabInfo {
  std::string  title, path, encoded;
  LocationKind kind = LocationKind::Local;
  bool         tutorial = false;
  std::string  remote_error;
};
struct PaneInfo {
  std::string          path, encoded;  // Display path and durable location.
  LocationKind         kind = LocationKind::Local;
  bool                 read_only = false;
  std::string          filter, remote_error;
  int                  sort = 0;  // 0 name, 1 name desc, 2 size, 3 size desc, 4 date, 5 date desc
  bool                 loading = false, loading_unattended = false;
  double               load_ms = 0;
  int64_t              items_total = 0, items_visible = 0, items_selected = 0;
  int64_t              bytes_selected = 0, bytes_total = 0, largest_item = 0;
  int64_t              cursor_row = -1;
  bool                 show_permissions = false, show_owner_group = false;
  int                  active_tab = 0;
  std::vector<TabInfo> tabs;
  uint64_t             revision = 0;
  uint64_t             content_revision = 0, marks_revision = 0;  // Items or columns changed; selection changed.
};
using TabList = std::vector<TabInfo>;
PaneInfo pane(int side);
int      focused_side();
void     set_focused_side(int side);
bool     single_pane();
void     set_single_pane(bool on);

enum class FileKind : int { Regular = 0, Directory, Symlink, Block, Character, Fifo, Socket, Unknown, Error, NotFound };
struct RowInfo {
  int64_t     item = -1;
  std::string name, path, link_target, warning, permissions, owner, group, date;
  FileKind    kind = FileKind::Regular;
  bool        is_dir = false, is_executable = false, selected = false, is_link = false;
  int64_t     size = 0;
  int64_t     modified = 0;  // Seconds since 1970.
};
using RowList = std::vector<RowInfo>;
int64_t              row_count(int side);
RowInfo              row(int side, int64_t row);
std::vector<RowInfo> rows(int side, int64_t from, int64_t count);
int64_t              row_named(int side, const std::string& name);  // -1 when absent.
IndexList            selected_rows(int side);                       // Display rows of the selected items.

void set_cursor(int side, int64_t row);
void toggle_row(int side, int64_t row);
void set_row_selected(int side, int64_t row, bool selected);
void set_selected_rows(int side, const IndexList& rows);  // Exactly these rows selected.
void select_all(int side);
void clear_selection(int side);
int  glob_select(int side, const std::string& pattern, bool select);  // Returns the match count.
void set_filter(int side, const std::string& text);
void set_sort(int side, int sort);
void set_columns(int side, bool permissions, bool owner_group);
bool open_row(int side, int64_t row);  // Folder or archive; false for other files.
void go_up(int side);
void navigate(int side, const std::string& location, const std::string& focus);
void refresh(int side);
void stop_loading(int side);
void switch_tab(int side, int index);
void new_tab(int side, const std::string& location, bool tutorial);
void close_tab(int side, int index);
void move_tab(int side, int from, int to);
void close_tutorial_tabs();
// Keeps tutorial tabs in the workspace checkpoint (for explainers that restart the app).
void set_keep_tutorial_tabs(bool keep);
// After a restart: marks tabs under `prefix` as tutorial tabs again.
void adopt_tutorial_tabs(const std::string& prefix);

// Commands.
struct CommandInfo {
  std::string id, title, menu, scope, dialog, commander_key, mac_key, help;
  bool        hidden = false;
  int         use_count = 0;
};
using CommandList = std::vector<CommandInfo>;
std::vector<CommandInfo> commands();
bool                     command_available(const std::string& id);
bool                     execute(const std::string& id);
std::vector<std::string> palette(const std::string& query);

// Dialog work.
struct CopyOptions {
  std::vector<std::string> sources;
  std::string              destination;
  bool                     follow_links = false, keep_relative_links = true;
  int                      conflict = 0;  // 0 replace, 1 update if newer, 2 skip existing
};
struct DiscoveryInfo {
  bool        running = false, valid = false;
  int64_t     bytes = 0, files = 0, dirs = 0, links = 0, errors = 0, steps = 0;
  std::string current;
};
struct PreviewRow {
  std::string source, destination, kind, message;
  int64_t     bytes = 0;
};
using PreviewList = std::vector<PreviewRow>;
uint64_t                copy_discover(const CopyOptions& options);
DiscoveryInfo           discovery(uint64_t session);
std::vector<PreviewRow> discovery_preview(uint64_t session, int64_t from, int64_t count);
void                    discovery_cancel(uint64_t session);
// Starts the job once discovery finished; a .7z destination creates an archive.
std::string copy_start(uint64_t session, int side);

struct SubmitResult {
  std::string error;
  uint64_t    job = 0;
};
SubmitResult submit_move(const StringList& sources, const std::string& target, int side);
SubmitResult submit_delete(const StringList& sources, int side);
SubmitResult submit_mkdir(const std::string& folder, const std::string& name);
SubmitResult submit_rename(const StringList& sources, const StringList& names);
void         copy_to_clipboard(int side, bool names);

struct FindInfo {
  bool        running = false, truncated = false;
  int64_t     dirs = 0, files = 0, errors = 0, matches = 0;
  std::string status;
};
std::string              find_start(const std::string& root, const std::string& pattern);
void                     find_stop();
FindInfo                 find_info();
std::vector<std::string> find_results(int64_t from, int64_t count);
void                     find_reveal(int side, const std::string& path);

// Jobs.
struct JobInfo {
  uint64_t    id = 0;
  std::string type, state;  // COPY, MOVE, ...; queued, running, paused, cancelled, completed, completed_with_errors
  bool        stopped = false;
  double      percent = 0, current_percent = 0, mbps = 0, average_mbps = 0;
  int64_t     items_done = 0, items_total = 0, items_failed = 0, items_skipped = 0, errors = 0;
  double      bytes_done = 0, bytes_total = 0;
  std::string current, recovery_note, first_error;
  double      queued = -1, started = -1, finished = -1;
};
struct JobDetail {
  JobInfo                  info;
  std::vector<std::string> items, errors;
  bool                     expired = false;
};
using JobList = std::vector<JobInfo>;
struct RunningJob {
  bool    present = false;
  JobInfo job;
  int64_t queued = 0;
};
std::vector<JobInfo> jobs();  // Running first, then history, newest first.
RunningJob           running_job();
JobDetail            job_detail(uint64_t id);
std::string          pause_job(uint64_t id);
std::string          resume_job(uint64_t id);
std::string          cancel_job(uint64_t id);
void                 dismiss_job(uint64_t id);
uint64_t             transfer_rate();
void                 set_transfer_rate(uint64_t bytes_per_second, bool persist);

struct ErrorInfo {
  std::string message;
  double      time = 0;
};
using ErrorList = std::vector<ErrorInfo>;
std::vector<ErrorInfo> errors(int count);  // Newest first.
int64_t                error_count();
void                   clear_errors();
void                   report_error(const std::string& message);  // any thread

struct BookmarkInfo {
  std::string title, path, encoded;
  LocationKind kind = LocationKind::Local;
};
using BookmarkList = std::vector<BookmarkInfo>;
std::vector<BookmarkInfo> bookmarks();
void                      add_bookmark(const std::string& location);
void                      remove_bookmark(const std::string& encoded);

// Editor. Attaching is reported through Changes::attaches; the app shows it in a native window
// (scene_socket) or runs it in a terminal view.
std::string open_in_editor();
std::string switch_to_editor();
struct RestartResult {
  int         status = 2;  // 0 ready, 1 needs confirmation to import a legacy checkpoint, 2 failed
  std::string error;
};
RestartResult restart_editor(bool allow_legacy);
void set_editor_session(const std::string& session_store, const StringList& environment);
void set_editor_switch_key(const std::string& key);
// The app draws Fresh's scene natively: attaches carry the session's scene socket when it has one.
void set_editor_scene_attach(bool on);

// SSH. authenticate blocks while ssh asks its questions (through SSH_ASKPASS); call it off the main thread.
int         ssh_authenticate(const std::string& host);  // any thread
std::string ssh_open(const std::string& host, const std::string& path);
void        set_endpoint_command(const std::string& host, const std::string& command);  // any thread

// Events, as Lua scripts see them.
struct Event {
  uint64_t    sequence = 0, request = 0;
  std::string name, detail;
};
struct EventBatch {
  std::vector<Event> events;
  uint64_t           cursor = 0;
};
using EventList = std::vector<Event>;
EventBatch events_since(uint64_t cursor);

// Formatting helpers shared with the terminal interface.
std::string format_bytes(double bytes);
std::string display_location(const std::string& encoded);

}  // namespace fce
