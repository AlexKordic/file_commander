
#include "file_panel.hpp"
#include "commander.h"
#include "dialogs.hpp"
#include "log.hpp"
#include "theme.hpp"

#include <ftxui/component/component.hpp>
#include <ftxui/component/event.hpp>
#include <ftxui/dom/direction.hpp>
#include <ftxui/dom/elements.hpp>
#include <ftxui/dom/table.hpp>

#include <cmath>
#include <algorithm>
#include <cstdint>
#include <ftxui/screen/color.hpp>
#include <memory>
#include <string>
#include <utility>
#include <vector>

using namespace ftxui;

namespace ftxui {

namespace {

// Similar to std::clamp, but allow hi to be lower than lo.
template <class T> constexpr const T& clamp(const T& v, const T& lo, const T& hi) { return v < lo ? lo : hi < v ? hi : v; }

Decorator filetype_color(const DirItem& item) {
  if (item.is_dir()) return color(theme().file_directory_file);
  Color base = theme().file_type(item.type());
  if (item.is_exe()) { return color(Color::Interpolate(0.5, base, theme().file_perm_exe)); }
  return color(base);
}

}  // namespace

}  // namespace ftxui

/// @brief A list of file items. The user can navigate through them.
class FileList : public ComponentBase {
 public:
  int                 selected = 0;
  Component           filter;
  StringRef           filter_text;
  Dir*                dir;
  PanelSharedState::P app;

  FileList(PanelSharedState::P panel, std::string* filter_text) : filter_text(filter_text) {
    this->dir    = panel->dir;
    this->filter = panel->filter;
    app          = std::move(panel);
  }

  void Clamp() {
    int s = dir->items.size();
    boxes_.resize(s);
    selected = dir->offset_vissible(selected, 0);
  }

  void OnAnimation(animation::Params& params) override { filter->OnAnimation(params); }

  int64_t _itteration = 0;
  Element Render() override {
    _itteration++;
    Clamp();

    Elements   elements;
    const bool is_menu_focused = Focused();
    // elements.push_back(text("Render count == " + std::to_string(_itteration)));
    float      max_size        = dir->stats().largest_item_bytes;

    const int item_count = dir->items.size();
    for (int index = 0; index < item_count; ++index) {
      const DirItem& data = dir->items.at(index);
      if (false == data.visible()) {
        boxes_[index] = Box();
        continue;
      }

      const bool is_focused       = (selected == index) && is_menu_focused;
      const bool is_selected      = data.selected();
      auto       focus_management = (selected != index) ? ftxui::nothing : is_menu_focused ? ftxui::focus : ftxui::select;
      // clang-format off
      auto wrap = [&](const std::string& x, bool apply_focus=true) -> Element { 
        Element e;
        if(apply_focus && data.is_dir()) {
          e = text("/" + x);
        } else {
          e = text(x);
        }
        if (apply_focus && is_focused) e |= theme().files_focused;
        if (is_selected) e |= theme().files_selected;
        if(!is_focused && !is_selected) e |= filetype_color(data);
        return e;
      };
      auto produce_row = [&]()->Element{
        return hbox({
          wrap(data.filename_ref()) | xflex_grow | bgGaugeLeft(float(data.size()) / max_size, theme().size_gauge_full, theme().size_gauge_empty), 
          (data.is_dir() ? text("") : coloredInt(data.size())), 
          separatorLight(), 
          wrap(data.get_time(), false)
        }) | focus_management | reflect(boxes_[index]);
      };
      if(data.symlink_ref()) {
        elements.push_back(vbox({
          produce_row(),
          text(" -> " + data.symlink_ref()->native()) | dim
        }));
      } else {
        elements.push_back(produce_row());
      }
      // clang-format on
      // items_shown.push_back(ei);
    }
    return vbox(std::move(elements)) | yflex | reflect(box_);
  }

  std::string string_to_hex(const std::string& input) {
    static const char hex_digits[] = "0123456789ABCDEF";

    std::string output;
    output.reserve(input.length() * 2);
    for (unsigned char c : input) {
      output.push_back(hex_digits[c >> 4]);
      output.push_back(hex_digits[c & 15]);
    }
    return output;
  }

