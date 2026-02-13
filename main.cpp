
#include "bfs.hpp"
#include "commander.hpp"
#include "dialogs.hpp"
#include "file_io_jobs.hpp"
#include "file_panel.hpp"
#include "log.hpp"
#include "theme.hpp"

// #include <ftxui-grid-container/grid-container.hpp>
#include <deque>
#include <ftxui/component/component.hpp>
#include <ftxui/component/component_base.hpp>
#include <ftxui/component/component_options.hpp>
#include <ftxui/component/screen_interactive.hpp>
#include <ftxui/component/loop.hpp>
#include <ftxui/dom/elements.hpp>
#include <ftxui/dom/table.hpp>

#include <atomic>
#include <cmath>
#include <format>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <thread>
#include <utility>

#include <boost/filesystem.hpp>

extern "C" {
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
}

using namespace ftxui;
using namespace Perun;

// Global event callback for Lua testing framework (set in Lua init below)
static std::function<void(const std::string&, const std::string&)> g_fire_event;

class Panel;

using TargetFunc = std::function<Filepath(Panel*)>;

using ExecuteOnUiThread = std::function<void(std::function<void()>)>;

class DialogOverlay {
 public:
  Component   navigation;
  int         _active_dialog = 0;
  std::string _active_dialog_name;

  ftxui::Dialog::P get_overlay_dialog(const std::string& name) {
    auto it = _overlay_dialogs.find(name);
    if (it != _overlay_dialogs.end()) return it->second;
    return nullptr;
  }

 protected:
  ftxui::Dialog::P                        _main_document;     // always rendered, always first child of Panel::container
  Component                               _overlay_renderer;  // selected renderer from _overlay_dialogs, always second child of Panel::container
  std::map<std::string, ftxui::Dialog::P> _overlay_dialogs;

  bool dialog_active() { return _active_dialog > 0; }

  void close_dialog() {
    // Move navigation to main document
    _active_dialog = 0;
    _active_dialog_name.clear();
    _overlay_renderer.reset();
    // Remove all dialogs, child index > 0
    while (navigation->ChildCount() > 1) { navigation->ChildAt(navigation->ChildCount() - 1)->Detach(); }
    if (g_fire_event) g_fire_event("dialog_closed", "");
  }
  void show_dialog(std::string name) {
    if (!_overlay_dialogs.contains(name)) {
      Perun::l.e("show_dialog() name not registered", name);
      return;
    }
    _active_dialog = 1;
    _active_dialog_name = name;
    // Remove all dialogs, child index > 0
    while (navigation->ChildCount() > 1) { navigation->ChildAt(navigation->ChildCount() - 1)->Detach(); }
    // Add proper dialog
    auto dialog = _overlay_dialogs.at(name);
    navigation->Add(dialog->navigation);
    // dialog->container->TakeFocus();
    _overlay_renderer = dialog->renderer;
    // init dialog with input data
    dialog->OnShow();
    if (g_fire_event) g_fire_event("dialog_opened", name);
  }
};

class Panel : public DialogOverlay {
 public:
  Dir        dir;
  TargetFunc get_target;

  ExecuteOnUiThread                 run_on_ui;
  std::unique_ptr<FileChangeFunnel> update_funnel;
  Perun::FifoQueue<UpdatedFiles>    pending_changes;

