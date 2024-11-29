
#ifndef _PERUN_FC_THEME_
#define _PERUN_FC_THEME_

#include <ftxui/component/event.hpp>
#include <ftxui/dom/elements.hpp>
#include <boost/filesystem/file_status.hpp>
#include <ftxui/screen/color.hpp>

//
// TODO: Interactive configuration for shorcuts and style
//  > Structure key shortcuts to contain description 
//

struct Theme {
  Theme();

  size_t copy_files_min_y = 50;
  size_t errorlist_min_y = 50;
  double clear_errors_command_sequence = 1.0;
  int    clear_errors_command_repeat_count = 3;
  int    max_errors_to_show = 3; // in FileCommander error quick view

  ftxui::Event 
    key_switch_focused_panel,
    key_files_select,
    key_cancel_dialog,
    key_clear_selection,
    key_select_all,
    key_enter_dir,
    key_leave_dir,
    key_target_dir_to_focused_item_right,
    key_target_dir_to_focused_item_left,
    key_clear_errors,
    key_toggle_error_details;

  ftxui::Event key_mkdir, key_copy, key_move, key_delete, key_rename, key_names_to_clipboard, key_paths_to_clipboard, key_find;

  std::vector<ftxui::Color> filesize_colors;
  std::vector<ftxui::Color> debuginfo_colors;
  ftxui::Color size_gauge_full;
  ftxui::Color size_gauge_empty;

  ftxui::Color
    default_fg,
    default_bg,
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
};

Theme& theme();

#endif // _PERUN_FC_THEME_
