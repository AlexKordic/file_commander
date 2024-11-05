#ifndef _PERUN_FC_SHARED_STATE_
#define _PERUN_FC_SHARED_STATE_

#include <ftxui/component/component.hpp>
#include <boost/filesystem.hpp>

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

  std::function<void(boost::filesystem::path)> move_to;

  explicit PanelSharedState(Dir* d);
};

#endif  // _PERUN_FC_SHARED_STATE_
