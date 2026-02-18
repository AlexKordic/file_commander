#include "custom_controls.hpp"
#include "theme.hpp"

#include <ftxui/component/component.hpp>
#include <ftxui/component/event.hpp>
#include <ftxui/dom/direction.hpp>
#include <ftxui/dom/elements.hpp>
#include <ftxui/dom/table.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <ftxui/screen/color.hpp>
#include <memory>
#include <string>
#include <utility>
#include <vector>

using namespace ftxui;

namespace ftxui {

Event event_from_string(std::string s) {
  if(s == "<-") return Event::ArrowLeft;
  if(s == "->") return Event::ArrowRight;
  if(s == "up") return Event::ArrowUp;
  if(s == "down") return Event::ArrowDown;
  if(s == "c<-") return Event::ArrowLeftCtrl;
  if(s == "c->") return Event::ArrowRightCtrl;
  if(s == "cup") return Event::ArrowUpCtrl;
  if(s == "cdown") return Event::ArrowDownCtrl;
  if(s == "back") return Event::Backspace;
  if(s == "del") return Event::Delete;
  if(s == "esc") return Event::Escape;
  if(s == "ret") return Event::Return;
  if(s == "tab") return Event::Tab;
  if(s == "stab") return Event::TabReverse;

  if(s == "f1") return Event::F1;
  if(s == "f2") return Event::F2;
  if(s == "f3") return Event::F3;
  if(s == "f4") return Event::F4;
  if(s == "f5") return Event::F5;
  if(s == "f6") return Event::F6;
  if(s == "f7") return Event::F7;
  if(s == "f8") return Event::F8;
  if(s == "f9") return Event::F9;
  if(s == "f10") return Event::F10;
  if(s == "f11") return Event::F11;
  if(s == "f12") return Event::F12;

  if(s.size() == 1) return Event::Character(s[0]);
  if(s.size() == 2) {
    if(s[0] == 'c') {
      if(s[1] == 'A') return Event::CtrlA;
      if(s[1] == 'B') return Event::CtrlB;
      if(s[1] == 'C') return Event::CtrlC;
      if(s[1] == 'D') return Event::CtrlD;
      if(s[1] == 'E') return Event::CtrlE;
      if(s[1] == 'F') return Event::CtrlF;
      if(s[1] == 'G') return Event::CtrlG;
      if(s[1] == 'H') return Event::CtrlH;
      if(s[1] == 'I') return Event::CtrlI;
      if(s[1] == 'J') return Event::CtrlJ;
      if(s[1] == 'K') return Event::CtrlK;
      if(s[1] == 'L') return Event::CtrlL;
      if(s[1] == 'M') return Event::CtrlM;
      if(s[1] == 'N') return Event::CtrlN;
      if(s[1] == 'O') return Event::CtrlO;
      if(s[1] == 'P') return Event::CtrlP;
      if(s[1] == 'Q') return Event::CtrlQ;
      if(s[1] == 'R') return Event::CtrlR;
      if(s[1] == 'S') return Event::CtrlS;
      if(s[1] == 'T') return Event::CtrlT;
      if(s[1] == 'U') return Event::CtrlU;
      if(s[1] == 'V') return Event::CtrlV;
      if(s[1] == 'W') return Event::CtrlW;
      if(s[1] == 'X') return Event::CtrlX;
      if(s[1] == 'Y') return Event::CtrlY;
      if(s[1] == 'Z') return Event::CtrlZ;
    } else if(s[0] == 'a') {
      if(s[1] == 'A') return Event::AltA;
      if(s[1] == 'B') return Event::AltB;
      if(s[1] == 'C') return Event::AltC;
      if(s[1] == 'D') return Event::AltD;
      if(s[1] == 'E') return Event::AltE;
      if(s[1] == 'F') return Event::AltF;
      if(s[1] == 'G') return Event::AltG;
      if(s[1] == 'H') return Event::AltH;
      if(s[1] == 'I') return Event::AltI;
      if(s[1] == 'J') return Event::AltJ;
      if(s[1] == 'K') return Event::AltK;
      if(s[1] == 'L') return Event::AltL;
      if(s[1] == 'M') return Event::AltM;
      if(s[1] == 'N') return Event::AltN;
      if(s[1] == 'O') return Event::AltO;
      if(s[1] == 'P') return Event::AltP;
      if(s[1] == 'Q') return Event::AltQ;
      if(s[1] == 'R') return Event::AltR;
      if(s[1] == 'S') return Event::AltS;
      if(s[1] == 'T') return Event::AltT;
      if(s[1] == 'U') return Event::AltU;
      if(s[1] == 'V') return Event::AltV;
      if(s[1] == 'W') return Event::AltW;
      if(s[1] == 'X') return Event::AltX;
      if(s[1] == 'Y') return Event::AltY;
      if(s[1] == 'Z') return Event::AltZ;
    }
  }

  return Event::Custom;
}

std::string event_to_string(const Event& e) {
  if (e == Event::ArrowLeft) return "<-";
  if (e == Event::ArrowRight) return "->";
  if (e == Event::ArrowUp) return "Up";
  if (e == Event::ArrowDown) return "Down";
  if (e == Event::ArrowLeftCtrl) return "Ctrl+<-";
  if (e == Event::ArrowRightCtrl) return "Ctrl+->";
  if (e == Event::ArrowUpCtrl) return "Ctrl+Up";
  if (e == Event::ArrowDownCtrl) return "Ctrl+Down";
  if (e == Event::Backspace) return "Backspace";
  if (e == Event::Delete) return "Delete";
  if (e == Event::Escape) return "Esc";
  if (e == Event::Return) return "Enter";
  if (e == Event::Tab) return "Tab";
  if (e == Event::TabReverse) return "Shift+Tab";

  if (e == Event::F1) return "F1";
  if (e == Event::F2) return "F2";
  if (e == Event::F3) return "F3";
  if (e == Event::F4) return "F4";
  if (e == Event::F5) return "F5";
  if (e == Event::F6) return "F6";
  if (e == Event::F7) return "F7";
  if (e == Event::F8) return "F8";
  if (e == Event::F9) return "F9";
  if (e == Event::F10) return "F10";
  if (e == Event::F11) return "F11";
  if (e == Event::F12) return "F12";

  if (e == Event::Character(' ')) return "Space";
  if (e == Event::Character('?')) return "?";
  if (e == Event::Character('+')) return "+";
  if (e == Event::Character('-')) return "-";

  if (e == Event::CtrlA) return "Ctrl+A";
  if (e == Event::CtrlB) return "Ctrl+B";
  if (e == Event::CtrlC) return "Ctrl+C";
  if (e == Event::CtrlD) return "Ctrl+D";
  if (e == Event::CtrlE) return "Ctrl+E";
  if (e == Event::CtrlF) return "Ctrl+F";
  if (e == Event::CtrlG) return "Ctrl+G";
  if (e == Event::CtrlH) return "Ctrl+H";
  if (e == Event::CtrlI) return "Ctrl+I";
  if (e == Event::CtrlJ) return "Ctrl+J";
  if (e == Event::CtrlK) return "Ctrl+K";
  if (e == Event::CtrlL) return "Ctrl+L";
  if (e == Event::CtrlM) return "Ctrl+M";
  if (e == Event::CtrlN) return "Ctrl+N";
  if (e == Event::CtrlO) return "Ctrl+O";
  if (e == Event::CtrlP) return "Ctrl+P";
  if (e == Event::CtrlQ) return "Ctrl+Q";
  if (e == Event::CtrlR) return "Ctrl+R";
  if (e == Event::CtrlS) return "Ctrl+S";
  if (e == Event::CtrlT) return "Ctrl+T";
  if (e == Event::CtrlU) return "Ctrl+U";
  if (e == Event::CtrlV) return "Ctrl+V";
  if (e == Event::CtrlW) return "Ctrl+W";
  if (e == Event::CtrlX) return "Ctrl+X";
  if (e == Event::CtrlY) return "Ctrl+Y";
  if (e == Event::CtrlZ) return "Ctrl+Z";

  return "?";
}

std::string event_to_token(const Event& e) {
  if (e == Event::ArrowLeft) return "<-";
  if (e == Event::ArrowRight) return "->";
  if (e == Event::ArrowUp) return "up";
  if (e == Event::ArrowDown) return "down";
  if (e == Event::ArrowLeftCtrl) return "c<-";
  if (e == Event::ArrowRightCtrl) return "c->";
  if (e == Event::ArrowUpCtrl) return "cup";
  if (e == Event::ArrowDownCtrl) return "cdown";
  if (e == Event::Backspace) return "back";
  if (e == Event::Delete) return "del";
  if (e == Event::Escape) return "esc";
  if (e == Event::Return) return "ret";
  if (e == Event::Tab) return "tab";
  if (e == Event::TabReverse) return "stab";

  if (e == Event::F1) return "f1";
  if (e == Event::F2) return "f2";
  if (e == Event::F3) return "f3";
  if (e == Event::F4) return "f4";
  if (e == Event::F5) return "f5";
  if (e == Event::F6) return "f6";
  if (e == Event::F7) return "f7";
  if (e == Event::F8) return "f8";
  if (e == Event::F9) return "f9";
  if (e == Event::F10) return "f10";
  if (e == Event::F11) return "f11";
  if (e == Event::F12) return "f12";

  if (e == Event::Character(' ')) return " ";
  if (e == Event::Character('?')) return "?";
  if (e == Event::Character('+')) return "+";
  if (e == Event::Character('-')) return "-";

  if (e == Event::CtrlA) return "cA";
  if (e == Event::CtrlB) return "cB";
  if (e == Event::CtrlC) return "cC";
  if (e == Event::CtrlD) return "cD";
  if (e == Event::CtrlE) return "cE";
  if (e == Event::CtrlF) return "cF";
  if (e == Event::CtrlG) return "cG";
  if (e == Event::CtrlH) return "cH";
  if (e == Event::CtrlI) return "cI";
  if (e == Event::CtrlJ) return "cJ";
  if (e == Event::CtrlK) return "cK";
  if (e == Event::CtrlL) return "cL";
  if (e == Event::CtrlM) return "cM";
  if (e == Event::CtrlN) return "cN";
  if (e == Event::CtrlO) return "cO";
  if (e == Event::CtrlP) return "cP";
  if (e == Event::CtrlQ) return "cQ";
  if (e == Event::CtrlR) return "cR";
  if (e == Event::CtrlS) return "cS";
  if (e == Event::CtrlT) return "cT";
  if (e == Event::CtrlU) return "cU";
  if (e == Event::CtrlV) return "cV";
  if (e == Event::CtrlW) return "cW";
  if (e == Event::CtrlX) return "cX";
  if (e == Event::CtrlY) return "cY";
  if (e == Event::CtrlZ) return "cZ";

  return "";
}

namespace {

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

}  // namespace

std::string box_to_string(const Box& box) { return std::format("x:{} y:{} w:{} h:{}", box.x_min, box.y_min, box.x_max, box.y_max); }

class ColoredInt : public Node {
 public:
  explicit ColoredInt(int64_t n, std::vector<Color> colors = {Color::White, Color::White, Color::Yellow, Color::Red, Color::Plum3}) : text_(std::to_string(n)), colors_(std::move(colors)) {
    // This handle NAN correctly:
    if (!(progress_ > 0.F)) { progress_ = 0.F; }
    if (!(progress_ < 1.F)) { progress_ = 1.F; }
  }

