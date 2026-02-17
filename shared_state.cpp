
#include "shared_state.hpp"

#include <ftxui/dom/elements.hpp>
#include "bfs.hpp"

PanelSharedState::PanelSharedState(Dir* d) : dir(d) {
  move_to             = [](boost::filesystem::path p) {};
  enter_archive       = [](const Filepath&) -> bool { return false; };
  leave_virtual_dir   = [](int64_t&) -> bool { return false; };
  get_focused_item    = []() -> Filepath const* { return nullptr; };
  set_focused_index   = [](int index) {};
  get_focused_index   = []() -> int { return 0; };
  set_min_y           = [](int y) {};
  action.close_dialog = []() {};
  action.show_dialog  = []() {};
}
