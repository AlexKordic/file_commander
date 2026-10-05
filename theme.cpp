
#include "theme.hpp"
#include <ftxui/dom/elements.hpp>
#include <ftxui/screen/color.hpp>

#include <algorithm>
#include <array>
#include <cctype>
#include <cstdlib>
#include <string>
#include <vector>

using namespace ftxui;

namespace {

struct ColorToken {
  const char* name;
  Color       color;
};

std::string to_lower_ascii(std::string s) {
  for (char& ch : s) {
    if (ch >= 'A' && ch <= 'Z') ch = static_cast<char>('a' + (ch - 'A'));
  }
  return s;
}

const std::vector<ColorToken>& color_tokens_table() {
  static const std::vector<ColorToken> tokens = {
    {"black", Color::Black},
    {"white", Color::White},
    {"red", Color::Red},
    {"green", Color::Green},
    {"yellow", Color::Yellow},
    {"blue", Color::Blue},
    {"magenta", Color::Magenta},
    {"cyan", Color::Cyan},
    {"gray_dark", Color::GrayDark},
    {"gray_light", Color::GrayLight},
    {"grey0", Color::Grey0},
    {"grey19", Color::Grey19},
    {"grey27", Color::Grey27},
    {"gold1", Color::Gold1},
    {"plum2", Color::Plum2},
    {"plum3", Color::Plum3},
    {"dark_green", Color::DarkGreen},
    {"dark_sea_green4", Color::DarkSeaGreen4},
    {"dark_olive_green3_ter", Color::DarkOliveGreen3Ter},
    {"light_goldenrod2_ter", Color::LightGoldenrod2Ter},
    {"orange_red1", Color::OrangeRed1},
    {"spring_green1", Color::SpringGreen1},
    {"pale_turquoise1", Color::PaleTurquoise1},
    {"pale_green1", Color::PaleGreen1},
    {"wheat4", Color::Wheat4},
    {"salmon1", Color::Salmon1},
    {"light_pink3", Color::LightPink3},
    {"turquoise2", Color::Turquoise2},
    {"misty_rose3", Color::MistyRose3},
    {"dark_khaki", Color::DarkKhaki},
    {"medium_purple4", Color::MediumPurple4},
  };
  return tokens;
}

bool token_to_color(std::string token, Color& out) {
  token = to_lower_ascii(std::move(token));

  if (token.size() > 1 && token[0] == 'p') {
    bool digits = true;
    for (size_t i = 1; i < token.size(); ++i) {
      if (!std::isdigit(static_cast<unsigned char>(token[i]))) {
        digits = false;
        break;
      }
    }
    if (digits) {
      int idx = std::atoi(token.c_str() + 1);
      if (idx >= 0 && idx <= 255) {
        out = Color(Color::Palette256(idx));
        return true;
      }
    }
  }

  const auto& tokens = color_tokens_table();
  auto        it = std::find_if(tokens.begin(), tokens.end(), [&token](const ColorToken& x) { return token == x.name; });
  if (it == tokens.end()) return false;
  out = it->color;
  return true;
}

const std::vector<std::pair<std::string, std::string>>& editable_color_defs() {
  static const std::vector<std::pair<std::string, std::string>> defs = {
    {"default_fg", "Default Foreground"},
    {"default_bg", "Default Background"},
    {"files_path_fg", "Path Foreground"},
    {"files_path_bg", "Path Background"},
    {"files_filter_fg", "Filter Foreground"},
    {"files_filter_bg", "Filter Background"},
    {"files_border_color", "Border Color"},
    {"files_selected_fg", "Selected Item Color"},
    {"files_warning_fg", "Warning Color"},
    {"files_focused_full", "Focused Gauge Full"},
    {"files_focused_empty", "Focused Gauge Empty"},
    {"files_unfocused_full", "Unfocused Gauge Full"},
    {"files_unfocused_empty", "Unfocused Gauge Empty"},
    {"file_regular_file", "File Color"},
    {"file_directory_file", "Directory Color"},
    {"file_symlink_file", "Symlink Color"},
    {"file_perm_exe", "Executable Accent"},
    {"file_status_error", "Status Error Color"},
    {"file_type_unknown", "Unknown Type Color"},
    {"size_gauge_full", "Size Gauge Full"},
    {"size_gauge_empty", "Size Gauge Empty"},
    {"progress_operation_fg", "Progress Operation"},
    {"progress_total_fg", "Progress Total"},
    {"progress_current_fg", "Progress Current"},
    {"sort_button_bg", "Sort Button Background"},
    {"sort_button_active_bg", "Sort Active Background"},
    {"sort_button_active_fg", "Sort Active Foreground"},
    {"mkdir_errortxt_fg", "Mkdir Error Color"},
    {"clipboard_msg_fg", "Clipboard Message Color"},
    {"copy_destination_fg", "Copy Destination Color"},
    {"recent_error_fg", "Recent Error Color"},
  };
  return defs;
}

bool set_color_field(Theme& t, const std::string& id, const Color& color) {
  if (id == "default_fg") {
    t.default_fg = color;
  } else if (id == "default_bg") {
    t.default_bg = color;
  } else if (id == "files_path_fg") {
    t.files_path_fg = color;
  } else if (id == "files_path_bg") {
    t.files_path_bg = color;
  } else if (id == "files_filter_fg") {
    t.files_filter_fg = color;
  } else if (id == "files_filter_bg") {
    t.files_filter_bg = color;
  } else if (id == "files_border_color") {
    t.files_border_color = color;
  } else if (id == "files_selected_fg") {
    t.files_selected_fg = color;
  } else if (id == "files_warning_fg") {
    t.files_warning_fg = color;
  } else if (id == "files_focused_full") {
    t.files_focused_full = color;
  } else if (id == "files_focused_empty") {
    t.files_focused_empty = color;
  } else if (id == "files_unfocused_full") {
    t.files_unfocused_full = color;
  } else if (id == "files_unfocused_empty") {
    t.files_unfocused_empty = color;
  } else if (id == "file_regular_file") {
    t.file_regular_file = color;
  } else if (id == "file_directory_file") {
    t.file_directory_file = color;
  } else if (id == "file_symlink_file") {
    t.file_symlink_file = color;
  } else if (id == "file_perm_exe") {
    t.file_perm_exe = color;
  } else if (id == "file_status_error") {
    t.file_status_error = color;
  } else if (id == "file_type_unknown") {
    t.file_type_unknown = color;
  } else if (id == "size_gauge_full") {
    t.size_gauge_full = color;
  } else if (id == "size_gauge_empty") {
    t.size_gauge_empty = color;
  } else if (id == "progress_operation_fg") {
    t.progress_operation_fg = color;
  } else if (id == "progress_total_fg") {
    t.progress_total_fg = color;
  } else if (id == "progress_current_fg") {
    t.progress_current_fg = color;
  } else if (id == "sort_button_bg") {
    t.sort_button_bg = color;
  } else if (id == "sort_button_active_bg") {
    t.sort_button_active_bg = color;
  } else if (id == "sort_button_active_fg") {
    t.sort_button_active_fg = color;
  } else if (id == "mkdir_errortxt_fg") {
    t.mkdir_errortxt_fg = color;
  } else if (id == "clipboard_msg_fg") {
    t.clipboard_msg_fg = color;
  } else if (id == "copy_destination_fg") {
    t.copy_destination_fg = color;
  } else if (id == "recent_error_fg") {
    t.recent_error_fg = color;
  } else {
    return false;
  }
  return true;
}

}  // namespace