  Panel(Filepath location, TargetFunc get_target, ExecuteOnUiThread e) : get_target(get_target), run_on_ui(e) {
    this->move_to(location);
    _state                      = std::make_shared<PanelSharedState>(&dir);
    navigation                  = Container::Tab({}, &_active_dialog);
    _state->move_to             = [this](Filepath where) { this->move_to(where); };
    _state->action.close_dialog = [this]() { close_dialog(); };
    _state->action.show_dialog  = [this]() {
      _state->action.arguments->target = this->get_target(this);
      show_dialog(_state->action.dialog);
    };
    _files         = std::make_shared<ftxui::Files>(_state);
    _main_document = std::dynamic_pointer_cast<ftxui::Dialog>(_files);
    navigation->Add(_main_document->navigation);
    // register dialogs
    _overlay_dialogs["Mkdir"]           = std::make_shared<MkdirDialog>(_state);
    _overlay_dialogs["Rename"]          = std::make_shared<RenameDialog>(_state);
    _overlay_dialogs["Copy"]            = std::make_shared<CopyDialog>(_state);
    _overlay_dialogs["Move"]            = std::make_shared<MoveDialog>(_state);
    _overlay_dialogs["Delete"]          = std::make_shared<DeleteDialog>(_state);
    _overlay_dialogs["Find"]            = std::make_shared<Nyi>(_state);
    _overlay_dialogs["NameToClipboard"] = std::make_shared<ToClipboardDialog>(_state);
    _overlay_dialogs["PathToClipboard"] = std::make_shared<ToClipboardDialog>(_state);
  }
  void move_to(Filepath& where) {
    // clear old updates that don't matter any more
    pending_changes.erase_if([this](const UpdatedFiles& x) -> bool { return true; });

    Err err = dir.move_to(where);
    if (!err.ok()) {
      file_operations().report_error("[Panel move_to] " + err.steps.front());
      return;
    }
    update_funnel = FileChangeFunnel::create(where, [this](UpdatedFiles changes) {
      // record changes
      pending_changes.push(std::move(changes));
      // schedule apply changes on UI thread
      this->run_on_ui([this]() {
        while (true) {
          UpdatedFiles batch;
          FifoError    err = this->pending_changes.try_pop(batch);
          if (FifoError::OK != err) return;
          this->dir.partial_refresh(std::move(batch));
        }
      });
    });
    if (g_fire_event) g_fire_event("dir_changed", where.native());
  }
  Element render() {
    // Panel is always shown
    Element document = _main_document->renderer->Render();
    // Overwrite with active dialog
    if (!_overlay_renderer) return document;
    return dbox({
      document,
      _overlay_renderer->Render() | yflex | clear_under_colors | center,
    });
  }
  Filepath focused_dir() {
    // get focused item, if its dir return item's path
    auto focused = _state->get_focused_item();
    if (!focused) return dir.path;
    boost::system::error_code ec;
    const bool                isdir = boost::filesystem::is_directory(*focused, ec);
    if (!ec.failed() && isdir) return *focused;
    // dir.path would be root of the shown dir, but we want to support list of files all from different dirs, for ex. search result.
    return focused->parent_path();
  }

  void set_debug_info(std::function<Element()> info) { _files->debug_info = info; }

  PanelSharedState::P get_shared_state() const { return _state; }

 private:
  PanelSharedState::P    _state;
  std::shared_ptr<Files> _files;
};

std::string job_type_to_string(JobInstructions::Type type) {
  switch (type) {
  case JobInstructions::Type::COPY: return "COPY";
  case JobInstructions::Type::MOVE: return "MOVE";
  case JobInstructions::Type::DELETE: return "DELETE";
  default: return "?";
  }
}

