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

  Component container;
  Component renderer;

  Dialog(Component c, Component r) : container(std::move(c)), renderer(std::move(r)) {}
  Dialog() = default;

  virtual void OnShow(std::shared_ptr<CommandArgs> data) = 0;
};

struct Files : Dialog {
  Component   files;
  std::string filter_txt;
  Component   sort_name, sort_size, sort_time;

  PanelSharedState::P state;

  Err  init(PanelSharedState::P s);
  void OnShow(std::shared_ptr<CommandArgs> data) override {}
};

struct Nyi : Dialog {
  Nyi(PanelSharedState::P s);
  void OnShow(std::shared_ptr<CommandArgs> data) override {}
};

}  // namespace ftxui

#endif  // _PERUN_FC_DIALOGS_
