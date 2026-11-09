#include "app_model.hpp"

#include "archive.hpp"
#include "file_io_jobs.hpp"
#include "location.hpp"
#include "operation.hpp"

#include <algorithm>

using Perun::file_operations;
using Perun::JobSnapshot;
using Perun::JobSpec;
using Perun::JobState;
using Perun::Operation;
using Perun::OperationPlan;
using Perun::OperationType;

namespace {
// id, title, menu, scope, dialog, commander key, mac key, help, hidden
const std::vector<AppCommand> kCommands = {
  {"select_toggle", "Select or Deselect Item", "Edit", "panel", "", "Space", "Space", "Marks the item under the cursor and moves down."},
  {"clear_selection", "Deselect All", "Edit", "panel", "", "Esc", "Esc", "Clears the selection in the focused pane."},
  {"select_all", "Select All", "Edit", "panel", "", "Ctrl+A", "Cmd+A", "Selects every item that matches the filter."},
  {"glob_select", "Select by Pattern…", "Edit", "panel", "GlobSelect", "+", "+", "Selects items matching a pattern such as *.jpg."},
  {"glob_deselect", "Deselect by Pattern…", "Edit", "panel", "GlobDeselect", "-", "-", "Deselects items matching a pattern."},
  {"names_to_clipboard", "Copy Names", "Edit", "panel", "", "Ctrl+N", "Cmd+C", "Copies the selected names to the clipboard, in display order."},
  {"paths_to_clipboard", "Copy Paths", "Edit", "panel", "", "Ctrl+P", "Opt+Cmd+C", "Copies the selected full paths to the clipboard, in display order."},
  {"find", "Find…", "Edit", "panel", "Find", "F3", "Cmd+F", "Finds files by name below a folder."},
  {"enter_dir", "Open", "Go", "panel", "", "Enter", "Cmd+Down", "Opens the folder or archive under the cursor; offers to extract a compressed file."},
  {"open_as_archive", "Open as Archive", "Go", "panel", "", "Ctrl+PageDown", "Opt+Cmd+Down", "Browses the file under the cursor as an archive, whatever its name."},
  {"leave_dir", "Enclosing Folder", "Go", "panel", "", "?", "Cmd+Up", "Goes to the parent folder."},
  {"switch_panel", "Switch Pane", "Go", "global", "", "Tab", "Tab", "Moves the focus to the other pane."},
  {"target_right", "Show in Right Pane", "Go", "global", "", "Ctrl+Right", "Opt+Cmd+Right", "Shows the focused folder in the right pane."},
  {"target_left", "Show in Left Pane", "Go", "global", "", "Ctrl+Left", "Opt+Cmd+Left", "Shows the focused folder in the left pane."},
  {"open_bookmarks", "Bookmarks", "Go", "global", "Bookmarks", "Ctrl+B", "Opt+Cmd+B", "Shows your bookmarks."},
  {"add_bookmark", "Bookmark This Folder", "Go", "global", "", "", "Ctrl+Cmd+T", "Adds the focused pane's folder to the bookmarks."},
  {"copy", "Copy to Other Pane…", "File", "panel", "Copy", "F5", "Shift+Cmd+C", "Copies the selection; the destination defaults to the other pane."},
  {"move", "Move to Other Pane…", "File", "panel", "Move", "F6", "Shift+Cmd+X", "Moves the selection into the other pane's folder."},
  {"mkdir", "New Folder…", "File", "panel", "Mkdir", "F7", "Shift+Cmd+N", "Creates a folder."},
  {"rename", "Rename…", "File", "panel", "Rename", "F2", "Enter", "Renames the selected items."},
  {"delete", "Delete Immediately…", "File", "panel", "Delete", "F8", "Opt+Cmd+Backspace", "Deletes the selection permanently. There is no trash."},
  {"open_in_editor", "Open in Editor", "File", "global", "", "F4", "Cmd+O", "Opens the selected files, or the folder, in the editor."},
  {"tab_new", "New Tab", "File", "global", "", "Ctrl+T", "Cmd+T", "Opens a new tab in the focused pane."},
  {"tab_close", "Close Tab", "File", "global", "", "Ctrl+W", "Cmd+W", "Closes the focused pane's tab."},
  {"connect_ssh", "Connect to Server…", "File", "global", "ConnectSSH", "", "Cmd+K", "Opens an SSH location in a new tab."},
  {"run_script", "Run Lua Script…", "File", "global", "RunScript", "", "", "Runs a Lua script with fc run, in a terminal window."},
  {"refresh_dir", "Refresh", "View", "global", "", "Ctrl+R", "Cmd+R", "Reads the folder again."},
  {"toggle_single_panel_mode", "Single Pane", "View", "global", "", "Ctrl+O", "Opt+Cmd+1", "Shows only the focused pane, or both."},
  {"toggle_permissions_column", "Permissions Column", "View", "panel", "", "Ctrl+L", "", "Shows or hides the permissions column."},
  {"toggle_owner_group_column", "Owner Column", "View", "panel", "", "Ctrl+G", "", "Shows or hides the owner:group column."},
  {"sort_by_name", "Sort by Name", "View", "panel", "", "", "Ctrl+Opt+Cmd+1", "Sorts by name; again reverses the order."},
  {"sort_by_size", "Sort by Size", "View", "panel", "", "", "Ctrl+Opt+Cmd+2", "Sorts by size; again reverses the order."},
  {"sort_by_date", "Sort by Date", "View", "panel", "", "", "Ctrl+Opt+Cmd+3", "Sorts by date; again reverses the order."},
  {"command_palette", "Command Palette…", "View", "global", "CommandPalette", "F1", "Shift+Cmd+P", "Searches and runs any command, and rebinds keys."},
  {"edit_theme_colors", "Theme Editor…", "View", "global", "ThemeColors", "Ctrl+K", "", "Edits colors and fonts of the theme."},
  {"tab_next", "Next Tab", "Window", "global", "", "F12", "Ctrl+Tab", "Shows the next tab of the focused pane."},
  {"tab_prev", "Previous Tab", "Window", "global", "", "F11", "Ctrl+Shift+Tab", "Shows the previous tab of the focused pane."},
  {"toggle_job_list", "Activity", "Window", "global", "JobList", "F9", "Opt+Cmd+L", "Shows jobs: progress, pause, resume and cancel."},
  {"toggle_errors", "Errors", "Window", "global", "ErrorList", "Ctrl+E", "Opt+Cmd+E", "Lists errors from file operations."},
  {"clear_errors", "Clear Errors", "Window", "global", "", "", "", "Clears the error list."},
  {"switch_to_file_commander", "Switch to Editor", "Window", "global", "", "F10", "Ctrl+Cmd+E", "Brings the editor or File Commander to the front."},
  {"switch_editor_prev", "Switch to Editor (Alternative)", "Window", "global", "", "Ctrl+Y", "", "Alternative key for switching to the editor."},
  {"switch_editor_next", "Switch to Editor (Second Alternative)", "Window", "global", "", "Ctrl+U", "", "Alternative key for switching to the editor."},
  {"restart_editor_backend", "Restart Editor Backend…", "Window", "global", "RestartEditor", "", "", "Restarts the editor after upgrading Fresh; unsaved text survives."},
  {"transfer_speed", "Transfer Speed…", "Transfers", "global", "TransferSpeed", "", "", "Limits the speed of copies and moves, even while they run."},
  {"help", "Help: Explain a Feature…", "Help", "global", "Help", "", "", "Lists feature explainers and the entire tutorial."},
  {"simulate_crash", "Simulate Crash", "Help", "global", "SimulateCrash", "", "", "Kills File Commander for the crash recovery explainer.", true},
};
}  // namespace

