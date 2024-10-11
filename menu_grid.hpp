
#ifndef _PERUN_FC_GRID_IN_MENU_
#define _PERUN_FC_GRID_IN_MENU_

#include <ftxui/component/component.hpp>

#include "commander.h"

#include <vector>

namespace ftxui {

// TODO: Render only visible items. Dir can contain thousands of items but <90 are diplayed.
// TODO: - Use reflect decorator to determine the size of rendered table https://github.com/ArthurSonzogni/FTXUI/discussions/423
Component GridMenu(std::vector<DirItem>* entries, int* selected);

}

#endif // _PERUN_FC_GRID_IN_MENU_
