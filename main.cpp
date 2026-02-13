
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
#include <ftxui/dom/elements.hpp>
#include <ftxui/dom/table.hpp>

#include <cmath>
#include <format>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <utility>

#include <boost/filesystem.hpp>

extern "C" {
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
}

using namespace ftxui;
using namespace Perun;

class Panel;

using TargetFunc = std::function<Filepath(Panel*)>;

using ExecuteOnUiThread = std::function<void(std::function<void()>)>;

class DialogOverlay {
 public:
  Component navigation;
  int       _active_dialog = 0;

 protected:
  ftxui::Dialog::P                        _main_document;     // always rendered, always first child of Panel::container
  Component                               _overlay_renderer;  // selected renderer from _overlay_dialogs, always second child of Panel::container
  std::map<std::string, ftxui::Dialog::P> _overlay_dialogs;

  bool dialog_active() { return _active_dialog > 0; }

  void close_dialog() {
    // Move navigation to main document
    _active_dialog = 0;
    _overlay_renderer.reset();
    // Remove all dialogs, child index > 0
    while (navigation->ChildCount() > 1) { navigation->ChildAt(navigation->ChildCount() - 1)->Detach(); }
  }
  void show_dialog(std::string name) {
    if (!_overlay_dialogs.contains(name)) {
      Perun::l.e("show_dialog() name not registered", name);
      return;
    }
    _active_dialog = 1;
    // Remove all dialogs, child index > 0
    while (navigation->ChildCount() > 1) { navigation->ChildAt(navigation->ChildCount() - 1)->Detach(); }
    // Add proper dialog
    auto dialog = _overlay_dialogs.at(name);
    navigation->Add(dialog->navigation);
    // dialog->container->TakeFocus();
    _overlay_renderer = dialog->renderer;
    // init dialog with input data
    dialog->OnShow();
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

// --- LuaJIT scripting support ---

static int lua_fc_post_event(lua_State* L) {
  const char* event_str = luaL_checkstring(L, 1);
  auto*       screen    = ScreenInteractive::Active();
  if (screen) {
    auto e = event_from_string(std::string(event_str));
    screen->Post(e);
  }
  return 0;
}

static int lua_fc_sleep(lua_State* L) {
  int ms = (int)luaL_checknumber(L, 1);
  std::this_thread::sleep_for(std::chrono::milliseconds(ms));
  return 0;
}

static int lua_fc_quit(lua_State* L) {
  auto* screen = ScreenInteractive::Active();
  if (screen) { screen->Exit(); }
  return 0;
}

static void run_lua_script(const std::string& script_path) {
  // Wait for screen to become active
  for (;;) {
    std::this_thread::sleep_for(std::chrono::milliseconds(16));
    if (ScreenInteractive::Active()) break;
  }

  lua_State* L = luaL_newstate();
  luaL_openlibs(L);

  // Register 'fc' module: fc.post_event(), fc.sleep(), fc.quit()
  lua_newtable(L);
  lua_pushcfunction(L, lua_fc_post_event);
  lua_setfield(L, -2, "post_event");
  lua_pushcfunction(L, lua_fc_sleep);
  lua_setfield(L, -2, "sleep");
  lua_pushcfunction(L, lua_fc_quit);
  lua_setfield(L, -2, "quit");
  lua_setglobal(L, "fc");

  if (luaL_dofile(L, script_path.c_str()) != 0) {
    const char* err = lua_tostring(L, -1);
    file_operations().report_error(std::string("[Lua] ") + (err ? err : "unknown error"));
    auto* screen = ScreenInteractive::Active();
    if (screen) screen->Post(Event::Custom);
    lua_pop(L, 1);
  }
  lua_close(L);
}

// --- end LuaJIT scripting support ---

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

  // Run lua script in background thread if "run script.lua" was specified
  if (lua_mode) {
    std::thread([lua_script_path]() { run_lua_script(lua_script_path); }).detach();
  }

  // screen.TrackMouse(false);

  // NOTE: exec(..) before .Loop() doesnt have effect, because there is no global active screen.
  screen.Loop(app.renderer);

  return 0;
}
