
#include "shared_state.hpp"

PanelSharedState::PanelSharedState(Dir* d) : dir(d) {
  move_to = [](boost::filesystem::path p) {};
}

