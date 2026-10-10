#pragma once

// One side of the two-pane layout without any UI toolkit: tabs, the active
// tab's listing, cursor, filter, columns, directory loads and watchers. The
// FTXUI Panel and the macOS app both present this state. Every method runs on
// the owner's thread; workers only post closures back through `post`.

#include "archive.hpp"
#include "commander.hpp"
#include "fifo_queue.hpp"
#include "latest_work.hpp"
#include "workspace.hpp"

#include <atomic>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

class PaneModel {
 public:
  using Post = std::function<void(std::function<void()>)>;
  using Emit = std::function<void(const std::string&, const std::string&)>;
  using DirectoryReader = std::function<Err(Dir&, const Filepath&, const std::atomic<bool>*)>;

  struct Tab {
    Dir                          dir;
    int                          cursor = 0;  // Index into dir.items.
    std::string                  filter;
    bool                         permissions = false, owner_group = false;
    std::vector<ResolvedArchive> archive_stack;
    std::optional<TabWorkspace>  restore;
    std::string                  remote_error;
    bool                         tutorial = false;  // Opened by an explainer; closed when it ends.
  };

  PaneModel(Filepath initial, Post post, Emit emit, DirectoryReader reader = {});
  ~PaneModel();
  PaneModel(const PaneModel&) = delete;
  PaneModel& operator=(const PaneModel&) = delete;

  // Revisions: content changes the listing; layout changes tabs, path or columns.
  uint64_t revision() const { return _revision; }
  void     touch() { ++_revision; }

  const Tab& active() const { return _tabs[_active]; }
  Tab&       active() { return _tabs[_active]; }
  Dir&       dir() { return active().dir; }
  const Dir& dir() const { return active().dir; }
  int        tab_count() const { return int(_tabs.size()); }
  int        active_tab_index() const { return _active; }
  const Tab& tab(int index) const { return _tabs.at(index); }
  Location   location() const;
  Location   tab_location(int index) const;

  bool   loading() const { return _loading; }
  bool   loading_unattended() const { return _loading_unattended; }
  double last_load_ms() const { return _last_load_ms; }
  bool   in_archive_view() const;
  void   cancel_loading();

  // Navigation.
  void     move_to(const Filepath& where, Filepath focus = {});
  void     refresh();
  bool     enter(int item_index);  // Directory or archive; false for other files.
  void     leave();
  Filepath focused_dir() const;
  void     restart_initial_load();

  // Tabs.
  void new_tab(std::optional<Filepath> where = {}, bool tutorial = false);
  void close_tab(int index);
  void close_tutorial_tabs();
  // Marks tabs whose location starts with `prefix` as tutorial tabs (after a restart).
  void adopt_tutorial_tabs(const std::string& prefix);
  void cycle_tab(int delta);
  void switch_to_tab(int index);
  void move_tab(int from, int to);

  // Listing state.
  const std::vector<int>& visible_rows();  // Item indices in display order.
  int                     row_of_item(int item_index);
  int                     cursor() const { return active().cursor; }
  const DirItem*          cursor_item() const;
  void                    set_cursor(int item_index);
  void                    set_filter(std::string text);
  void                    set_sort(Orderby order);
  void                    set_columns(bool permissions, bool owner_group);
  void                    toggle_select(int item_index);
  void                    set_selected(int item_index, bool selected);
  void                    select_all();
  void                    clear_selection();
  int                     glob_select(const std::string& pattern, bool select);
  CommandArgs::P          command_args() const;  // Selection, or the cursor item when nothing is selected.

  // Workspace.
  // Tutorial tabs are left out unless `with_tutorial` (an explainer that restarts the app).
  PanelWorkspace capture_workspace(bool with_tutorial = false) const;
  void           restore_workspace(const PanelWorkspace&);

 private:
  void load_directory(Filepath where, bool archive, bool recover, Filepath focus = {}, bool background_refresh = false);
  void load_active_tab();
  void load_delta(UpdatedFiles batch);
  void apply_changes(UpdatedFiles batch);
  void start_watcher(const Filepath& where);
  void restore_cursor(const Filepath& focused_before, int index_before);
  void prune_archive_stack(const Filepath& path);
  bool leave_virtual_dir();
  void changed() { ++_revision; _visible_dirty = true; }

  Post                               _post;
  Emit                               _emit;
  DirectoryReader                    _read_directory;
  std::vector<Tab>                   _tabs;
  int                                _active = 0;
  std::shared_ptr<std::atomic<bool>> _alive = std::make_shared<std::atomic<bool>>(true);
  LatestWork                         _loader;
  std::unique_ptr<FileChangeFunnel>  _funnel;
  Perun::FifoQueue<UpdatedFiles>     _pending_changes;
  uint64_t                           _watch_generation = 0;
  uint64_t                           _load_generation  = 0;
  uint64_t                           _revision         = 1;
  bool                               _loading            = false;
  bool                               _loading_unattended = false;
  bool                               _refresh_after_load = false;
  double                             _last_load_ms       = 0;
  std::vector<int>                   _visible;
  bool                               _visible_dirty = true;
};

bool glob_match_casefold(const std::string& pattern, const std::string& text);
