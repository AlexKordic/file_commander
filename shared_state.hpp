#ifndef _PERUN_FC_SHARED_STATE_
#define _PERUN_FC_SHARED_STATE_

#include "bfs.hpp"

#include <ftxui/component/component.hpp>

#include <functional>
#include <memory>

class Dir;
struct CommandArgs;

struct PanelSharedState {
  using P = std::shared_ptr<PanelSharedState>;

  Dir*             dir;
  ftxui::Component filter;
  struct Action {
    std::shared_ptr<CommandArgs> arguments;
    std::string                  dialog;
    std::function<void()>        show_dialog;
    std::function<void()>        close_dialog;
  } action;
  bool    commands_enabled = true;
  int64_t render_count     = 0;

  std::function<void(Filepath)>    move_to;
  std::function<Filepath const*()> get_focused_item;

  explicit PanelSharedState(Dir* d);
  PanelSharedState() = delete;
};

#endif  // _PERUN_FC_SHARED_STATE_
