
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

/// @brief Option for the Menu component.
/// @ingroup component
struct FileListOption {
  std::vector<DirItem>* entries;       ///> The list of entries.
  Ref<int>              selected = 0;  ///> The index of the selected entry.

  // Style:
  UnderlineOption          underline;
  MenuEntryOption          entries_option;
  Direction                direction = Direction::Down;
  std::function<Element()> elements_prefix;
  std::function<Element()> elements_infix;
  std::function<Element()> elements_postfix;

  // Observers:
  std::function<void()> on_change;  ///> Called when the selected entry changes.
  std::function<void()> on_enter;   ///> Called when the user presses enter.
  Ref<int>              focused_entry = 0;
};

namespace {

// Similar to std::clamp, but allow hi to be lower than lo.
template <class T>
constexpr const T& clamp(const T& v, const T& lo, const T& hi) {
  return v < lo ? lo : hi < v ? hi
                              : v;
}

Element DefaultOptionTransform(const EntryState& state) {
  std::string label = (state.active ? "> " : "  ") + state.label;  // NOLINT
  Element     e     = text(std::move(label));
  if (state.focused) {
    e = e | inverted;
  }
  if (state.active) {
    e = e | bold;
  }
  return e;
}

bool IsHorizontal(Direction direction) {
  switch (direction) {
  case Direction::Left:
  case Direction::Right:
    return true;
  case Direction::Down:
  case Direction::Up:
    return false;
  }
  return false;  // NOT_REACHED()
}

}  // namespace

}  // namespace ftxui

/// @brief A list of items. The user can navigate through them.
/// @ingroup component
class FileList : public ComponentBase, public FileListOption {
 public:
  explicit FileList(std::vector<DirItem>* entries, int* selected) {
    this->entries  = entries;
    this->selected = Ref<int>(selected);
  }

  bool IsHorizontal() { return ftxui::IsHorizontal(direction); }
  void OnChange() {
    if (on_change) {
      on_change();
    }
  }

  void OnEnter() {
    if (on_enter) {
      on_enter();
    }
  }

  void Clamp() {
    if (selected() != selected_previous_) {
      SelectedTakeFocus();
    }
    boxes_.resize(size());
    selected()         = ftxui::clamp(selected(), 0, size() - 1);
    selected_previous_ = ftxui::clamp(selected_previous_, 0, size() - 1);
    selected_focus_    = ftxui::clamp(selected_focus_, 0, size() - 1);
    focused_entry()    = ftxui::clamp(focused_entry(), 0, size() - 1);
  }

  void OnAnimation(animation::Params& params) override {
    animator_first_.OnAnimation(params);
    animator_second_.OnAnimation(params);
    for (auto& animator : animator_background_) {
      animator.OnAnimation(params);
    }
    for (auto& animator : animator_foreground_) {
      animator.OnAnimation(params);
    }
  }

  Element Render() override {
    Clamp();
    UpdateAnimationTarget();

    Elements   elements;
    const bool is_menu_focused = Focused();
    if (elements_prefix) {
      elements.push_back(elements_prefix());
    }
    elements.reserve(size());

    auto default_transform = [](const EntryState& state) -> Element {
      Element e = text(state.label);
      if (state.focused) {
        // Changes on mouse move and up/down
        e = e | theme().files_focused;
      }
      if (state.active) {
        // Changes on scroll and up/down
        e = e | theme().files_selected;
      }
      return e;
    };
    auto transform = entries_option.transform ? entries_option.transform : default_transform;
    // rows.push_back({text("Name"), text("Size"), text("MTime")});
    for (int i = 0; i < size(); ++i) {
      if (i != 0 && elements_infix) {
        elements.push_back(elements_infix());
      }
      const auto& data             = entries->at(i);
      const bool  is_focused       = (focused_entry() == i) && is_menu_focused;
      const bool  is_selected      = data.selected;
      auto        focus_management = (selected_focus_ != i) ? ftxui::nothing : is_menu_focused ? ftxui::focus
                                                                                               : ftxui::select;
      auto        wrap             = [&](std::string x) -> Element {
        return transform(EntryState{std::move(x), false, is_selected, is_focused}) | AnimatedColorStyle(i) | theme().file_type(data.type);
      };
      elements.push_back(hbox({wrap(data.path.filename().native()) | xflex_grow,
                               (data.is_dir() ? text("") : coloredInt(data.size)),
                               separatorLight(),
                               wrap(data.get_time())})
                         | focus_management | reflect(boxes_[i]));
    }

    if (elements_postfix) {
      elements.push_back(elements_postfix());
    }

    // if (IsInverted(direction)) {
    //   std::reverse(elements.begin(), elements.end());
    // }

    const Element bar = IsHorizontal() ? hbox(std::move(elements)) : vbox(std::move(elements));

    if (!underline.enabled) {
      return bar | reflect(box_);
    }

    if (IsHorizontal()) {
      return vbox({
               bar | xflex,
               separatorHSelector(first_, second_,  //
                                  underline.color_active,
                                  underline.color_inactive),
             })
        | reflect(box_);
    } else {
      return hbox({
               separatorVSelector(first_, second_,  //
                                  underline.color_active,
                                  underline.color_inactive),
               bar | yflex,
             })
        | reflect(box_);
    }
  }

