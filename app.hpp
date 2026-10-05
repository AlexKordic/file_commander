#ifndef FC_APP_HPP_
#define FC_APP_HPP_

// Application-level classes: DialogOverlay, Panel, FileCommander
// UI assembly declarations. Implementations live in app.cpp.

#include "application_events.hpp"
#include "archive.hpp"
#include "bfs.hpp"
#include "commander.hpp"
#include "custom_controls.hpp"
#include "dialogs.hpp"
#include "editor_manager.hpp"
#include "workspace.hpp"
#include "file_io_jobs.hpp"
#include "latest_work.hpp"
#include "log.hpp"
#include "theme.hpp"

#include <deque>
#include <ftxui/component/component.hpp>
#include <ftxui/component/component_base.hpp>
#include <ftxui/component/component_options.hpp>
#include <ftxui/dom/elements.hpp>

#include <functional>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include <boost/filesystem.hpp>

using namespace ftxui;
using namespace Perun;

class Panel;

using TargetFunc = std::function<Filepath(Panel*)>;

using ExecuteOnUiThread = std::function<void(std::function<void()>)>;
using RunWithRestoredIO = std::function<int(std::function<int()>)>;

class DialogOverlay {
 public:
  Component   navigation;
  int         _active_dialog = 0;
  std::string _active_dialog_name;

  // Application event publisher; configured by FileCommander at composition.
  std::function<void(const std::string&, const std::string&)> on_event;

  ftxui::Dialog::P get_overlay_dialog(const std::string& name);

 protected:
  ftxui::Dialog::P                        _main_document;     // always rendered, always first child of Panel::container
  Component                               _overlay_renderer;  // selected renderer from _overlay_dialogs, always second child of Panel::container
  std::map<std::string, ftxui::Dialog::P> _overlay_dialogs;

  bool dialog_active();

  void close_dialog();
  void show_dialog(std::string name);
};

// DialogOverlay supports drawing overlay dialogs on top of this Panel.
class Panel : public DialogOverlay {
 public:
  using ArchiveView = ResolvedArchive;

  struct TabState {
    Dir                      dir;
    int                      focused_index = 0;
    std::string              filter_txt;
    bool                     show_permissions_column = false;
    bool                     show_owner_group_column = false;
    std::vector<ArchiveView> archive_stack;
    std::optional<TabWorkspace> restore;
  };

  Dir        dir;
  TargetFunc get_target;

  std::shared_ptr<std::atomic<bool>> _callback_alive = std::make_shared<std::atomic<bool>>(true);
  ExecuteOnUiThread                  run_on_ui;
  std::unique_ptr<FileChangeFunnel>  update_funnel;
  Perun::FifoQueue<UpdatedFiles>     pending_changes;
  uint64_t                           _watch_generation = 0;
  using DirectoryReader                                = std::function<Err(Dir&, const Filepath&, const std::atomic<bool>*)>;
  DirectoryReader _read_directory;
  LatestWork      _loader;
  uint64_t        _load_generation    = 0;
  uint64_t        items_revision      = 0;
  bool            _loading            = false;
  bool            _refresh_after_load = false;
  Filepath        _loading_path;
  bool            loading() const;
  void            cancel_loading();

  ~Panel();

  Panel(Filepath location, TargetFunc get_target, ExecuteOnUiThread e, DirectoryReader reader = {}, bool defer_load = false);

  int tab_count() const;
  int active_tab_index() const;

  std::vector<Filepath> tab_paths() const;
  PanelWorkspace capture_workspace() const;
  void restore_workspace(const PanelWorkspace&);

  void new_tab();

  void close_tab();

  void cycle_tab(int delta);

  int tab_index_at_mouse(Event event) const;

  void switch_to_tab(int index);

  Location location() const;

  void move_to(const Filepath& where, Filepath focus = {});

  void     load_directory(Filepath where, bool archive, bool recover, Filepath focus = {}, bool background_refresh = false);
  Element  render();
  Filepath focused_dir();

  bool enter_archive(const Filepath& archive_candidate);

  bool leave_virtual_dir(int64_t& focused_id);

  bool execute_file_command(const std::string& id);

  void execute_dialog_command(const std::string& dialog_name);

  void set_debug_info(std::function<Element()> info);

  PanelSharedState::P get_shared_state() const;

 private:
  Element render_tabs() const;

  void sync_active_tab_state();

