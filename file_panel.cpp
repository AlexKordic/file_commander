
#include "file_panel.hpp"
#include "commander.hpp"
#include "dialogs.hpp"
#include "log.hpp"
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
#include <functional>
#include <memory>
#include <string>
#include <utility>
#include <vector>

using namespace ftxui;

RowInfo::RowInfo(bool menu_focused, float max_size, int& rows_placed) : is_menu_focused(menu_focused), max_size(max_size), rows_placed(rows_placed) {}

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

// Similar to std::clamp, but allow hi to be lower than lo.
template <class T> constexpr const T& clamp(const T& v, const T& lo, const T& hi) { return v < lo ? lo : hi < v ? hi : v; }

Decorator filetype_color(const DirItem& item) {
  if (item.is_dir()) return color(theme().file_directory_file);
  Color base = theme().file_type(item.type());
  if (item.is_exe()) { return color(Color::Interpolate(0.5, base, theme().file_perm_exe)); }
  return color(base);
}

}  // namespace

std::function<Element(RowInfo&)> filelist_transform() {
  return [](RowInfo& r) -> Element {
    const DirItem& data = *(r.data);
    Element        n;
    Element        size;
    if (data.is_dir()) {
      n    = text("/" + data.filename_ref());
      size = text("");
    } else {
      n    = text(data.filename_ref());
      size = coloredInt(data.size());
    }
    n = n | xflex_grow | bgGaugeLeft(float(data.size()) / r.max_size);
    if (r.focused) n |= theme().files_focused;
    if (r.selected) n |= theme().files_selected;
    if (!r.focused && !r.selected) n |= filetype_color(data);

    Element t = text(data.get_time());
    if (r.selected) t |= theme().files_selected;

    Element row = hbox({std::move(n), std::move(size), separatorLight(), std::move(t)});
    if (r.focused) {
      if (r.is_menu_focused) row |= ftxui::focus;
      else row |= ftxui::select;
    }
    row |= reflect(*r.box);
    if (data.symlink_ref() || data.warning_ref()) {
      Elements rows = {std::move(row)};
      if (data.symlink_ref()) {
        rows.push_back(text(" -> " + data.symlink_ref()->native()) | theme().files_symlink);
        r.rows_placed++;
      }
      if (data.warning_ref()) {
        rows.push_back(text(*data.warning_ref()) | theme().files_warning);
        r.rows_placed++;
      }
      return vbox(std::move(rows));
    }
    return std::move(row);
  };
}

// Normally ftxui would wrap vbox(all files) | vscroll_indicator | yframe | border.
// We want: vbox(only visible file count) | vscroll_indicator | yframe | border
// To achieve this reverse flow of information is needed. Instead of instancing files then calculating scroll bar size we want FileList to create only visible count of files and use total file count info to construct scroll bar.
// Additionally one file entry can be 3 lines high, so we need to account for that.
// ??? To integrate vscroll_indicator into FileList we need Custom element to wrap our rendered content.
// Maybe r.yflex_grow = 1 is the solution to occupying all available space.

std::string box_to_string(const Box& box) { return std::format("x:{} y:{} w:{} h:{}", box.x_min, box.y_min, box.x_max, box.y_max); }

bool RedrawVariables::operator==(const RedrawVariables& other) const { return items_produced == other.items_produced && items_total == other.items_total && component_height == other.component_height && screen_height == other.screen_height; }

SizeContext::SizeContext() {
  last_v.component_height = -1;
  last_v.screen_height    = -1;
  last_v.items_produced   = -1;
  last_v.items_total      = -1;
}

void SizeContext::set_screen_height(int height) {
  if (height != v.screen_height) should_redraw = true;
  v.screen_height = height;
}
void SizeContext::set_component_height(int height) {
  if (height != v.component_height) should_redraw = true;
  v.component_height = height;
}
void SizeContext::invoke_redraw() {
  // protect against infinite redraws
  if (v == last_v) return;
  last_v = v;
  redraw();
}

class FilelistScrollIndicator : public NodeDecorator {
 private:
  SizeContext* _context;

 public:
  // using NodeDecorator::NodeDecorator;
  FilelistScrollIndicator(Element child, SizeContext* context) : NodeDecorator(std::move(child)), _context(context) {}

  void ComputeRequirement() override {
    NodeDecorator::ComputeRequirement();
    requirement_ = children_[0]->requirement();
    requirement_.min_x++;
  }

  void SetBox(Box box) override {
    box_ = box;
    box.x_max--;
    children_[0]->SetBox(box);
  }

