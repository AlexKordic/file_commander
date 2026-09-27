#include "fc_framework.hpp"
#include "scripting.hpp"
#include "app.hpp"

#include <ftxui/component/event.hpp>

#include <chrono>
#include <cstring>

using namespace ftxui;
using namespace Perun;

// =====================================================================
// ScheduledUpdates implementation
// =====================================================================

ScheduledUpdates::~ScheduledUpdates() { stop(); }

void ScheduledUpdates::start() {
  if (_running.exchange(true)) return;  // already running
  _thread = std::thread([this]() { run(); });
}

void ScheduledUpdates::stop() {
  if (!_running.exchange(false)) return;  // already stopped
  _cv.notify_all();
  if (_thread.joinable()) _thread.join();
}

void ScheduledUpdates::schedule_at(double timestamp) {
  std::lock_guard lock(_mutex);
  _timers.push(timestamp);
  _cv.notify_all();
}

void ScheduledUpdates::start_periodic(int interval_ms) {
  std::lock_guard lock(_mutex);
  _periodic_ms = interval_ms;
  _cv.notify_all();
}

void ScheduledUpdates::stop_periodic() {
  start_periodic(0);
}

void ScheduledUpdates::run() {
  while (_running) {
    std::unique_lock lock(_mutex);

    // Compute next wake time
    double next_wake = 0;
    bool   has_wake  = false;

    // Check one-shot timers
    if (!_timers.empty()) {
      next_wake = _timers.top();
      has_wake  = true;
    }

    // Check periodic interval
    if (_periodic_ms > 0) {
      double periodic_wake = now() + _periodic_ms / 1000.0;
      if (!has_wake || periodic_wake < next_wake) {
        next_wake = periodic_wake;
      }
      has_wake = true;
    }

    if (!has_wake) {
      // Nothing scheduled — wait until notified
      _cv.wait(lock, [this]() { return !_running || _periodic_ms > 0 || !_timers.empty(); });
      continue;
    }

    if (!_running) break;

    // Wait until next_wake or notification
    double wait_seconds = next_wake - now();
    if (wait_seconds > 0) {
      _cv.wait_for(lock, std::chrono::duration<double>(wait_seconds));
    }

    if (!_running) break;

    // Remove expired one-shot timers
    double current = now();
    while (!_timers.empty() && _timers.top() <= current) {
      _timers.pop();
    }

    lock.unlock();

    // Wake the FTXUI event loop
    _notify();
  }
}

// =====================================================================
// LuaScripting implementation
// =====================================================================

LuaScripting::LuaScripting(FileCommander& app, ftxui::Component root)
    : _app(app), _root(std::move(root)), _scheduler(app.get_left().get_shared_state()->notify) {}

LuaScripting::~LuaScripting() { cleanup(); }

// --- Debug logging ---

void LuaScripting::log(const char* msg) {
  if (!_log_file) _log_file = fopen("/tmp/fc_lua_debug.log", "w");
  if (_log_file) { fprintf(_log_file, "%s\n", msg); fflush(_log_file); }
}

// --- Registry-based 'this' access ---

LuaScripting* LuaScripting::from_lua(lua_State* L) {
  lua_getfield(L, LUA_REGISTRYINDEX, "fc_scripting");
  auto* self = static_cast<LuaScripting*>(lua_touserdata(L, -1));
  lua_pop(L, 1);
  return self;
}

// --- Setup ---