  void ComputeRequirement() override {
    requirement_.min_x = string_width(text_);
    requirement_.min_y = 1;
  }

  void Render(Screen& screen) override {
    int       x = box_.x_min;
    const int y = box_.y_min;
    if (y > box_.y_max) { return; }

    int index = 0;
    for (const auto& cell : Utf8ToGlyphs(text_)) {
      if (x > box_.x_max) { return; }
      if (cell == "\n") { continue; }
      screen.PixelAt(x, y).character = cell;
      const int   digit_index        = text_.size() - index - 1;
      const int   color_index        = std::clamp(digit_index / group_size, 0, (int)colors_.size() - 1);
      const Color c                  = colors_[color_index];
      if (c.IsOpaque()) {
        screen.PixelAt(x, y).foreground_color = c;
      } else {
        Color& color = screen.PixelAt(x, y).foreground_color;
        color        = Color::Blend(color, c);
      }
      ++x;
      ++index;
    }
  }

 private:
  int const          group_size = 3;
  std::vector<Color> colors_;
  std::string        text_;
  float              progress_;
};

Element coloredInt(int64_t n) { return ftxui::make_shared<ColoredInt>(n, theme().filesize_colors); }

class BgGaugeLeft : public NodeDecorator {
 public:
  BgGaugeLeft(Element child, float fraction, Color full, Color empty) : NodeDecorator(std::move(child)), _full(full), _empty(empty) { _fraction = std::min(1.0f, std::max(0.0f, fraction)); }