  // NOLINTNEXTLINE(readability-function-cognitive-complexity)
  bool OnEvent(Event event) override {
    Clamp();
    if (!CaptureMouse(event)) { return false; }

    if (event.is_mouse()) { return OnMouseEvent(event); }

    if (Focused()) {
      // Perun::l.d("OnEvent", "", {{"_", string_to_hex(event.input())}, {"dbg", event.DebugString()}, {";", "\n"}});
      const int old_selected = selected;
      const int page_lines   = box_.y_max - box_.y_min;
      if (event == Event::ArrowUp || event == Event::Character('k')) { selected = dir->prev_visible(selected); }
      if (event == Event::ArrowDown || event == Event::Character('j')) { selected = dir->next_visible(selected); }
      // if (event == Event::ArrowLeft || event == Event::Character('h')) { OnLeft(); }
      // if (event == Event::ArrowRight || event == Event::Character('l')) { OnRight(); }
      if (event == Event::PageUp) { selected = dir->offset_vissible(selected, -page_lines); }
      if (event == Event::PageDown) { selected = dir->offset_vissible(selected, page_lines); }
      if (event == Event::Home) { selected = dir->offset_vissible(0, 0); }
      if (event == Event::End) { selected = dir->offset_vissible(dir->items.size(), 0); }

      if (event == theme().key_files_select) {
        dir->item_toggle_select(selected);
        selected = dir->next_visible(selected);
        return true;
      }
      if (event == theme().key_clear_selection) {
        dir->clear_selection();
        return true;
      }
      if (event == theme().key_select_all) {
        dir->select_all();
        return true;
      }
      if (event == theme().key_leave_dir) {
        const DirItem::P old_path = dir->path;
        Err              e        = dir->leave_dir();
        if (!e.ok()) {
          Perun::l.e("dir->leave_dir()", e.steps.front());
          return false;
        }
        selected = 0;
        filter_text->clear();
        // find our old_path and set it as focused
        for (int i = 0; i < dir->items.size(); i++) {
          const DirItem& item = dir->items.at(i);
          if (item.path_ref() == old_path) {
            selected = i;
            break;
          }
        }
        return true;
      }
      if (event == theme().key_enter_dir) {
        if (dir->items.empty()) return false;
        DirItem& where = dir->items.at(selected);
        if (where.is_dir()) {
          DirItem::P p = where.path_ref();
          app->move_to(p);
          return true;
          // Err        e = dir->move_to(p);
          // if (e.ok()) {
          //   selected = 0;
          //   filter_text->clear();
          //   return true;
          // }
          // Perun::l.e("dir->move_to()", e.steps.front());
        }
        return false;
      }

      // check for registered actions
      for (const auto& action : commands().available) {
        if (event == action.key) {
          app->action.dialog            = action.dialog;
          app->action.arguments         = dir->take_selected();
          app->action.arguments->origin = dir->path;
          const bool no_items           = dir->items.empty();
          if (no_items) {
            // no items for selected to point to
            app->action.arguments->focused = DirItem::P();
          } else {
            app->action.arguments->focused = dir->items.at(selected).path_ref();
          }
          app->action.show_dialog();
          return true;
        }
      }

      if (selected != old_selected) { return true; }

      static const Event forbidden_events[]  = {Event::ArrowDown, Event::ArrowUp};
      static const auto  b_                  = std::begin(forbidden_events);
      static const auto  e_                  = std::end(forbidden_events);
      const bool         dont_send_to_filter = std::find(b_, e_, event) != e_;
      if (dont_send_to_filter) return false;

      // let the filter handle key events
      const bool filter_changed = filter->OnEvent(event);
      if (filter_changed) { dir->apply_filter(filter_text()); }
      return filter_changed;
    }

    if (event == Event::Return) {
      // OnEnter();
      return true;
    }

    return false;
  }

  bool OnMouseEvent(Event event) {
    if (event.mouse().button == Mouse::WheelDown || event.mouse().button == Mouse::WheelUp) { return OnMouseWheel(event); }

    // no mouse move handling // if (event.mouse().button != Mouse::None && event.mouse().button != Mouse::Left) { return false; }
    if (event.mouse().button != Mouse::Left) { return false; }
    if (!CaptureMouse(event)) { return false; }
    for (int i = 0; i < dir->items.size(); ++i) {
      if (!boxes_[i].Contain(event.mouse().x, event.mouse().y)) { continue; }

      TakeFocus();
      if (selected != i) {
        selected = dir->next_visible(selected);
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

    if (event.mouse().button == Mouse::WheelUp) { selected = dir->prev_visible(selected); }
    if (event.mouse().button == Mouse::WheelDown) { selected = dir->next_visible(selected); }

    // selected = ftxui::clamp(selected, 0, size() - 1);
    // if (selected() != old_selected) {
    //   SelectedTakeFocus();
    //   OnChange();
    // }
    return true;
  }

  bool Focusable() const final { return true; }

 protected:
  // Mouse click support:
  std::vector<Box> boxes_;
  Box              box_;
};

Component ftxui::FileList(PanelSharedState::P panel, std::string* filter_text) { return std::make_shared<::FileList>(std::move(panel), filter_text); }

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

Element ftxui::bgGaugeLeft(float fraction, Color full, Color empty, Element child) { return std::make_shared<BgGaugeLeft>(std::move(child), fraction, full, empty); }

Decorator ftxui::bgGaugeLeft(float fraction, Color full, Color empty) {
  return [fraction, full, empty](Element child) { return bgGaugeLeft(fraction, full, empty, std::move(child)); };
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

Element   ftxui::showInputCursor(Element child, Ref<int> cursor_position) { return std::make_shared<ShowInputCursor>(std::move(child), cursor_position); }
Decorator ftxui::showInputCursor(Ref<int> cursor_position) {
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
        screen.PixelAt(x, y) = Pixel();
        screen.PixelAt(x, y).character = " ";
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
Element ftxui::clear_under_colors(Element element) {
  return std::make_shared<ClearUnder>(std::move(element));
}