bool LuaScripting::setup(const std::string& script_path) {
  log("setup: start");
  _lua = luaL_newstate();
  luaL_openlibs(_lua);

  // 1. Store 'this' in Lua registry
  lua_pushlightuserdata(_lua, this);
  lua_setfield(_lua, LUA_REGISTRYINDEX, "fc_scripting");

  // 2. Register 'fc' table with plain C functions (no upvalues)
  lua_newtable(_lua);

  auto reg = [this](const char* name, lua_CFunction fn) {
    lua_pushcfunction(_lua, fn);
    lua_setfield(_lua, -2, name);
  };

  // clang-format off
  reg("key",               l_key);
  reg("quit",              l_quit);
  reg("left_cd",           l_left_cd);
  reg("right_cd",          l_right_cd);
  reg("left_path",         l_left_path);
  reg("right_path",        l_right_path);
  reg("focused",           l_focused);
  reg("selected",          l_selected);
  reg("errors",            l_errors);
  reg("state",             l_state);
  reg("wait_event",        l_wait_event);
  reg("wait_for_jobs",     l_wait_for_jobs);
  reg("sleep",             l_sleep);
  reg("set_transfer_rate", l_set_transfer_rate);
  reg("cancel_job",        l_cancel_job);
  reg("pause_job",         l_pause_job);
  reg("job_history",       l_job_history);
  reg("test_heartbeat",    l_test_heartbeat);
  // clang-format on

  lua_setglobal(_lua, "fc");

  // 3. Load fc_framework.lua
  log("setup: loading framework");
  if (luaL_loadbuffer(_lua, fc_lua_framework, sizeof(fc_lua_framework) - 1, "@fc_framework.lua") != 0 || lua_pcall(_lua, 0, 0, 0) != 0) {
    const char* err = lua_tostring(_lua, -1);
    std::string msg = std::string("[Lua framework] ") + (err ? err : "unknown error");
    log(msg);
    file_operations().report_error(msg);
    lua_pop(_lua, 1);
    return false;
  }
  log("setup: framework loaded OK");

  // 4. Call __framework_init(context) — pass 'this' to Lua side
  lua_getglobal(_lua, "__framework_init");
  lua_pushlightuserdata(_lua, this);
  lua_call(_lua, 1, 0);

  // 5. Create coroutine and load the test script
  _lua_co = lua_newthread(_lua);
  // Count hooks must also cover loops that LuaJIT would otherwise compile.
  luaJIT_setmode(_lua_co, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_OFF);
  lua_sethook(_lua_co, execution_hook, LUA_MASKCOUNT, 10000);
  log(("setup: loading script " + script_path).c_str());
  if (luaL_loadfile(_lua_co, script_path.c_str()) != 0) {
    const char* err = lua_tostring(_lua_co, -1);
    std::string msg = std::string("[Lua load] ") + (err ? err : "unknown error");
    log(msg);
    file_operations().report_error(msg);
    return false;
  }
  log("setup: script loaded, ready for initial resume");

  // Start the scheduler thread (idles on cv until something is scheduled)
  _scheduler.start();
  heartbeat_test_timeout();

  return true;
}

// --- tick() — called after every RunOnceBlocking() ---

void LuaScripting::tick() {
  if (_finished) return;
  if (check_test_timeout_and_abort()) return;

  // First call: start the Lua coroutine
  if (!_started && _lua_co) {
    if (_app.get_left().loading() || _app.get_right().loading()) return;
    // Startup publication must finish before scripts can operate on panels.
    poll_async_events();
    _event_log.clear();
    _event_cursor = 0;
    heartbeat_test_timeout();
    _started = true;
    log("tick: starting Lua coroutine (initial resume)");
    int status = lua_resume(_lua_co, 0);
    log(("tick: initial resume status = " + std::to_string(status)).c_str());
    handle_resume_status(status);
    return;
  }

  // Subsequent calls: check pending waits
  if (_pending_wait) {
    check_waits();
  }
}

void LuaScripting::heartbeat_test_timeout() {
  _test_deadline = now() + _test_timeout_window_sec;
  _scheduler.schedule_at(_test_deadline);
}

bool LuaScripting::check_test_timeout_and_abort() {
  if (_finished) return true;
  if (_test_deadline <= 0.0) return false;
  const double deadline = _pending_wait ? std::max(_test_deadline, _pending_wait->deadline + 1.0) : _test_deadline;
  if (now() <= deadline) return false;

  std::string msg = "[Lua] FAIL: hard timeout exceeded 6s";
  log("ERROR: " + msg);
  file_operations().report_error(msg);
  finish_script(1);
  return true;
}

// --- fire_event ---

void LuaScripting::fire_event(const std::string& name, const std::string& detail) {
  while (_event_cursor>0 && !_event_log.empty()) { _event_log.pop_front(); --_event_cursor; }
  if (_event_log.size()>=4095) {
    while(_event_log.size()>=4094) _event_log.pop_front();
    _event_log.push_back({"event_history_expired",now(),"resync application state"});
  }
  _event_log.push_back({name, now(), detail});
}

// --- finished ---

bool LuaScripting::finished() const { return _finished; }

// --- cleanup ---

void LuaScripting::cleanup() {
  _scheduler.stop();
  _app.on_event = {};
  _app.get_left().on_event = {};
  _app.get_right().on_event = {};
  if (_lua) { lua_close(_lua); _lua = nullptr; _lua_co = nullptr; }
  if (_log_file) { fclose(_log_file); _log_file = nullptr; }
}

