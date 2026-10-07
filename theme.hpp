
#ifndef _PERUN_FC_THEME_
#define _PERUN_FC_THEME_

#include <ftxui/component/event.hpp>
#include <ftxui/dom/elements.hpp>
#include <boost/filesystem/file_status.hpp>
#include <ftxui/screen/color.hpp>

#include <map>
#include <string>
#include <vector>

//
// TODO: Interactive configuration for shorcuts and style
//  > Structure key shortcuts to contain description 
//

struct KeyBindings {
  KeyBindings();
  ftxui::Event key_switch_focused_panel, key_new_tab, key_close_tab, key_next_tab, key_prev_tab,
      key_files_select, key_glob_select, key_glob_deselect, key_cancel_dialog, key_clear_selection,
      key_select_all, key_enter_dir, key_leave_dir, key_toggle_single_panel_mode,
      key_toggle_permissions_column, key_toggle_owner_group_column, key_refresh_dir,
      key_target_dir_to_focused_item_right, key_target_dir_to_focused_item_left, key_clear_errors,
      key_toggle_error_details, key_toggle_job_list, key_bookmarks_dialog, key_theme_colors,
      key_command_palette, key_open_in_editor, key_switch_to_file_commander, key_switch_editor_prev,
      key_switch_editor_next, key_restart_editor_backend, key_connect_ssh;

  ftxui::Event key_mkdir, key_copy, key_move, key_delete, key_rename, key_names_to_clipboard, key_paths_to_clipboard, key_find;

};
KeyBindings& keys();

struct Theme {
  Theme();

  float  copyfiles_height_screen_portion = 0.9;
  float  errorlist_height_screen_portion = 0.9;
  double clear_errors_command_sequence = 1.0;
  int    clear_errors_command_repeat_count = 3;
  int    max_errors_to_show = 3; // in FileCommander error quick view

  std::vector<ftxui::Color> filesize_colors;
  std::vector<ftxui::Color> debuginfo_colors;
  ftxui::Color size_gauge_full;
  ftxui::Color size_gauge_empty;

  ftxui::Color
    default_fg,
    default_bg,
    files_path_fg,
    files_path_bg,
    files_filter_fg,
    files_filter_bg,
    files_border_color,
    files_selected_fg,
    files_warning_fg,
    progress_operation_fg,
    progress_total_fg,
    progress_current_fg,
    sort_button_bg,
    sort_button_active_bg,
    sort_button_active_fg,
    mkdir_errortxt_fg,
    clipboard_msg_fg,
    copy_destination_fg,
    recent_error_fg,
    files_focused_full,
    files_focused_empty,
    files_unfocused_full,
    files_unfocused_empty,
    file_perm_exe,
    file_status_error,
    file_file_not_found,
    file_regular_file,
    file_directory_file,
    file_symlink_file,
    file_block_file,
    file_character_file,
    file_fifo_file,
    file_socket_file,
    file_reparse_file,
    file_type_unknown;

  ftxui::Decorator 
    files_path,
    files_filter_search,
    files_border,
    files_selected,
    files_focused,
    files_hovered,
    files_warning,
    files_symlink,
    fileskind_dir,

    sort_button,
    sort_button_active,

    mkdir_errortxt,
    clipboard_msg,
    copy_destination,

    progress_operation,
    progress_total,
    progress_current,

    recent_error,

    unused;
  
  ftxui::Color file_type(boost::filesystem::file_type t);

  void                                        reset_color_defaults();
  void                                        refresh_decorators();
  std::vector<std::pair<std::string, std::string>> editable_colors() const;
  std::vector<std::string>                    available_color_tokens() const;
  std::map<std::string, std::string>          export_color_tokens() const;
  void                                        import_color_tokens(const std::map<std::string, std::string>& tokens);
  bool                                        set_color_token(const std::string& id, const std::string& token, std::string* error = nullptr);
  std::string                                 color_token(const std::string& id) const;

  std::map<std::string, std::string> color_token_values;
};

Theme& theme();

#endif // _PERUN_FC_THEME_