  void Render(Screen& screen) override {
    int border = std::lround(box_.x_min + ((box_.x_max - box_.x_min + 1) * _fraction));
    if (_full.IsOpaque()) {
      for (int y = box_.y_min; y <= box_.y_max; ++y) {
        for (int x = box_.x_min; x < border; ++x) { screen.PixelAt(x, y).background_color = _full; }
      }
    } else {
      for (int y = box_.y_min; y <= box_.y_max; ++y) {
        for (int x = box_.x_min; x < border; ++x) {
          Color& color = screen.PixelAt(x, y).background_color;
          color        = Color::Blend(color, _full);
        }
      }
    }
    if (_empty.IsOpaque()) {
      for (int y = box_.y_min; y <= box_.y_max; ++y) {
        for (int x = border; x <= box_.x_max; ++x) { screen.PixelAt(x, y).background_color = _empty; }
      }
    } else {
      for (int y = box_.y_min; y <= box_.y_max; ++y) {
        for (int x = border; x <= box_.x_max; ++x) {
          Color& color = screen.PixelAt(x, y).background_color;
          color        = Color::Blend(color, _empty);
        }
      }
    }
    NodeDecorator::Render(screen);
  }

  float _fraction;
  Color _full;
  Color _empty;
};

Element bgGaugeLeft(float fraction, Color full, Color empty, Element child) { return ftxui::make_shared<BgGaugeLeft>(std::move(child), fraction, full, empty); }

Decorator bgGaugeLeft(float fraction, Color full, Color empty) {
  return [fraction, full, empty](Element child) { return bgGaugeLeft(fraction, full, empty, std::move(child)); };
}
Decorator bgGaugeLeft(float fraction) {
  return [fraction](Element child) { return bgGaugeLeft(fraction, theme().size_gauge_full, theme().size_gauge_empty, std::move(child)); };
}

class ShowInputCursor : public NodeDecorator {
 public:
  ShowInputCursor(Element child, Ref<int> cursor_position) : NodeDecorator(std::move(child)), _cursor_position(cursor_position) {}

