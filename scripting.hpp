#ifndef FC_SCRIPTING_HPP_
#define FC_SCRIPTING_HPP_

#include <atomic>
#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <optional>
#include <queue>
#include <set>
#include <string>
#include <thread>
#include <vector>

#include <ftxui/component/component.hpp>

extern "C" {
#include <lua.h>
#include <luajit.h>
#include <lualib.h>
#include <lauxlib.h>
}

// Forward declarations (defined in app.hpp)
class FileCommander;
class Panel;

// =====================================================================
// ScheduledUpdates — general-purpose timer thread for screen refresh
// =====================================================================

class ScheduledUpdates {
public:
  explicit ScheduledUpdates(std::function<void()> notify = [] {}) : _notify(std::move(notify)) {}
  ~ScheduledUpdates();  // calls stop()

  void start();   // launches background thread (idempotent)
  void stop();    // signals exit, joins thread

  /// Schedule a one-shot screen update at a specific timestamp (now()-based).
  void schedule_at(double timestamp);

  /// Start periodic screen updates every interval_ms milliseconds.
  /// Replaces any previous periodic interval. 0 = disable.
  void start_periodic(int interval_ms);

  /// Stop periodic updates (equivalent to start_periodic(0)).
  void stop_periodic();

private:
  std::function<void()> _notify;
  // Min-heap: soonest timestamp on top
  std::priority_queue<double, std::vector<double>, std::greater<double>> _timers;
  std::mutex              _mutex;
  std::condition_variable _cv;
  std::atomic<bool>       _running{false};
  int                     _periodic_ms = 0;
  std::thread             _thread;

  void run();  // thread function
};

// =====================================================================
// LuaScripting — owns all Lua state, event log, poll state, C callbacks
// =====================================================================

class LuaScripting {
public:
  /// Construct with references to the app and root component for OnEvent dispatch.
  LuaScripting(FileCommander& app, ftxui::Component root);
  ~LuaScripting();

  /// Load fc_framework.lua + test script, prepare coroutine. Returns false on error.
  bool setup(const std::string& script_path);

  /// Called after every RunOnceBlocking() in the explicit Loop.
  /// On first call: starts the Lua coroutine (initial lua_resume).
  /// On subsequent calls: polls async events, checks pending waits,
  /// resumes coroutine if a wait condition is met or timed out.
  void tick();

  /// Fire a named event from C++ code (Panel, DialogOverlay, etc.)
  void fire_event(const std::string& name, const std::string& detail = "");

  /// Has the Lua script finished (completed or errored)?
  bool finished() const;
  int exit_code() const { return _exit_code; }

  /// Close Lua state and stop scheduler.
  void cleanup();

private:
  // --- Application references (replaces g_app, g_root) ---
  FileCommander&   _app;
  ftxui::Component _root;

  // --- Lua VM (replaces g_lua, g_lua_co, g_lua_finished) ---
  lua_State* _lua    = nullptr;
  lua_State* _lua_co = nullptr;
  bool       _finished = false;
  int        _exit_code = 0;
  bool       _started  = false;   // has initial resume happened?

  // --- Event log (replaces g_event_log, g_event_cursor) ---
  struct ScriptEvent {
    std::string name;
    double      timestamp;
    std::string detail;
  };
  std::deque<ScriptEvent> _event_log;
  size_t                  _event_cursor = 0;

  // --- Pending wait (replaces g_pending_wait) ---
  struct PendingWait {
    std::vector<std::string> event_names;
    double                   deadline;
    bool                     sleep_mode = false;
    bool                     jobs_mode = false;
    std::optional<std::string> detail;
  };
  std::optional<PendingWait> _pending_wait;

  // --- Async poll state (replaces g_had_running_job, etc.) ---
  bool   _had_running_job = false;
  bool   _had_discovery   = false;
  uint64_t _last_discovery_id = 0;  // track process identity for fast-completion detection
  int    _poll_count = 0;
  uint64_t _last_job_sequence = 0;
  uint64_t _last_left_revision = 0;
  uint64_t _last_right_revision = 0;
  std::set<uint64_t> _completed_discoveries;
  std::set<uint64_t> _completed_searches;
  bool   _event_baseline_initialized = false;
  int    _last_left_item_count = -1;
  int    _last_right_item_count = -1;
  int    _last_left_selected_count = -1;
  int    _last_right_selected_count = -1;
  int    _last_error_count = -1;
  int    _last_job_items_done = -1;
  std::string _last_job_state_name;
  std::string _last_focus_side;
  bool   _last_single_panel_mode = false;
  bool   _had_find = false;
  void*  _last_find_ptr = nullptr;

  // --- Per-test watchdog (hard timeout window between heartbeats) ---
  double _test_timeout_window_sec = 6.0;
  double _test_deadline = -1.0;

  // --- Timer thread (replaces g_poll_active + detached thread) ---
  ScheduledUpdates _scheduler;

  // --- Debug logging (replaces g_lua_log) ---
  FILE* _log_file = nullptr;
  void  log(const char* msg);
  void  log(const std::string& msg) { log(msg.c_str()); }

  // --- Internal methods (replaces free functions) ---
  void begin_action();
  void poll_async_events();     // detect job_started/completed, discovery_completed
  void finish_script(int exit_code);
  static void execution_hook(lua_State* L, lua_Debug*);
  void handle_resume_status(int status);  // handle lua_resume return code
  void check_waits();           // called from tick(): check event log + timeout, resume if met
  void heartbeat_test_timeout();
  bool check_test_timeout_and_abort();

  // --- Lua C callbacks: access 'this' via registry, not globals ---
  static LuaScripting* from_lua(lua_State* L);  // extract 'this' from registry

  static int l_key(lua_State* L);
  static int l_quit(lua_State* L);
  static int l_left_cd(lua_State* L);
  static int l_right_cd(lua_State* L);
  static int l_left_path(lua_State* L);
  static int l_right_path(lua_State* L);
  static int l_focused(lua_State* L);
  static int l_selected(lua_State* L);
  static int l_errors(lua_State* L);
  static int l_state(lua_State* L);
  static int l_wait_event(lua_State* L);
  static int l_wait_for_jobs(lua_State* L);
  static int l_sleep(lua_State* L);
  static int l_set_transfer_rate(lua_State* L);
  static int l_cancel_job(lua_State* L);
  static int l_pause_job(lua_State* L);
  static int l_job_history(lua_State* L);
  static int l_test_heartbeat(lua_State* L);

  // --- Helpers ---
  static void push_panel_state(lua_State* L, Panel& panel);
  Panel& get_focused_panel();
};

#endif  // FC_SCRIPTING_HPP_