struct JobProgressBar {
  Element render() {
    auto  jobinfo = file_operations().get_running_job();
    auto& job     = jobinfo.job;
    if (!job) return text("[Empty]") | theme().progress_operation;
    std::string task_info = std::format(" [{}] [{}] ", jobinfo.queued_jobs, job_type_to_string(job->_type));
    if (job->is_stopped()) return text(task_info + " [Stopped]") | theme().progress_operation;
    std::lock_guard lock(job->_m);
    const bool      current_index_valid = job->_current_item_index >= 0 && job->_current_item_index < job->_items.size();
    if (!current_index_valid) return text(task_info + " [task index invalid]") | theme().progress_operation;
    const DirItem& item        = job->_items.at(job->_current_item_index);
    const int64_t  items_total = job->item_count();

    switch (job->_type) {
    case JobInstructions::Type::COPY: {
      if (!item.symlink_ref()) return text(task_info + " [item target missing]") | theme().progress_operation;
      std::string total_info = std::format(" [{:3}] {:5}[{:5}] Mbps {}/{} items ", std::lround(job->_total.percentage), std::lround(job->_total.Mbps), std::lround(job->_total.average_Mbps), job->_current_item_index + 1, items_total);
      std::string curr_info  = std::format(" [{:3}] {:5}Mbps {} ", std::lround(job->_current_item.percentage), std::lround(job->_current_item.Mbps), item.path_ref().native());
      return hbox({
        // TODO: implement DELETE, MOVE
        text(task_info) | theme().progress_operation,
        text("|"),
        bgGaugeLeft(job->_total.percentage / 100, theme().size_gauge_full, theme().size_gauge_empty, text(total_info)) | theme().progress_total,
        text("|"),
        bgGaugeLeft(job->_current_item.percentage / 100, theme().size_gauge_full, theme().size_gauge_empty, text(curr_info)) | xflex_grow | theme().progress_current,
        text("|"),
      });
    } break;
    case JobInstructions::Type::MOVE: {
      // just _current_item_index is being updated
      float       item_percentage = std::max(0.0, std::min(100.0, job->_current_item_index * 100.0 / items_total));
      std::string count_info      = std::format(" [{:3}] {}/{} items ", std::lround(item_percentage), std::lround(job->_current_item_index), items_total);
      return hbox({
        text(task_info) | theme().progress_operation,
        text("|"),
        bgGaugeLeft(item_percentage / 100, theme().size_gauge_full, theme().size_gauge_empty, text(count_info)) | xflex_grow | theme().progress_current,
        text("|"),
      });
    } break;
    case JobInstructions::Type::DELETE: {
      float       byte_percentage = std::max(0.0, std::min(100.0, 100.0 * job->_bytes_processed / job->_bytes_total));
      float       item_percentage = std::max(0.0, std::min(100.0, job->_current_item_index * 100.0 / items_total));
      std::string byte_info       = std::format(" [{:3}] {}/{} bytes ", std::lround(byte_percentage), std::lround(job->_bytes_processed), std::lround(job->_bytes_total));
      std::string count_info      = std::format(" [{:3}] {}/{} items ", std::lround(item_percentage), std::lround(job->_current_item_index), items_total);
      return hbox({
        // TODO: implement DELETE, MOVE
        text(task_info) | theme().progress_operation,
        text("|"),
        bgGaugeLeft(item_percentage / 100, theme().size_gauge_full, theme().size_gauge_empty, text(byte_info)) | theme().progress_total,
        text("|"),
        bgGaugeLeft(byte_percentage / 100, theme().size_gauge_full, theme().size_gauge_empty, text(count_info)) | xflex_grow | theme().progress_current,
        text("|"),
      });
    }
    }
  }
};

class FileCommander : public DialogOverlay {
 protected:
  Panel              left, right;
  JobProgressBar     progress_bar;
  std::deque<double> clear_errors_sequence;

  std::function<void()> _close_dialog;
  std::function<int()>  _get_dimx;

 public:
  int       _left_size   = 20;
  int       _screen_dimx = 0;
  Component renderer;

  Panel& get_left() { return left; }
  Panel& get_right() { return right; }

  FileCommander(Filepath l, Filepath r, ExecuteOnUiThread exec, std::function<int()> dimx) : left(l, get_target(), exec), right(r, get_target(), exec), _get_dimx(dimx) {
    _close_dialog         = [this]() { close_dialog(); };
    auto global_shortcuts = [this](Event event) -> bool { return this->handle_global_shortcuts(event); };
    // Overlay dialogs on top of main document:
    // + errors - fullscreen
    // - commands - top, expands as needed
    // - tasks - fullscreen

    left.set_debug_info([]() -> Element { return screen_render_time(); });

    navigation = Container::Tab({}, &_active_dialog);

    // NOTE: When ResizableSplitRight, which is a Component, is used it expects components having .Render() as children.
    //       So we need to combine navigation with its render, like so:
    Component            left_combined  = Renderer(left.navigation, [this]() -> Element { return left.render(); });
    Component            right_combined = Renderer(right.navigation, [this]() -> Element { return right.render(); });
    ResizableSplitOption split;
    split.back            = left_combined;
    split.main            = right_combined;
    split.main_size       = &(this->_left_size);
    split.direction       = ftxui::Direction::Right;
    split.separator_func  = [this]() -> Element { return ::ftxui::separatorDouble(); };
    Component both_panels = CatchEvent(ResizableSplit(split), global_shortcuts);

    navigation->Add(both_panels);
    _overlay_dialogs["ErrorList"] = std::make_shared<ErrorListDialog>(_close_dialog);
    renderer                      = Renderer(navigation, [=, this]() -> Element {
      // TODO: different when single panel layout is active
      // check for resize:
      int screen_w = _get_dimx();
      if (screen_w != _screen_dimx) {
        _screen_dimx = screen_w;
        _left_size   = screen_w / 2;
      }

      Elements el;
      auto     jobinfo = file_operations().get_running_job();
      // Two panels side by side
      // el.push_back(hbox({left.render() | xflex_grow, right.render() | xflex_grow}) | yflex | bgcolor(theme().default_bg) | color(theme().default_fg));
      el.push_back(both_panels->Render() | yflex | bgcolor(theme().default_bg) | color(theme().default_fg));
      // Progress bar if there is a job running
      if (jobinfo.job && false == jobinfo.job->is_stopped()) { el.push_back(progress_bar.render()); }
      // Quick preview of latest errors
      auto errors = file_operations().get_errors(theme().max_errors_to_show);
      for (auto& x : errors) { el.push_back(text(" 咎 " + x.message) | theme().recent_error); }
      Element document = vbox(std::move(el));
      if (!_overlay_renderer) return document;
      return dbox({document, _overlay_renderer->Render() | yflex | clear_under_colors | hcenter});
    });
  }
  // returns
  TargetFunc get_target() {
    return [this](Panel* self) -> Filepath {
      // self is origin pannel, return target panel's path
      if (self == &left) return right.dir.path;
      if (self == &right) return left.dir.path;
      l.e("FileCommander::get_target", "unknown self");
      return left.dir.path;
    };
  }