// --- poll_async_events ---

void LuaScripting::poll_async_events() {
  _poll_count++;
  auto focused_side = [&]() -> std::string {
    if (_app.get_left().navigation->Focused()) return "left";
    if (_app.get_right().navigation->Focused()) return "right";
    Panel& focused = _app.focused_panel();
    return (&focused == &_app.get_left()) ? "left" : "right";
  };
  auto job_state_name = [](const std::shared_ptr<JobSpec>& job) -> std::string {
    if (!job) return "none";
    switch (job->_state.load()) {
    case Perun::JobState::QUEUED: return "queued";
    case Perun::JobState::RUNNING: return "running";
    case Perun::JobState::PAUSED: return "paused";
    case Perun::JobState::CANCELLED: return "cancelled";
    case Perun::JobState::COMPLETED: return "completed";
    case Perun::JobState::COMPLETED_WITH_ERRORS: return "completed_with_errors";
    }
    return "unknown";
  };

  const std::string current_focus_side = focused_side();
  const bool        current_single_panel_mode = _app.single_panel_mode();

  // Transitions are retained by the job manager even between UI frames.
  for (const auto& event : file_operations().events_since(_last_job_sequence)) {
    if(event.history_expired) { fire_event("job_history_expired",std::to_string(event.sequence)); continue; }
    fire_event(event.completed ? "job_completed" : "job_started", std::to_string(event.job_id));
  }
  auto jobinfo = file_operations().get_running_job();
  int current_job_items_done = -1;
  std::string current_job_state = job_state_name(jobinfo.job);
  if (jobinfo.job) {
    {
      std::lock_guard lock(jobinfo.job->_m);
      current_job_items_done = static_cast<int>(jobinfo.job->_items_done);
    }
    _had_running_job = !jobinfo.job->is_stopped();
  } else {
    _had_running_job = false;
  }

  // Completion identity is per request, including repeated searches in one dialog.
  for (auto* panel : {&_app.get_left(), &_app.get_right()}) {
    auto copy = std::dynamic_pointer_cast<CopyDialog>(panel->get_overlay_dialog("Copy"));
    if (copy && copy->_discovery_process) {
      auto* discovery = copy->_discovery_process.get();
      if (!discovery->_running.load() && _completed_discoveries.insert(discovery->_sequence_id).second)
        fire_event("discovery_completed", std::to_string(discovery->_sequence_id));
    }
    auto find = std::dynamic_pointer_cast<FindDialog>(panel->get_overlay_dialog("Find"));
    if (find && find->_completed.load() && !find->_running.load() && _completed_searches.insert(find->_sequence_id).second)
      fire_event("find_completed", std::to_string(find->_sequence_id));
  }

  auto count_selected = [](Panel& panel) -> int {
    int selected = 0;
    for (const auto& item : panel.dir.items) {
      if (item.selected()) selected++;
    }
    return selected;
  };
  const int left_item_count      = static_cast<int>(_app.get_left().dir._calculated.items_visible);
  const int right_item_count     = static_cast<int>(_app.get_right().dir._calculated.items_visible);
  const int left_selected_count  = count_selected(_app.get_left());
  const int right_selected_count = count_selected(_app.get_right());
  const int error_count          = static_cast<int>(file_operations().dataset_size().total);

  if (!_event_baseline_initialized) {
    _event_baseline_initialized = true;
    _last_left_item_count       = left_item_count;
    _last_right_item_count      = right_item_count;
    _last_left_revision = _app.get_left().items_revision;
    _last_right_revision = _app.get_right().items_revision;
    _last_left_selected_count   = left_selected_count;
    _last_right_selected_count  = right_selected_count;
    _last_error_count           = error_count;
    _last_focus_side            = current_focus_side;
    _last_single_panel_mode     = current_single_panel_mode;
    _last_job_state_name        = current_job_state;
    _last_job_items_done        = current_job_items_done;
    return;
  }

  if (current_focus_side != _last_focus_side) {
    fire_event("focus_changed", current_focus_side);
  }
  if (current_single_panel_mode != _last_single_panel_mode) {
    fire_event("single_panel_mode_changed", current_single_panel_mode ? "on" : "off");
  }
  if (current_job_state != _last_job_state_name) {
    fire_event("job_state_changed", current_job_state);
  }
  if (current_job_items_done >= 0 && current_job_items_done != _last_job_items_done) {
    fire_event("job_progress", std::to_string(current_job_items_done));
  }

  const bool left_items_changed  = left_item_count != _last_left_item_count || _app.get_left().items_revision != _last_left_revision;
  const bool right_items_changed = right_item_count != _last_right_item_count || _app.get_right().items_revision != _last_right_revision;
  if (left_items_changed || right_items_changed) {
    std::string detail = "both";
    if (left_items_changed && !right_items_changed) detail = "left";
    if (!left_items_changed && right_items_changed) detail = "right";
    fire_event("items_updated", detail);
  }

  if (left_selected_count != _last_left_selected_count) {
    fire_event("selection_changed", "left:" + std::to_string(left_selected_count));
  }
  if (right_selected_count != _last_right_selected_count) {
    fire_event("selection_changed", "right:" + std::to_string(right_selected_count));
  }

  if (error_count > _last_error_count) {
    for (int i = _last_error_count; i < error_count; ++i) {
      JobErrorInfo e = file_operations().get_error(i);
      fire_event("error_reported", e.valid() ? e.message : "");
    }
  } else if (error_count < _last_error_count) {
    fire_event("errors_cleared", std::to_string(error_count));
  }

  _last_left_revision = _app.get_left().items_revision;
  _last_right_revision = _app.get_right().items_revision;
  _last_left_item_count      = left_item_count;
  _last_right_item_count     = right_item_count;
  _last_left_selected_count  = left_selected_count;
  _last_right_selected_count = right_selected_count;
  _last_error_count          = error_count;
  _last_focus_side           = current_focus_side;
  _last_single_panel_mode    = current_single_panel_mode;
  _last_job_state_name       = current_job_state;
  _last_job_items_done       = current_job_items_done;
}

