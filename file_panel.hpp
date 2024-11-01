
#ifndef _PERUN_FC_GRID_IN_MENU_
#define _PERUN_FC_GRID_IN_MENU_

#include <ftxui/component/component.hpp>
#include <ftxui/component/screen_interactive.hpp>

#include "shared_state.hpp"

#include <cstdint>

namespace ftxui {

// TODO: Render only visible items. Dir can contain thousands of items but <90 are diplayed.
// TODO: - Use reflect decorator to determine the size of rendered table https://github.com/ArthurSonzogni/FTXUI/discussions/423
Component FileList(PanelSharedState::P panel, std::string* filter_text);

Element coloredInt(int64_t n);

Element bgGaugeLeft(float fraction, Color full, Color empty, Element child);

Decorator bgGaugeLeft(float fraction, Color full, Color empty);

Element showInputCursor(Element child, Ref<int> cursor_position);

Decorator showInputCursor(Ref<int> cursor_position);

Element clear_under_colors(Element element);

}  // namespace ftxui

#endif  // _PERUN_FC_GRID_IN_MENU_
