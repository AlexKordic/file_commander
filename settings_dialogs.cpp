#include "traversal.hpp"

#include "dialogs.hpp"
#include "dialog_support.hpp"
#include "archive.hpp"
#include "bfs.hpp"
#include "commander.hpp"
#include "file_io_jobs.hpp"
#include "custom_controls.hpp"
#include "log.hpp"
#include "shared_state.hpp"
#include "theme.hpp"

#include <boost/filesystem/file_status.hpp>
#include <boost/filesystem/operations.hpp>
#include <boost/system/detail/error_code.hpp>

#include <cstdint>
#include <ftxui/component/component.hpp>
#include <ftxui/component/screen_interactive.hpp>
#include <ftxui/dom/elements.hpp>
#include <ftxui/screen/color_info.hpp>

#include <algorithm>
#include <cmath>
#include <cctype>
#include <cstdlib>
#include <deque>
#include <format>
#include <mutex>
#include <memory>
#include <string>
#include <thread>

using boost::filesystem::directory_entry;
using boost::filesystem::directory_iterator;
using boost::filesystem::file_status;
using boost::system::error_code;

using Perun::file_operations;
using Perun::CopyConflictMode;
using Perun::JobInstructions;
using Perun::JobSpec;
using Perun::JobState;
using Perun::JobSnapshot;
using Perun::Operation;
using Perun::OperationPlan;
using Perun::OperationType;
using Perun::selection_plan;

std::string time_to_string(double time);

