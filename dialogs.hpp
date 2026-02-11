#ifndef _PERUN_FC_DIALOGS_
#define _PERUN_FC_DIALOGS_

#include "commander.hpp"
#include "shared_state.hpp"

#include <cstdint>
#include <ftxui/component/component.hpp>
#include <ftxui/component/event.hpp>

#include <memory>
#include <string>
#include <thread>

namespace ftxui {

Element screen_render_time();

Decorator filetype_color(const DirItem& item);

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
  Component files;
  // std::string filter_txt;
  Component sort_name, sort_size, sort_time;
  int       filter_cursor_pos = 0;

  explicit Files(PanelSharedState::P s);
  void OnShow() override {}

  DataSource _data_source;

  std::function<Element()> debug_info;
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

enum class CopyConflict {
  Replace,
  Update,
  Skip,
};

struct CopyDialog;

struct CopyDiscoveryProgress {
  int64_t byte_count  = 0;
  int64_t file_count  = 0;
  int64_t dir_count   = 0;
  int64_t link_count  = 0;
  int64_t error_count = 0;
  std::string current_file;
  std::string current_dir;
};

struct CopyDiscoveryProcess {
  using P = std::shared_ptr<CopyDiscoveryProcess>;

  CopyDiscoveryProgress get_progress();

  bool         _running                 = true;
  bool         _follow_links            = false;
  bool         _preserve_relative_links = true;
  CopyConflict _conflict                = CopyConflict::Replace;
  DataSource   _data_source;
  int64_t      _bytes_total = 0;
  bool         _completed   = false;
  Component    _files;

  PanelSharedState::P  _state;
  std::unique_ptr<Dir> _dir;
  struct Visited {
    DirItem  source;
    Filepath destination;
  };
  std::vector<Visited>         _visited_dirs;
  std::shared_ptr<CommandArgs> _input_paths;
  Filepath                     _target;
  std::thread                  _thread;
  std::mutex                   _m;
  CopyDiscoveryProgress        _progress;

  CopyDiscoveryProcess(CopyDialog* parent, Filepath target);
  ~CopyDiscoveryProcess();

  void _discover(const std::vector<DirItem>& files, Filepath destination);
  void _queue_link(Filepath const& location, Filepath const& destination, boost::filesystem::perms p);
  void _queue_error(const DirItem& item, Filepath const& new_record_path, std::string error_message);
  bool _queue_dir(const DirItem& item, Filepath const& new_record_path);
  void _stat_file(Filepath const& item_path);
  void _queue_file(const DirItem& item, Filepath const& new_record_path);
  void _run();
};

struct CopyDialog : Dialog {
  CopyDialog(PanelSharedState::P data);
  void OnShow() override;

  std::string destination_path;

  Component button_cancel, button_ok;
  Component op_follow_links;
  Component op_preserve_relative_links;
  Component input_destination_path;
  int       filter_cursor_pos      = 0;
  int       destination_cursor_pos = 0;

  Component _filelist_wrapper;

  bool         b_follow_links            = false;
  // bool b_preserve_timestamps     = true;
  // bool b_preserve_ownership      = false;
  bool         b_preserve_relative_links = true;
  CopyConflict _conflict                 = CopyConflict::Replace;

  CopyDiscoveryProcess::P _discovery_process;

  Element render();
  void    run_copy();
  void    cancel();

  void _clear_operation_state();
  void _start_new_discovery();
};

struct MoveDialog : Dialog {
  MoveDialog(PanelSharedState::P data);
  void OnShow() override;

  int       selected = 0;
  Component menu;
  Component button_ok;
  Component button_close;

  void                ok();
  void                cancel();
  PanelSharedState::P _operation_state;
};

struct DeleteDialog : Dialog {
  DeleteDialog(PanelSharedState::P s);
  void OnShow() override;

  int       selected = 0;
  Component menu;
  Component button_ok;
  Component button_close;
  void      ok();
  void      cancel();

  PanelSharedState::P _operation_state;
};

struct Nyi : Dialog {
  Nyi(PanelSharedState::P s);
  void OnShow() override {}
};

struct ErrorListDialog : Dialog {
  ErrorListDialog(std::function<void()> close_dialog);
  void OnShow() override;
  void cancel();
  void clear();

  Component button_hide;
  Component button_clear;
  Component _errors;
  double    latest_error_time = 0;

  DataSource _data_source;

  std::function<void()> close_dialog;
};

}  // namespace ftxui

#endif  // _PERUN_FC_DIALOGS_
