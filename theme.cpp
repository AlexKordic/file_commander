
#include "theme.hpp"
#include <ftxui/dom/elements.hpp>
#include <ftxui/screen/color.hpp>

using namespace ftxui;

Theme::Theme() {
  files_border = borderStyled(Color::DarkOliveGreen3Ter);
  files_selected = bgcolor(Color::Gold1);
  files_focused = color(Color::DarkOliveGreen2) | inverted | bold;

  file_status_error = color(Color::Red);
  file_file_not_found = color(Color::Red);
  file_regular_file = color(Color::White);
  file_directory_file = color(Color::Turquoise2);
  file_symlink_file = color(Color::Magenta);
  file_block_file = color(Color::SandyBrown);
  file_character_file = color(Color::Salmon1);
  file_fifo_file = color(Color::LightGoldenrod3);
  file_socket_file = color(Color::MistyRose3);
  file_reparse_file = color(Color::DarkKhaki);
  file_type_unknown = color(Color::Red);
}

ftxui::Decorator Theme::file_type(boost::filesystem::file_type t) {
  switch(t) {
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