  bool handle_global_shortcuts(Event event) {
    // if (event == Event::Special("startup")) {
    //   handle_pending_commandline_events();
    //   return true;
    // }

    if (event == theme().key_toggle_error_details && !dialog_active()) {
      show_dialog("ErrorList");
      return true;
    }

    if (event == theme().key_clear_errors) {
      clear_errors_sequence.emplace_front(now());
      while (clear_errors_sequence.size() > theme().clear_errors_command_repeat_count) { clear_errors_sequence.pop_back(); }
      const double sequence_interval = clear_errors_sequence.front() - clear_errors_sequence.back();
      const bool   full_sequence     = clear_errors_sequence.size() >= theme().clear_errors_command_repeat_count;
      const bool   in_time_window    = sequence_interval < theme().clear_errors_command_sequence;
      if (full_sequence && in_time_window) {
        auto seq = clear_errors_sequence;
        file_operations().clear_errors();
        clear_errors_sequence.clear();
        return true;
      }
      // we let this event through when it's not a full sequence or it's not in time window
    } else {
      clear_errors_sequence.clear();
    }

    // Tab between panels
    if (event == theme().key_switch_focused_panel) {
      // switch focus to target pannel
      if (left.navigation->Focused()) {
        right.navigation->TakeFocus();
      } else {
        left.navigation->TakeFocus();
      }
      return true;
    }
    if (event == theme().key_refresh_dir) {
      if (left.navigation->Focused()) {
        left.dir.refresh();
      } else {
        right.dir.refresh();
      }
      return true;
    }
    // Move target to selected dir.
    // Do not apply if dialog is active on the source panel. When rename is open we want ctrl+right/left to move cursor by entire word.
    const bool change_right = event == theme().key_target_dir_to_focused_item_right && left.navigation->Focused();
    const bool change_left  = event == theme().key_target_dir_to_focused_item_left && right.navigation->Focused();
    if (change_right) {
      const bool dialog_active = left._active_dialog > 0;
      if (dialog_active) return false;
      Filepath where = left.focused_dir();
      right.move_to(where);
      return true;
    } else if (change_left) {
      const bool dialog_active = right._active_dialog > 0;
      if (dialog_active) return false;
      Filepath where = right.focused_dir();
      left.move_to(where);
      return true;
    }
    return false;
  }
};

// cache logs issued in current screen loop, and flush them at the end of screen loop
class LogAdapter {
 public:
  explicit LogAdapter(ScreenInteractive& screen) {
    print_log  = l.produce;
    flush_logs = screen.WithRestoredIO([&] {
      printing = false;
      for (const auto& x : log_queue) { print_log(x.first, x.second); }
      log_queue.clear();
    });
    l.produce  = [this, &screen](std::string const& txt, const char level) {
      log_queue.push_back(std::make_pair(txt, level));
      if (printing == false) {
        printing = true;
        screen.Post(flush_logs);
      }
    };
  }
  ~LogAdapter() {
    l.produce = print_log;
    for (const auto& x : log_queue) { print_log(x.first, x.second); }
  }

 protected:
  bool printing = false;

  std::vector<std::pair<std::string, char>>                     log_queue;
  std::function<void(std::string const& txt, const char level)> print_log;
  std::function<void()>                                         flush_logs;
};

#include <iostream>

void set_console_size(int width, int height) { std::cout << "\e[8;" << height << ";" << width << "t"; }

// =====================================================================
// LuaJIT testing framework — same-thread, coroutine-based
// =====================================================================

