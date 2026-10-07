#ifndef _PERUN_FC_DIALOGS_
#define _PERUN_FC_DIALOGS_

#include "commander.hpp"
#include "commands.hpp"
#include "archive.hpp"
#include "copy_planner.hpp"
#include "file_io_jobs.hpp"
#include "shared_state.hpp"
#include "editor_manager.hpp"

#include <cstdint>
#include <ftxui/component/component.hpp>
#include <ftxui/component/event.hpp>

#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace ftxui {

Element screen_render_time();

Decorator filetype_color(const DirItem& item);

struct ThemeColorEntry {
  std::string id;
  std::string label;
  std::string token;
};

struct Dialog {
  using P = std::shared_ptr<Dialog>;

  PanelSharedState::P app;
  Component           navigation;
  Component           renderer;

  // Dialog(Component c, Component r) : navigation(std::move(c)), renderer(std::move(r)) {}
  explicit Dialog(PanelSharedState::P app);
  virtual ~Dialog() { _alive->store(false); }
  std::shared_ptr<std::atomic<bool>> _alive=std::make_shared<std::atomic<bool>>(true);
  uint64_t _submission_generation=0;
  std::shared_ptr<Perun::JobSpec> _pending;
  bool submit(Perun::OperationPlan,std::function<void(const Perun::JobSnapshot&)>);
  void cancel_submission();

  virtual void OnShow() = 0;
};

struct Files : Dialog {
  Component files;
  // std::string filter_txt;
  Component sort_name, sort_size, sort_time;
  int       filter_cursor_pos = 0;

  explicit Files(PanelSharedState::P s);
  void OnShow() override {}
  bool execute_command(const std::string& id);

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

struct GlobSelectDialog : Dialog {
  GlobSelectDialog(PanelSharedState::P s, bool select_mode);
  void OnShow() override;

  std::string pattern;
  std::string error;
  bool        select_mode = true;
  int         cursor_pos  = 0;

  Component input_pattern;
  Component button_ok;
  Component button_close;

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
  std::vector<std::unique_ptr<Item>> rows;

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

struct CopyDiscoveryProcess : CopyPlanner {
  using P = std::shared_ptr<CopyDiscoveryProcess>;
  DataSource _data_source;
  Component _files;
  PanelSharedState::P _state;
  std::unique_ptr<Dir> _dir;
  bool _completed=false;
  CopyDiscoveryProcess(CopyDialog* parent,Filepath target);
  void publish_preview();
};

struct CopyDialog : Dialog {
  CopyDialog(PanelSharedState::P data);
  void OnShow() override;

  std::string destination_path;
  bool _confirm_when_ready = false;

  Component button_cancel, button_ok;
  Component op_follow_links;
  Component op_preserve_relative_links;
  Component op_conflict_mode;
  Component input_destination_path;
  int       filter_cursor_pos      = 0;
  int       destination_cursor_pos = 0;
  int       conflict_mode_selected = 0;

  std::vector<std::string> conflict_mode_labels;

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

struct FindDialog : Dialog {
  FindDialog(PanelSharedState::P s);
  ~FindDialog();
  void OnShow() override;

  std::string root_path;
  std::string pattern;
  std::string status;
  int         root_cursor_pos    = 0;
  int         pattern_cursor_pos = 0;

  Component input_root;
  Component input_pattern;
  Component button_find;
  Component button_open;
  Component button_close;
  Component results_menu;

  DataSource _data_source;

  std::vector<Filepath> _results;
  std::mutex            _results_mutex;
  std::thread           _worker;
  std::atomic<bool> _truncated{false};
  std::atomic<bool>     _running{false};
  std::atomic<bool>     _completed{false};
  uint64_t _sequence_id = 0;
  std::atomic<int64_t>  _dirs_scanned{0};
  std::atomic<int64_t>  _files_scanned{0};
  std::atomic<int64_t>  _errors{0};

  void start_search();
  void stop_search();
  void open_selected();
  void cancel();
};

struct Nyi : Dialog {
  Nyi(PanelSharedState::P s);
  void OnShow() override {}
  bool execute_command(const std::string& id);
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

struct JobListDialog : Dialog {
  JobListDialog(std::function<void()> close_dialog);
  void OnShow() override;
  void cancel();

  // Job list view (DataSource-backed)
  std::vector<std::shared_ptr<const Perun::JobSnapshot>> jobs;
  DataSource _job_data_source;
  Component  _job_list;
  Component  button_close;
  Component  button_dismiss_all;

  // Detail view (DataSource-backed)
  bool                            in_detail = false;
  int                             view_mode = 0;  // 0=list, 1=detail
  std::shared_ptr<const Perun::JobSnapshot> detail_job;
  DataSource                      _detail_items_data_source;
  Component                       _detail_items;
  DataSource                      _detail_errors_data_source;
  Component                       _detail_errors;
  Component                       detail_back_button;
  Component                       detail_close_button;