const std::vector<AppCommand>& app_commands() { return kCommands; }

const AppCommand* find_app_command(const std::string& id) {
  auto at = std::find_if(kCommands.begin(), kCommands.end(), [&](const AppCommand& c) { return c.id == id; });
  return at == kCommands.end() ? nullptr : &*at;
}

AppModel::AppModel(Filepath left, Filepath right, Post post) : _post(std::move(post)) {
  auto pane_emit = [this](const std::string& name, const std::string& detail) { emit(name, detail); };
  _left          = std::make_unique<PaneModel>(left, _post, pane_emit);
  _right         = std::make_unique<PaneModel>(right, _post, pane_emit);
  _editor.set_status_sink([](const std::string& text) {
    if (!text.empty()) file_operations().report_error(text);
  });
  try {
    _editor.set_session_store(SettingsStore::path("editor_session.json"));
  } catch (const std::exception& e) { file_operations().report_error(e.what()); }
  register_commands();
}

AppModel::~AppModel() = default;

void AppModel::set_focused_side(int side) {
  side = side ? 1 : 0;
  if (_focused == side) return;
  _focused = side;
  ++_layout_revision;
}

void AppModel::set_single_pane(bool on) {
  if (_single == on) return;
  _single = on;
  ++_layout_revision;
  settings_changed();
}