// --- Debug logging for Lua framework ---
static FILE* g_lua_log = nullptr;
static void lua_log(const char* msg) {
  if (!g_lua_log) g_lua_log = fopen("/tmp/fc_lua_debug.log", "w");
  if (g_lua_log) { fprintf(g_lua_log, "%s\n", msg); fflush(g_lua_log); }
}

// --- Global state accessible to Lua C functions ---
static FileCommander* g_app  = nullptr;
static Component      g_root = nullptr;  // app.renderer — for OnEvent dispatch
static lua_State*     g_lua  = nullptr;  // main Lua state (owns everything)
static lua_State*     g_lua_co = nullptr;  // coroutine running the test script
static bool           g_lua_finished = false;

// --- Event log ---
struct LuaEvent {
  std::string name;
  double      timestamp;
  std::string detail;
};
static std::deque<LuaEvent> g_event_log;
static size_t               g_event_cursor = 0;  // position in log when wait started

static void fire_event(const std::string& name, const std::string& detail = "") {
  g_event_log.push_back({name, now(), detail});
}

// --- Pending wait (for fc.wait_event / fc.sleep) ---
struct PendingWait {
  std::vector<std::string> event_names;
  double                   deadline;
  bool                     sleep_mode = false;  // true => deadline is success (sleep), false => deadline is timeout
};
static std::optional<PendingWait> g_pending_wait;

// --- Poll timer: posts Event::Custom periodically while a Lua wait is pending ---
static std::atomic<bool> g_poll_active{false};

static void start_lua_poll_timer() {
  if (g_poll_active.exchange(true)) return;
  std::thread([]() {
    while (g_poll_active) {
      std::this_thread::sleep_for(std::chrono::milliseconds(50));
      auto* screen = ScreenInteractive::Active();
      if (screen) screen->Post(Event::Custom);
    }
  }).detach();
}

static void stop_lua_poll_timer() { g_poll_active = false; }

// --- Poll async events (job completion, discovery) ---
// These originate on worker threads; we detect them by polling on the UI thread.
static bool g_had_running_job = false;
static bool g_had_discovery   = false;

static int    g_poll_count = 0;
static double g_last_job_finished_time = -1;
static double g_last_job_started_time  = -1;

static void poll_async_events() {
  g_poll_count++;
  // Job start/completion — detect by timestamps to avoid missing fast jobs
  auto jobinfo = file_operations().get_running_job();
  if (jobinfo.job) {
    // Detect job start
    if (jobinfo.job->_started_time > 0 && jobinfo.job->_started_time != g_last_job_started_time) {
      g_last_job_started_time = jobinfo.job->_started_time;
      lua_log("poll: job_started");
      fire_event("job_started", "");
    }
    // Detect job completion
    if (jobinfo.job->_finished_time > 0 && jobinfo.job->_finished_time != g_last_job_finished_time) {
      g_last_job_finished_time = jobinfo.job->_finished_time;
      lua_log("poll: job_completed");
      fire_event("job_completed", "");
    }
    g_had_running_job = !jobinfo.job->is_stopped();
  } else {
    g_had_running_job = false;
  }

  // Copy discovery completion — check both panels
  bool discovery_running = false;
  bool has_discovery = false;
  if (g_app) {
    for (auto* panel : {&g_app->get_left(), &g_app->get_right()}) {
      auto copy_dlg = std::dynamic_pointer_cast<CopyDialog>(panel->get_overlay_dialog("Copy"));
      if (copy_dlg && copy_dlg->_discovery_process) {
        has_discovery = true;
        if (copy_dlg->_discovery_process->_running) {
          discovery_running = true;
        }
      }
    }
  }
  if (g_poll_count <= 5 || (g_poll_count % 20 == 0)) {
    lua_log(("poll #" + std::to_string(g_poll_count) + ": has_disc=" + std::to_string(has_discovery) + " disc_run=" + std::to_string(discovery_running) + " had_disc=" + std::to_string(g_had_discovery)).c_str());
  }
  if (g_had_discovery && !discovery_running) {
    lua_log("poll: discovery_completed");
    fire_event("discovery_completed", "");
  }
  g_had_discovery = discovery_running;
}

