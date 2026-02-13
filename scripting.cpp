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
    auto* screen = ScreenInteractive::Active();
    if (screen) screen->Post(Event::Custom);
  }
}

// =====================================================================
// LuaScripting implementation
// =====================================================================

LuaScripting::LuaScripting(FileCommander& app, ftxui::Component root)
    : _app(app), _root(std::move(root)) {}

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
  reg("key",        l_key);
  reg("quit",       l_quit);
  reg("left_cd",    l_left_cd);
  reg("right_cd",   l_right_cd);
  reg("left_path",  l_left_path);
  reg("right_path", l_right_path);
  reg("focused",    l_focused);
  reg("selected",   l_selected);
  reg("errors",     l_errors);
  reg("state",      l_state);
  reg("wait_event", l_wait_event);
  reg("sleep",      l_sleep);
  // clang-format on

  lua_setglobal(_lua, "fc");

  // 3. Load fc_framework.lua
  log("setup: loading framework");
  if (luaL_dofile(_lua, "fc_framework.lua") != 0) {
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

  return true;
}

// --- tick() — called after every RunOnceBlocking() ---

void LuaScripting::tick() {
  if (_finished) return;

  // First call: start the Lua coroutine
  if (!_started && _lua_co) {
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

// --- fire_event ---

void LuaScripting::fire_event(const std::string& name, const std::string& detail) {
  _event_log.push_back({name, now(), detail});
}

// --- finished ---

bool LuaScripting::finished() const { return _finished; }

// --- cleanup ---

void LuaScripting::cleanup() {
  _scheduler.stop();
  if (_lua) { lua_close(_lua); _lua = nullptr; _lua_co = nullptr; }
  if (_log_file) { fclose(_log_file); _log_file = nullptr; }
}

// --- poll_async_events ---

void LuaScripting::poll_async_events() {
  _poll_count++;
  // Job start/completion — detect by timestamps to avoid missing fast jobs
  auto jobinfo = file_operations().get_running_job();
  if (jobinfo.job) {
    // Detect job start
    if (jobinfo.job->_started_time > 0 && jobinfo.job->_started_time != _last_job_started_time) {
      _last_job_started_time = jobinfo.job->_started_time;
      log("poll: job_started");
      fire_event("job_started", "");
    }
    // Detect job completion
    if (jobinfo.job->_finished_time > 0 && jobinfo.job->_finished_time != _last_job_finished_time) {
      _last_job_finished_time = jobinfo.job->_finished_time;
      log("poll: job_completed");
      fire_event("job_completed", "");
    }
    _had_running_job = !jobinfo.job->is_stopped();
  } else {
    _had_running_job = false;
  }

  // Copy discovery completion — check both panels
  bool discovery_running = false;
  bool has_discovery = false;
  for (auto* panel : {&_app.get_left(), &_app.get_right()}) {
    auto copy_dlg = std::dynamic_pointer_cast<CopyDialog>(panel->get_overlay_dialog("Copy"));
    if (copy_dlg && copy_dlg->_discovery_process) {
      has_discovery = true;
      if (copy_dlg->_discovery_process->_running) {
        discovery_running = true;
      }
    }
  }
  if (_poll_count <= 5 || (_poll_count % 20 == 0)) {
    log("poll #" + std::to_string(_poll_count) + ": has_disc=" + std::to_string(has_discovery) + " disc_run=" + std::to_string(discovery_running) + " had_disc=" + std::to_string(_had_discovery));
  }
  if (_had_discovery && !discovery_running) {
    log("poll: discovery_completed");
    fire_event("discovery_completed", "");
  }
  _had_discovery = discovery_running;
}

// --- handle_resume_status ---

void LuaScripting::handle_resume_status(int status) {
  if (status == 0) {
    // Coroutine finished normally
    _finished = true;
  } else if (status == LUA_YIELD) {
    // Coroutine yielded (waiting for event or sleeping)
  } else {
    // Error
    const char* err = lua_tostring(_lua_co, -1);
    file_operations().report_error(std::string("[Lua] ") + (err ? err : "unknown error"));
    _finished = true;
    // Post Custom to refresh error display
    auto* screen = ScreenInteractive::Active();
    if (screen) screen->Post(Event::Custom);
  }
}

// --- check_waits ---

void LuaScripting::check_waits() {
  if (!_pending_wait || _finished) return;

  // Poll for async events
  poll_async_events();

  // Check event log for match (only if we have event names to match)
  if (!_pending_wait->event_names.empty()) {
    for (size_t i = _event_cursor; i < _event_log.size(); i++) {
      for (auto& name : _pending_wait->event_names) {
        if (_event_log[i].name == name) {
          // Match! Resume coroutine with true
          _pending_wait.reset();
          _event_cursor = _event_log.size();
          lua_pushboolean(_lua_co, 1);
          int status = lua_resume(_lua_co, 1);
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
      int status = lua_resume(_lua_co, 0);
      handle_resume_status(status);
    } else {
      // Timeout — resume with nil
      lua_pushnil(_lua_co);
      int status = lua_resume(_lua_co, 1);
      handle_resume_status(status);
    }
  }
}

// =====================================================================
// Lua C callbacks — static methods, access 'this' via from_lua()
// =====================================================================

// fc.key(name_or_table)
int LuaScripting::l_key(lua_State* L) {
  auto* self = from_lua(L);
  if (!self->_root) return luaL_error(L, "fc not initialized");
  // Handle table argument: process each element
  if (lua_istable(L, 1)) {
    int n = (int)lua_objlen(L, 1);
    for (int i = 1; i <= n; i++) {
      lua_rawgeti(L, 1, i);
      const char* name = luaL_checkstring(L, -1);
      size_t      len  = strlen(name);
      if (len == 1) {
        self->_root->OnEvent(Event::Character(name[0]));
      } else {
        self->_root->OnEvent(event_from_string(std::string(name)));
      }
      lua_pop(L, 1);
    }
    return 0;
  }
  // Single string argument
  const char* name = luaL_checkstring(L, 1);
  size_t      len  = strlen(name);
  if (len == 1) {
    self->_root->OnEvent(Event::Character(name[0]));
  } else {
    self->_root->OnEvent(event_from_string(std::string(name)));
  }
  return 0;
}

// fc.quit()
int LuaScripting::l_quit(lua_State* L) {
  auto* self = from_lua(L);
  self->log("fc.quit() called");
  self->cleanup();
  _exit(0);
  return 0;
}

// fc.left_cd(path)
int LuaScripting::l_left_cd(lua_State* L) {
  auto* self = from_lua(L);
  auto path = boost::filesystem::path(luaL_checkstring(L, 1));
  self->_app.get_left().move_to(path);
  return 0;
}

// fc.right_cd(path)
int LuaScripting::l_right_cd(lua_State* L) {
  auto* self = from_lua(L);
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
  if (_app.get_left().navigation->Focused()) return _app.get_left();
  return _app.get_right();
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
  // tabs (NOT YET IMPLEMENTED — always 1 tab)
  lua_newtable(L);  // tabs array
  lua_newtable(L);  // tabs[1]
  lua_pushstring(L, panel.dir.path.native().c_str());
  lua_setfield(L, -2, "path");
  lua_pushboolean(L, 1);
  lua_setfield(L, -2, "active");
  lua_rawseti(L, -2, 1);  // tabs[1] = {...}
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

  // jobs
  lua_newtable(L);
  auto jobinfo = file_operations().get_running_job();
  bool has_job = jobinfo.job && !jobinfo.job->is_stopped();
  lua_pushboolean(L, has_job);
  lua_setfield(L, -2, "active");
  if (has_job) {
    const char* jtype = "?";
    switch (jobinfo.job->_type) {
    case JobInstructions::Type::COPY: jtype = "copy"; break;
    case JobInstructions::Type::MOVE: jtype = "move"; break;
    case JobInstructions::Type::DELETE: jtype = "delete"; break;
    }
    lua_pushstring(L, jtype);
    lua_setfield(L, -2, "type");
    std::lock_guard lock(jobinfo.job->_m);
    lua_pushnumber(L, jobinfo.job->_total.percentage);
    lua_setfield(L, -2, "progress");
    lua_pushinteger(L, jobinfo.job->item_count());
    lua_setfield(L, -2, "items_total");
    lua_pushinteger(L, jobinfo.job->_current_item_index);
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

  // Poll once to catch events that already happened
  self->poll_async_events();

  // Check if event already in log since last cursor position
  for (size_t i = self->_event_cursor; i < self->_event_log.size(); i++) {
    for (auto& name : names) {
      if (self->_event_log[i].name == name) {
        self->_event_cursor = self->_event_log.size();
        lua_pushboolean(L, 1);
        return 1;  // already happened, no yield
      }
    }
  }

  // Not yet — set up wait and yield
  double deadline = now() + timeout_ms / 1000.0;
  self->_pending_wait = PendingWait{std::move(names), deadline, false};
  self->_event_cursor = self->_event_log.size();
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