KeyBindings& keys() { static KeyBindings bindings;return bindings; }
KeyBindings::KeyBindings() {
  key_switch_focused_panel             = Event::Tab;
  key_new_tab                          = Event::CtrlT;
  key_close_tab                        = Event::CtrlW;
  key_next_tab                         = Event::F12;
  key_prev_tab                         = Event::F11;
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
  key_toggle_job_list      = Event::F9;
  key_bookmarks_dialog     = Event::CtrlB;
  key_theme_colors         = Event::CtrlK;
  key_command_palette      = Event::F1;
  key_open_in_editor       = Event::F4;
  key_switch_to_file_commander = Event::F10;
  key_switch_editor_prev   = Event::CtrlY;
  key_switch_editor_next   = Event::CtrlU;
  key_restart_editor_backend = Event::Custom; // Palette only until rebound.
  key_copy               = Event::F5;
  key_move               = Event::F6;
  key_mkdir              = Event::F7;
  key_delete             = Event::F8;
  key_rename             = Event::F2;
  key_names_to_clipboard = Event::CtrlN;
  key_paths_to_clipboard = Event::CtrlP;
  key_find               = Event::F3;
}

Theme::Theme() {


  filesize_colors  = {Color::White, Color::White, Color::Yellow, Color::IndianRed1, Color::Plum3};
  debuginfo_colors = {Color::Black, Color::Yellow, Color::IndianRed1, Color::Plum3};
  files_hovered   = inverted;  // bgcolor(Color(25,25,25,100));
  files_focused   = bold;
  files_symlink   = dim;

  file_file_not_found = Color::Red;
  file_block_file     = Color::SandyBrown;
  file_character_file = Color::Salmon1;
  file_fifo_file      = Color::LightGoldenrod3;
  file_socket_file    = Color::MistyRose3;
  file_reparse_file   = Color::DarkKhaki;

  reset_color_defaults();
  refresh_decorators();

}