// --- handle_resume_status ---

void LuaScripting::finish_script(int exit_code) {
  _exit_code = exit_code;
  _finished = true;
  _pending_wait.reset();
  if (auto* screen = ScreenInteractive::Active()) screen->Exit();
}

void LuaScripting::execution_hook(lua_State* L, lua_Debug*) {
  auto* self = from_lua(L);
  if (self->_test_deadline > 0 && now() > self->_test_deadline)
    luaL_error(L, "hard timeout exceeded 6s");
}

void LuaScripting::handle_resume_status(int status) {
  if (status == 0) {
    finish_script(0);
  } else if (status != LUA_YIELD) {
    const char* err = lua_tostring(_lua_co, -1);
    std::string errmsg = std::string("[Lua] ") + (err ? err : "unknown error");
    log("ERROR: " + errmsg);
    file_operations().report_error(errmsg);
    finish_script(1);
  }
}

// --- check_waits ---

void LuaScripting::check_waits() {
  if (!_pending_wait || _finished) return;
  if (check_test_timeout_and_abort()) return;

  // Poll for async events
  poll_async_events();

  if (_pending_wait->jobs_mode && file_operations().idle()) {
    _pending_wait.reset();
    heartbeat_test_timeout();
    lua_pushboolean(_lua_co, 1);
    handle_resume_status(lua_resume(_lua_co, 1));
    return;
  }

  // Check event log for match (only if we have event names to match)
  if (!_pending_wait->event_names.empty()) {
    for (size_t i = _event_cursor; i < _event_log.size(); i++) {
      for (auto& name : _pending_wait->event_names) {
        if (_event_log[i].name == name && (!_pending_wait->detail || *_pending_wait->detail == _event_log[i].detail)) {
          // Match! Resume coroutine with true
          const auto detail = _event_log[i].detail;
          _pending_wait.reset();
          // Advance only past the matched event. This preserves trailing events
          // that may have been produced in the same poll cycle for subsequent waits.
          _event_cursor = i + 1;
          lua_pushboolean(_lua_co, 1);
          lua_pushstring(_lua_co, detail.c_str());
          heartbeat_test_timeout();
          int status = lua_resume(_lua_co, 2);
          handle_resume_status(status);
          return;
        }
      }
    }
    _event_cursor = _event_log.size();
  }

  // Check deadline
  if (now() > _pending_wait->deadline) {
    bool was_sleep = _pending_wait->sleep_mode;
    _pending_wait.reset();
    if (was_sleep) {
      // Sleep completed — resume with no return value
      heartbeat_test_timeout();
      int status = lua_resume(_lua_co, 0);
      handle_resume_status(status);
    } else {
      // Timeout — resume with nil
      lua_pushnil(_lua_co);
      heartbeat_test_timeout();
      int status = lua_resume(_lua_co, 1);
      handle_resume_status(status);
    }
  }
}

