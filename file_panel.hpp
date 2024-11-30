
#ifndef _PERUN_FC_GRID_IN_MENU_
#define _PERUN_FC_GRID_IN_MENU_

#include "shared_state.hpp"

#include <boost/filesystem.hpp>
#include <ftxui/component/component.hpp>

#include <cstdint>
#include <functional>

namespace ftxui {

std::function<Element(RowInfo&)> filelist_transform();

// DONE: Render only visible items. Dir can contain thousands of items but <90 are diplayed.
// DONE: - Use reflect decorator to determine the size of rendered table https://github.com/ArthurSonzogni/FTXUI/discussions/423
Component fileList(PanelSharedState::P panel, std::string* filter_text, std::function<void()> redraw_ui);

Element coloredInt(int64_t n);

Element bgGaugeLeft(float fraction, Color full, Color empty, Element child);

Decorator bgGaugeLeft(float fraction, Color full, Color empty);
Decorator bgGaugeLeft(float fraction);

Element showInputCursor(Element child, Ref<int> cursor_position);

Decorator showInputCursor(Ref<int> cursor_position);

Element clear_under_colors(Element element);

using HightMismatch = std::function<void()>;

struct RedrawVariables {
  int items_produced   = 0;
  int items_total      = 0;
  int component_height = 10;
  int screen_height    = 250;

  bool operator==(const RedrawVariables& other) const;
};

struct SizeContext {
  Box             box;  // Mouse click support
  RedrawVariables v;
  RedrawVariables last_v;
  int             start_index   = 0;
  int             focused_index = 0;

  int _min_y = 1;

  std::vector<Box*> produced;
  int               items_visible       = 0;
  int               visible_start_index = 0;

  SizeContext();
  void set_screen_height(int height);
  void set_component_height(int height);
  void invoke_redraw();

  HightMismatch redraw;
  bool          should_redraw = false;
};

Decorator filelist_scroll_indicator(SizeContext* context);

Decorator fl_reflect(SizeContext* context);

}  // namespace ftxui

#endif  // _PERUN_FC_GRID_IN_MENU_
