
#include "theme.hpp"
#include <ftxui/dom/elements.hpp>
#include <ftxui/screen/color.hpp>

using namespace ftxui;

Theme::Theme() {
  key_files_select    = Event::Character(' ');
  key_clear_selection = Event::Escape;
  key_enter_dir       = Event::Return;
  key_leave_dir       = Event::Character("?");
  key_select_all      = Event::CtrlA;

  filesize_colors  = {Color::White, Color::White, Color::Yellow, Color::Red, Color::Plum3};
  size_gauge_full  = Color::MediumPurple4;
  size_gauge_empty = Color::Grey0;

  files_path          = color(Color::LightGoldenrod2Ter) | bgcolor(Color::GrayDark);
  files_filter_search = color(Color::Plum2) | bgcolor(Color::GrayDark);
  files_border        = borderStyled(Color::DarkOliveGreen3Ter);
  files_selected      = color(Color::Gold1) | bold;
  files_focused       = color(Color::DarkOliveGreen2) | inverted | bold;

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

  mkdir_errortxt = color(Color::LightPink3);
  clipboard_msg  = color(Color::LightPink3);

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