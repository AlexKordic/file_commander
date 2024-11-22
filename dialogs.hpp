#ifndef _PERUN_FC_DIALOGS_
#define _PERUN_FC_DIALOGS_

#include "commander.hpp"
#include "shared_state.hpp"

// #include <boost/filesystem.hpp>
#include <ftxui/component/component.hpp>
#include <ftxui/component/event.hpp>

#include <memory>
#include <string>

using RedrawUI = std::function<void()>;

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

struct CopyDialog : Dialog {
  RedrawUI redraw_ui;
  CopyDialog(PanelSharedState::P data, RedrawUI r);
  void OnShow() override;

  std::string destination_path;

  Component button_cancel, button_ok;
  Component op_follow_links;
  Component op_preserve_relative_links;
  Component input_destination_path;

  Component files;

  bool b_follow_links            = false;
  // bool b_preserve_timestamps     = true;
  // bool b_preserve_ownership      = false;
  bool b_preserve_relative_links = true;

  Element render();
  void    run_copy();
  void    cancel_copy();

  PanelSharedState::P  _operation_state;
  std::string          _filter_text;
  std::unique_ptr<Dir> _virtual_dir; // enumerate items to copy
  void _clear_operation_state();

  struct Visited {
    DirItem  source;
    Filepath destination;
  };
  std::vector<Visited> _visited_dirs;

  void _queue_files(const std::vector<DirItem>& files, Filepath destination);
};

struct Nyi : Dialog {
  Nyi(PanelSharedState::P s);
  void OnShow() override {}
};

}  // namespace ftxui

#endif  // _PERUN_FC_DIALOGS_
