
#ifndef _PERUN_FC_GRID_IN_MENU_
#define _PERUN_FC_GRID_IN_MENU_

#include <boost/filesystem.hpp>
#include <ftxui/component/component.hpp>

#include <cstdint>

namespace ftxui {

Event event_from_string(std::string s);

Element coloredInt(int64_t n);

Element bgGaugeLeft(float fraction, Color full, Color empty, Element child);

Decorator bgGaugeLeft(float fraction, Color full, Color empty);
Decorator bgGaugeLeft(float fraction);

Element showInputCursor(Element child, Ref<int> cursor_position);

Decorator showInputCursor(Ref<int> cursor_position);

Element clear_under_colors(Element element);

}  // namespace ftxui

#endif  // _PERUN_FC_GRID_IN_MENU_