  Component tab;

  std::function<void()> close_dialog;

  void    open_detail();
  void    close_detail();
  void    dismiss_selected();
  void    dismiss_all_clean();
  void    rebuild_list();
  Element render_list();
  Element render_detail();

  static std::string state_icon(Perun::JobState state);
  static std::string format_duration(double seconds);
  static std::string format_bytes(double bytes);
};

struct BookmarksDialog : Dialog {
  BookmarksDialog(
    std::function<void()> close_dialog,
    std::function<std::vector<Filepath>()> list_bookmarks,
    std::function<void()> add_current_dir,
    std::function<void(const Filepath&)> remove_bookmark,
    std::function<void(const Filepath&)> open_bookmark
  );
  void OnShow() override;
  void cancel();

  std::function<void()> close_dialog;
  std::function<std::vector<Filepath>()> list_bookmarks;
  std::function<void()> add_current_dir;
  std::function<void(const Filepath&)> remove_bookmark;
  std::function<void(const Filepath&)> open_bookmark;

  std::vector<Filepath> bookmarks;
  DataSource            _data_source;
  Component             list_menu;
  Component             button_add;
  Component             button_remove;
  Component             button_open;
  Component             button_close;

  void refresh();
  bool has_selected() const;
  int64_t selected_index() const;
  void run_open();
  void run_add();
  void run_remove();
};

struct RestartEditorDialog : Dialog {
  RestartEditorDialog(std::function<void()> close_dialog,
    std::function<EditorManager::RestartResult(bool, std::string&)> prepare,
    std::function<void()> attach);
  void OnShow() override;
  void restart();
  std::function<void()> close_dialog, attach;
  std::function<EditorManager::RestartResult(bool, std::string&)> prepare;
  Component button_restart, button_cancel;
  bool legacy_confirmation = false;
  std::string error;
};

struct ConnectSSHDialog : Dialog {
  ConnectSSHDialog(std::function<void()> close,
                   std::function<bool(const std::string &, const std::string &, std::string &)> connect);
  void OnShow() override;
  std::string host, path = "/", error;
  Component host_input, path_input;
};

struct CommandPaletteDialog : Dialog {
  CommandPaletteDialog(
    std::function<void()> close_dialog,
    std::function<std::vector<Command>()> list_commands,
    std::function<void(const std::string&)> execute_command,
    std::function<bool(const std::string&, const Event&, std::string&)> rebind_command
  );
  void OnShow() override;
  void cancel();

  std::function<void()> close_dialog;
  std::function<std::vector<Command>()> list_commands;
  std::function<void(const std::string&)> execute_command;
  std::function<bool(const std::string&, const Event&, std::string&)> rebind_command;

  std::string filter_txt;
  int         filter_cursor_pos = 0;
  DataSource  _data_source;
  Component   input_filter;
  Component   list_menu;
  Component   button_close;
  Component   button_run;
  Component   button_rebind;

  std::vector<Command> commands_all;
  std::vector<int64_t> visible_ids;
  std::string          status_message;
  bool                 capture_key_mode = false;

  void apply_filter();
  void run_selected();
  void start_rebind();
  bool capture_rebind_key(const Event& e);
};

struct ThemeColorsDialog : Dialog {
  ThemeColorsDialog(
    std::function<void()> close_dialog,
    std::function<std::vector<ThemeColorEntry>()> list_entries,
    std::function<std::vector<std::string>()> list_tokens,
    std::function<bool(const std::string&, const std::string&, std::string&)> set_color_token,
    std::function<void()> reset_defaults,
    std::function<void()> persist_colors
  );
  void OnShow() override;
  void cancel();

  std::function<void()> close_dialog;
  std::function<std::vector<ThemeColorEntry>()> list_entries;
  std::function<std::vector<std::string>()> list_tokens;
  std::function<bool(const std::string&, const std::string&, std::string&)> set_color_token;
  std::function<void()> reset_defaults;
  std::function<void()> persist_colors;

  std::vector<ThemeColorEntry> entries;
  std::vector<std::string>     tokens;
  DataSource                   _data_source;
  Component                    list_menu;
  Component                    button_save;
  Component                    button_reset;
  Component                    button_close;
  std::string                  status_message;
  bool                         picker_open = false;
  std::vector<std::vector<int>> picker_grid;
  int                          picker_row = 0;
  int                          picker_col = 0;

  void open_picker_for_focused();
  void move_picker(int drow, int dcol);
  void accept_picker();
  void cancel_picker();
  int  selected_picker_index() const;
  Element render_picker() const;
};

}  // namespace ftxui

#endif  // _PERUN_FC_DIALOGS_