void AppModel::offer_extraction(int side, const Filepath& archive) {
  DialogRequest request;
  request.name     = "Extract";
  request.side     = side;
  request.selected = {archive};
  request.focused  = archive;
  request.origin   = pane(side).dir().path;
  request.target   = pane(1 - side).dir().path;
  _dialogs.push_back(std::move(request));
}

void AppModel::request_dialog(const std::string& name, bool with_selection) {
  DialogRequest request;
  request.name = name;
  request.side = _focused;
  if (with_selection) {
    auto& pane       = this->pane(_focused);
    auto  args       = pane.command_args();
    request.selected = args->selected;
    request.focused  = args->focused;
    request.origin   = pane.dir().path;
    request.target   = this->pane(1 - _focused).dir().path;
  }
  _dialogs.push_back(std::move(request));
}

void AppModel::register_commands() {
  auto always  = [] { return true; };
  auto add     = [&](const std::string& id, std::function<void()> run, std::function<bool()> available) {
    _handlers[id] = {std::move(run), std::move(available)};
  };
  auto focused = [this]() -> PaneModel& { return pane(_focused); };
  auto has_items = [this] { return !pane(_focused).dir().items.empty(); };

  for (const auto& command : kCommands) {
    if (command.dialog.empty()) continue;
    const bool panel = command.scope == "panel";
    add(command.id, [this, name = command.dialog, panel] {
      if (name == "Mkdir" || name == "Rename" || name == "Move" || name == "Delete") {
        auto error = archive_mutation_error(pane(_focused).dir().path);
        if (!error.empty()) {
          file_operations().report_error(error);
          return;
        }
      }
      request_dialog(name, panel);
    }, always);
  }
  add("select_toggle", [focused] {
    auto& pane = focused();
    if (auto* item = pane.cursor_item()) {
      int index = int(item - pane.dir().items.data());
      pane.toggle_select(index);
      pane.set_cursor(pane.dir().next_visible(index));
    }
  }, has_items);
  add("clear_selection", [focused] { focused().clear_selection(); }, always);
  add("select_all", [focused] { focused().select_all(); }, always);
  add("enter_dir", [this, focused] {
    auto& pane = focused();
    if (auto* item = pane.cursor_item())
      if (pane.enter(int(item - pane.dir().items.data())) == PaneModel::EnterResult::OfferExtraction) offer_extraction(_focused, item->path_ref());
  }, has_items);
  add("open_as_archive", [focused] {
    auto& pane = focused();
    if (auto* item = pane.cursor_item()) pane.browse_archive(int(item - pane.dir().items.data()));
  }, has_items);
  add("leave_dir", [focused] { focused().leave(); }, always);
  add("toggle_permissions_column", [this, focused] {
    auto& pane = focused();
    pane.set_columns(!pane.active().permissions, pane.active().owner_group);
    settings_changed();
  }, always);
  add("toggle_owner_group_column", [this, focused] {
    auto& pane = focused();
    pane.set_columns(pane.active().permissions, !pane.active().owner_group);
    settings_changed();
  }, always);
  auto sort = [this, focused](Orderby ascending, Orderby descending) {
    auto& pane = focused();
    pane.set_sort(pane.dir().order_by == ascending ? descending : ascending);
    settings_changed();
  };
  add("sort_by_name", [sort] { sort(Orderby::NAME_ASC, Orderby::NAME_DESC); }, always);
  add("sort_by_size", [sort] { sort(Orderby::SIZE_ASC, Orderby::SIZE_DESC); }, always);
  add("sort_by_date", [sort] { sort(Orderby::TIME_ASC, Orderby::TIME_DESC); }, always);
  add("names_to_clipboard", [this] { copy_to_clipboard(_focused, true); }, has_items);
  add("paths_to_clipboard", [this] { copy_to_clipboard(_focused, false); }, has_items);
  // In single-pane mode this shows the other pane, still alone.
  add("switch_panel", [this] { set_focused_side(1 - _focused); }, always);
  add("tab_new", [focused] { focused().new_tab(); }, always);
  add("tab_close", [focused] { focused().close_tab(focused().active_tab_index()); }, [focused] { return focused().tab_count() > 1; });
  add("tab_next", [focused] { focused().cycle_tab(1); }, always);
  add("tab_prev", [focused] { focused().cycle_tab(-1); }, always);
  add("refresh_dir", [focused] { focused().refresh(); }, always);
  add("toggle_single_panel_mode", [this] { set_single_pane(!_single); }, always);
  add("target_right", [this] { pane(1).move_to(pane(_focused).focused_dir()); }, always);
  add("target_left", [this] { pane(0).move_to(pane(_focused).focused_dir()); }, always);
  add("add_bookmark", [this] { add_bookmark(pane(_focused).dir().path); }, always);
  add("clear_errors", [] { file_operations().clear_errors(); }, always);
  add("open_in_editor", [this] {
    auto error = open_in_editor();
    if (!error.empty()) file_operations().report_error(error);
  }, always);
  for (const char* id : {"switch_to_file_commander", "switch_editor_prev", "switch_editor_next"}) {
    add(id, [this] {
      auto error = switch_to_editor();
      if (!error.empty()) file_operations().report_error(error);
    }, always);
  }
}