// =====================================================================
// Lua C callbacks — static methods, access 'this' via from_lua()
// =====================================================================

// A command establishes the event checkpoint for its subsequent waits. Poll
// first so old asynchronous changes cannot masquerade as its result. Consecutive
// waits still preserve trailing events produced by that command.
void LuaScripting::begin_action() {
  poll_async_events();
  _event_cursor = _event_log.size();
}

// fc.key(name_or_table)
int LuaScripting::l_key(lua_State* L) {
  auto* self = from_lua(L);
  if (!self->_root) return luaL_error(L, "fc not initialized");
  self->begin_action();
  auto dispatch_name = [self](const std::string& name) {
    if (name.size() == 1) {
      self->_root->OnEvent(Event::Character(name[0]));
      return;
    }
    if (name.size() >= 3) {
      const Command* action = commands().find_by_id(name);
      if (action) {
        self->_app.execute_palette_command(name);
        return;
      }
    }
    self->_root->OnEvent(event_from_string(name));
  };
  // Handle table argument: process each element
  if (lua_istable(L, 1)) {
    int n = (int)lua_objlen(L, 1);
    for (int i = 1; i <= n; i++) {
      lua_rawgeti(L, 1, i);
      const char* name = luaL_checkstring(L, -1);
      dispatch_name(name);
      lua_pop(L, 1);
    }
    return 0;
  }
  // Single string argument
  const char* name = luaL_checkstring(L, 1);
  dispatch_name(name);
  return 0;
}

// fc.quit()
int LuaScripting::l_quit(lua_State* L) {
  auto* self = from_lua(L);
  self->log("fc.quit() called");
  self->_finished = true;
  // Exit the FTXUI event loop gracefully
  auto* screen = ScreenInteractive::Active();
  if (screen) screen->Exit();
  return 0;
}

// fc.left_cd(path)
int LuaScripting::l_left_cd(lua_State* L) {
  auto* self = from_lua(L);
  self->begin_action();
  auto path = boost::filesystem::path(luaL_checkstring(L, 1));
  self->_app.get_left().move_to(path);
  return 0;
}

// fc.right_cd(path)
int LuaScripting::l_right_cd(lua_State* L) {
  auto* self = from_lua(L);
  self->begin_action();
  auto path = boost::filesystem::path(luaL_checkstring(L, 1));
  self->_app.get_right().move_to(path);
  return 0;
}

// fc.left_path()
int LuaScripting::l_left_path(lua_State* L) {
  auto* self = from_lua(L);
  lua_pushstring(L, self->_app.get_left().dir.path.native().c_str());
  return 1;
}

// fc.right_path()
int LuaScripting::l_right_path(lua_State* L) {
  auto* self = from_lua(L);
  lua_pushstring(L, self->_app.get_right().dir.path.native().c_str());
  return 1;
}

// Helper: get the focused panel
Panel& LuaScripting::get_focused_panel() {
  return _app.focused_panel();
}

// fc.focused()
int LuaScripting::l_focused(lua_State* L) {
  auto* self = from_lua(L);
  auto& panel   = self->get_focused_panel();
  auto  focused = panel.get_shared_state()->get_focused_item();
  if (focused) {
    lua_pushstring(L, focused->native().c_str());
  } else {
    lua_pushnil(L);
  }
  return 1;
}

// fc.selected()
int LuaScripting::l_selected(lua_State* L) {
  auto* self = from_lua(L);
  auto& panel = self->get_focused_panel();
  lua_newtable(L);
  int idx = 1;
  for (auto& item : panel.dir.items) {
    if (item.selected()) {
      lua_pushstring(L, item.path_ref().native().c_str());
      lua_rawseti(L, -2, idx++);
    }
  }
  return 1;
}

// fc.errors()
int LuaScripting::l_errors(lua_State* L) {
  auto errors = file_operations().get_errors(9999);
  lua_newtable(L);
  int idx = 1;
  for (auto& e : errors) {
    lua_pushstring(L, e.message.c_str());
    lua_rawseti(L, -2, idx++);
  }
  return 1;
}

