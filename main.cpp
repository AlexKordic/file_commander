
#include <ftxui/component/component.hpp>
#include <ftxui/component/component_base.hpp>
#include <ftxui/dom/elements.hpp>  // vbox, hbox
#include <ftxui/dom/table.hpp>

#include <ftxui-grid-container/grid-container.hpp>

#include "file_panel.hpp"
#include "theme.hpp"

#include "commander.h"
#include "log.hpp"

using namespace ftxui;
using namespace Perun;

#include <boost/filesystem.hpp>

struct Panel {
  Dir       dir;
  Component files;
  Panel() {
    files = FileList(&dir.items, &dir.cursor_pos);
  }
  void move_to(DirItem::P& where) {
    dir.refresh(where);
    // TODO: trigger render
  }

  Element render_header() {
    return text(dir.path.native()) | color(Color::LightGoldenrod2Ter);
  }
  Element render_files() {
    return files->Render() | vscroll_indicator | frame | theme().files_border;
  }
  Element render() {
    // return Renderer(files, [&]() {
      return vbox({render_header(), render_files()});
    // });
  }
};

int main() {
  auto  cwd = boost::filesystem::current_path();
  Panel left, right;
  left.move_to(cwd);
  right.move_to(cwd);
  // Event linkage
  Component both_pannels = Container::Horizontal({left.files, right.files});

  auto screen = ScreenInteractive::Fullscreen();
  // screen.Loop(both_pannels);
  screen.Loop(Renderer(both_pannels, [&]() ->Element {
    return hbox({left.render() | xflex_grow, separatorLight(), right.render() | xflex_grow});
  }));

  return 0;
}