  void Render(Screen& screen) final {
    NodeDecorator::Render(screen);

    // Will draw only on right border of our box.
    // Each pixel allows for half of vertical line: up:╹ full:┃ down:╻
    if (_context->v.items_produced >= _context->v.items_total) return;  // no need for scroll bar
    // All calculation is done in char units
    // TODO: Fix calculation for items_produced != rows_produced (symlinks with warnings)
    float items_total     = _context->v.items_total;
    float widget_height   = float(box_.y_max) - box_.y_min + 1;
    float visible_portion = float(_context->v.items_produced) / items_total;
    float start_point     = (float(_context->start_index) / items_total) * widget_height;
    float end_point       = start_point + (visible_portion * widget_height);
    float start_y         = box_.y_min + start_point;
    float end_y           = box_.y_min + end_point;

    // determine should we start half line:
    const float firstpixel_start_fraction = start_y - int(start_y);
    if (firstpixel_start_fraction < 0.25) {
      screen.PixelAt(box_.x_max, int(start_y)).character = "┃";
    } else {  // in case of shortest line, let it be half line at the top:
      screen.PixelAt(box_.x_max, int(start_y)).character = "╻";
    }
    if (int(end_y) <= box_.y_max) {
      const float lastpixel_end_fraction = end_y - int(end_y);
      if (lastpixel_end_fraction < 0.25) {
        // Test: Maybe use empty char by not rendering to a pixel
        screen.PixelAt(box_.x_max, int(end_y)).character = " ";
      } else if (lastpixel_end_fraction < 0.75) {  // in case of shortest line, let it be half line at the bottom:
        screen.PixelAt(box_.x_max, int(end_y)).character = "╹";
      } else {
        screen.PixelAt(box_.x_max, int(end_y)).character = "┃";
      }
    }
    int last_full_y = std::min(int(end_y) - 1, box_.y_max);
    for (int y = int(start_y) + 1; y <= last_full_y; ++y) { screen.PixelAt(box_.x_max, y).character = "┃"; }
  }
};

Element filelistScrollIndicator(SizeContext* context, Element child) { return std::make_shared<FilelistScrollIndicator>(std::move(child), context); }

Decorator filelist_scroll_indicator(SizeContext* context) {
  return [context](Element child) { return filelistScrollIndicator(context, std::move(child)); };
}

class FileListReflect : public Node {
 public:
  FileListReflect(Element child, SizeContext* context) : Node(unpack(std::move(child))), _context(context) { int ii = 14; }

  void ComputeRequirement() final {
    Node::ComputeRequirement();
    requirement_ = children_[0]->requirement();

    requirement_.flex_grow_y   = 1;  // _context->v.screen_height;
    requirement_.flex_shrink_y = 1;  // _context->v.component_height;
    // DONE: inspect what pannel do here !
    // DONE: experiment with 1.
    requirement_.min_y         = _context->_min_y;
  }

  void SetBox(Box box) final {
    _context->box = box;
    // Perun::l.d("FileListReflect::SetBox", "", {{"box", box_to_string(box)}});
    Node::SetBox(box);
    children_[0]->SetBox(box);
  }

  void Render(Screen& screen) final {
    _context->set_screen_height(screen.dimy());
    _context->box = Box::Intersection(screen.stencil, _context->box);
    _context->set_component_height(_context->box.y_max - _context->box.y_min + 1);
    //
    // Redraw to allow FileList to produce more Elements
    // This action can cause a cascade of redraws.
    const bool all_items_visible              = _context->v.items_total == _context->v.items_produced;
    const bool rowcount_larger_than_component = _context->v.items_total > _context->v.component_height;
    const bool filelist_matched_rowcount      = _context->v.component_height == _context->v.items_produced;  // should also trigger y-shrink
    if (_context->should_redraw || !all_items_visible && rowcount_larger_than_component && !filelist_matched_rowcount) {
      _context->should_redraw = false;
      _context->invoke_redraw();
    }
    Node::Render(screen);
  }

 private:
  SizeContext* _context;
};

Decorator fl_reflect(SizeContext* context) {
  return [context](Element child) -> Element { return std::make_shared<FileListReflect>(std::move(child), context); };
}

/// @brief A list of file items. The user can navigate through them.
class FileList : public ComponentBase {
 public:
  int                 selected = 0;
  Component           filter;
  StringRef           filter_text;
  Dir*                dir;
  PanelSharedState::P app;
  RedrawUI            redraw_ui;

  FileList(PanelSharedState::P panel, std::string* filter_text, RedrawUI redraw_ui) : filter_text(filter_text), redraw_ui(redraw_ui) {
    this->dir    = panel->dir;
    this->filter = panel->filter;
    app          = std::move(panel);
    _size.redraw = redraw_ui;

    app->get_focused_item = [this]() -> Filepath const* {
      this->Clamp();
      auto focused_index = dir->offset_vissible(selected, 0);
      if (dir->items.empty()) return nullptr;
      auto& focused = dir->items.at(focused_index);
      return &focused.path_ref();
    };
    app->set_min_y = [this](int y) { _size._min_y = y; };
  }

  void Clamp() {
    int s = dir->items.size();
    boxes_.resize(s);
    selected = dir->offset_vissible(selected, 0);
  }

  void OnAnimation(animation::Params& params) override { filter->OnAnimation(params); }

