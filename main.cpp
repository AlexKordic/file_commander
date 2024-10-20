
#include <condition_variable>
#include <ftxui-grid-container/grid-container.hpp>
#include <ftxui/component/component.hpp>
#include <ftxui/component/component_base.hpp>
#include <ftxui/component/component_options.hpp>
#include <ftxui/dom/elements.hpp>  // vbox, hbox
#include <ftxui/dom/table.hpp>

#include <iostream>
#include <memory>
#include <mutex>
#include <string>

#include "file_panel.hpp"
#include "theme.hpp"

#include "commander.h"
#include "log.hpp"

using namespace ftxui;
using namespace Perun;

#include <boost/filesystem.hpp>

class Panel {
 public:
  Dir       dir;
  Component container;

  Panel() {
    auto opt      = InputOption::Default();
    opt.multiline = false;
    opt.transform = [](InputState state) {
      if (state.is_placeholder) {
        return state.element | theme().files_path;
      } else {
        return state.element | theme().files_filter_search;
      }
    };
    filter    = Input(&filter_txt, &dir_path, opt);
    files     = FileList(&dir, filter, &filter_txt);
    sort_name = Button("Name", [&] { dir.sort_toggle_name_direction(); }, ButtonOption::Ascii());
    sort_size = Button("Size", [&] { dir.sort_toggle_size_direction(); }, ButtonOption::Ascii());
    sort_time = Button("Date", [&] { dir.sort_toggle_time_direction(); }, ButtonOption::Ascii());
    container = Container::Vertical({Container::Horizontal({sort_name, sort_size, sort_time}), files});
    files->TakeFocus();
  }
  void move_to(DirItem::P& where) {
    dir.move_to(where);
    dir_path = dir.path.native();
    // TODO: trigger render
  }
  Element render() { return vbox({render_header(), render_selection(), render_files()}); }

 private:
  Component   files;
  Component   filter;
  std::string dir_path, filter_txt;
  Component   sort_name, sort_size, sort_time;

  // rendering
  Element render_header() { return filter->Render() | ftxui::focus | ftxui::select; }
  Element render_files() { return files->Render() | vscroll_indicator | yframe | theme().files_border; }
  Element render_selection() {
    std::string prefixes[3] = {"  ", "  ", "  "};
    switch (dir.order_by) {
    case Orderby::NAME_ASC: prefixes[0] = "↑↑"; break;
    case Orderby::NAME_DESC: prefixes[0] = "↓↓"; break;
    case Orderby::SIZE_ASC: prefixes[1] = "↑↑"; break;
    case Orderby::SIZE_DESC: prefixes[1] = "↓↓"; break;
    case Orderby::TIME_ASC: prefixes[2] = "↑↑"; break;
    case Orderby::TIME_DESC: prefixes[2] = "↓↓"; break;
    }
    auto     s        = dir.stats();
    Elements children = {
      text("sel " + std::to_string(s.items_selected) + "/" + std::to_string(s.items_total)), text(" bytes "), coloredInt(s.bytes_selected), text("/"), coloredInt(s.bytes_total), text(" | "), text(prefixes[0]), sort_name->Render(), text(prefixes[1]), sort_size->Render(), text(prefixes[2]), sort_time->Render(),
    };
    return hbox(std::move(children));
  }
};

#include <ftxui/screen/terminal.hpp>

int main() {
  auto  cwd = boost::filesystem::current_path();
  Panel left, right;
  left.move_to(cwd);
  right.move_to(cwd);
  // Event linkage
  Component both_pannels = Container::Horizontal({left.container, right.container});

  auto screen = ScreenInteractive::Fullscreen();

  // std::mutex               log_m;
  // std::condition_variable  log_cond;
  std::vector<std::string> log_queue;
  // volatile bool            log_thread_running = true;
  // std::thread t([&] {
  //   while (log_thread_running) {
  //     {
  //       std::unique_lock l(log_m);
  //       if (log_queue.empty()) {
  //         log_cond.wait(l);
  //         continue;
  //       }
  //     }
  //     std::this_thread::sleep_for(std::chrono::milliseconds(60));
  //     std::vector<std::string> to_print;
  //     {
  //       std::lock_guard l(log_m);
  //       to_print = std::move(log_queue);
  //       log_queue.clear();
  //     }
  //     screen.WithRestoredIO(Closure);
  //     for(const std::string& s : to_print) {

  //     }
  //   }
  // });

  bool notified   = false;
  auto print_log  = l.produce;
  auto flush_logs = screen.WithRestoredIO([&] {
    auto terminal = Terminal::Size();
    notified      = false;
    // screen.ResetCursorPosition();
    // screen.SetCursorPosition();
    for (const std::string& s : log_queue) { print_log(s, 'd'); }
    // std::cout << std::endl;
    // std::this_thread::sleep_for(std::chrono::milliseconds(1000));
    log_queue.clear();
    // screen.PostEvent(Event::Custom);
  });
  l.produce       = [&](std::string const& txt, const char level) {
    log_queue.push_back(txt);
    if (notified == false) {
      notified = true;
      screen.Post(flush_logs);
    }
  };
  // screen.TrackMouse(false);
  screen.Loop(Renderer(both_pannels, [&]() -> Element { return hbox({left.render() | xflex_grow, separatorLight(), right.render() | xflex_grow}); }));

  return 0;
}
