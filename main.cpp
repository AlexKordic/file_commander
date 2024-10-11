
#include <ftxui/component/component.hpp>
#include <ftxui/component/component_base.hpp>
#include <ftxui/component/screen_interactive.hpp>
#include <ftxui/dom/elements.hpp>  // vbox
#include <ftxui/dom/table.hpp>

#include <ftxui-grid-container/grid-container.hpp>

#include "menu_grid.hpp"

#include "commander.h"
#include "log.hpp"

using namespace ftxui;
using namespace Perun;

#include <boost/filesystem.hpp>

// FTXUI notes

int main() {
  auto cwd = boost::filesystem::current_path();
  l.d("CWD", cwd.native());
  Dir dir;
  dir.refresh(cwd);

  std::vector<std::string> tab_items;
  for (auto& item : dir.items) {
    l.w(item.type == DirItem::Type::directory_file ? "dir" : "file", item.path.filename().native(), {{"t", item.w_time}, {"size", item.size}});
  }
  // https://github.com/ArthurSonzogni/FTXUI/discussions/212
  Component menu = GridMenu(&dir.items, &dir.cursor_pos);
  
  auto screen = ScreenInteractive::Fullscreen();
  Component renderer = Renderer(menu, [&]() {
    return vbox({
      text(cwd.native()) | color(Color::LightGoldenrod2Ter),
      menu->Render() | vscroll_indicator | frame | border
    });
  });
  screen.Loop(renderer);

  return 0;

  // std::string output;

  // Decorator style = size(WIDTH, EQUAL, 5);

  // auto f = [&](const std::string& input) { output += input; };

  // Component button0 = Button("0", [&] { f("0"); }) | style;
  // Component button1 = Button("1", [&] { f("1"); }) | style;
  // Component button2 = Button("2", [&] { f("2"); }) | style;
  // Component button3 = Button("3", [&] { f("3"); }) | style;
  // Component button4 = Button("4", [&] { f("4"); }) | style;
  // Component button5 = Button("5", [&] { f("5"); }) | style;
  // Component button6 = Button("6", [&] { f("6"); }) | style;
  // Component button7 = Button("7", [&] { f("7"); }) | style;
  // Component button8 = Button("8", [&] { f("8"); }) | style;
  // Component button9 = Button("9", [&] { f("9"); }) | style;

  // auto backButton = Button("B",
  //                     [&] {
  //                       if(output.length() != 0) {
  //                         output.pop_back();
  //                       }
  //                     })
  //   | style;

  // Component resetButton = Button("R", [&] { output = ""; }) | style;

  // Component grid = GridContainer({{button1, button2, button3},
  //   {button4, button5, button6},
  //   {button7, button8, button9},
  //   {resetButton, button0, backButton}});

  // Component renderer = Renderer(grid, [&] {
  //   return window(text("keypad") | center,
  //            {
  //              vbox({
  //                text(output) | border,
  //                grid->Render() | center | flex,
  //              }),
  //            })
  //     | size(WIDTH, EQUAL, 30) | center;
  // });

  // screen.Loop(renderer);
}