void Theme::reset_color_defaults() {
  color_token_values.clear();
  set_color_token("default_fg", "white");
  set_color_token("default_bg", "black");
  set_color_token("files_path_fg", "light_goldenrod2_ter");
  set_color_token("files_path_bg", "gray_dark");
  set_color_token("files_filter_fg", "plum2");
  set_color_token("files_filter_bg", "gray_dark");
  set_color_token("files_border_color", "dark_olive_green3_ter");
  set_color_token("files_selected_fg", "gold1");
  set_color_token("files_warning_fg", "orange_red1");
  set_color_token("files_focused_full", "dark_green");
  set_color_token("files_focused_empty", "dark_sea_green4");
  set_color_token("files_unfocused_full", "grey19");
  set_color_token("files_unfocused_empty", "grey27");
  set_color_token("file_regular_file", "white");
  set_color_token("file_directory_file", "turquoise2");
  set_color_token("file_symlink_file", "magenta");
  set_color_token("file_perm_exe", "spring_green1");
  set_color_token("file_status_error", "red");
  set_color_token("file_type_unknown", "red");
  set_color_token("size_gauge_full", "medium_purple4");
  set_color_token("size_gauge_empty", "grey0");
  set_color_token("progress_operation_fg", "spring_green1");
  set_color_token("progress_total_fg", "pale_turquoise1");
  set_color_token("progress_current_fg", "pale_green1");
  set_color_token("sort_button_bg", "wheat4");
  set_color_token("sort_button_active_bg", "wheat4");
  set_color_token("sort_button_active_fg", "salmon1");
  set_color_token("mkdir_errortxt_fg", "light_pink3");
  set_color_token("clipboard_msg_fg", "light_pink3");
  set_color_token("copy_destination_fg", "light_pink3");
  set_color_token("recent_error_fg", "light_pink3");
  refresh_decorators();
}

void Theme::refresh_decorators() {
  files_path            = color(files_path_fg) | bgcolor(files_path_bg);
  files_filter_search   = color(files_filter_fg) | bgcolor(files_filter_bg);
  files_border          = borderStyled(files_border_color);
  files_selected        = color(files_selected_fg) | bold;
  files_warning         = color(files_warning_fg);
  progress_operation    = color(progress_operation_fg);
  progress_total        = color(progress_total_fg);
  progress_current      = color(progress_current_fg);
  sort_button           = bgcolor(sort_button_bg);
  sort_button_active    = bgcolor(sort_button_active_bg) | color(sort_button_active_fg);
  mkdir_errortxt        = color(mkdir_errortxt_fg);
  clipboard_msg         = color(clipboard_msg_fg);
  copy_destination      = color(copy_destination_fg);
  recent_error          = color(recent_error_fg) | bold;
}

std::vector<std::pair<std::string, std::string>> Theme::editable_colors() const {
  return editable_color_defs();
}

std::vector<std::string> Theme::available_color_tokens() const {
  std::vector<std::string> out;
  const auto&              tokens = color_tokens_table();
  out.reserve(tokens.size());
  for (const auto& x : tokens) out.push_back(x.name);
  return out;
}

std::map<std::string, std::string> Theme::export_color_tokens() const {
  return color_token_values;
}

void Theme::import_color_tokens(const std::map<std::string, std::string>& tokens) {
  for (const auto& [id, token] : tokens) { set_color_token(id, token); }
  refresh_decorators();
}

bool Theme::set_color_token(const std::string& id, const std::string& token, std::string* error) {
  Color resolved;
  if (!token_to_color(token, resolved)) {
    if (error) *error = "Unknown color token: " + token;
    return false;
  }
  if (!set_color_field(*this, id, resolved)) {
    if (error) *error = "Unknown color id: " + id;
    return false;
  }
  color_token_values[id] = to_lower_ascii(token);
  refresh_decorators();
  return true;
}

std::string Theme::color_token(const std::string& id) const {
  auto it = color_token_values.find(id);
  if (it == color_token_values.end()) return "";
  return it->second;
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
