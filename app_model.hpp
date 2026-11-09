#pragma once

// The application without a UI toolkit: two panes, the command catalog and
// its single dispatch path, bookmarks, settings, the workspace checkpoint and
// the editor. The macOS app drives it through fc_engine.hpp. Everything here
// runs on the owner's (main) thread.

#include "application_events.hpp"
#include "dialog_models.hpp"
#include "editor_manager.hpp"
#include "pane_model.hpp"
#include "settings.hpp"
#include "workspace.hpp"

#include <chrono>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

// One command. Keys are portable chords such as "F5", "Ctrl+T" or
// "Shift+Cmd+P"; the app matches them, the model only stores them.
struct AppCommand {
  std::string id, title, menu, scope, dialog, commander_key, mac_key, help;
  bool        hidden = false;  // Not in the palette or menus.
};
const std::vector<AppCommand>& app_commands();
const AppCommand*              find_app_command(const std::string& id);

// A request for the interface to show something, produced by a command.
struct DialogRequest {
  std::string           name;
  int                   side = 0;
  std::vector<Filepath> selected;
  Filepath              focused, origin, target;
};

class AppModel {
 public:
  using Post = std::function<void(std::function<void()>)>;
  AppModel(Filepath left, Filepath right, Post post);
  ~AppModel();

  PaneModel& pane(int side) { return side == 0 ? *_left : *_right; }
  int        focused_side() const { return _focused; }
  void       set_focused_side(int side);
  bool       single_pane() const { return _single; }
  void       set_single_pane(bool on);
  uint64_t   layout_revision() const { return _layout_revision; }
  uint64_t   bookmarks_revision() const { return _bookmarks_revision; }

  // Commands: the one dispatch path for keys, menus, the palette and explainers.
  bool                     available(const std::string& id);
  bool                     execute(const std::string& id);
  std::vector<std::string> palette(const std::string& query);
  int                      use_count(const std::string& id) const;

  std::vector<DialogRequest> take_dialog_requests() { return std::exchange(_dialogs, {}); }
  std::vector<std::string>   take_notices() { return std::exchange(_notices, {}); }

  // Bookmarks are locations, kept sorted by display name.
  const std::vector<Location>& bookmarks() const { return _bookmarks; }
  void                         add_bookmark(const Filepath& path);
  void                         remove_bookmark(const Filepath& path);

  // Settings, shared with the terminal interface through settings.json.
  void     load_settings(bool restore_paths);
  void     save_settings();
  void     settings_changed() { _settings_dirty = true; }
  uint64_t transfer_rate() const;
  void     set_transfer_rate(uint64_t bytes_per_second, bool persist);

  // Workspace checkpoint: call often; it writes at most every 500 ms.
  void enable_workspace(bool restore);
  void checkpoint_workspace(bool force = false);
  void tick();  // Periodic housekeeping: workspace, settings, state events.
  // While an explainer that restarts the app runs, its tabs are checkpointed too.
  bool keep_tutorial_tabs = false;

  std::shared_ptr<ApplicationEvents> events = std::make_shared<ApplicationEvents>();
  void                               emit(const std::string& name, const std::string& detail, uint64_t request = 0) { events->publish(name, detail, request); }
  void                               observe_state();

  EditorManager& editor() { return _editor; }
  std::string    open_in_editor();
  std::string    switch_to_editor();
  void           notice(std::string text) { _notices.push_back(std::move(text)); }

  // Clipboard: copies the focused pane's names or paths through a job.
  void copy_to_clipboard(int side, bool names);
  // Opens an SSH location in a new tab of the focused pane.
  void open_ssh(const std::string& host, const std::string& path);
  // The extraction popup: asks the front end, through an "Extract" dialog request, where to extract `archive`.
  void offer_extraction(int side, const Filepath& archive);

 private:
  void register_commands();
  void request_dialog(const std::string& name, bool with_selection);

  struct Handler {
    std::function<void()> run;
    std::function<bool()> available;
  };
  Post                           _post;
  std::unique_ptr<PaneModel>     _left, _right;
  int                            _focused = 0;
  bool                           _single  = false;
  uint64_t                       _layout_revision = 1, _bookmarks_revision = 1;
  std::map<std::string, Handler> _handlers;
  std::map<std::string, int>     _use_counts;
  uint64_t                       _command_sequence = 0;
  std::vector<DialogRequest>     _dialogs;
  std::vector<std::string>       _notices;
  std::vector<Location>          _bookmarks;
  EditorManager                  _editor;
  std::optional<AppSettings>     _loaded_settings;  // Keeps what only the terminal interface uses.
  uint64_t                       _transfer_rate_saved = 0;
  bool                           _settings_dirty = false;
  bool                           _workspace_enabled = false;
  std::string                    _last_workspace_text;
  std::chrono::steady_clock::time_point _last_workspace_check{}, _last_settings_save{};
  struct Observation {
    uint64_t left = 0, right = 0;
    int64_t  left_selected = 0, right_selected = 0;
    int      focus = 0;
    bool     single = false;
  };
  std::optional<Observation> _last_view;
};