// --- Handle Lua coroutine resume status ---
static void handle_lua_resume_status(int status) {
  if (status == 0) {
    // Coroutine finished normally
    g_lua_finished = true;
    stop_lua_poll_timer();
  } else if (status == LUA_YIELD) {
    // Coroutine yielded (waiting for event or sleeping)
  } else {
    // Error
    const char* err = lua_tostring(g_lua_co, -1);
    file_operations().report_error(std::string("[Lua] ") + (err ? err : "unknown error"));
    g_lua_finished = true;
    stop_lua_poll_timer();
    // Post Custom to refresh error display
    auto* screen = ScreenInteractive::Active();
    if (screen) screen->Post(Event::Custom);
  }
}

// --- Check pending Lua waits and resume coroutine if condition met ---
static void check_lua_waits() {
  if (!g_pending_wait || g_lua_finished) return;

  // Poll for async events
  poll_async_events();

  // Check event log for match (only if we have event names to match)
  if (!g_pending_wait->event_names.empty()) {
    for (size_t i = g_event_cursor; i < g_event_log.size(); i++) {
      for (auto& name : g_pending_wait->event_names) {
        if (g_event_log[i].name == name) {
          // Match! Resume coroutine with true
          g_pending_wait.reset();
          g_event_cursor = g_event_log.size();
          stop_lua_poll_timer();
          lua_pushboolean(g_lua_co, 1);
          int status = lua_resume(g_lua_co, 1);
          handle_lua_resume_status(status);
          return;
        }
      }
    }
    g_event_cursor = g_event_log.size();
  }

  // Check deadline
  if (now() > g_pending_wait->deadline) {
    bool was_sleep = g_pending_wait->sleep_mode;
    g_pending_wait.reset();
    stop_lua_poll_timer();
    if (was_sleep) {
      // Sleep completed — resume with no return value
      int status = lua_resume(g_lua_co, 0);
      handle_lua_resume_status(status);
    } else {
      // Timeout — resume with nil
      lua_pushnil(g_lua_co);
      int status = lua_resume(g_lua_co, 1);
      handle_lua_resume_status(status);
    }
  }
}

// =====================================================================
// Lua C functions registered in the 'fc' table
// =====================================================================

// fc.key(name_or_table) — dispatch key event or action, synchronous
static int lua_fc_key(lua_State* L) {
  if (!g_root) return luaL_error(L, "fc not initialized");
  // Handle table argument: process each element
  if (lua_istable(L, 1)) {
    int n = (int)lua_objlen(L, 1);
    for (int i = 1; i <= n; i++) {
      lua_rawgeti(L, 1, i);
      const char* name = luaL_checkstring(L, -1);
      size_t      len  = strlen(name);
      if (len == 1) {
        g_root->OnEvent(Event::Character(name[0]));
      } else {
        g_root->OnEvent(event_from_string(std::string(name)));
      }
      lua_pop(L, 1);
    }
    return 0;
  }
  // Single string argument
  const char* name = luaL_checkstring(L, 1);
  size_t      len  = strlen(name);
  if (len == 1) {
    g_root->OnEvent(Event::Character(name[0]));
  } else {
    // len >= 2: use event_from_string (covers "f5", "cA", "up", "esc", "ret", "tab", etc.)
    // TODO: when action registry is implemented, try action lookup first for len >= 3
    g_root->OnEvent(event_from_string(std::string(name)));
  }
  return 0;
}

// fc.quit() — exit the application (uses _exit for clean termination in test mode,
// since FTXUI's EventListener blocks on stdin when backgrounded)
static int lua_fc_quit(lua_State* L) {
  lua_log("fc.quit() called");
  stop_lua_poll_timer();
  if (g_lua_log) { fclose(g_lua_log); g_lua_log = nullptr; }
  _exit(0);
  return 0;
}

// fc.left_cd(path) — navigate left panel to given path
static int lua_fc_left_cd(lua_State* L) {
  if (!g_app) return luaL_error(L, "fc not initialized");
  auto path = boost::filesystem::path(luaL_checkstring(L, 1));
  g_app->get_left().move_to(path);
  return 0;
}

// fc.right_cd(path) — navigate right panel to given path
static int lua_fc_right_cd(lua_State* L) {
  if (!g_app) return luaL_error(L, "fc not initialized");
  auto path = boost::filesystem::path(luaL_checkstring(L, 1));
  g_app->get_right().move_to(path);
  return 0;
}

// fc.left_path() — returns left panel directory path
static int lua_fc_left_path(lua_State* L) {
  if (!g_app) return luaL_error(L, "fc not initialized");
  lua_pushstring(L, g_app->get_left().dir.path.native().c_str());
  return 1;
}

