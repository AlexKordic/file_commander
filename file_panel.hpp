
#ifndef _PERUN_FC_GRID_IN_MENU_
#define _PERUN_FC_GRID_IN_MENU_

#include "shared_state.hpp"

#include <ftxui/component/component.hpp>
#include <boost/filesystem.hpp>

#include <cstdint>
#include <functional>

namespace ftxui {



// DONE: Render only visible items. Dir can contain thousands of items but <90 are diplayed.
// DONE: - Use reflect decorator to determine the size of rendered table https://github.com/ArthurSonzogni/FTXUI/discussions/423
Component FileList(PanelSharedState::P panel, std::string* filter_text, std::function<void()> redraw_ui);

Element coloredInt(int64_t n);

Element bgGaugeLeft(float fraction, Color full, Color empty, Element child);

Decorator bgGaugeLeft(float fraction, Color full, Color empty);

Element showInputCursor(Element child, Ref<int> cursor_position);

Decorator showInputCursor(Ref<int> cursor_position);

Element clear_under_colors(Element element);

}  // namespace ftxui

#endif  // _PERUN_FC_GRID_IN_MENU_