bool AppModel::available(const std::string& id) {
  auto at = _handlers.find(id);
  return at != _handlers.end() && at->second.available();
}

bool AppModel::execute(const std::string& id) {
  auto at = _handlers.find(id);
  if (at == _handlers.end() || !at->second.available()) return false;
  at->second.run();
  ++_use_counts[id];
  settings_changed();
  emit("command_executed", id, ++_command_sequence);
  observe_state();
  return true;
}

int AppModel::use_count(const std::string& id) const {
  auto at = _use_counts.find(id);
  return at == _use_counts.end() ? 0 : at->second;
}

std::vector<std::string> AppModel::palette(const std::string& query) {
  struct Ranked {
    const AppCommand* command;
    int               score;
  };
  std::vector<Ranked> ranked;
  const auto          q = lower_ascii(query);
  for (const auto& command : kCommands) {
    if (command.hidden) continue;
    int score = palette_score(q, lower_ascii(command.id + " " + command.title));
    if (score < 0) continue;
    ranked.push_back({&command, score});
  }
  std::stable_sort(ranked.begin(), ranked.end(), [this](const Ranked& a, const Ranked& b) {
    if (a.score != b.score) return a.score > b.score;
    if (use_count(a.command->id) != use_count(b.command->id)) return use_count(a.command->id) > use_count(b.command->id);
    return a.command->title < b.command->title;
  });
  std::vector<std::string> out;
  for (const auto& r : ranked) out.push_back(r.command->id);
  return out;
}

void AppModel::add_bookmark(const Filepath& path) {
  auto location = Location::decode(path.native());
  if (std::find(_bookmarks.begin(), _bookmarks.end(), location) != _bookmarks.end()) return;
  _bookmarks.push_back(std::move(location));
  std::sort(_bookmarks.begin(), _bookmarks.end(), [](const auto& a, const auto& b) { return a.display() < b.display(); });
  ++_bookmarks_revision;
  settings_changed();
}

void AppModel::remove_bookmark(const Filepath& path) {
  auto location = Location::decode(path.native());
  auto before   = _bookmarks.size();
  _bookmarks.erase(std::remove(_bookmarks.begin(), _bookmarks.end(), location), _bookmarks.end());
  if (_bookmarks.size() != before) {
    ++_bookmarks_revision;
    settings_changed();
  }
}