// Helper: push panel state subtable onto the Lua stack
void LuaScripting::push_panel_state(lua_State* L, Panel& panel) {
  lua_newtable(L);
  // path
  lua_pushstring(L, panel.dir.path.native().c_str());
  lua_setfield(L, -2, "path");
  lua_pushboolean(L, panel.loading());
  lua_setfield(L, -2, "loading");
  // item_count (visible items)
  lua_pushinteger(L, panel.dir._calculated.items_visible);
  lua_setfield(L, -2, "item_count");
  // focused_index
  auto state = panel.get_shared_state();
  int  fi    = state->get_focused_index ? state->get_focused_index() : 0;
  lua_pushinteger(L, fi);
  lua_setfield(L, -2, "focused_index");
  // focused_path
  auto focused = state->get_focused_item ? state->get_focused_item() : nullptr;
  if (focused) {
    lua_pushstring(L, focused->native().c_str());
  } else {
    lua_pushnil(L);
  }
  lua_setfield(L, -2, "focused_path");
  // selected_count + selected_paths
  int selected_count = 0;
  lua_newtable(L);  // selected_paths table
  int idx = 1;
  for (auto& item : panel.dir.items) {
    if (item.selected()) {
      selected_count++;
      lua_pushstring(L, item.path_ref().native().c_str());
      lua_rawseti(L, -2, idx++);
    }
  }
  lua_setfield(L, -2, "selected_paths");
  lua_pushinteger(L, selected_count);
  lua_setfield(L, -2, "selected_count");
  // filter
  lua_pushstring(L, panel.dir.filter.phrase.c_str());
  lua_setfield(L, -2, "filter");
  // sort
  const char* sort_str = "name_asc";
  switch (panel.dir.order_by) {
  case Orderby::NAME_ASC: sort_str = "name_asc"; break;
  case Orderby::NAME_DESC: sort_str = "name_desc"; break;
  case Orderby::SIZE_ASC: sort_str = "size_asc"; break;
  case Orderby::SIZE_DESC: sort_str = "size_desc"; break;
  case Orderby::TIME_ASC: sort_str = "time_asc"; break;
  case Orderby::TIME_DESC: sort_str = "time_desc"; break;
  }
  lua_pushstring(L, sort_str);
  lua_setfield(L, -2, "sort");
  // has_dialog / active_dialog
  lua_pushboolean(L, panel._active_dialog > 0);
  lua_setfield(L, -2, "has_dialog");
  if (panel._active_dialog_name.empty()) {
    lua_pushnil(L);
  } else {
    lua_pushstring(L, panel._active_dialog_name.c_str());
  }
  lua_setfield(L, -2, "active_dialog");
  // column visibility
  lua_pushboolean(L, state->show_permissions_column);
  lua_setfield(L, -2, "show_permissions_column");
  lua_pushboolean(L, state->show_owner_group_column);
  lua_setfield(L, -2, "show_owner_group_column");
  // tabs
  lua_newtable(L);  // tabs array
  const auto tabs = panel.tab_paths();
  const int  active_tab = panel.active_tab_index();
  for (int i = 0; i < (int)tabs.size(); ++i) {
    lua_newtable(L);  // tabs[i + 1]
    lua_pushstring(L, tabs[i].native().c_str());
    lua_setfield(L, -2, "path");
    lua_pushboolean(L, i == active_tab);
    lua_setfield(L, -2, "active");
    lua_rawseti(L, -2, i + 1);
  }
  lua_setfield(L, -2, "tabs");
}

