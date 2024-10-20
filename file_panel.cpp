
#include "file_panel.hpp"
#include "theme.hpp"

#include <ftxui/component/component.hpp>
#include <ftxui/dom/direction.hpp>  // for Direction, Direction::Down, Direction::Left, Direction::Right, Direction::Up
#include <ftxui/dom/elements.hpp>

#include <ftxui/component/event.hpp>  // for Event, Event::ArrowDown, Event::ArrowLeft, Event::ArrowRight, Event::ArrowUp, Event::End, Event::Home, Event::PageDown, Event::PageUp, Event::Return, Event::Tab, Event::TabReverse
#include <ftxui/dom/table.hpp>        // for Table, TableSelection

#include <algorithm>
#include <cstdint>
#include <functional>  // for function
#include <string>      // for operator+, string
#include <utility>     // for move
#include <vector>      // for vector, __alloc_traits<>::value_type

using namespace ftxui;

namespace ftxui {

namespace {

// Similar to std::clamp, but allow hi to be lower than lo.
template <class T> constexpr const T& clamp(const T& v, const T& lo, const T& hi) { return v < lo ? lo : hi < v ? hi : v; }

}  // namespace

}  // namespace ftxui

/// @brief A list of file items. The user can navigate through them.
class FileList : public ComponentBase {
 public:
  int       selected = 0;
  Component filter;
  StringRef filter_text;
  Dir*      dir;
  // std::vector<int> items_shown;

  FileList(Dir* dir, Component filter, StringRef filter_text) {
    this->dir         = dir;
    this->filter      = filter;
    this->filter_text = filter_text;
  }

  void Clamp() {
    int s = dir->items.size();
    boxes_.resize(s);
    selected = ftxui::clamp(selected, 0, s - 1);
  }

  void OnAnimation(animation::Params& params) override { filter->OnAnimation(params); }

  int64_t _itteration = 0;
  Element Render() override {
    _itteration++;
    Clamp();

    Elements   elements;
    const bool is_menu_focused = Focused();
    elements.push_back(text("Render count == " + std::to_string(_itteration)));

    const int item_count = dir->items.size();
    for (int index = 0; index < item_count; ++index) {
      const DirItem& data = dir->items.at(index);

      const bool is_focused       = (selected == index) && is_menu_focused;
      const bool is_selected      = data.selected();
      auto       focus_management = (selected != index) ? ftxui::nothing : is_menu_focused ? ftxui::focus : ftxui::select;
      // clang-format off
      auto wrap = [&](const std::string& x) -> Element { 
        Element e = text(x);
        if (is_focused) e |= theme().files_focused;
        if (is_selected) e |= theme().files_selected;
        return e | theme().file_type(data.type());
      };
      elements.push_back(
        hbox({
          wrap(data.filename_ref()) | xflex_grow, 
          (data.is_dir() ? text("") : coloredInt(data.size())), 
          separatorLight(), 
          wrap(data.get_time())
        }) | focus_management | reflect(boxes_[index])
      );
      // clang-format on
      // items_shown.push_back(ei);
    }

    return vbox(std::move(elements)) | yflex | reflect(box_);
  }

  // NOLINTNEXTLINE(readability-function-cognitive-complexity)
  bool OnEvent(Event event) override {
    Clamp();
    if (!CaptureMouse(event)) { return false; }

    if (event.is_mouse()) { return OnMouseEvent(event); }

    if (Focused()) {
      const int old_selected = selected;
      if (event == Event::ArrowUp || event == Event::Character('k')) { selected--; }
      if (event == Event::ArrowDown || event == Event::Character('j')) { selected++; }
      // if (event == Event::ArrowLeft || event == Event::Character('h')) { OnLeft(); }
      // if (event == Event::ArrowRight || event == Event::Character('l')) { OnRight(); }
      if (event == Event::PageUp) { selected -= box_.y_max - box_.y_min; }
      if (event == Event::PageDown) { selected += box_.y_max - box_.y_min; }
      if (event == Event::Home) { selected = 0; }
      if (event == Event::End) { selected = size() - 1; }

      // Skip tab actions
      // if (event == Event::Tab && size()) {
      //   selected() = (selected() + 1) % size();
      // }
      // if (event == Event::TabReverse && size()) {
      //   selected() = (selected() + size() - 1) % size();
      // }
      if (event == theme().key_files_select) {
        dir->item_toggle_select(selected);
        selected++;
      }
      if (event == theme().key_clear_selection) {
        dir->clear_selection();
        return true;
      }

      selected = ftxui::clamp(selected, 0, size() - 1);

      if (selected != old_selected) { return true; }
      // let the filter handle key events
      return filter->OnEvent(event);
    }

    if (event == Event::Return) {
      // OnEnter();
      return true;
    }

    return false;
  }

  bool OnMouseEvent(Event event) {
    if (event.mouse().button == Mouse::WheelDown || event.mouse().button == Mouse::WheelUp) { return OnMouseWheel(event); }

    if (event.mouse().button != Mouse::None && event.mouse().button != Mouse::Left) { return false; }
    if (!CaptureMouse(event)) { return false; }
    for (int i = 0; i < size(); ++i) {
      if (!boxes_[i].Contain(event.mouse().x, event.mouse().y)) { continue; }

      TakeFocus();
      if (selected != i) {
        selected = i;
        // OnChange();
      }
      // if (event.mouse().button == Mouse::Left &&
      //     event.mouse().motion == Mouse::Pressed) {
      //   if (selected() != i) {
      //     selected() = i;
      //     selected_previous_ = selected();
      //     OnChange();
      //   }
      //   return true;
      // }
    }
    return false;
  }

  bool OnMouseWheel(Event event) {
    if (!box_.Contain(event.mouse().x, event.mouse().y)) { return false; }
    const int old_selected = selected;

    if (event.mouse().button == Mouse::WheelUp) { selected--; }
    if (event.mouse().button == Mouse::WheelDown) { selected++; }

    selected = ftxui::clamp(selected, 0, size() - 1);
    // if (selected() != old_selected) {
    //   SelectedTakeFocus();
    //   OnChange();
    // }
    return true;
  }

  bool  Focusable() const final { return dir->items.size(); }
  int   size() const { return dir->stats().items_visible; }
  // int   size() const { return entries->size(); }
  float FirstTarget() {
    if (boxes_.empty()) { return 0.F; }
    const int value = boxes_[selected].y_min - box_.y_min;
    return float(value);
  }
  float SecondTarget() {
    if (boxes_.empty()) { return 0.F; }
    const int value = boxes_[selected].y_max - box_.y_min;
    return float(value);
  }

 protected:
  // Mouse click support:
  std::vector<Box> boxes_;
  Box              box_;
};

Component ftxui::FileList(Dir* dir, Component filter, StringRef filter_text) { return std::make_shared<::FileList>(dir, filter, filter_text); }

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

Element ftxui::coloredInt(int64_t n) { return std::make_shared<ColoredInt>(n, theme().filesize_colors); }