  void Render(Screen& screen) override {
    const bool draw_cursor = true;
    // TODO: animate blinking by toggling draw_cursor
    if (draw_cursor) {
      int x = std::max(box_.x_min, std::min(box_.x_max, box_.x_min + _cursor_position()));
      for (int y = box_.y_min; y <= box_.y_max; ++y) { screen.PixelAt(x, y).inverted = !screen.PixelAt(x, y).inverted; }
    }
    NodeDecorator::Render(screen);
  }

  Ref<int> _cursor_position;
};

Element   showInputCursor(Element child, Ref<int> cursor_position) { return ftxui::make_shared<ShowInputCursor>(std::move(child), cursor_position); }
Decorator showInputCursor(Ref<int> cursor_position) {
  return [cursor_position](Element child) -> Element { return showInputCursor(std::move(child), cursor_position); };
}

class ClearUnder : public NodeDecorator {
 public:
  using NodeDecorator::NodeDecorator;

  void Render(Screen& screen) override {
    const Color fg = theme().default_fg;
    const Color bg = theme().default_bg;
    for (int y = box_.y_min; y <= box_.y_max; ++y) {
      for (int x = box_.x_min; x <= box_.x_max; ++x) {
        screen.PixelAt(x, y)                  = Pixel();
        screen.PixelAt(x, y).character        = " ";
        screen.PixelAt(x, y).background_color = bg;
        screen.PixelAt(x, y).foreground_color = fg;
      }
    }
    Node::Render(screen);
  }
};

/// @brief Before drawing |child|, clear the pixels below. This is useful in
//         combinaison with dbox.
/// @see ftxui::dbox
/// @ingroup dom
Element clear_under_colors(Element element) { return ftxui::make_shared<ClearUnder>(std::move(element)); }

}  // namespace ftxui
