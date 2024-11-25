
#include "shared_state.hpp"
#include "bfs.hpp"

PanelSharedState::PanelSharedState(Dir* d) : dir(d) {
  move_to             = [](boost::filesystem::path p) {};
  get_focused_item    = []() -> Filepath const* { return nullptr; };
  action.close_dialog = []() {};
  action.show_dialog  = []() {};
}
