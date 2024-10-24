#ifndef _PERUN_FC_DIALOGS_
#define _PERUN_FC_DIALOGS_

#include "err.hpp"
#include "shared_state.hpp"

#include <ftxui/component/component.hpp>
#include <ftxui/component/event.hpp>

#include <map>
#include <memory>
#include <string>

namespace ftxui {

struct Command {
  Event       key;
  std::string dialog;
};

struct Commands {
  std::vector<Command> available;
  Commands();
};

Commands& commands();

struct Dialog {
  using P = std::shared_ptr<Dialog>;

  Component navigation;
  Component renderer;

  Dialog(Component c, Component r) : navigation(std::move(c)), renderer(std::move(r)) {}
  Dialog() = default;

  virtual void OnShow() = 0;
};

struct Files : Dialog {
  Component   files;
  std::string filter_txt;
  Component   sort_name, sort_size, sort_time;

  PanelSharedState::P state;

  Err  init(PanelSharedState::P s);
  void OnShow() override {}
};

struct MkdirDialog : Dialog {
  std::string         new_dir_name;
  PanelSharedState::P app;
  std::string         error;

  Component textbox;
  Component button_ok;
  Component button_close;

  MkdirDialog(PanelSharedState::P s);
  void OnShow() override;

  void    ok();
  void    cancel();
  Element render();
};

struct RenameDialog : Dialog {
  PanelSharedState::P app;

  RenameDialog(PanelSharedState::P data);
  void OnShow() override;

  struct Item {
    std::string content;
    int         cursor_position = 0;
  };
  std::vector<Item> rows;

  int       selected = 0;
  Component menu;
  Component button_ok;
  Component button_close;

  void ok();
  void cancel();
};

struct Nyi : Dialog {
  Nyi(PanelSharedState::P s);
  void OnShow() override {}
};

}  // namespace ftxui

#endif  // _PERUN_FC_DIALOGS_
