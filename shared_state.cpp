
#include "shared_state.hpp"
#include "file_panel.hpp"

#include <ftxui/dom/elements.hpp>
#include "bfs.hpp"

PanelSharedState::PanelSharedState(Dir* d) : dir(d) {
  move_to             = [](boost::filesystem::path p) {};
  get_focused_item    = []() -> Filepath const* { return nullptr; };
  set_min_y           = [](int y) {};
  action.close_dialog = []() {};
  action.show_dialog  = []() {};
  transform           = ftxui::filelist_transform();
}