  void SelectedTakeFocus() {
    selected_previous_ = selected();
    selected_focus_    = selected();
  }

  void OnUp() {
    switch (direction) {
    case Direction::Up:
      selected()++;
      break;
    case Direction::Down:
      selected()--;
      break;
    case Direction::Left:
    case Direction::Right:
      break;
    }
  }

  void OnDown() {
    switch (direction) {
    case Direction::Up:
      selected()--;
      break;
    case Direction::Down:
      selected()++;
      break;
    case Direction::Left:
    case Direction::Right:
      break;
    }
  }

  void OnLeft() {
    switch (direction) {
    case Direction::Left:
      selected()++;
      break;
    case Direction::Right:
      selected()--;
      break;
    case Direction::Down:
    case Direction::Up:
      break;
    }
  }

  void OnRight() {
    switch (direction) {
    case Direction::Left:
      selected()--;
      break;
    case Direction::Right:
      selected()++;
      break;
    case Direction::Down:
    case Direction::Up:
      break;
    }
  }

  // NOLINTNEXTLINE(readability-function-cognitive-complexity)
  bool OnEvent(Event event) override {
    Clamp();
    if (!CaptureMouse(event)) {
      return false;
    }

    if (event.is_mouse()) {
      return OnMouseEvent(event);
    }

    if (Focused()) {
      const int old_selected = selected();
      if (event == Event::ArrowUp || event == Event::Character('k')) {
        OnUp();
      }
      if (event == Event::ArrowDown || event == Event::Character('j')) {
        OnDown();
      }
      if (event == Event::ArrowLeft || event == Event::Character('h')) {
        OnLeft();
      }
      if (event == Event::ArrowRight || event == Event::Character('l')) {
        OnRight();
      }
      if (event == Event::PageUp) {
        selected() -= box_.y_max - box_.y_min;
      }
      if (event == Event::PageDown) {
        selected() += box_.y_max - box_.y_min;
      }
      if (event == Event::Home) {
        selected() = 0;
      }
      if (event == Event::End) {
        selected() = size() - 1;
      }

      // Skip tab actions
      // if (event == Event::Tab && size()) {
      //   selected() = (selected() + 1) % size();
      // }
      // if (event == Event::TabReverse && size()) {
      //   selected() = (selected() + size() - 1) % size();
      // }
      if (event == theme().key_files_select) {
        entries->at(focused_entry()).selected = !entries->at(focused_entry()).selected;
        OnDown();
      }

      selected() = ftxui::clamp(selected(), 0, size() - 1);

      if (selected() != old_selected) {
        focused_entry() = selected();
        SelectedTakeFocus();
        OnChange();
        return true;
      }
    }

    if (event == Event::Return) {
      OnEnter();
      return true;
    }

    return false;
  }

