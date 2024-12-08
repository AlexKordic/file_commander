#ifndef _PERUN_FC_SHARED_STATE_
#define _PERUN_FC_SHARED_STATE_

#include "bfs.hpp"

#include <ftxui/component/component.hpp>

#include <functional>
#include <memory>

class Dir;
class DirItem;
struct CommandArgs;

// struct RowInfo {
//   const bool     is_menu_focused;
//   const float    max_size;
//   int            index    = 0;
//   bool           focused  = false;
//   bool           selected = false;
//   ftxui::Box*    box      = nullptr;
//   const DirItem* data     = nullptr;

//   RowInfo(bool menu_focused, float max_size);
// };

struct PanelSharedState {
  using P = std::shared_ptr<PanelSharedState>;

  Dir*             dir;
  ftxui::Component filter;
  std::string      filter_txt;
  struct Action {
    std::shared_ptr<CommandArgs> arguments;
    std::string                  dialog;
    std::function<void()>        show_dialog;
    std::function<void()>        close_dialog;
  } action;
  // bool    commands_enabled = true;
  int64_t render_count     = 0;

  // std::function<ftxui::Element(RowInfo&)> transform;
  std::function<void(Filepath)>           move_to;
  std::function<void(int)>                set_min_y;
  std::function<Filepath const*()>        get_focused_item;
  std::function<void(int)>                set_focused_index;
  std::function<int()>                    get_focused_index;

  explicit PanelSharedState(Dir* d);
  PanelSharedState() = delete;
};

#endif  // _PERUN_FC_SHARED_STATE_
