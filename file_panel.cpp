
#include "file_panel.hpp"
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

Element coloredInt(int64_t n) { return std::make_shared<ColoredInt>(n, theme().filesize_colors); }

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

Element bgGaugeLeft(float fraction, Color full, Color empty, Element child) { return std::make_shared<BgGaugeLeft>(std::move(child), fraction, full, empty); }

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

Element   showInputCursor(Element child, Ref<int> cursor_position) { return std::make_shared<ShowInputCursor>(std::move(child), cursor_position); }
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
Element clear_under_colors(Element element) { return std::make_shared<ClearUnder>(std::move(element)); }

}  // namespace ftxui