namespace ftxui {
BookmarksDialog::BookmarksDialog(
  std::function<void()> close_dialog,
  std::function<std::vector<Filepath>()> list_bookmarks,
  std::function<void()> add_current_dir,
  std::function<void(const Filepath&)> remove_bookmark,
  std::function<void(const Filepath&)> open_bookmark
) : Dialog(nullptr),
    close_dialog(std::move(close_dialog)),
    list_bookmarks(std::move(list_bookmarks)),
    add_current_dir(std::move(add_current_dir)),
    remove_bookmark(std::move(remove_bookmark)),
    open_bookmark(std::move(open_bookmark)) {
  ButtonOption ascii_button;
  ascii_button.transform = ascii_button_transform();
  button_add             = Button(" Add Current ", [this] { run_add(); }, ascii_button);
  button_remove          = Button(" Remove ", [this] { run_remove(); }, ascii_button);
  button_open            = Button(" Open ", [this] { run_open(); }, ascii_button);
  button_close           = Button(" Close ", [this] { cancel(); }, ascii_button);

  _data_source.dataset_size = [this]() -> DataSize {
    int64_t size = static_cast<int64_t>(bookmarks.size());
    return {size, 0, std::max(int64_t{0}, size - 1)};
  };
  _data_source.move_id_by = [this](int64_t& id, int64_t delta) -> bool {
    int64_t old = id;
    int64_t max = std::max(int64_t{0}, static_cast<int64_t>(bookmarks.size()) - 1);
    id = std::clamp(id + delta, int64_t{0}, max);
    return id != old;
  };
  _data_source.count_items_before = [](int64_t id) -> int64_t { return id; };
  _data_source.transform = [this](DSRenderContext& c) -> Element {
    if (c.id < 0 || c.id >= static_cast<int64_t>(bookmarks.size())) return text("<invalid>");
    Element row = text(" " + Location::decode(bookmarks.at(c.id).native()).display());
    if (c.focused) {
      row |= c.component_focused ? bgcolor(Color::DarkBlue) : bgcolor(Color::GrayDark);
      row |= ftxui::focus;
    }
    return row;
  };
  _data_source.on_event = [this](DSEventContext c) -> bool {
    if (c.event == Event::Return) {
      run_open();
      return true;
    }
    if (c.event == Event::Delete || c.event == Event::Backspace || c.event == Event::Character('d')) {
      run_remove();
      return true;
    }
    return c.handled;
  };
  _data_source.min_y = 10;
  list_menu          = clipped_menu(&_data_source);

  navigation = CatchEvent(Container::Vertical({
                            Container::Horizontal({button_add, button_remove, button_open, button_close}),
                            list_menu,
                          }),
                          [this](Event e) -> bool {
                            if (e == keys().key_cancel_dialog) {
                              cancel();
                              return true;
                            }
                            if (e == Event::Character('a')) {
                              run_add();
                              return true;
                            }
                            return false;
                          });
  renderer   = Renderer(navigation, [this]() -> Element {
    auto title = text(" Bookmarks [" + std::to_string(bookmarks.size()) + "] ") | bold | hcenter;
    auto content = vbox({
      hbox({
        button_add->Render() | hcenter | xflex_grow,
        separator(),
        button_remove->Render() | hcenter | xflex_grow,
        separator(),
        button_open->Render() | hcenter | xflex_grow,
        separator(),
        button_close->Render() | hcenter | xflex_grow,
      }),
      separator(),
      bookmarks.empty() ? (text("  No bookmarks. Press 'a' to add current directory.") | dim) : (list_menu->Render() | yflex),
    });
    return window(title, content, BorderStyle::DOUBLE);
  });
}

void BookmarksDialog::OnShow() {
  refresh();
  list_menu->TakeFocus();
}

void BookmarksDialog::cancel() { close_dialog(); }

void BookmarksDialog::refresh() {
  bookmarks = list_bookmarks ? list_bookmarks() : std::vector<Filepath>();
  if (bookmarks.empty()) {
    _data_source.focused_id = 0;
  } else {
    _data_source.focused_id = std::clamp(_data_source.focused_id, int64_t{0}, static_cast<int64_t>(bookmarks.size()) - 1);
  }
}

bool BookmarksDialog::has_selected() const {
  return !bookmarks.empty() && _data_source.focused_id >= 0 && _data_source.focused_id < static_cast<int64_t>(bookmarks.size());
}

int64_t BookmarksDialog::selected_index() const {
  if (!has_selected()) return -1;
  return _data_source.focused_id;
}

void BookmarksDialog::run_open() {
  const int64_t index = selected_index();
  if (index < 0) return;
  const Filepath selected = bookmarks.at(index);
  if (open_bookmark) open_bookmark(selected);
  close_dialog();
}

void BookmarksDialog::run_add() {
  if (add_current_dir) add_current_dir();
  refresh();
}

void BookmarksDialog::run_remove() {
  const int64_t index = selected_index();
  if (index < 0) return;
  const Filepath selected = bookmarks.at(index);
  if (remove_bookmark) remove_bookmark(selected);
  refresh();
}

namespace {

std::string to_lower_ascii(std::string s) {
  for (char& c : s) {
    c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  }
  return s;
}

int fuzzy_score(const std::string& query_lower, const std::string& text_lower) {
  if (query_lower.empty()) return 0;
  int  score         = 0;
  int  qpos          = 0;
  int  last_match_id = -2;
  bool has_prefix    = false;
  for (int i = 0; i < static_cast<int>(text_lower.size()) && qpos < static_cast<int>(query_lower.size()); ++i) {
    if (text_lower[i] != query_lower[qpos]) continue;
    if (qpos == 0 && i == 0) {
      has_prefix = true;
      score += 20;
    }
    const bool contiguous = i == last_match_id + 1;
    score += contiguous ? 10 : 3;
    const bool word_start = i == 0 || text_lower[i - 1] == ' ' || text_lower[i - 1] == '_' || text_lower[i - 1] == '-';
    if (word_start) score += 4;
    last_match_id = i;
    qpos++;
  }
  if (qpos != static_cast<int>(query_lower.size())) return -1;
  if (has_prefix) score += 10;
  return score;
}

}  // namespace

//
// CommandPaletteDialog
//

CommandPaletteDialog::CommandPaletteDialog(
  std::function<void()> close_dialog,
  std::function<std::vector<Command>()> list_commands,
  std::function<void(const std::string&)> execute_command,
  std::function<bool(const std::string&, const Event&, std::string&)> rebind_command
) : Dialog(nullptr),
    close_dialog(std::move(close_dialog)),
    list_commands(std::move(list_commands)),
    execute_command(std::move(execute_command)),
    rebind_command(std::move(rebind_command)) {
  ButtonOption ascii_button;
  ascii_button.transform = ascii_button_transform();
  button_run             = Button(" Run ", [this] { run_selected(); }, ascii_button);
  button_rebind          = Button(" Rebind ", [this] { start_rebind(); }, ascii_button);
  button_close           = Button(" Close ", [this] { cancel(); }, ascii_button);

  InputOption input_opt;
  input_opt.multiline       = false;
  input_opt.cursor_position = &filter_cursor_pos;
  input_opt.on_change       = [this]() { apply_filter(); };
  input_opt.on_enter        = [this]() { run_selected(); };
  input_filter              = Input(&filter_txt, "Search command", input_opt) | showInputCursor(&filter_cursor_pos);

  _data_source.dataset_size = [this]() -> DataSize {
    auto sz = static_cast<int64_t>(visible_ids.size());
    return {sz, 0, std::max(int64_t{0}, sz - 1)};
  };
  _data_source.move_id_by = [this](int64_t& id, int64_t delta) -> bool {
    int64_t old = id;
    int64_t max = std::max(int64_t{0}, static_cast<int64_t>(visible_ids.size()) - 1);
    id = std::clamp(id + delta, int64_t{0}, max);
    return id != old;
  };
  _data_source.count_items_before = [](int64_t id) -> int64_t { return id; };
  _data_source.on_event = [this](DSEventContext c) -> bool {
    if (c.event == Event::Return) {
      run_selected();
      return true;
    }
    return c.handled;
  };
  _data_source.transform = [this](DSRenderContext& c) -> Element {
    if (c.id < 0 || c.id >= static_cast<int64_t>(visible_ids.size())) return text("<invalid>");
    const Command& cmd = commands_all.at(visible_ids.at(c.id));
    auto row = hbox({
      text(" " + cmd.description) | xflex_grow,
      text(" " + event_to_string(cmd.key) + " ") | dim,
    });
    if (c.focused) {
      row |= c.component_focused ? bgcolor(Color::DarkBlue) : bgcolor(Color::GrayDark);
      row |= ftxui::focus;
    }
    return row;
  };
  _data_source.min_y = 12;
  list_menu          = clipped_menu(&_data_source);

  navigation = CatchEvent(Container::Vertical({
                            Container::Horizontal({button_run, button_rebind, button_close}),
                            input_filter,
                            list_menu,
                          }),
                          [this](Event e) -> bool {
                            if (capture_key_mode) return capture_rebind_key(e);
                            if (e == Event::CtrlK) {
                              start_rebind();
                              return true;
                            }
                            return close_on_esc(this)(e);
                          });
  renderer   = Renderer(navigation, [this]() -> Element {
    auto title = text(" Command Palette [" + std::to_string(visible_ids.size()) + "] ") | bold | hcenter;
    auto content = vbox({
      hbox({
        button_run->Render() | hcenter | xflex_grow,
        separator(),
        button_rebind->Render() | hcenter | xflex_grow,
        separator(),
        button_close->Render() | hcenter | xflex_grow,
      }),
      separator(),
      input_filter->Render(),
      separator(),
      capture_key_mode ? (text(" Press new key for selected command (Esc to cancel) ") | dim) : (text(" Press Ctrl+K or use Rebind button to change selected shortcut ") | dim),
      !status_message.empty() ? (text(" " + status_message + " ") | dim) : text(""),
      separator(),
      visible_ids.empty() ? (text("  No commands.") | dim) : (list_menu->Render() | yflex),
    });
    return window(title, content, BorderStyle::DOUBLE);
  });
}

void CommandPaletteDialog::cancel() { close_dialog(); }

void CommandPaletteDialog::OnShow() {
  commands_all = list_commands ? list_commands() : std::vector<Command>();
  filter_txt.clear();
  filter_cursor_pos = 0;
  status_message.clear();
  capture_key_mode = false;
  apply_filter();
  auto screen = ScreenInteractive::Active();
  if (screen) _data_source.min_y = std::max(12, static_cast<int>(0.8 * screen->dimy()));
  input_filter->TakeFocus();
}

void CommandPaletteDialog::apply_filter() {
  struct RankedItem {
    int64_t index;
    int     score;
  };
  std::vector<RankedItem> ranked;
  ranked.reserve(commands_all.size());

  const std::string query = to_lower_ascii(filter_txt);
  for (int64_t i = 0; i < static_cast<int64_t>(commands_all.size()); ++i) {
    const Command& cmd  = commands_all.at(i);
    const std::string searchable = to_lower_ascii(cmd.id + " " + cmd.description);
    int score = fuzzy_score(query, searchable);
    if (query.empty()) score = 0;
    if (score < 0) continue;
    ranked.push_back({i, score});
  }

  std::sort(ranked.begin(), ranked.end(), [this](const RankedItem& a, const RankedItem& b) {
    if (a.score != b.score) return a.score > b.score;
    const Command& ca = commands_all.at(a.index);
    const Command& cb = commands_all.at(b.index);
    if (ca.use_count != cb.use_count) return ca.use_count > cb.use_count;
    return ca.description < cb.description;
  });

  visible_ids.clear();
  visible_ids.reserve(ranked.size());
  for (const auto& x : ranked) visible_ids.push_back(x.index);

  if (visible_ids.empty()) {
    _data_source.focused_id = 0;
  } else {
    _data_source.focused_id = std::clamp(_data_source.focused_id, int64_t{0}, static_cast<int64_t>(visible_ids.size()) - 1);
  }
}

void CommandPaletteDialog::run_selected() {
  if (visible_ids.empty()) return;
  const int64_t focused = std::clamp(_data_source.focused_id, int64_t{0}, static_cast<int64_t>(visible_ids.size()) - 1);
  const Command& cmd = commands_all.at(visible_ids.at(focused));
  if (execute_command) execute_command(cmd.id);
}

void CommandPaletteDialog::start_rebind() {
  if (visible_ids.empty()) return;
  status_message = "Waiting for new shortcut key...";
  capture_key_mode = true;
}

bool CommandPaletteDialog::capture_rebind_key(const Event& e) {
  if (e == Event::Escape) {
    capture_key_mode = false;
    status_message   = "Shortcut rebinding canceled";
    return true;
  }
  if (e == Event::Custom || e.is_mouse() || e.is_cursor_position()) return true;
  if (visible_ids.empty()) {
    capture_key_mode = false;
    return true;
  }

  const int64_t focused = std::clamp(_data_source.focused_id, int64_t{0}, static_cast<int64_t>(visible_ids.size()) - 1);
  const Command cmd = commands_all.at(visible_ids.at(focused));
  capture_key_mode = false;
  if (!rebind_command) {
    status_message = "Rebinding callback is not available";
    return true;
  }

  std::string err;
  const bool ok = rebind_command(cmd.id, e, err);
  if (ok) {
    status_message = "Updated '" + cmd.description + "' to " + event_to_string(e);
    commands_all = list_commands ? list_commands() : std::vector<Command>();
    apply_filter();
  } else {
    status_message = err.empty() ? "Failed to rebind shortcut" : err;
  }
  return true;
}

//
// ThemeColorsDialog
//

namespace {

std::string normalize_color_name(std::string value) {
  std::string out;
  out.reserve(value.size());
  for (char ch : value) {
    if (std::isalnum(static_cast<unsigned char>(ch))) {
      out.push_back(static_cast<char>(std::tolower(static_cast<unsigned char>(ch))));
    }
  }
  return out;
}

bool parse_palette_token(std::string token, int& index) {
  if (token.size() < 2) return false;
  token = normalize_color_name(std::move(token));
  if (token.empty() || token[0] != 'p') return false;
  for (size_t i = 1; i < token.size(); ++i) {
    if (!std::isdigit(static_cast<unsigned char>(token[i]))) return false;
  }
  index = std::atoi(token.c_str() + 1);
  return index >= 0 && index <= 255;
}

bool token_to_palette_index(const std::string& token, int& out_index) {
  if (parse_palette_token(token, out_index)) return true;
  const std::string norm = normalize_color_name(token);
  if (norm.empty()) return false;
  for (int i = 0; i <= 255; ++i) {
    const auto info = GetColorInfo(Color::Palette256(i));
    if (normalize_color_name(info.name ? info.name : "") == norm) {
      out_index = i;
      return true;
    }
  }
  return false;
}

std::string palette_token_for_index(int index) {
  return "p" + std::to_string(std::clamp(index, 0, 255));
}

std::vector<std::vector<int>> palette_256_grid() {
  std::vector<ColorInfo> info_gray;
  std::vector<ColorInfo> info_color;
  for (int i = 16; i < 256; ++i) {
    ColorInfo info = GetColorInfo(Color::Palette256(i));
    if (info.saturation == 0) {
      info_gray.push_back(info);
    } else {
      info_color.push_back(info);
    }
  }

  std::sort(info_color.begin(), info_color.end(), [](const ColorInfo& a, const ColorInfo& b) { return a.hue < b.hue; });

  std::vector<std::vector<ColorInfo>> info_columns(8);
  info_columns[0] = info_gray;
  for (size_t i = 0; i < info_color.size(); ++i) {
    info_columns[1 + 7 * i / info_color.size()].push_back(info_color[i]);
  }

  for (auto& column : info_columns) {
    std::sort(column.begin(), column.end(), [](const ColorInfo& a, const ColorInfo& b) { return a.value < b.value; });
    for (int i = 0; i < static_cast<int>(column.size()) - 1; ++i) {
      int best_index    = i + 1;
      int best_distance = 255 * 255 * 3;
      for (int j = i + 1; j < static_cast<int>(column.size()); ++j) {
        const int dx       = static_cast<int>(column[i].red) - static_cast<int>(column[j].red);
        const int dy       = static_cast<int>(column[i].green) - static_cast<int>(column[j].green);
        const int dz       = static_cast<int>(column[i].blue) - static_cast<int>(column[j].blue);
        const int distance = dx * dx + dy * dy + dz * dz;
        if (distance < best_distance) {
          best_distance = distance;
          best_index    = j;
        }
      }
      std::swap(column[i + 1], column[best_index]);
    }
  }

  std::vector<std::vector<int>> grid;
  grid.reserve(info_columns.size());
  for (const auto& column : info_columns) {
    std::vector<int> row;
    row.reserve(column.size());
    for (const auto& item : column) row.push_back(item.index_256);
    grid.push_back(std::move(row));
  }
  return grid;
}

}  // namespace

ThemeColorsDialog::ThemeColorsDialog(
  std::function<void()> close_dialog,
  std::function<std::vector<ThemeColorEntry>()> list_entries,
  std::function<std::vector<std::string>()> list_tokens,
  std::function<bool(const std::string&, const std::string&, std::string&)> set_color_token,
  std::function<void()> reset_defaults,
  std::function<void()> persist_colors
) : Dialog(nullptr),
    close_dialog(std::move(close_dialog)),
    list_entries(std::move(list_entries)),
    list_tokens(std::move(list_tokens)),
    set_color_token(std::move(set_color_token)),
    reset_defaults(std::move(reset_defaults)),
    persist_colors(std::move(persist_colors)) {
  ButtonOption ascii_button;
  ascii_button.transform = ascii_button_transform();
  button_save            = Button(" Save ", [this] {
    if (this->persist_colors) this->persist_colors();
    status_message = "Theme colors saved";
  }, ascii_button);
  button_reset           = Button(" Reset Defaults ", [this] {
    if (this->reset_defaults) this->reset_defaults();
    entries = this->list_entries ? this->list_entries() : std::vector<ThemeColorEntry>();
    status_message = "Reset to default colors";
  }, ascii_button);
  button_close           = Button(" Close ", [this] { cancel(); }, ascii_button);

  _data_source.dataset_size = [this]() -> DataSize {
    auto sz = static_cast<int64_t>(entries.size());
    return {sz, 0, std::max(int64_t{0}, sz - 1)};
  };
  _data_source.move_id_by = [this](int64_t& id, int64_t delta) -> bool {
    int64_t old = id;
    int64_t max = std::max(int64_t{0}, static_cast<int64_t>(entries.size()) - 1);
    id = std::clamp(id + delta, int64_t{0}, max);
    return id != old;
  };
  _data_source.count_items_before = [](int64_t id) -> int64_t { return id; };
  _data_source.on_event = [this](DSEventContext c) -> bool {
    if (c.event == Event::Return) {
      open_picker_for_focused();
      return true;
    }
    return c.handled;
  };
  _data_source.transform = [this](DSRenderContext& c) -> Element {
    if (c.id < 0 || c.id >= static_cast<int64_t>(entries.size())) return text("<invalid>");
    const auto& entry = entries.at(c.id);
    auto row = hbox({
      text(" " + entry.label) | xflex_grow,
      text(" " + entry.token + " ") | dim,
    });
    if (c.focused) {
      row |= c.component_focused ? bgcolor(Color::DarkBlue) : bgcolor(Color::GrayDark);
      row |= ftxui::focus;
    }
    return row;
  };
  _data_source.min_y = 14;
  list_menu          = clipped_menu(&_data_source);

  navigation = CatchEvent(Container::Vertical({
                            Container::Horizontal({button_save, button_reset, button_close}),
                            list_menu,
                          }),
                          [this](Event e) -> bool {
                            if (picker_open) {
                              if (e == Event::ArrowUp) {
                                move_picker(-1, 0);
                                return true;
                              }
                              if (e == Event::ArrowDown) {
                                move_picker(+1, 0);
                                return true;
                              }
                              if (e == Event::ArrowLeft) {
                                move_picker(0, -1);
                                return true;
                              }
                              if (e == Event::ArrowRight) {
                                move_picker(0, +1);
                                return true;
                              }
                              if (e == Event::Return) {
                                accept_picker();
                                return true;
                              }
                              if (e == Event::Escape) {
                                cancel_picker();
                                return true;
                              }
                              return true;
                            }
                            if (e == Event::Return && list_menu->Focused()) {
                              open_picker_for_focused();
                              return true;
                            }
                            return close_on_esc(this)(e);
                          });
  renderer   = Renderer(navigation, [this]() -> Element {
    auto title = text(" Theme Colors [" + std::to_string(entries.size()) + "] ") | bold | hcenter;
    auto content = vbox({
      hbox({
        button_save->Render() | hcenter | xflex_grow,
        separator(),
        button_reset->Render() | hcenter | xflex_grow,
        separator(),
        button_close->Render() | hcenter | xflex_grow,
      }),
      separator(),
      text(" Use Up/Down to select a color, Enter to open picker. ") | dim,
      !status_message.empty() ? (text(" " + status_message + " ") | dim) : text(""),
      separator(),
      entries.empty() ? (text("  No editable colors.") | dim) : (list_menu->Render() | yflex),
    });
    Element base = window(title, content, BorderStyle::DOUBLE);
    if (!picker_open) return base;
    return dbox({base, render_picker() | clear_under_colors | center});
  });
}

void ThemeColorsDialog::OnShow() {
  entries = list_entries ? list_entries() : std::vector<ThemeColorEntry>();
  tokens  = list_tokens ? list_tokens() : std::vector<std::string>();
  picker_grid = palette_256_grid();
  picker_row  = 0;
  picker_col  = 0;
  picker_open = false;
  status_message.clear();
  _data_source.focused_id = 0;
  auto screen = ScreenInteractive::Active();
  if (screen) _data_source.min_y = std::max(12, static_cast<int>(0.8 * screen->dimy()));
  list_menu->TakeFocus();
}

void ThemeColorsDialog::cancel() { close_dialog(); }

void ThemeColorsDialog::open_picker_for_focused() {
  if (entries.empty() || picker_grid.empty()) return;
  const int64_t focused = std::clamp(_data_source.focused_id, int64_t{0}, static_cast<int64_t>(entries.size()) - 1);
  const auto&   entry   = entries.at(focused);
  int           wanted  = 16;
  token_to_palette_index(entry.token, wanted);
  picker_row  = 0;
  picker_col  = 0;
  picker_open = true;

  for (int r = 0; r < static_cast<int>(picker_grid.size()); ++r) {
    for (int c = 0; c < static_cast<int>(picker_grid[r].size()); ++c) {
      if (picker_grid[r][c] == wanted) {
        picker_row = r;
        picker_col = c;
        return;
      }
    }
  }
}

void ThemeColorsDialog::move_picker(int drow, int dcol) {
  if (!picker_open || picker_grid.empty()) return;
  picker_row = std::clamp(picker_row + drow, 0, static_cast<int>(picker_grid.size()) - 1);
  if (picker_grid[picker_row].empty()) {
    picker_col = 0;
    return;
  }
  picker_col = std::clamp(picker_col + dcol, 0, static_cast<int>(picker_grid[picker_row].size()) - 1);
}

void ThemeColorsDialog::accept_picker() {
  if (!picker_open || entries.empty()) return;
  const int64_t focused = std::clamp(_data_source.focused_id, int64_t{0}, static_cast<int64_t>(entries.size()) - 1);
  auto&         entry   = entries.at(focused);
  const std::string next_token = palette_token_for_index(selected_picker_index());
  std::string error;
  if (!set_color_token || !set_color_token(entry.id, next_token, error)) {
    status_message = error.empty() ? "Failed to update theme color" : error;
    return;
  }
  entry.token    = next_token;
  status_message = "Updated " + entry.label + " -> " + next_token;
  picker_open    = false;
}

void ThemeColorsDialog::cancel_picker() {
  if (!picker_open) return;
  picker_open = false;
}

int ThemeColorsDialog::selected_picker_index() const {
  if (picker_grid.empty()) return 16;
  const int row = std::clamp(picker_row, 0, static_cast<int>(picker_grid.size()) - 1);
  if (picker_grid[row].empty()) return 16;
  const int col = std::clamp(picker_col, 0, static_cast<int>(picker_grid[row].size()) - 1);
  return picker_grid[row][col];
}

Element ThemeColorsDialog::render_picker() const {
  const int         idx         = selected_picker_index();
  const std::string chosen_name = palette_token_for_index(idx);

  auto chosen_text = text(" Chosen: " + chosen_name + "                                ") | bgcolor(Color(Color::Palette256(idx)));

  Elements rows;
  for (int r = 0; r < static_cast<int>(picker_grid.size()); ++r) {
    Elements row;
    for (int c = 0; c < static_cast<int>(picker_grid[r].size()); ++c) {
      const bool selected = (r == picker_row) && (c == picker_col);
      auto       cell     = text(selected ? "[]" : "  ") | bgcolor(Color(Color::Palette256(picker_grid[r][c])));
      if (selected) {
        cell |= inverted;
        cell |= bold;
      }
      row.push_back(std::move(cell));
    }
    rows.push_back(hbox(std::move(row)));
  }

  auto content = vbox({
    chosen_text,
    separator(),
    vbox(std::move(rows)),
    separator(),
    text(" Arrows: move  Enter: apply  Esc: cancel ") | dim,
  });
  return window(text(" Color Picker (256) ") | bold | hcenter, content, BorderStyle::DOUBLE);
}

//
// Commands
//

}
