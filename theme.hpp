
#ifndef _PERUN_FC_THEME_
#define _PERUN_FC_THEME_

#include <ftxui/component/event.hpp>
#include <ftxui/dom/elements.hpp>
#include <boost/filesystem/file_status.hpp>

struct Theme {
  Theme();

  ftxui::Event 
    key_files_select,
    key_clear_selection,
    key_select_all,
    key_enter_dir,
    key_leave_dir;

  ftxui::Event key_mkdir, key_copy, key_move, key_delete, key_rename, key_names_to_clipboard, key_paths_to_clipboard, key_find;

  std::vector<ftxui::Color> filesize_colors;
  ftxui::Color size_gauge_full;
  ftxui::Color size_gauge_empty;
  
  ftxui::Decorator 
    files_path,
    files_filter_search,
    files_border,
    files_selected,
    files_focused,
    fileskind_dir,

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
    file_type_unknown,

    sort_button,
    sort_button_active,

    mkdir_errortxt,
    clipboard_msg,

    unused;
  
  ftxui::Decorator file_type(boost::filesystem::file_type t);
};

Theme& theme();

#endif // _PERUN_FC_THEME_
