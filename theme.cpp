
#include "theme.hpp"
#include <ftxui/dom/elements.hpp>
#include <ftxui/screen/color.hpp>

using namespace ftxui;

Theme::Theme() {
  key_switch_focused_panel             = Event::Tab;
  key_new_tab                          = Event::CtrlT;
  key_close_tab                        = Event::CtrlW;
  key_next_tab                         = Event::F11;
  key_prev_tab                         = Event::F12;
  key_target_dir_to_focused_item_right = Event::ArrowRightCtrl;
  key_target_dir_to_focused_item_left  = Event::ArrowLeftCtrl;

  key_files_select         = Event::Character(' ');
  key_glob_select          = Event::Character('+');
  key_glob_deselect        = Event::Character('-');
  key_cancel_dialog        = Event::Escape;
  key_clear_selection      = Event::Escape;
  key_enter_dir            = Event::Return;
  key_leave_dir            = Event::Character("?");
  key_refresh_dir          = Event::CtrlR;
  key_toggle_single_panel_mode = Event::CtrlO;
  key_toggle_permissions_column = Event::CtrlL;
  key_toggle_owner_group_column = Event::CtrlG;
  key_select_all           = Event::CtrlA;
  key_clear_errors         = Event::Escape;
  key_toggle_error_details = Event::CtrlE;
  key_toggle_job_list      = Event::F4;
  key_bookmarks_dialog     = Event::CtrlB;
  key_command_palette      = Event::F1;

  filesize_colors  = {Color::White, Color::White, Color::Yellow, Color::IndianRed1, Color::Plum3};
  debuginfo_colors = {Color::Black, Color::Yellow, Color::IndianRed1, Color::Plum3};
  size_gauge_full  = Color::MediumPurple4;
  size_gauge_empty = Color::Grey0;

  files_path            = color(Color::LightGoldenrod2Ter) | bgcolor(Color::GrayDark);
  files_filter_search   = color(Color::Plum2) | bgcolor(Color::GrayDark);
  files_border          = borderStyled(Color::DarkOliveGreen3Ter);
  files_selected        = color(Color::Gold1) | bold;
  files_hovered         = inverted;  // bgcolor(Color(25,25,25,100));
  files_focused         = bold;
  files_focused_full    = Color::DarkGreen;
  files_focused_empty   = Color::DarkSeaGreen4;
  files_unfocused_full  = Color::Grey19;
  files_unfocused_empty = Color::Grey27;

  files_warning = color(Color::OrangeRed1);
  files_symlink = dim;

  progress_operation = color(Color::SpringGreen1);
  progress_total     = color(Color::PaleTurquoise1);
  progress_current   = color(Color::PaleGreen1);

  default_fg = Color::White;
  default_bg = Color::Black;

  file_perm_exe       = Color::SpringGreen1;
  file_status_error   = Color::Red;
  file_file_not_found = Color::Red;
  file_regular_file   = Color::White;
  file_directory_file = Color::Turquoise2;
  file_symlink_file   = Color::Magenta;
  file_block_file     = Color::SandyBrown;
  file_character_file = Color::Salmon1;
  file_fifo_file      = Color::LightGoldenrod3;
  file_socket_file    = Color::MistyRose3;
  file_reparse_file   = Color::DarkKhaki;
  file_type_unknown   = Color::Red;

  sort_button        = bgcolor(Color::Wheat4);
  sort_button_active = bgcolor(Color::Wheat4) | color(Color::Salmon1);

  mkdir_errortxt   = color(Color::LightPink3);
  clipboard_msg    = color(Color::LightPink3);
  copy_destination = color(Color::LightPink3);

  recent_error = color(Color::LightPink3) | bold;

  key_copy               = Event::F5;
  key_move               = Event::F6;
  key_mkdir              = Event::F7;
  key_delete             = Event::F8;
  key_rename             = Event::F2;
  key_names_to_clipboard = Event::CtrlN;
  key_paths_to_clipboard = Event::CtrlP;
  key_find               = Event::F3;
}

ftxui::Color Theme::file_type(boost::filesystem::file_type t) {
  switch (t) {
  case boost::filesystem::status_error: return file_status_error;
  case boost::filesystem::file_not_found: return file_file_not_found;
  case boost::filesystem::regular_file: return file_regular_file;
  case boost::filesystem::directory_file: return file_directory_file;
  case boost::filesystem::symlink_file: return file_symlink_file;
  case boost::filesystem::block_file: return file_block_file;
  case boost::filesystem::character_file: return file_character_file;
  case boost::filesystem::fifo_file: return file_fifo_file;
  case boost::filesystem::socket_file: return file_socket_file;
  case boost::filesystem::reparse_file: return file_reparse_file;
  case boost::filesystem::type_unknown: return file_type_unknown;
  }
}

Theme& theme() {
  static Theme t_;
  return t_;
}
