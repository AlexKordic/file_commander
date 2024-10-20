
#ifndef _PERUN_FC_GRID_IN_MENU_
#define _PERUN_FC_GRID_IN_MENU_

#include <ftxui/component/component.hpp>
#include <ftxui/component/screen_interactive.hpp>

#include "commander.h"

#include <cstdint>
#include <vector>

namespace ftxui {

// TODO: Render only visible items. Dir can contain thousands of items but <90 are diplayed.
// TODO: - Use reflect decorator to determine the size of rendered table https://github.com/ArthurSonzogni/FTXUI/discussions/423
Component FileList(Dir* dir, Component filter, StringRef filter_text);

Element coloredInt(int64_t n);

}

#endif // _PERUN_FC_GRID_IN_MENU_