  void start_watcher(const Filepath& where);

 public:
  // Apply a watcher batch on the UI thread.
  void apply_changes(UpdatedFiles batch);

  void load_delta(UpdatedFiles batch);

 private:
  void load_active_tab();

  void _restore_focus_after_update(const Filepath& focused_path_before, int focused_index_before);

  bool in_archive_view(const Filepath& path) const;

  void _prune_archive_stack(const Filepath& path);

  PanelSharedState::P      _state;
  std::shared_ptr<Files>   _files;
  std::vector<TabState>    _tabs;
  std::vector<ArchiveView> _archive_stack;
  mutable std::vector<Box> _tab_boxes;
  int                      _active_tab = 0;
};

inline std::string job_type_to_string(JobInstructions::Type type) {
  switch (type) {
  case JobInstructions::Type::COPY: return "COPY";
  case JobInstructions::Type::MOVE: return "MOVE";
  case JobInstructions::Type::DELETE: return "DELETE";
  case JobInstructions::Type::ARCHIVE_CREATE: return "ARCHIVE";
  case JobInstructions::Type::MKDIR: return "MKDIR";
  case JobInstructions::Type::RENAME: return "RENAME";
  case JobInstructions::Type::CLIPBOARD: return "CLIPBOARD";
  default: return "?";
  }
}

struct JobProgressBar {
  bool      _has_running_job = false;
  Component cancel_button;
  Component pause_button;

  JobProgressBar();

  Element render();
};

class FileCommander : public DialogOverlay {
 protected:
  Panel                 left, right;
  JobProgressBar        progress_bar;
  std::deque<double>    clear_errors_sequence;
  std::vector<Location> _bookmarks;
  bool                  _last_main_focus_left = true;
  bool                  _single_panel_mode    = false;
  EditorManager         _editor_manager;
  RunWithRestoredIO     _run_with_restored_io;

  std::function<void()> _close_dialog;
  std::function<int()>  _get_dimx;

 public:
  int       _left_size   = 20;
  int       _screen_dimx = 0;
  Component renderer;

  Panel& get_left();
  Panel& get_right();
  bool   single_panel_mode() const;
  Panel& focused_panel();

  std::vector<Filepath> focused_selection_for_editor();

  bool open_in_editor(std::string& error);

  std::vector<Command> list_palette_commands();

  std::vector<ThemeColorEntry> list_theme_colors() const;

  bool set_theme_color(const std::string& id, const std::string& token, std::string& error);

  void reset_theme_colors();

  bool apply_key_bindings(const std::map<std::string, std::string>& bindings, std::string& error);

  bool rebind_palette_command(const std::string& id, const Event& key, std::string& error);

  void start_initial_navigation();

  void load_settings(bool restore_paths);

  void save_settings() const;
  void enable_workspace(bool restore_paths);
  void checkpoint_workspace(bool force = false);

  std::vector<Filepath> list_bookmarks() const;
  void                  add_bookmark(const Filepath& path);
  void                  remove_bookmark(const Filepath& path);

  void open_bookmark(const Filepath& path);

  void add_current_focused_dir_bookmark();

  void set_single_panel_mode(bool enabled);

  struct CommandHandler {
    std::function<bool()> run, available;
  };
  std::map<std::string, CommandHandler> handlers;
  std::shared_ptr<ApplicationEvents>    events           = std::make_shared<ApplicationEvents>();
  uint64_t                              command_sequence = 0;
  void                                  register_commands();
  bool                                  command_available(const std::string& id);
  bool                                  execute_command(const std::string& id);
  void                                  execute_palette_command(const std::string& id);
  struct ViewObservation {
    uint64_t left_revision = 0, right_revision = 0;
    int64_t  left_selected = 0, right_selected = 0;
    bool     focus_left = true, single = false;
  };
  std::optional<ViewObservation> last_view;
  void                           observe_state();

  FileCommander(Filepath l, Filepath r, ExecuteOnUiThread exec, std::function<int()> dimx, RunWithRestoredIO run_with_restored_io = {}, bool defer_load = false);
  // returns
  TargetFunc get_target();

 private:
  static void save_theme_colors();
  bool _workspace_enabled = false;
  std::string _last_workspace_text;
  std::chrono::steady_clock::time_point _last_workspace_check{};

 public:
  bool handle_global_shortcuts(Event event);
};

#endif  // FC_APP_HPP_
