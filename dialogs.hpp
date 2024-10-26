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

  PanelSharedState::P app;
  Component           navigation;
  Component           renderer;

  // Dialog(Component c, Component r) : navigation(std::move(c)), renderer(std::move(r)) {}
  explicit Dialog(PanelSharedState::P app);

  virtual void OnShow() = 0;
};

struct Files : Dialog {
  Component   files;
  std::string filter_txt;
  Component   sort_name, sort_size, sort_time;

  explicit Files(PanelSharedState::P s);
  void OnShow() override {}
};

struct MkdirDialog : Dialog {
  std::string new_dir_name;
  std::string error;

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

struct ToClipboardDialog : Dialog {
  ToClipboardDialog(PanelSharedState::P data);
  void OnShow() override;

  int       items_copied = 0;
  Component button_close;
  Element   render();
};

struct CopyDialog : Dialog {};

struct Nyi : Dialog {
  Nyi(PanelSharedState::P s);
  void OnShow() override {}
};

}  // namespace ftxui

#endif  // _PERUN_FC_DIALOGS_