  bool OnMouseEvent(Event event) {
    if (event.mouse().button == Mouse::WheelDown || event.mouse().button == Mouse::WheelUp) {
      return OnMouseWheel(event);
    }

    if (event.mouse().button != Mouse::None && event.mouse().button != Mouse::Left) {
      return false;
    }
    if (!CaptureMouse(event)) {
      return false;
    }
    for (int i = 0; i < size(); ++i) {
      if (!boxes_[i].Contain(event.mouse().x, event.mouse().y)) {
        continue;
      }

      TakeFocus();
      focused_entry() = i;
      if (selected() != i) {
        selected()         = i;
        selected_previous_ = selected();
        OnChange();
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
    if (!box_.Contain(event.mouse().x, event.mouse().y)) {
      return false;
    }
    const int old_selected = selected();

    if (event.mouse().button == Mouse::WheelUp) {
      selected()--;
    }
    if (event.mouse().button == Mouse::WheelDown) {
      selected()++;
    }

    selected() = ftxui::clamp(selected(), 0, size() - 1);
    if (selected() != selected_previous_) {
      selected_previous_ = selected();
      SelectedTakeFocus();
      OnChange();
    }
    focused_entry() = selected();

    // if (selected() != old_selected) {
    //   SelectedTakeFocus();
    //   OnChange();
    // }
    return true;
  }

  void UpdateAnimationTarget() {
    UpdateColorTarget();
    UpdateUnderlineTarget();
  }

  void UpdateColorTarget() {
    if (size() != int(animation_background_.size())) {
      animation_background_.resize(size());
      animation_foreground_.resize(size());
      animator_background_.clear();
      animator_foreground_.clear();

      const int len = size();
      animator_background_.reserve(len);
      animator_foreground_.reserve(len);
      for (int i = 0; i < len; ++i) {
        animation_background_[i] = 0.F;
        animation_foreground_[i] = 0.F;
        animator_background_.emplace_back(&animation_background_[i], 0.F,
                                          std::chrono::milliseconds(0),
                                          animation::easing::Linear);
        animator_foreground_.emplace_back(&animation_foreground_[i], 0.F,
                                          std::chrono::milliseconds(0),
                                          animation::easing::Linear);
      }
    }

    const bool is_menu_focused = Focused();
    for (int i = 0; i < size(); ++i) {
      const bool is_focused  = (focused_entry() == i) && is_menu_focused;
      const bool is_selected = (selected() == i);
      float      target      = is_selected ? 1.F : is_focused ? 0.5F
                                                              : 0.F;  // NOLINT
      if (animator_background_[i].to() != target) {
        animator_background_[i] = animation::Animator(
          &animation_background_[i], target,
          entries_option.animated_colors.background.duration,
          entries_option.animated_colors.background.function);
        animator_foreground_[i] = animation::Animator(
          &animation_foreground_[i], target,
          entries_option.animated_colors.foreground.duration,
          entries_option.animated_colors.foreground.function);
      }
    }
  }

  Decorator AnimatedColorStyle(int i) {
    Decorator style = nothing;
    if (entries_option.animated_colors.foreground.enabled) {
      style = style | color(Color::Interpolate(animation_foreground_[i], entries_option.animated_colors.foreground.inactive, entries_option.animated_colors.foreground.active));
    }

    if (entries_option.animated_colors.background.enabled) {
      style = style | bgcolor(Color::Interpolate(animation_background_[i], entries_option.animated_colors.background.inactive, entries_option.animated_colors.background.active));
    }
    return style;
  }

  void UpdateUnderlineTarget() {
    if (!underline.enabled) {
      return;
    }

    if (FirstTarget() == animator_first_.to() && SecondTarget() == animator_second_.to()) {
      return;
    }

    if (FirstTarget() >= animator_first_.to()) {
      animator_first_ = animation::Animator(
        &first_, FirstTarget(), underline.follower_duration,
        underline.follower_function, underline.follower_delay);

      animator_second_ = animation::Animator(
        &second_, SecondTarget(), underline.leader_duration,
        underline.leader_function, underline.leader_delay);
    } else {
      animator_first_ = animation::Animator(
        &first_, FirstTarget(), underline.leader_duration,
        underline.leader_function, underline.leader_delay);

      animator_second_ = animation::Animator(
        &second_, SecondTarget(), underline.follower_duration,
        underline.follower_function, underline.follower_delay);
    }
  }

  bool  Focusable() const final { return entries->size(); }
  int   size() const { return int(entries->size()); }
  float FirstTarget() {
    if (boxes_.empty()) {
      return 0.F;
    }
    const int value = IsHorizontal() ? boxes_[selected()].x_min - box_.x_min
                                     : boxes_[selected()].y_min - box_.y_min;
    return float(value);
  }
  float SecondTarget() {
    if (boxes_.empty()) {
      return 0.F;
    }
    const int value = IsHorizontal() ? boxes_[selected()].x_max - box_.x_min
                                     : boxes_[selected()].y_max - box_.y_min;
    return float(value);
  }

 protected:
  int selected_previous_ = selected();
  int selected_focus_    = selected();

  // Mouse click support:
  std::vector<Box> boxes_;
  Box              box_;

  // Animation support:
  float                            first_           = 0.F;
  float                            second_          = 0.F;
  animation::Animator              animator_first_  = animation::Animator(&first_, 0.F);
  animation::Animator              animator_second_ = animation::Animator(&second_, 0.F);
  std::vector<animation::Animator> animator_background_;
  std::vector<animation::Animator> animator_foreground_;
  std::vector<float>               animation_background_;
  std::vector<float>               animation_foreground_;
};

Component ftxui::FileList(std::vector<DirItem>* entries, int* selected) {
  return std::make_shared<::FileList>(entries, selected);
}

class ColoredInt : public Node {
 public:
  explicit ColoredInt(int64_t n, std::vector<Color> colors = {Color::White, Color::White, Color::Yellow, Color::Red, Color::Plum3})
      : text_(std::to_string(n)), colors_(std::move(colors)) {
    // This handle NAN correctly:
    if (!(progress_ > 0.F)) {
      progress_ = 0.F;
    }
    if (!(progress_ < 1.F)) {
      progress_ = 1.F;
    }
  }

  void ComputeRequirement() override {
    requirement_.min_x = string_width(text_);
    requirement_.min_y = 1;
  }

  void Render(Screen& screen) override {
    int       x = box_.x_min;
    const int y = box_.y_min;
    if (y > box_.y_max) {
      return;
    }

    int index = 0;
    for (const auto& cell : Utf8ToGlyphs(text_)) {
      if (x > box_.x_max) {
        return;
      }
      if (cell == "\n") {
        continue;
      }
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

Element ftxui::coloredInt(int64_t n) {
  return std::make_shared<ColoredInt>(n, theme().filesize_colors);
}