void AppModel::load_settings(bool restore_paths) {
  try {
    auto settings = SettingsStore::load(SettingsStore::path());
    if (!settings) return;
    _loaded_settings = settings;
    const auto& s    = *settings;
    auto        apply = [](PaneModel& pane, const PanelSettings& p) {
      pane.dir().order_by = p.sort;
      pane.dir()._sort();
      pane.dir()._calculate();
      pane.set_columns(p.permissions, p.owner_group);
    };
    apply(*_left, s.left);
    apply(*_right, s.right);
    _single  = s.single_panel;
    _focused = s.focused_panel == "right" ? 1 : 0;
    _bookmarks.clear();
    for (const auto& p : s.bookmarks)
      if (!p.empty()) add_bookmark(p);
    _use_counts.clear();
    for (const auto& [id, count] : s.command_use_count) _use_counts[id] = count;
    _editor.set_binary_override(s.fresh_binary_path);
    _transfer_rate_saved = s.transfer_rate_limit;
    file_operations().set_transfer_rate(_transfer_rate_saved);
    if (_editor.last_session_id().empty()) _editor.set_last_session_id(s.last_editor_session_id);
    if (restore_paths) {
      auto navigate = [](PaneModel& pane, const std::string& path) {
        boost::system::error_code ec;
        if (!path.empty() && (Location::decode(path).remote() || Location::decode(path).read_only() ||
                              (boost::filesystem::is_directory(path, ec) && !ec)))
          pane.move_to(path);
      };
      navigate(*_left, s.left.path);
      navigate(*_right, s.right.path);
    }
    ++_layout_revision;
    _settings_dirty = false;
  } catch (const std::exception& e) { file_operations().report_error("[Settings] " + std::string(e.what())); }
}

void AppModel::save_settings() {
  try {
    AppSettings s = _loaded_settings.value_or(AppSettings{});
    auto capture  = [](PaneModel& pane) {
      return PanelSettings{pane.location().encode(), pane.dir().order_by, pane.active().permissions, pane.active().owner_group};
    };
    s.left          = capture(*_left);
    s.right         = capture(*_right);
    s.single_panel  = _single;
    s.focused_panel = _focused ? "right" : "left";
    s.bookmarks.clear();
    for (const auto& p : _bookmarks) s.bookmarks.push_back(p.encode());
    for (const auto& [id, count] : _use_counts) s.command_use_count[id] = std::max(0, count);
    // key_bindings belong to the terminal interface and are written back as loaded.
    s.fresh_binary_path      = _editor.binary_override();
    s.last_editor_session_id = _editor.last_session_id();
    s.transfer_rate_limit    = _transfer_rate_saved;
    SettingsStore::save(SettingsStore::path(), s);
    _loaded_settings = s;
    _settings_dirty  = false;
  } catch (const std::exception& e) { file_operations().report_error("[Settings] " + std::string(e.what())); }
}

uint64_t AppModel::transfer_rate() const { return file_operations().transfer_rate(); }

void AppModel::set_transfer_rate(uint64_t bytes_per_second, bool persist) {
  file_operations().set_transfer_rate(bytes_per_second);
  if (persist) {
    _transfer_rate_saved = bytes_per_second;
    settings_changed();
  }
}

void AppModel::enable_workspace(bool restore) {
  try {
    auto saved = WorkspaceStore::load(SettingsStore::path("workspace.json"));
    if (saved && restore) {
      _left->restore_workspace(saved->left);
      _right->restore_workspace(saved->right);
      _single  = saved->single_panel;
      _focused = saved->focused_panel == "right" ? 1 : 0;
      ++_layout_revision;
    }
    _workspace_enabled = true;
  } catch (const std::exception& e) {
    _workspace_enabled = false;
    file_operations().report_error("[Workspace] " + std::string(e.what()) + "; checkpoint retained");
  }
}

