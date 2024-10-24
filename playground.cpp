// Copyright 2020 Arthur Sonzogni. All rights reserved.
// Use of this source code is governed by the MIT license that can be found in
// the LICENSE file.
#include <ftxui/dom/linear_gradient.hpp>  // for LinearGradient
#include <ftxui/screen/color.hpp>         // for Color, Color::White, Color::Red, Color::Blue, Color::Black, Color::GrayDark, ftxui
#include <functional>                     // for function
#include <string>                         // for allocator, string
#include <utility>                        // for move

#include "ftxui/component/component.hpp"           // for Input, Horizontal, Vertical, operator|
#include "ftxui/component/component_base.hpp"      // for Component
#include "ftxui/component/component_options.hpp"   // for InputState, InputOption
#include "ftxui/component/screen_interactive.hpp"  // for ScreenInteractive
#include "ftxui/dom/elements.hpp"                  // for operator|=, Element, bgcolor, operator|, separatorEmpty, color, borderEmpty, separator, text, center, dim, hbox, vbox, border, borderDouble, borderRounded

namespace ftxui {

// Helper class.
class NodeDecorator : public Node {
 public:
  explicit NodeDecorator(Element child) : Node({std::move(child)}) {}
  void ComputeRequirement() override {
    Node::ComputeRequirement();
    requirement_ = children_[0]->requirement();
  }
  void SetBox(Box box) override {
    Node::SetBox(box);
    children_[0]->SetBox(box);
  }
};

class ShowInputCursor : public NodeDecorator {
 public:
  ShowInputCursor(Element child, Ref<int> cursor_position) : NodeDecorator(std::move(child)), _cursor_position(cursor_position) { }

  void Render(Screen& screen) override {
    const bool draw_cursor = true;
    // TODO: animate blinking by toggling draw_cursor
    if(draw_cursor) {
      int x = std::max(1, std::min(box_.x_max, _cursor_position() +1));
      for (int y = box_.y_min; y <= box_.y_max; ++y) {
        screen.PixelAt(x, y).inverted = true; 
      }
    }
    NodeDecorator::Render(screen);
  }

  Ref<int> _cursor_position;
};

Element showInputCursor(Element child, Ref<int> cursor_position) {
  return std::make_shared<ShowInputCursor>(std::move(child), cursor_position);
}
Decorator showInputCursor(Ref<int> cursor_position) {
  return [cursor_position](Element child)-> Element{
    return showInputCursor(std::move(child), cursor_position);
  };
}

}

using namespace ftxui;

struct Item{
  std::string content;
  int         cursor_position = 0;

  Item(const char * s) : content(s) {}
};

int main() { 
  // Lines we want to display, each in its own Input
  std::vector<Item> lines = {
    R"(#include ftxui/component/captured_mouse.hpp"  // for ftxui)",
    R"(#include ftxui/component/component.hpp"  // for Radiobox, Vertical, Checkbox, Horizontal, Renderer, ResizableSplitBottom, ResizableSplitRight)",
    R"(#include ftxui/component/component_base.hpp"      // for ComponentBase)",
    R"(#include ftxui/component/screen_interactive.hpp"  // for ScreenInteractive)",
    R"(#include ftxui/dom/elements.hpp"  // for text, window, operator|, vbox, hbox, Element, flexbox, bgcolor, filler, flex, size, border, hcenter, color, EQUAL, bold, dim, notflex, xflex_grow, yflex_grow, HEIGHT, WIDTH)",
    R"(#include ftxui/dom/flexbox_config.hpp"  // for FlexboxConfig, FlexboxConfig::AlignContent, FlexboxConfig::JustifyContent, FlexboxConfig::AlignContent::Center, FlexboxConfig::AlignItems, FlexboxConfig::Direction, FlexboxConfig::JustifyContent::Center, FlexboxConfig::Wrap)",
    R"(#include ftxui/screen/color.hpp"        // for Color, Color::Black)",
  };
  int selected = 0;
  auto menu = Container::Vertical({}, &selected);
  auto menu_event_filter = [&selected, menu](Event event)-> bool{
    if(event == Event::ArrowUp || (event.is_mouse() && event.mouse().button == Mouse::WheelUp)) {
      selected = std::max(0, selected - 1);
      return true;
    }
    if(event == Event::ArrowDown || (event.is_mouse() && event.mouse().button == Mouse::WheelDown)) {
      selected = std::min((int)menu->ChildCount() - 1, selected + 1);
      return true;
    }
    bool any = false;
    int c = menu->ChildCount();
    for(int i=0; i<c; i++) {
      any |= menu->ChildAt(i)->OnEvent(event);
    }
    return any;
  };
  for(int i=0; i<lines.size(); i++) {
    InputOption style;
    style.content = &(lines.at(i).content);
    style.placeholder = "";
    style.cursor_position = &(lines.at(i).cursor_position);
    Component txt = Input(style) | showInputCursor(&(lines.at(i).cursor_position));
    menu->Add(txt);
  }
  auto renderer = Renderer(CatchEvent(menu, menu_event_filter), [&] {
    return vbox({
               menu->Render() | frame | size(HEIGHT, LESS_THAN, 5),
           }) |
           border;
  });
  auto screen = ScreenInteractive::TerminalOutput(); 
  screen.Loop(renderer);
  return 0;
}
