
#include "bfs.hpp"
#include "commander.hpp"
#include "dialogs.hpp"
#include "file_io_jobs.hpp"
#include "file_panel.hpp"
#include "log.hpp"
#include "theme.hpp"

#include <ftxui-grid-container/grid-container.hpp>
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
  RedrawUI                          redraw_ui;
  std::unique_ptr<FileChangeFunnel> update_funnel;
  Perun::FifoQueue<UpdatedFiles>    pending_changes;

  Panel(Filepath location, TargetFunc get_target, ExecuteOnUiThread e, RedrawUI r) : get_target(get_target), run_on_ui(e), redraw_ui(r) {
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
    _overlay_dialogs["Copy"]            = std::make_shared<CopyDialog>(_state, redraw_ui);
    _overlay_dialogs["Move"]            = std::make_shared<Nyi>(_state);
    _overlay_dialogs["Delete"]          = std::make_shared<Nyi>(_state);
    _overlay_dialogs["Find"]            = std::make_shared<Nyi>(_state);
    _overlay_dialogs["NameToClipboard"] = std::make_shared<ToClipboardDialog>(_state);
    _overlay_dialogs["PathToClipboard"] = std::make_shared<ToClipboardDialog>(_state);
  }
  void move_to(Filepath& where) {
    dir.move_to(where);
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
    // clear old updates that don't matter any more
    pending_changes.erase_if([this](const UpdatedFiles& x) -> bool { return true; });
  }
  Element render() {
    // Panel is always shown
    Element document = _main_document->renderer->Render();
    // Overwrite with active dialog
    if (!_overlay_renderer) return document;
    return dbox({
      document,
      _overlay_renderer->Render() | clear_under_colors | center,
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

 private:
  PanelSharedState::P    _state;
  std::shared_ptr<Files> _files;
};

std::string job_type_to_string(JobInstructions::Type type) {
  switch (type) {
  case JobInstructions::Type::COPY: return "COPY";
  case JobInstructions::Type::MOVE: return "MOVE";
  case JobInstructions::Type::DELETE: return "DELETE";
  }
}

struct JobProgressBar {
  Element render() {
    auto  jobinfo = file_operations().get_running_job();
    auto& job     = jobinfo.job;
    if (!job) return text("empty");
    if (job->is_stopped()) return text("stopped");
    std::lock_guard lock(job->_m);
    const bool      current_index_valid = job->_current_item_index >= 0 && job->_current_item_index < job->_items.size();
    if (!current_index_valid) return text("invalid data");
    const DirItem& item = job->_items.at(job->_current_item_index);
    if (!item.symlink_ref()) return text("malformed current item");
    std::string total_info = std::format(" [{:3}] {:5}[{:5}] Mbps {}/{} items ", std::lround(job->_total.percentage), std::lround(job->_total.Mbps), std::lround(job->_total.average_Mbps), job->_current_item_index + 1, job->_items.size());
    std::string curr_info  = std::format(" [{:3}] {:5}Mbps {} ", std::lround(job->_current_item.percentage), std::lround(job->_current_item.Mbps), item.path_ref().native());
    std::string task_info  = std::format(" [{}] [{}] ", jobinfo.queued_jobs, job_type_to_string(job->_type));
    return hbox({
      // TODO: implement DELETE, MOVE
      text(task_info) | theme().progress_operation,
      text("|"),
      bgGaugeLeft(job->_total.percentage / 100, theme().size_gauge_full, theme().size_gauge_empty, text(total_info)) | theme().progress_total,
      text("|"),
      bgGaugeLeft(job->_current_item.percentage / 100, theme().size_gauge_full, theme().size_gauge_empty, text(curr_info)) | xflex_grow | theme().progress_current,
      text("|"),
    });
  }
};

class FileCommander {
 protected:
  Panel          left, right;
  JobProgressBar progress_bar;

 public:
  Component navigation;
  Component renderer;
  FileCommander(Filepath l, Filepath r, ExecuteOnUiThread exec, RedrawUI redraw) : left(l, get_target(), exec, redraw), right(r, get_target(), exec, redraw) {
    auto global_shortcuts = [this](Event event) -> bool {
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
      // Move target to selected dir
      const bool change_right = event == theme().key_target_dir_to_focused_item_right && left.navigation->Focused();
      const bool change_left  = event == theme().key_target_dir_to_focused_item_left && right.navigation->Focused();
      if (change_right) {
        Filepath where = left.focused_dir();
        right.move_to(where);
        return true;
      } else if (change_left) {
        Filepath where = right.focused_dir();
        left.move_to(where);
        return true;
      }
      return false;
    };
    navigation = CatchEvent(Container::Horizontal({left.navigation, right.navigation}), global_shortcuts);
    renderer   = Renderer(navigation, [&]() -> Element {
      // Two panels side by side
      Elements el;
      auto     jobinfo = file_operations().get_running_job();
      if (jobinfo.job) { el.push_back(progress_bar.render()); }
      el.push_back(hbox({left.render() | xflex_grow, right.render() | xflex_grow}) | bgcolor(theme().default_bg) | color(theme().default_fg));
      // TODO: why is this separator required for progress bar to be rendered?
      el.push_back(separatorLight());
      return vbox(std::move(el));
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

int main(int argc, char** argv) {
  // For debugging
  set_console_size(140, 60);

  auto screen = ScreenInteractive::Fullscreen();

  auto cwd        = boost::filesystem::current_path();
  auto left_path  = argc > 1 ? argv[1] : cwd;
  auto right_path = argc > 2 ? argv[2] : cwd;

  auto exec = [&screen](std::function<void()> f) -> void {
    screen.Post(f);
    screen.Post(Event::Custom);
  };
  auto          redraw = [&screen]() -> void { screen.Post(Event::Custom); };
  FileCommander app(left_path, right_path, exec, redraw);

  LogAdapter adapt_logs(screen);

  // screen.TrackMouse(false);
  screen.Loop(app.renderer);

  return 0;
}