  int _find_start_index() {
    int       items_placed = 0;
    int       start_index  = dir->offset_vissible(selected, -_size.v.component_height / 2);
    const int item_count   = dir->items.size();
    for (int index = start_index; index < item_count && items_placed < _size.v.component_height; ++index) {
      if (dir->items.at(index).visible()) { ++items_placed; }
    }
    while (start_index > 0 && items_placed < _size.v.component_height) {
      // prepend items in amount equal to mising at the end
      const int index_before = dir->prev_visible(start_index);
      if (index_before >= start_index) break;
      start_index = index_before;
      items_placed++;
    }
    return start_index;
  }

  Element Render() override {
    app->render_count++;
    Clamp();

    Elements   elements;
    const bool is_menu_focused = Focused();

    int       start_index = _find_start_index();
    const int item_count  = dir->items.size();
    _size.v.items_total   = item_count;
    _size.start_index     = start_index;
    _size.rows_produced   = 0;
    RowInfo row_info(is_menu_focused, dir->stats().largest_item_bytes, _size.rows_produced);
    int     items_placed = 0;
    for (int index = start_index; index < item_count && items_placed < _size.v.component_height; ++index) {
      const DirItem& data = dir->items.at(index);
      if (false == data.visible()) {
        boxes_[index] = Box();
        continue;
      }
      ++items_placed;

      row_info.index    = index;
      row_info.focused  = (selected == index) && is_menu_focused;
      row_info.selected = data.selected();
      row_info.data     = &data;
      row_info.box      = &boxes_[index];

      // clang-format off
      auto transform = [](RowInfo& r)-> Element {
        const DirItem& data = *(r.data);
        Element n;
        Element size;
        if(data.is_dir()) {
          n    = text("/" + data.filename_ref());
          size = text("");
        } else {
          n    = text(data.filename_ref());
          size = coloredInt(data.size());
        }
        n = n | xflex_grow | bgGaugeLeft(float(data.size()) / r.max_size);
        if(r.focused)  n |= theme().files_focused;
        if(r.selected) n |= theme().files_selected;
        if(!r.focused && !r.selected) n |= filetype_color(data);

        Element t = text(data.get_time());
        if(r.selected) t |= theme().files_selected;

        Element row = hbox({std::move(n), std::move(size), separatorLight(), std::move(t)});
        if(r.focused) {
          if(r.is_menu_focused) row |= ftxui::focus;
          else row |= ftxui::select;
        }
        row |= reflect(*r.box);
        if(data.symlink_ref() || data.warning_ref()) {
          Elements rows = {std::move(row)};
          if(data.symlink_ref()) {
            rows.push_back(text(" -> " + data.symlink_ref()->native()) | theme().files_symlink);
            r.rows_placed++;
          }
          if(data.warning_ref()) {
            rows.push_back(text(*data.warning_ref()) | theme().files_warning);
            r.rows_placed++;
          }
          return vbox(std::move(rows));
        }
        return std::move(row);
      };
      elements.push_back(transform(row_info));
      row_info.rows_placed++;
      // clang-format on
    }
    _size.v.items_produced = items_placed;
    return vbox(std::move(elements)) | yframe | fl_reflect(&_size) | filelist_scroll_indicator(&_size);
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

  bool OnEvent(Event event) override {
    Clamp();
    if (!CaptureMouse(event)) { return false; }

    if (event.is_mouse()) { return OnMouseEvent(event); }

    if (Focused()) {
      // Perun::l.d("OnEvent", "", {{"_", string_to_hex(event.input())}, {"dbg", event.DebugString()}, {";", "\n"}});
      const int old_selected = selected;
      const int page_lines   = _size.box.y_max - _size.box.y_min;
      if (event == Event::ArrowUp || event == Event::Character('k')) { selected = dir->prev_visible(selected); }
      if (event == Event::ArrowDown || event == Event::Character('j')) { selected = dir->next_visible(selected); }
      // if (event == Event::ArrowLeft || event == Event::Character('h')) { OnLeft(); }
      // if (event == Event::ArrowRight || event == Event::Character('l')) { OnRight(); }
      if (event == Event::PageUp) { selected = dir->offset_vissible(selected, -page_lines); }
      if (event == Event::PageDown) { selected = dir->offset_vissible(selected, page_lines); }
      if (event == Event::Home) { selected = dir->offset_vissible(0, 0); }
      if (event == Event::End) { selected = dir->offset_vissible(dir->items.size(), 0); }

      if (app->commands_enabled) {
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
          const Filepath old_path   = dir->path;
          const Filepath parent_dir = dir->path.parent_path();
          app->move_to(parent_dir);
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
            Filepath p = where.path_ref();
            app->move_to(p);
            selected = 0;
            filter_text->clear();
            return true;
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
              app->action.arguments->focused = Filepath();
            } else {
              app->action.arguments->focused = dir->items.at(selected).path_ref();
            }
            app->action.show_dialog();
            return true;
          }
        }
      }  // end of commands_enabled

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
    if (!_size.box.Contain(event.mouse().x, event.mouse().y)) { return false; }
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
  SizeContext      _size;
  // Mouse click support:
  std::vector<Box> boxes_;
};

Component fileList(PanelSharedState::P panel, std::string* filter_text, RedrawUI redraw_ui) { return std::make_shared<FileList>(std::move(panel), filter_text, redraw_ui); }

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
