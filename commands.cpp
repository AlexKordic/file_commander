#include "commands.hpp"
#include <algorithm>
#include "theme.hpp"

namespace ftxui {
Commands::Commands() {
  available.reserve(64);
  available.push_back({"select_toggle", keys().key_files_select, "", "Select / Deselect Focused Item", CommandScope::PANEL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"clear_selection", keys().key_clear_selection, "", "Clear Selection", CommandScope::PANEL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"select_all", keys().key_select_all, "", "Select All", CommandScope::PANEL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"enter_dir", keys().key_enter_dir, "", "Enter Directory", CommandScope::PANEL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"leave_dir", keys().key_leave_dir, "", "Leave Directory", CommandScope::PANEL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"toggle_permissions_column", keys().key_toggle_permissions_column, "", "Toggle Permissions Column", CommandScope::PANEL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"toggle_owner_group_column", keys().key_toggle_owner_group_column, "", "Toggle Owner/Group Column", CommandScope::PANEL, CommandKind::EXECUTE_CALLBACK});

  available.push_back({"copy", keys().key_copy, "Copy", "Copy", CommandScope::PANEL, CommandKind::SHOW_DIALOG});
  available.push_back({"move", keys().key_move, "Move", "Move", CommandScope::PANEL, CommandKind::SHOW_DIALOG});
  available.push_back({"delete", keys().key_delete, "Delete", "Delete", CommandScope::PANEL, CommandKind::SHOW_DIALOG});
  available.push_back({"rename", keys().key_rename, "Rename", "Rename", CommandScope::PANEL, CommandKind::SHOW_DIALOG});
  available.push_back({"mkdir", keys().key_mkdir, "Mkdir", "Make Directory", CommandScope::PANEL, CommandKind::SHOW_DIALOG});
  available.push_back({"find", keys().key_find, "Find", "Find", CommandScope::PANEL, CommandKind::SHOW_DIALOG});
  available.push_back({"glob_select", keys().key_glob_select, "GlobSelect", "Select by Glob", CommandScope::PANEL, CommandKind::SHOW_DIALOG});
  available.push_back({"glob_deselect", keys().key_glob_deselect, "GlobDeselect", "Deselect by Glob", CommandScope::PANEL, CommandKind::SHOW_DIALOG});
  available.push_back({"names_to_clipboard", keys().key_names_to_clipboard, "NameToClipboard", "Names to Clipboard", CommandScope::PANEL, CommandKind::SHOW_DIALOG});
  available.push_back({"paths_to_clipboard", keys().key_paths_to_clipboard, "PathToClipboard", "Paths to Clipboard", CommandScope::PANEL, CommandKind::SHOW_DIALOG});

  available.push_back({"switch_panel", keys().key_switch_focused_panel, "", "Switch Focused Panel", CommandScope::GLOBAL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"tab_new", keys().key_new_tab, "", "New Tab in Focused Panel", CommandScope::GLOBAL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"tab_close", keys().key_close_tab, "", "Close Active Tab in Focused Panel", CommandScope::GLOBAL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"tab_next", keys().key_next_tab, "", "Next Tab in Focused Panel", CommandScope::GLOBAL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"tab_prev", keys().key_prev_tab, "", "Previous Tab in Focused Panel", CommandScope::GLOBAL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"toggle_single_panel_mode", keys().key_toggle_single_panel_mode, "", "Toggle Single Panel Full Width", CommandScope::GLOBAL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"refresh_dir", keys().key_refresh_dir, "", "Refresh Directory", CommandScope::GLOBAL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"target_right", keys().key_target_dir_to_focused_item_right, "", "Target Right Panel to Focused Item", CommandScope::GLOBAL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"target_left", keys().key_target_dir_to_focused_item_left, "", "Target Left Panel to Focused Item", CommandScope::GLOBAL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"toggle_errors", keys().key_toggle_error_details, "ErrorList", "Toggle Error List", CommandScope::GLOBAL, CommandKind::SHOW_DIALOG});
  available.push_back({"toggle_job_list", keys().key_toggle_job_list, "JobList", "Toggle Job List", CommandScope::GLOBAL, CommandKind::SHOW_DIALOG});
  available.push_back({"open_bookmarks", keys().key_bookmarks_dialog, "Bookmarks", "Open Bookmarks", CommandScope::GLOBAL, CommandKind::SHOW_DIALOG});
  available.push_back({"edit_theme_colors", keys().key_theme_colors, "ThemeColors", "Edit Theme Colors", CommandScope::GLOBAL, CommandKind::SHOW_DIALOG});
  available.push_back({"open_in_editor", keys().key_open_in_editor, "", "Open in Fresh Editor", CommandScope::GLOBAL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"switch_to_file_commander", keys().key_switch_to_file_commander, "", "Switch to Editor / Back (detach)", CommandScope::GLOBAL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"switch_editor_prev", keys().key_switch_editor_prev, "", "Switch to Editor (previous-session alias)", CommandScope::GLOBAL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"switch_editor_next", keys().key_switch_editor_next, "", "Switch to Editor (next-session alias)", CommandScope::GLOBAL, CommandKind::EXECUTE_CALLBACK});
}

const Command* Commands::find_by_id(const std::string& id) const {
  auto it = std::find_if(available.begin(), available.end(), [&id](const Command& c) { return c.id == id; });
  return it == available.end() ? nullptr : &(*it);
}

Command* Commands::find_by_id(const std::string& id) {
  auto it = std::find_if(available.begin(), available.end(), [&id](const Command& c) { return c.id == id; });
  return it == available.end() ? nullptr : &(*it);
}

bool Commands::increment_use_count(const std::string& id) {
  auto* c = find_by_id(id);
  if (!c) return false;
  c->use_count++;
  return true;
}

bool Commands::set_use_count(const std::string& id, int use_count) {
  auto* c = find_by_id(id);
  if (!c) return false;
  c->use_count = std::max(0, use_count);
  return true;
}

bool Commands::set_key(const std::string& id, const Event& key) {
  auto* c = find_by_id(id);
  if (!c) return false;
  c->key = key;
  if (c->binding) *c->binding = key;
  return true;
}

const Command* Commands::find_panel_by_key(const Event& key) const {
  auto it = std::find_if(available.begin(), available.end(), [&key](const Command& c) { return c.key == key && c.scope == CommandScope::PANEL; });
  return it == available.end() ? nullptr : &(*it);
}

std::vector<Command> Commands::list_all() const { return available; }

Commands& commands() {
  static Commands _c;
  return _c;
}

}  // namespace ftxui