// fc.state()
int LuaScripting::l_state(lua_State* L) {
  auto* self = from_lua(L);
  lua_newtable(L);  // root table

  // left panel
  push_panel_state(L, self->_app.get_left());
  lua_setfield(L, -2, "left");

  // right panel
  push_panel_state(L, self->_app.get_right());
  lua_setfield(L, -2, "right");

  lua_pushboolean(L, self->_app.single_panel_mode());
  lua_setfield(L, -2, "single_panel_mode");

  lua_newtable(L);
  for (const auto& command : commands().list_all()) {
    lua_pushstring(L, event_to_token(command.key).c_str());
    lua_setfield(L, -2, command.id.c_str());
  }
  lua_setfield(L, -2, "key_bindings");

  // jobs
  lua_newtable(L);
  auto jobinfo = file_operations().get_running_job();
  bool has_job = jobinfo.job && !jobinfo.job->is_stopped();
  lua_pushboolean(L, has_job);
  lua_setfield(L, -2, "active");
  if (jobinfo.job) {
    // Job state — available for both active and stopped jobs
    const char* state_str = "unknown";
    switch (jobinfo.job->_state.load()) {
    case Perun::JobState::QUEUED:               state_str = "queued"; break;
    case Perun::JobState::RUNNING:              state_str = "running"; break;
    case Perun::JobState::PAUSED:               state_str = "paused"; break;
    case Perun::JobState::CANCELLED:            state_str = "cancelled"; break;
    case Perun::JobState::COMPLETED:            state_str = "completed"; break;
    case Perun::JobState::COMPLETED_WITH_ERRORS: state_str = "completed_with_errors"; break;
    }
    lua_pushstring(L, state_str);
    lua_setfield(L, -2, "state");
  }
  if (has_job) {
    const char* jtype = "?";
    switch (jobinfo.job->_type) {
    case JobInstructions::Type::COPY: jtype = "copy"; break;
    case JobInstructions::Type::MOVE: jtype = "move"; break;
    case JobInstructions::Type::DELETE: jtype = "delete"; break;
    case JobInstructions::Type::ARCHIVE_CREATE: jtype = "archive_create"; break;
    }
    lua_pushstring(L, jtype);
    lua_setfield(L, -2, "type");
    std::lock_guard lock(jobinfo.job->_m);
    lua_pushnumber(L, jobinfo.job->_total.percentage);
    lua_setfield(L, -2, "progress");
    lua_pushinteger(L, jobinfo.job->item_count());
    lua_setfield(L, -2, "items_total");
    lua_pushinteger(L, jobinfo.job->_items_done);
    lua_setfield(L, -2, "items_done");
  } else {
    lua_pushnil(L);
    lua_setfield(L, -2, "type");
    lua_pushnumber(L, 0);
    lua_setfield(L, -2, "progress");
    lua_pushinteger(L, 0);
    lua_setfield(L, -2, "items_total");
    lua_pushinteger(L, 0);
    lua_setfield(L, -2, "items_done");
  }
  lua_pushinteger(L, jobinfo.queued_jobs);
  lua_setfield(L, -2, "queued");
  lua_setfield(L, -2, "jobs");

  // errors
  auto errors = file_operations().get_errors(9999);
  lua_pushinteger(L, (int)errors.size());
  lua_setfield(L, -2, "error_count");
  lua_newtable(L);
  int eidx = 1;
  for (auto& e : errors) {
    lua_newtable(L);
    lua_pushstring(L, e.message.c_str());
    lua_setfield(L, -2, "message");
    lua_pushnumber(L, e.time);
    lua_setfield(L, -2, "time");
    lua_rawseti(L, -2, eidx++);
  }
  lua_setfield(L, -2, "errors");

  return 1;
}

// fc.wait_event(name_or_table, timeout_ms)
int LuaScripting::l_wait_event(lua_State* L) {
  auto* self = from_lua(L);

  // Collect event name(s)
  std::vector<std::string> names;
  if (lua_istable(L, 1)) {
    int n = (int)lua_objlen(L, 1);
    for (int i = 1; i <= n; i++) {
      lua_rawgeti(L, 1, i);
      names.push_back(luaL_checkstring(L, -1));
      lua_pop(L, 1);
    }
  } else {
    names.push_back(luaL_checkstring(L, 1));
  }
  int timeout_ms = luaL_optinteger(L, 2, 5000);
  std::optional<std::string> detail;
  if (!lua_isnoneornil(L, 3)) detail = luaL_checkstring(L, 3);

  // Poll once to catch events that already happened
  self->poll_async_events();

  // Check if event already in log since last cursor position
  for (size_t i = self->_event_cursor; i < self->_event_log.size(); i++) {
    for (auto& name : names) {
      if (self->_event_log[i].name == name && (!detail || *detail == self->_event_log[i].detail)) {
        // Preserve trailing already-logged events for the caller's next wait.
        self->_event_cursor = i + 1;
        lua_pushboolean(L, 1);
        lua_pushstring(L, self->_event_log[i].detail.c_str());
        return 2;  // already happened, no yield
      }
    }
  }

  // Not yet — set up wait and yield
  double deadline = now() + timeout_ms / 1000.0;
  self->_pending_wait = PendingWait{std::move(names), deadline, false, false, detail};
  self->_event_cursor = self->_event_log.size();
  self->_scheduler.schedule_at(deadline);
  return lua_yield(L, 0);
}

