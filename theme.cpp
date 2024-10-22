
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

  file_status_error   = color(Color::Red);
  file_file_not_found = color(Color::Red);
  file_regular_file   = color(Color::White);
  file_directory_file = color(Color::Turquoise2);
  file_symlink_file   = color(Color::Magenta);
  file_block_file     = color(Color::SandyBrown);
  file_character_file = color(Color::Salmon1);
  file_fifo_file      = color(Color::LightGoldenrod3);
  file_socket_file    = color(Color::MistyRose3);
  file_reparse_file   = color(Color::DarkKhaki);
  file_type_unknown   = color(Color::Red);

  sort_button        = bgcolor(Color::Wheat4);
  sort_button_active = bgcolor(Color::Wheat4) | color(Color::Salmon1);

  key_copy               = Event::F5;
  key_move               = Event::F6;
  key_mkdir              = Event::F7;
  key_delete             = Event::F8;
  key_rename             = Event::F2;
  key_names_to_clipboard = Event::CtrlN;
  key_paths_to_clipboard = Event::CtrlP;
  key_find               = Event::F3;
}

ftxui::Decorator Theme::file_type(boost::filesystem::file_type t) {
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