void AppModel::checkpoint_workspace(bool force) {
  if (!_workspace_enabled || _left->loading() || _right->loading()) return;
  auto now = std::chrono::steady_clock::now();
  if (!force && now - _last_workspace_check < std::chrono::milliseconds(500)) return;
  _last_workspace_check = now;
  try {
    AppWorkspace saved{_left->capture_workspace(keep_tutorial_tabs), _right->capture_workspace(keep_tutorial_tabs), _single,
                       _focused ? "right" : "left"};
    auto         text = WorkspaceStore::encode(saved);
    if (text == _last_workspace_text) return;
    SettingsStore::atomic_write(SettingsStore::path("workspace.json"), text);
    _last_workspace_text = std::move(text);
  } catch (const std::exception& e) { file_operations().report_error("[Workspace] " + std::string(e.what())); }
}

void AppModel::tick() {
  observe_state();
  checkpoint_workspace();
  auto now = std::chrono::steady_clock::now();
  // Preferences are saved soon after each change, not only at exit.
  if (_settings_dirty && now - _last_settings_save > std::chrono::seconds(1)) {
    _last_settings_save = now;
    save_settings();
  }
}

void AppModel::observe_state() {
  Observation current{_left->revision(), _right->revision(), _left->dir().stats().items_selected, _right->dir().stats().items_selected,
                      _focused, _single};
  if (_last_view) {
    if (current.left_selected != _last_view->left_selected) emit("selection_changed", "left:" + std::to_string(current.left_selected));
    if (current.right_selected != _last_view->right_selected) emit("selection_changed", "right:" + std::to_string(current.right_selected));
    if (current.focus != _last_view->focus) emit("focus_changed", current.focus ? "right" : "left");
    if (current.single != _last_view->single) emit("single_panel_mode_changed", current.single ? "on" : "off");
  }
  _last_view = current;
}

std::string AppModel::open_in_editor() {
  auto& pane  = this->pane(_focused);
  auto  error = archive_mutation_error(pane.dir().path);
  if (!error.empty()) return error;
  auto selected = pane.command_args()->selected;
  for (const auto& path : selected) {
    error = archive_mutation_error(path);
    if (!error.empty()) return error;
  }
  if (selected.empty()) return "No focused item to open in the editor";
  auto is_directory = [&pane](const Filepath& p) {
    if (is_remote(p)) {
      for (auto& item : pane.dir().items)
        if (item.path_ref() == p) return item.is_dir();
      return false;
    }
    boost::system::error_code ec;
    return boost::filesystem::is_directory(p, ec) && !ec;
  };
  if (selected.size() == 1 && is_directory(selected.front())) {
    _editor.open_directory(selected.front(), error);
    return error;
  }
  std::vector<Filepath> files;
  for (const auto& p : selected)
    if (!is_directory(p)) files.push_back(p);
  if (!files.empty()) _editor.open_files_in_last_session(files, error);
  else _editor.open_directory(pane.focused_dir(), error);
  return error;
}

std::string AppModel::switch_to_editor() {
  std::string error;
  _editor.switch_to_editor(pane(_focused).dir().path, error);
  return error;
}

void AppModel::copy_to_clipboard(int side, bool names) {
  auto        selected = pane(side).command_args()->selected;
  std::string text;
  // The selection is in panel order, so the text lists items as they are shown.
  for (const auto& path : selected) {
    text += names ? path.filename().native() : path.native();
    text += "\n";
  }
  if (!text.empty()) text.pop_back();
  OperationPlan plan;
  plan.type = OperationType::CLIPBOARD;
  plan.steps.push_back({Operation::Kind::ClipboardText, {}, {}, {}, text});
  auto job       = std::make_shared<JobSpec>(std::make_shared<const OperationPlan>(std::move(plan)));
  job->completed = [this, post = _post, count = selected.size(), names](std::shared_ptr<const JobSnapshot> result) {
    post([this, result, count, names] {
      if (result->_state == JobState::COMPLETED) notice(std::to_string(count) + (names ? " names" : " paths") + " copied to clipboard");
    });
  };
  file_operations().add_job(job);
}

void AppModel::open_ssh(const std::string& host, const std::string& path) {
  if (path.empty() || path.front() != '/') throw std::runtime_error("An absolute remote directory is required");
  auto location = Location::decode("ssh://" + host + path);
  pane(_focused).new_tab(location.resource());
}