// fc.wait_for_jobs(timeout_ms): includes jobs popped but not yet published active.
int LuaScripting::l_wait_for_jobs(lua_State* L) {
  auto* self = from_lua(L);
  if (file_operations().idle()) { lua_pushboolean(L, 1); return 1; }
  const double deadline = now() + luaL_optinteger(L, 1, 30000) / 1000.0;
  self->_pending_wait = PendingWait{{}, deadline, false, true};
  self->_scheduler.schedule_at(deadline);
  return lua_yield(L, 0);
}

// fc.sleep(ms)
int LuaScripting::l_sleep(lua_State* L) {
  auto* self = from_lua(L);
  int ms = (int)luaL_checknumber(L, 1);
  double deadline = now() + ms / 1000.0;
  self->_pending_wait = PendingWait{{}, deadline, true};
  self->_scheduler.schedule_at(deadline);
  return lua_yield(L, 0);
}

// fc.set_transfer_rate(bytes_per_second)
int LuaScripting::l_set_transfer_rate(lua_State* L) {
  uint64_t bps = (uint64_t)luaL_checknumber(L, 1);
  file_operations().set_transfer_rate(bps);
  return 0;
}

// fc.cancel_job() — cancel the currently running job
int LuaScripting::l_cancel_job(lua_State* L) {
  from_lua(L)->begin_action();
  auto jobinfo = file_operations().get_running_job();
  if (jobinfo.job && !jobinfo.job->is_stopped()) {
    file_operations().cancel_job(jobinfo.job.get());
    lua_pushboolean(L, 1);
  } else {
    lua_pushboolean(L, 0);
  }
  return 1;
}

// fc.pause_job() — toggle pause/resume for the currently running job
int LuaScripting::l_pause_job(lua_State* L) {
  from_lua(L)->begin_action();
  auto jobinfo = file_operations().get_running_job();
  if (jobinfo.job && !jobinfo.job->is_stopped()) {
    file_operations().pause_job(jobinfo.job.get());
    lua_pushboolean(L, 1);
  } else {
    lua_pushboolean(L, 0);
  }
  return 1;
}

// fc.job_history() — return array of {id, type, state, items_done, items_total, errors, bytes_done, bytes_total}
int LuaScripting::l_job_history(lua_State* L) {
  auto history = file_operations().get_job_history();
  lua_newtable(L);
  int idx = 1;
  for (auto& source : history) {
    auto job=source->snapshot(false);
    lua_newtable(L);

    lua_pushinteger(L, static_cast<int>(job->_job_id));
    lua_setfield(L, -2, "id");

    const char* type_str = "?";
    switch (job->_type) {
    case JobInstructions::Type::COPY:   type_str = "copy"; break;
    case JobInstructions::Type::MOVE:   type_str = "move"; break;
    case JobInstructions::Type::DELETE: type_str = "delete"; break;
    case JobInstructions::Type::ARCHIVE_CREATE: type_str = "archive_create"; break;
    }
    lua_pushstring(L, type_str);
    lua_setfield(L, -2, "type");

    const char* state_str = "unknown";
    switch (job->_state.load()) {
    case Perun::JobState::QUEUED:               state_str = "queued"; break;
    case Perun::JobState::RUNNING:              state_str = "running"; break;
    case Perun::JobState::PAUSED:               state_str = "paused"; break;
    case Perun::JobState::CANCELLED:            state_str = "cancelled"; break;
    case Perun::JobState::COMPLETED:            state_str = "completed"; break;
    case Perun::JobState::COMPLETED_WITH_ERRORS: state_str = "completed_with_errors"; break;
    }
    lua_pushstring(L, state_str);
    lua_setfield(L, -2, "state");

    lua_pushinteger(L, job->_items_done);
    lua_setfield(L, -2, "items_done");

    lua_pushinteger(L, static_cast<int>(job->item_count()));
    lua_setfield(L, -2, "items_total");

    lua_pushinteger(L, static_cast<int>(job->_error_count));
    lua_setfield(L, -2, "errors");

    lua_pushnumber(L, job->_bytes_processed);
    lua_setfield(L, -2, "bytes_done");

    lua_pushnumber(L, job->_bytes_total);
    lua_setfield(L, -2, "bytes_total");

    lua_rawseti(L, -2, idx++);
  }
  return 1;
}

int LuaScripting::l_test_heartbeat(lua_State* L) {
  (void)L;
  auto* self = from_lua(L);
  self->heartbeat_test_timeout();
  return 0;
}
