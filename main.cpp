
#include <ftxui-grid-container/grid-container.hpp>
#include <ftxui/component/component.hpp>
#include <ftxui/component/component_base.hpp>
#include <ftxui/component/component_options.hpp>
#include <ftxui/component/screen_interactive.hpp>
#include <ftxui/dom/elements.hpp>
#include <ftxui/dom/table.hpp>

#include <functional>
#include <memory>
#include <string>
#include <utility>

#include "commander.h"
#include "dialogs.hpp"
#include "log.hpp"

#include <boost/filesystem.hpp>

using namespace ftxui;
using namespace Perun;

class Panel;

using TargetFunc = std::function<DirItem::P(Panel*)>;

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

  explicit Panel(DirItem::P location, TargetFunc get_target) : get_target(get_target) {
    dir.move_to(location);
    state                      = std::make_shared<PanelSharedState>(&dir);
    navigation                  = Container::Tab({}, &_active_dialog);
    state->action.close_dialog = [this]() { close_dialog(); };
    state->action.show_dialog  = [this]() {
      state->action.arguments->target = this->get_target(this);
      show_dialog(state->action.dialog);
    };
    auto files = std::make_shared<ftxui::Files>(state);
    _main_document = std::dynamic_pointer_cast<ftxui::Dialog>(files);
    navigation->Add(_main_document->navigation);
    // register dialogs
    _overlay_dialogs["Mkdir"]           = std::make_shared<MkdirDialog>(state);
    _overlay_dialogs["Rename"]          = std::make_shared<RenameDialog>(state);
    _overlay_dialogs["Copy"]            = std::make_shared<Nyi>(state);
    _overlay_dialogs["Move"]            = std::make_shared<Nyi>(state);
    _overlay_dialogs["Delete"]          = std::make_shared<Nyi>(state);
    _overlay_dialogs["Find"]            = std::make_shared<Nyi>(state);
    _overlay_dialogs["NameToClipboard"] = std::make_shared<ToClipboardDialog>(state);
    _overlay_dialogs["PathToClipboard"] = std::make_shared<ToClipboardDialog>(state);
  }
  void    move_to(DirItem::P& where) { dir.move_to(where); }
  Element render() {
    // Panel is always shown
    Element document = _main_document->renderer->Render();
    // Overwrite with active dialog
    if (!_overlay_renderer) return document;
    return dbox({
      document,
      _overlay_renderer->Render() | clear_under | center,
    });
  }

 private:
  PanelSharedState::P state;
};

class FileCommander {
 protected:
  Panel left, right;

 public:
  Component navigation;
  Component renderer;
  FileCommander(DirItem::P location) : left(location, get_target()), right(location, get_target()) {
    navigation = Container::Horizontal({left.navigation, right.navigation});
    renderer  = Renderer(navigation, [&]() -> Element {
      // Two panels side by side
      return hbox({left.render() | xflex_grow, separatorLight(), right.render() | xflex_grow});
    });
  }
  // returns
  TargetFunc get_target() {
    return [this](Panel* self) -> DirItem::P {
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

int main() {
  auto          cwd = boost::filesystem::current_path();
  FileCommander app(cwd);

  auto       screen = ScreenInteractive::Fullscreen();
  LogAdapter adapt_logs(screen);

  // screen.TrackMouse(false);
  screen.Loop(app.renderer);

  return 0;
}