// fc.right_path() — returns right panel directory path
static int lua_fc_right_path(lua_State* L) {
  if (!g_app) return luaL_error(L, "fc not initialized");
  lua_pushstring(L, g_app->get_right().dir.path.native().c_str());
  return 1;
}

// Helper: get the focused panel (the one whose navigation is focused)
static Panel& get_focused_panel() {
  if (g_app->get_left().navigation->Focused()) return g_app->get_left();
  return g_app->get_right();
}

// fc.focused() — returns focused file path in the active panel
static int lua_fc_focused(lua_State* L) {
  if (!g_app) return luaL_error(L, "fc not initialized");
  auto& panel   = get_focused_panel();
  auto  focused = panel.get_shared_state()->get_focused_item();
  if (focused) {
    lua_pushstring(L, focused->native().c_str());
  } else {
    lua_pushnil(L);
  }
  return 1;
}

// fc.selected() — returns table of selected file paths in the active panel
static int lua_fc_selected(lua_State* L) {
  if (!g_app) return luaL_error(L, "fc not initialized");
  auto& panel = get_focused_panel();
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

// fc.errors() — returns table of error messages
static int lua_fc_errors(lua_State* L) {
  auto errors = file_operations().get_errors(9999);
  lua_newtable(L);
  int idx = 1;
  for (auto& e : errors) {
    lua_pushstring(L, e.message.c_str());
    lua_rawseti(L, -2, idx++);
  }
  return 1;
}

// Helper: push a panel state subtable onto the Lua stack
static void push_panel_state(lua_State* L, Panel& panel) {
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

// fc.state() — returns full state snapshot
static int lua_fc_state(lua_State* L) {
  if (!g_app) return luaL_error(L, "fc not initialized");
  lua_newtable(L);  // root table

  // left panel
  push_panel_state(L, g_app->get_left());
  lua_setfield(L, -2, "left");

  // right panel
  push_panel_state(L, g_app->get_right());
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

// fc.wait_event(name_or_table, timeout_ms) — yield coroutine until event or timeout
static int lua_fc_wait_event(lua_State* L) {
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
  poll_async_events();

  // Check if event already in log since last cursor position
  for (size_t i = g_event_cursor; i < g_event_log.size(); i++) {
    for (auto& name : names) {
      if (g_event_log[i].name == name) {
        g_event_cursor = g_event_log.size();
        lua_pushboolean(L, 1);
        return 1;  // already happened, no yield
      }
    }
  }

  // Not yet — set up wait and yield
  g_pending_wait = PendingWait{std::move(names), now() + timeout_ms / 1000.0, false};
  g_event_cursor = g_event_log.size();
  start_lua_poll_timer();
  return lua_yield(L, 0);
}

// fc.sleep(ms) — yield coroutine for N milliseconds
static int lua_fc_sleep(lua_State* L) {
  int ms = (int)luaL_checknumber(L, 1);
  g_pending_wait = PendingWait{{}, now() + ms / 1000.0, true};
  start_lua_poll_timer();
  return lua_yield(L, 0);
}

// =====================================================================
// Lua state setup
// =====================================================================

static void setup_lua_state(const std::string& script_path, ScreenInteractive& screen) {
  lua_log("setup_lua_state: start");
  g_lua = luaL_newstate();
  luaL_openlibs(g_lua);

  // Register 'fc' table with C functions
  lua_newtable(g_lua);
  // clang-format off
  auto reg = [](const char* name, lua_CFunction fn) {
    lua_pushcfunction(g_lua, fn);
    lua_setfield(g_lua, -2, name);
  };
  reg("key",        lua_fc_key);
  reg("quit",       lua_fc_quit);
  reg("left_cd",    lua_fc_left_cd);
  reg("right_cd",   lua_fc_right_cd);
  reg("left_path",  lua_fc_left_path);
  reg("right_path", lua_fc_right_path);
  reg("focused",    lua_fc_focused);
  reg("selected",   lua_fc_selected);
  reg("errors",     lua_fc_errors);
  reg("state",      lua_fc_state);
  reg("wait_event", lua_fc_wait_event);
  reg("sleep",      lua_fc_sleep);
  // clang-format on
  lua_setglobal(g_lua, "fc");

  // Wire up the event callback
  g_fire_event = fire_event;

  lua_log("setup_lua_state: loading framework");
  // Load framework Lua code
  if (luaL_dofile(g_lua, "fc_framework.lua") != 0) {
    const char* err = lua_tostring(g_lua, -1);
    std::string msg = std::string("[Lua framework] ") + (err ? err : "unknown error");
    lua_log(msg.c_str());
    file_operations().report_error(msg);
    lua_pop(g_lua, 1);
    return;
  }
  lua_log("setup_lua_state: framework loaded OK");

  // Create coroutine and load the test script
  g_lua_co = lua_newthread(g_lua);
  lua_log(("setup_lua_state: loading script " + script_path).c_str());
  if (luaL_loadfile(g_lua_co, script_path.c_str()) != 0) {
    const char* err = lua_tostring(g_lua_co, -1);
    std::string msg = std::string("[Lua load] ") + (err ? err : "unknown error");
    lua_log(msg.c_str());
    file_operations().report_error(msg);
    return;
  }
  lua_log("setup_lua_state: script loaded, ready for initial resume");
  // NOTE: Cannot screen.Post() here — task_sender_ is null before screen.Loop().
  // The initial resume is triggered by the CatchEvent handler on the first event.
}

// =====================================================================
// End LuaJIT testing framework
// =====================================================================

int main(int argc, char** argv) {
  // For debugging
  // set_console_size(140, 60);
  // -------------

  auto screen = ScreenInteractive::Fullscreen();

  // for (int i = 0; i < 50; ++i) {
  //   file_operations().report_error("[DBG] " + std::to_string(i) + " INITIAL single line item");
  // }
  // std::thread([&]() {
  //   for (int i = 0; true; ++i) {
  //     std::this_thread::sleep_for(std::chrono::seconds(1));
  //     file_operations().report_error("[LIVE DBG] " + std::to_string(i) + " single line item");
  //     screen.Post(Event::Custom);
  //   }
  // }).detach();

  auto cwd = boost::filesystem::current_path();

  // Check for "run script.lua" mode
  const bool        lua_mode = argc > 2 && std::string(argv[1]) == "run";
  const std::string lua_script_path = lua_mode ? argv[2] : "";

  auto left_path  = (!lua_mode && argc > 1) ? boost::filesystem::path(argv[1]) : cwd;
  auto right_path = (!lua_mode && argc > 2) ? boost::filesystem::path(argv[2]) : cwd;

  auto exec = [&screen](std::function<void()> f) -> void {
    screen.Post(f);
    screen.Post(Event::Custom);
  };
  // auto          redraw = [&screen]() -> void { screen.Post(Event::Custom); };
  auto          dimx = [&screen]() -> int { return screen.dimx(); };
  FileCommander app(left_path, right_path, exec, dimx);

  LogAdapter adapt_logs(screen);

  // Set up globals for Lua access
  g_app  = &app;
  g_root = app.renderer;

  screen.TrackMouse(false);

  if (lua_mode) {
    // Set up Lua state with same-thread coroutine execution
    setup_lua_state(lua_script_path, screen);
    // Wrap the renderer with a CatchEvent that checks Lua waits after every event.
    // Also triggers the initial coroutine resume on the first event (since screen.Post
    // doesn't work before the event loop starts — task_sender_ is null until Install).
    bool lua_started = false;
    auto lua_wrapper = CatchEvent(app.renderer, [&lua_started](Event e) -> bool {
      if (!lua_started && g_lua_co) {
        lua_started = true;
        lua_log("first event: starting Lua coroutine");
        int status = lua_resume(g_lua_co, 0);
        lua_log(("first event: resume status = " + std::to_string(status)).c_str());
        handle_lua_resume_status(status);
      }
      check_lua_waits();
      return false;  // don't consume — forward event to app.renderer
    });
    // NOTE: exec(..) before .Loop() doesnt have effect, because there is no global active screen.
    screen.Loop(lua_wrapper);
    // Cleanup Lua state
    if (g_lua) { lua_close(g_lua); g_lua = nullptr; }
    stop_lua_poll_timer();
  } else {
    // Normal mode — no Lua
    // NOTE: exec(..) before .Loop() doesnt have effect, because there is no global active screen.

    // old: screen.Loop(app.renderer);
    ftxui::Loop loop(&screen, app.renderer);
    while(!loop.HasQuitted()) {
      loop.RunOnceBlocking();
      // Now do lua scripting actions

    }
  }

  return 0;
}
