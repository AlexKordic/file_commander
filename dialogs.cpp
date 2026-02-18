
#include "dialogs.hpp"
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

std::string time_to_string(double time);

namespace ftxui {

namespace {
std::atomic<uint64_t> g_copy_discovery_sequence{1};
}

Element screen_render_time() {
  double seconds = 0;
  auto   screen  = ScreenInteractive::Active();
  if (screen) seconds = screen->LastFrameTime();
  const int ms = std::lround(1000.0 * seconds);
  auto      e  = text(" " + std::to_string(ms) + "ms ");
  if (ms > 500) {
    e = e | bgcolor(theme().debuginfo_colors[3]);
  } else if (ms > 120) {
    e = e | bgcolor(theme().debuginfo_colors[2]);
  } else if (ms > 16) {
    e = e | bgcolor(theme().debuginfo_colors[1]);
  } else {
    e = e | bgcolor(theme().debuginfo_colors[0]);
  }
  return e;
}

Dialog::Dialog(PanelSharedState::P app) : app(app) {}

std::function<Element(const EntryState&)> ascii_button_transform() {
  return [](const EntryState& s) -> Element {
    const std::string t = s.focused ? "[" + s.label + "]" : " " + s.label + " ";
    if (s.focused) return text(t) | theme().sort_button_active;
    return text(t) | theme().sort_button;
  };
}

std::function<Element(const EntryState& state)> text_menuitem_transform() {
  return [](const EntryState& state) -> Element {
    // std::string label = (state.active ? "> " : "  ") + state.label;
    Element e = paragraph(state.label);
    if (state.focused) { e = e | inverted; }
    if (state.active) { e = e | bold; }
    return e;
  };
}

// using GetIndex = std::function<int64_t()>;

std::function<bool(int64_t&, int64_t)> filelist_move_id_by(PanelSharedState::P app) {
  return [state = app](int64_t& index, int64_t offset) -> bool {
    int64_t old = index;
    index       = state->dir->offset_vissible(index, offset);
    return old != index;
  };
}

std::function<int64_t(int64_t)> filelist_count_items_before(PanelSharedState::P app) {
  return [state = app](int64_t index) -> int64_t {
    // TODO: optimize by using boost interval container https://www.boost.org/doc/libs/1_86_0/libs/icl/doc/html/index.html
    if (index > state->dir->items.size()) return state->dir->items.size();
    int64_t count = 0;
    int64_t total = std::min(index, int64_t(state->dir->items.size()));
    for (int64_t i = 0; i < total; i++) {
      if (state->dir->items.at(i).visible()) count++;
    }
    return count;
  };
}

std::function<Element(DSRenderContext&)> filelist_transform(PanelSharedState::P app) {
  return [state = app](DSRenderContext& ctx) -> Element {
    if (ctx.id < 0 || ctx.id >= state->dir->items.size()) { return text("<invalid index>"); }
    const int64_t  largest_item_bytes = state->dir->stats().largest_item_bytes;
    const DirItem& data               = state->dir->items.at(ctx.id);
    const bool     selected           = data.selected();

    Element n;
    Element size;
    if (data.is_dir()) {
      n    = text("/" + data.filename_ref());
      size = text("");
    } else {
      n    = text(data.filename_ref());
      size = coloredInt(data.size());
    }
    float     size_ratio = float(data.size()) / largest_item_bytes;
    Decorator highlight  = bgGaugeLeft(size_ratio);
    if (ctx.focused) {
      if (ctx.component_focused) {
        highlight = bgGaugeLeft(size_ratio, theme().files_focused_full, theme().files_focused_empty) | theme().files_focused;
      } else {
        highlight = bgGaugeLeft(size_ratio, theme().files_unfocused_full, theme().files_unfocused_empty) | theme().files_focused;
      }
    }
    n = n | xflex_grow | highlight;
    if (selected) n |= theme().files_selected;
    if (!ctx.focused && !selected) n |= filetype_color(data);

    Element perms = text(data.perms_string()) | dim;
    Element owner_group = text(data.owner_string() + ":" + data.group_string()) | dim;
    Element t = text(data.get_time());
    if (selected) t |= theme().files_selected;

    Elements cols;
    cols.push_back(std::move(n));
    if (state->show_permissions_column) {
      cols.push_back(separatorLight());
      cols.push_back(std::move(perms));
    }
    if (state->show_owner_group_column) {
      cols.push_back(separatorLight());
      cols.push_back(std::move(owner_group));
    }
    cols.push_back(std::move(size));
    cols.push_back(separatorLight());
    cols.push_back(std::move(t));

    Element row = hbox(std::move(cols));
    if (ctx.focused) {
      if (ctx.focused) row |= ftxui::focus;
      else row |= ftxui::select;  // TODO: ftxui::select does nothing in our case, decorate background somehow
    }
    if (data.symlink_ref() || data.warning_ref()) {
      Elements rows = {std::move(row)};
      if (data.symlink_ref()) { rows.push_back(text(" -> " + data.symlink_ref()->native()) | theme().files_symlink); }
      if (data.warning_ref()) { rows.push_back(text(*data.warning_ref()) | theme().files_warning); }
      row = vbox(std::move(rows));
    }
    if (ctx.hovered) { row |= theme().files_hovered; }
    return std::move(row);
  };
}

void setup_filelist_datasource(PanelSharedState::P app, DataSource& data_source) {
  data_source.dataset_size       = [state = app]() -> DataSize { return {state->dir->stats().items_visible, 0, state->dir->stats().items_total - 1}; };
  data_source.move_id_by         = filelist_move_id_by(app);
  data_source.count_items_before = filelist_count_items_before(app);
  data_source.transform          = filelist_transform(app);
}

bool filelist_handle_commands(PanelSharedState* app, DataSource* data_source, DSEventContext& ctx) {
  auto execute_panel_callback = [&]() -> bool {
    const Command* action = commands().find_panel_by_key(ctx.event);
    if (!action || action->kind != CommandKind::EXECUTE_CALLBACK) return false;

    data_source->focused_id = app->dir->offset_vissible(data_source->focused_id, 0);
    if (action->id == "select_toggle") {
      if (app->dir->items.empty()) return false;
      app->dir->item_toggle_select(data_source->focused_id);
      data_source->focused_id = app->dir->next_visible(data_source->focused_id);
      return true;
    }
    if (action->id == "clear_selection") {
      app->dir->clear_selection();
      return true;
    }
    if (action->id == "select_all") {
      app->dir->select_all();
      return true;
    }
    if (action->id == "toggle_permissions_column") {
      app->show_permissions_column = !app->show_permissions_column;
      return true;
    }
    if (action->id == "toggle_owner_group_column") {
      app->show_owner_group_column = !app->show_owner_group_column;
      return true;
    }
    if (action->id == "leave_dir") {
      if (app->leave_virtual_dir && app->leave_virtual_dir(data_source->focused_id)) {
        app->filter_txt.clear();
        return true;
      }
      const Filepath old_path   = app->dir->path;
      const Filepath parent_dir = app->dir->path.parent_path();
      app->move_to(parent_dir);
      data_source->focused_id = app->dir->offset_vissible(0, 0);
      app->filter_txt.clear();
      for (int i = 0; i < app->dir->items.size(); i++) {
        const DirItem& item = app->dir->items.at(i);
        if (item.path_ref() == old_path) {
          data_source->focused_id = i;
          break;
        }
      }
      return true;
    }
    if (action->id == "enter_dir") {
      if (app->dir->items.empty()) return false;
      DirItem& where = app->dir->items.at(data_source->focused_id);
      if (!where.is_dir()) {
        if (!app->enter_archive) return false;
        const bool entered_archive = app->enter_archive(where.path_ref());
        if (!entered_archive) return false;
        data_source->focused_id = app->dir->offset_vissible(0, 0);
        app->filter_txt.clear();
        return true;
      }
      app->move_to(where.path_ref());
      data_source->focused_id = app->dir->offset_vissible(0, 0);
      app->filter_txt.clear();
      return true;
    }
    return false;
  };

  if (execute_panel_callback()) return true;

  const Command* action = commands().find_panel_by_key(ctx.event);
  if (action) {
    if (action->kind != CommandKind::SHOW_DIALOG) return false;
    app->action.dialog            = action->dialog;
    app->action.arguments         = app->dir->take_selected();
    app->action.arguments->origin = app->dir->path;
    const bool no_items           = app->dir->items.empty();
    if (no_items) {
      // no items for selected to point to
      app->action.arguments->focused = Filepath();
    } else {
      app->action.arguments->focused = app->dir->items.at(data_source->focused_id).path_ref();
    }
    app->action.show_dialog();
    return true;
  }
  return false;
}

bool filelist_handle_filter(PanelSharedState* app, DataSource* data_source, DSEventContext& ctx) {
  if (ctx.handled) return true;
  static const Event forbidden_events[]  = {Event::ArrowDown, Event::ArrowUp};
  static const auto  b_                  = std::begin(forbidden_events);
  static const auto  e_                  = std::end(forbidden_events);
  const bool         dont_send_to_filter = std::find(b_, e_, ctx.event) != e_;
  if (dont_send_to_filter) return false;

  // let the filter handle key events
  const bool filter_changed = app->filter->OnEvent(ctx.event);
  if (filter_changed) {
    app->dir->apply_filter(app->filter_txt);
    data_source->move_id_by(data_source->focused_id, 0);
  }
  return filter_changed;
}

InputOption filelist_filter_opt(int& filter_cursor_pos) {
  InputOption input_opt = InputOption::Default();
  input_opt.multiline   = false;
  input_opt.transform   = [](InputState state) {
    if (state.is_placeholder) {
      return state.element | theme().files_path;
    } else {
      return state.element | theme().files_filter_search;
    }
  };
  input_opt.cursor_position = &filter_cursor_pos;
  return input_opt;
}

template <typename THIS> std::function<bool(Event e)> close_on_esc(THIS* self) {
  return [self](Event e) -> bool {
    if (e == theme().key_cancel_dialog) {
      self->cancel();
      return true;
    }
    return false;
  };
}

Decorator filetype_color(const DirItem& item) {
  if (item.is_dir()) return color(theme().file_directory_file);
  Color base = theme().file_type(item.type());
  if (item.is_exe()) { return color(Color::Interpolate(0.5, base, theme().file_perm_exe)); }
  return color(base);
}

//
// Files
//

Files::Files(PanelSharedState::P s) : Dialog(std::move(s)) {
  InputOption  input_opt = filelist_filter_opt(filter_cursor_pos);
  ButtonOption ascii_button;
  ascii_button.transform = ascii_button_transform();

  app->filter            = Input(&app->filter_txt, &(app->dir->path_txt), input_opt) | showInputCursor(&filter_cursor_pos);
  app->get_focused_index = [this]() -> int { return _data_source.focused_id; };
  app->set_focused_index = [this](int index) { _data_source.focused_id = this->app->dir->offset_vissible(index, 0); };
  app->get_focused_item  = [this]() -> Filepath const* {
    _data_source.focused_id = this->app->dir->offset_vissible(_data_source.focused_id, 0);
    auto focused_index      = app->dir->offset_vissible(_data_source.focused_id, 0);
    if (app->dir->items.empty()) return nullptr;
    auto& focused = app->dir->items.at(focused_index);
    return &focused.path_ref();
  };
  app->set_min_y = [this](int y) { _data_source.min_y = y; };

  files     = DBMenu(&_data_source);
  sort_name = Button("Name", [dir = app->dir] { dir->sort_toggle_name_direction(); }, ascii_button);
  sort_size = Button("Size", [dir = app->dir] { dir->sort_toggle_size_direction(); }, ascii_button);
  sort_time = Button("Date", [dir = app->dir] { dir->sort_toggle_time_direction(); }, ascii_button);

  setup_filelist_datasource(app, _data_source);

  _data_source.on_event = [app = app, data_source = &_data_source](DSEventContext ctx) -> bool {
    // handle commands first
    bool handled = filelist_handle_commands(app.get(), data_source, ctx);
    // then handle filter
    return handled || filelist_handle_filter(app.get(), data_source, ctx);
  };

  auto render_selection = [state = app, sort_name = sort_name, sort_size = sort_size, sort_time = sort_time]() -> Element {
    std::string prefixes[3] = {"  ", "  ", "  "};
    switch (state->dir->order_by) {
    case Orderby::NAME_ASC: prefixes[0] = "↑↑"; break;
    case Orderby::NAME_DESC: prefixes[0] = "↓↓"; break;
    case Orderby::SIZE_ASC: prefixes[1] = "↑↑"; break;
    case Orderby::SIZE_DESC: prefixes[1] = "↓↓"; break;
    case Orderby::TIME_ASC: prefixes[2] = "↑↑"; break;
    case Orderby::TIME_DESC: prefixes[2] = "↓↓"; break;
    }
    auto     s        = state->dir->stats();
    std::string columns = " cols:name,size,date";
    if (state->show_permissions_column) columns += ",perm";
    if (state->show_owner_group_column) columns += ",owner:group";
    Elements children = Elements({
      text(" Sel " + std::to_string(s.items_selected) + "/" + std::to_string(s.items_total)),
      text(" bytes "),
      coloredInt(s.bytes_selected),
      text("/"),
      coloredInt(s.bytes_total),
      text(" | "),
      text(prefixes[0]),
      sort_name->Render(),
      text(prefixes[1]),
      sort_size->Render(),
      text(prefixes[2]),
      sort_time->Render(),
      text(columns) | dim,
    });
    return hbox(std::move(children));
  };
  debug_info = [this]() -> Element { return text(" " + std::to_string(app->render_count) + " "); };
  // debug_info = [this]() -> Element { return hbox({
  //   text(std::to_string(_data_source.focused_id) + "[" + std::to_string(_data_source.real_start_id) + "]"),
  //   separator(),
  //   text(std::to_string(_data_source.items_visible) + "/" + std::to_string(_data_source.v.items_total)),
  // }); };

  navigation = Container::Vertical({Container::Horizontal({sort_name, sort_size, sort_time}), files});
  renderer   = Renderer(navigation, [app = app, render_selection = render_selection, files = files, this]() -> Element {
    app->render_count++;
    return vbox({
      hbox({text(" "), app->filter->Render() | ftxui::focus | ftxui::select, this->debug_info()}),
      render_selection(),
      files->Render() | theme().files_border,
    });
  });
  files->TakeFocus();
}

//
// Mkdir
//

MkdirDialog::MkdirDialog(PanelSharedState::P s) : Dialog(std::move(s)) {
  InputOption textbox_opt;
  textbox_opt.on_change = [this]() { this->error.clear(); };
  textbox_opt.on_enter  = [this]() { this->ok(); };
  textbox_opt.multiline = false;  // otherwise new_dir_name contains `\n` at the end
  textbox               = Input(&new_dir_name, "Name for new directory", textbox_opt);

  button_ok    = Button("   OK   ", [this] { this->ok(); });
  button_close = Button(" Cancel ", [this] { this->cancel(); });

  navigation = CatchEvent(Container::Vertical({
                            textbox,
                            button_ok,
                            button_close,
                          }),
                          close_on_esc(this));
  renderer   = Renderer(navigation, [this]() -> Element { return this->render(); });
}

void MkdirDialog::OnShow() {
  new_dir_name.clear();
  error.clear();
}

Element MkdirDialog::render() {
  Elements e = {
    paragraphAlignCenter("Create Dir in " + app->action.arguments->origin.native()),
    separator(),
    textbox->Render(),
  };
  if (!error.empty()) { e.push_back(text(error) | theme().mkdir_errortxt); }
  e.push_back(filler());
  e.push_back(button_ok->Render() | hcenter);
  e.push_back(button_close->Render() | hcenter);
  return window(text(" Make Dir ") | bold | hcenter, vbox(std::move(e)), BorderStyle::DOUBLE);
}

void MkdirDialog::ok() {
  // Create dir
  auto dir_path = app->action.arguments->origin;
  dir_path /= new_dir_name;
  // Perun::l.d("mkdir::ok", dir_path.native(), {{"base", app->action.arguments->origin.native()}, {"new_dir_name", new_dir_name}});
  if (boost::filesystem::exists(dir_path)) {
    // Display error
    error = "Name conflict";
    return;
  }
  boost::filesystem::create_directory(dir_path);
  // Close dialog
  // app->dir->refresh();
  app->action.close_dialog();
}

void MkdirDialog::cancel() { app->action.close_dialog(); }

namespace {

bool glob_match_ascii_case_insensitive(const std::string& pattern, const std::string& text) {
  const auto lower = [](char c) -> char { return static_cast<char>(std::tolower(static_cast<unsigned char>(c))); };

  size_t p = 0;
  size_t t = 0;
  size_t star = std::string::npos;
  size_t match = 0;

  while (t < text.size()) {
    if (p < pattern.size() && (pattern[p] == '?' || lower(pattern[p]) == lower(text[t]))) {
      ++p;
      ++t;
      continue;
    }
    if (p < pattern.size() && pattern[p] == '*') {
      star  = p++;
      match = t;
      continue;
    }
    if (star != std::string::npos) {
      p = star + 1;
      t = ++match;
      continue;
    }
    return false;
  }
  while (p < pattern.size() && pattern[p] == '*') ++p;
  return p == pattern.size();
}

}  // namespace

//
// Glob Select
//

GlobSelectDialog::GlobSelectDialog(PanelSharedState::P s, bool select_mode) : Dialog(std::move(s)), select_mode(select_mode) {
  InputOption input_opt;
  input_opt.multiline       = false;
  input_opt.cursor_position = &cursor_pos;
  input_opt.on_change       = [this]() { error.clear(); };
  input_opt.on_enter        = [this]() { ok(); };
  input_pattern             = Input(&pattern, "Pattern (e.g. *.txt)", input_opt) | showInputCursor(&cursor_pos);

  button_ok    = Button("   OK   ", [this] { ok(); });
  button_close = Button(" Cancel ", [this] { cancel(); });

  navigation = CatchEvent(Container::Vertical({
                            input_pattern,
                            button_ok,
                            button_close,
                          }),
                          close_on_esc(this));
  renderer   = Renderer(navigation, [this]() -> Element { return render(); });
}

void GlobSelectDialog::OnShow() {
  pattern.clear();
  error.clear();
  cursor_pos = 0;
  input_pattern->TakeFocus();
}

void GlobSelectDialog::ok() {
  if (pattern.empty()) {
    error = "Pattern is empty";
    return;
  }

  bool any_match = false;
  for (int i = 0; i < static_cast<int>(app->dir->items.size()); ++i) {
    const bool matches = glob_match_ascii_case_insensitive(pattern, app->dir->items.at(i).filename_ref());
    if (!matches) continue;
    any_match = true;
    if (select_mode && !app->dir->items.at(i).selected()) {
      app->dir->item_toggle_select(i);
    } else if (!select_mode && app->dir->items.at(i).selected()) {
      app->dir->item_toggle_select(i);
    }
  }
  if (!any_match) {
    error = "No items match pattern";
    return;
  }
  app->action.close_dialog();
}

void GlobSelectDialog::cancel() { app->action.close_dialog(); }

Element GlobSelectDialog::render() {
  const std::string title = select_mode ? " Select by Glob " : " Deselect by Glob ";
  const std::string hint  = select_mode ? "Select items matching wildcard pattern" : "Deselect items matching wildcard pattern";

  Elements children = {
    paragraphAlignCenter(hint),
    separator(),
    input_pattern->Render(),
  };
  if (!error.empty()) { children.push_back(text(error) | theme().mkdir_errortxt); }
  children.push_back(text("Wildcards: * matches many chars, ? matches one char") | dim);
  children.push_back(filler());
  children.push_back(button_ok->Render() | hcenter);
  children.push_back(button_close->Render() | hcenter);
  return window(text(title) | bold | hcenter, vbox(std::move(children)), BorderStyle::DOUBLE);
}

//
// Rename
//

RenameDialog::RenameDialog(PanelSharedState::P d) : Dialog(std::move(d)) {
  ButtonOption ascii_button;
  ascii_button.transform = ascii_button_transform();
  button_ok              = Button("Rename", [this] { this->ok(); }, ascii_button);
  button_close           = Button("Cancel", [this] { this->cancel(); }, ascii_button);
  menu                   = Container::Vertical({}, &selected);

  auto menu_event_filter = [this, menu = menu, button_ok = button_ok, button_close = button_close](Event event) -> bool {
    int& selected = this->selected;
    // UP/DOWN act like home/end for Input, but we want to scroll our menu
    if (event == Event::ArrowUp || (event.is_mouse() && event.mouse().button == Mouse::WheelUp)) {
      if (selected == 0) {
        button_ok->TakeFocus();
        return true;
      }
      selected = std::max(0, selected - 1);
      return true;
    }
    if (event == Event::ArrowDown || (event.is_mouse() && event.mouse().button == Mouse::WheelDown)) {
      selected = std::min((int)menu->ChildCount() - 1, selected + 1);
      return true;
    }
    if (event == Event::Return) {
      if (menu->ChildCount() == 1) {
        // Single file rename allows enter to trigger ok
        this->ok();
      } else {
        button_close->TakeFocus();
      }
      return true;
    }
    if (event == Event::Escape) {
      this->cancel();
      return true;
    }
    // Instead of passing event to active child we pass same event to all children.
    bool any = false;
    int  c   = menu->ChildCount();
    for (int i = 0; i < c; i++) { any |= menu->ChildAt(i)->OnEvent(event); }
    return any;
  };
  navigation = Container::Vertical({
    // First child are buttons
    Container::Horizontal({button_ok, button_close}),
    // Following children are path items to rename
    CatchEvent(menu, menu_event_filter),
  });
  renderer   = Renderer(navigation, [&] {
    // simple
    return window(text(" Rename ") | bold | hcenter,
                    vbox({
                    hbox({
                      button_ok->Render() | hcenter | xflex_grow,
                      separator(),
                      button_close->Render() | hcenter | xflex_grow,
                    }),
                    separator(),
                    menu->Render() | vscroll_indicator | yframe,
                  }),
                    BorderStyle::DOUBLE);
  });
}

void RenameDialog::OnShow() {
  // remove old data
  menu->DetachAllChildren();
  rows.clear();
  selected = 0;
  //
  app->action.arguments->use_focused_as_alternative();
  // create items
  int selected_count = app->action.arguments->selected.size();
  if (selected_count == 0) {
    cancel();
    return;
  }
  const bool same_dir = app->action.arguments->selected_share_same_dir();
  rows.resize(selected_count);
  for (int i = 0; i < selected_count; i++) {
    auto& data              = app->action.arguments->selected.at(i);
    rows[i].content         = data.filename().native();
    rows[i].cursor_position = 0;
    InputOption style;
    style.multiline           = false;
    style.content             = &(rows.at(i).content);
    style.placeholder         = "";
    style.cursor_position     = &(rows[i].cursor_position);
    Component input_field     = Input(style) | showInputCursor(&(rows.at(i).cursor_position));
    Component old_to_new_item = Renderer(input_field, [input_field, same_dir = same_dir, data = data]() -> Element {
      return vbox({
        text(same_dir ? data.filename().native() : data.native()) | dim,
        input_field->Render(),
      });
    });
    menu->Add(old_to_new_item);
  }
  menu->TakeFocus();
}

void RenameDialog::ok() {
  int selected_count = app->action.arguments->selected.size();
  for (int i = selected_count - 1; i >= 0; --i) {
    error_code ec;
    auto       original = app->action.arguments->selected.at(i);
    auto       new_path = original.parent_path() / rows.at(i).content;
    boost::filesystem::rename(original, new_path, ec);
    if (ec.failed()) {
      Perun::l.e("Rename failed", ec.to_string(), {{"original", original.native()}, {"new", new_path.native()}});
      continue;
    }
    rows.erase(rows.begin() + i);
    app->action.arguments->selected.erase(app->action.arguments->selected.begin() + i);
    menu->ChildAt(i)->Detach();
  }
  if (app->action.arguments->selected.empty()) {
    app->dir->clear_selection();
    app->action.close_dialog();
    return;
  }
  menu->TakeFocus();
}

void RenameDialog::cancel() { app->action.close_dialog(); }

//
// Copy
//

CopyConflict copy_conflict_from_index(int index) {
  switch (index) {
  case 1: return CopyConflict::Update;
  case 2: return CopyConflict::Skip;
  default: return CopyConflict::Replace;
  }
}

int copy_conflict_to_index(CopyConflict conflict) {
  switch (conflict) {
  case CopyConflict::Update: return 1;
  case CopyConflict::Skip: return 2;
  case CopyConflict::Replace:
  default: return 0;
  }
}

CopyConflictMode to_job_copy_conflict(CopyConflict conflict) {
  switch (conflict) {
  case CopyConflict::Update: return CopyConflictMode::Update;
  case CopyConflict::Skip: return CopyConflictMode::Skip;
  case CopyConflict::Replace:
  default: return CopyConflictMode::Replace;
  }
}

Filepath resolve_symlink(Filepath path) {
  std::vector<Filepath> chain;
  Filepath              current = std::move(path);
  for (;;) {
    error_code ec;
    Filepath   symlink_target = boost::filesystem::read_symlink(current, ec);
    if (ec.failed() || symlink_target.empty()) return current;
    if (symlink_target.is_relative()) {
      symlink_target = current.parent_path() / symlink_target;
    }
    symlink_target = symlink_target.lexically_normal();
    for (const Filepath& visited : chain) {
      error_code equivalent_ec;
      const bool same = boost::filesystem::equivalent(visited, symlink_target, equivalent_ec);
      if ((!equivalent_ec.failed() && same) || (equivalent_ec.failed() && visited == symlink_target)) {
        return Filepath();
      }
    }
    chain.push_back(current);
    current = symlink_target;
  }
}

bool is_subpath(Filepath parent, Filepath child) {
  parent = parent.lexically_normal();
  child  = child.lexically_normal();
  const std::string parent_text = parent.native();
  const std::string child_text  = child.native();
  if (parent_text.empty()) return false;
  if (child_text == parent_text) return true;
  std::string prefix = parent_text;
  if (prefix.back() != boost::filesystem::path::preferred_separator) {
    prefix.push_back(boost::filesystem::path::preferred_separator);
  }
  return child_text.rfind(prefix, 0) == 0;
}

/*
TODO:
  - Encapsulate _virtual_dir, _operational_state, _data_source, _files into discovery process
  - Run _queue_files in background
  - Render progress from _queue_files and hide ok button until all files are queued
  - Show ok button when all files are queued
  - Cancel should stop _queue_files
  - Symlink checkbox changes should restart the process
*/
CopyDialog::CopyDialog(PanelSharedState::P d) : Dialog(std::move(d)) {
  InputOption destination_opt = filelist_filter_opt(destination_cursor_pos);
  destination_opt.multiline   = false;
  destination_opt.on_enter    = [this]() { this->_start_new_discovery(); };
  input_destination_path      = Input(&destination_path, "Destination path", destination_opt) | showInputCursor(&destination_cursor_pos);

  button_ok     = Button("  COPY  ", [this] { this->run_copy(); });
  // TODO: add button "open in new tab ⮂ ↱↱↱ 🆕 tab  "
  button_cancel = Button(" Cancel ", [this] { this->cancel(); });
  CheckboxOption checkbox_opt;
  checkbox_opt.on_change     = [this]() { this->_start_new_discovery(); };
  op_follow_links            = Checkbox("Follow Links in Source", &b_follow_links, checkbox_opt);
  op_preserve_relative_links = Checkbox("Keep relative links", &b_preserve_relative_links, checkbox_opt);
  conflict_mode_labels       = {"Replace existing", "Update if newer", "Skip existing"};
  op_conflict_mode           = Radiobox(&conflict_mode_labels, &conflict_mode_selected);

  // _virtual_dir             = std::make_unique<Dir>();
  // _operation_state         = std::make_shared<PanelSharedState>(_virtual_dir.get());
  // _operation_state->filter = Input(&_operation_state->filter_txt, &(_virtual_dir->path_txt), filelist_filter_opt(filter_cursor_pos));
  // _files = DBMenu(&_data_source);
  // setup_filelist_datasource(_operation_state, _data_source);
  // _data_source.on_event = [app = _operation_state, data_source = &_data_source](DSEventContext ctx) -> bool {
  //   // handle filter only
  //   return filelist_handle_filter(app.get(), data_source, ctx);
  // };

  // Use Container::Vertical so events (arrow keys, mouse wheel) are properly
  // forwarded to the dynamically added _files child. Renderer(bool) overrides
  // OnEvent() and never delegates to children, which blocks scrolling.
  // The Render() of this container is never called — CopyDialog::render()
  // renders _files directly via the outer Renderer(navigation, lambda).
  _filelist_wrapper = Container::Vertical({});
  // // // _filelist_wrapper = _discovery_process ? _discovery_process->_files : Container::Vertical({});

  navigation = CatchEvent(Container::Vertical({
                            input_destination_path,
                            Container::Horizontal({button_ok, button_cancel}),
                            op_follow_links,
                            op_preserve_relative_links,
                            op_conflict_mode,
                            _filelist_wrapper,
                          }),
                          [this](Event e) {
                            if (e == theme().key_cancel_dialog) {
                              this->cancel();
                              return true;
                            }
                            if (e == Event::Character('1')) {
                              conflict_mode_selected = 0;
                              _conflict              = CopyConflict::Replace;
                              return true;
                            }
                            if (e == Event::Character('2')) {
                              conflict_mode_selected = 1;
                              _conflict              = CopyConflict::Update;
                              return true;
                            }
                            if (e == Event::Character('3')) {
                              conflict_mode_selected = 2;
                              _conflict              = CopyConflict::Skip;
                              return true;
                            }
                            if (e == theme().key_copy) {
                              this->run_copy();
                              return true;
                            }
                            return false;
                          });
  renderer   = Renderer(navigation, [this]() -> Element { return this->render(); });
}

void CopyDialog::cancel() {
  _clear_operation_state();
  app->action.close_dialog();
}

void CopyDialog::run_copy() {
  if (!_discovery_process) return;
  _conflict = copy_conflict_from_index(conflict_mode_selected);

  Filepath target(destination_path);
  if (target.empty()) target = app->action.arguments->target;
  if (is_archive_file_path(target)) {
    std::vector<DirItem> items;
    items.reserve(app->action.arguments->selected.size());
    for (const auto& source : app->action.arguments->selected) {
      auto& item = items.emplace_back(source);
      item._set_symlink_target(target);
    }
    auto job = std::make_shared<JobSpec>(JobSpec::Type::ARCHIVE_CREATE, std::move(items));
    _clear_operation_state();
    file_operations().add_job(job);
    app->dir->clear_selection();
    app->action.close_dialog();
    return;
  }

  auto job = std::make_shared<JobSpec>(JobSpec::Type::COPY,
                                       std::move(_discovery_process->_dir->items),
                                       to_job_copy_conflict(_conflict));
  _clear_operation_state();
  file_operations().add_job(job);
  app->dir->clear_selection();
  app->action.close_dialog();
}

Element CopyDialog::render() {
  int     file_count       = app->action.arguments->selected.size();
  Element file_list        = text("No files to copy");
  Element bytes_filter_row = text("");

  if (_discovery_process) {
    file_list        = _discovery_process->_files->Render();
    auto progress    = _discovery_process->get_progress();
    bytes_filter_row = hbox({
      text("Bytes: "),
      coloredInt(progress.byte_count),
      text(" | Dirs: "),
      text(std::to_string(progress.dir_count)),
      text(" | Files: "),
      text(std::to_string(progress.file_count)),
      text(" | Filter: "),
      _discovery_process->_state->filter->Render(),
    });
  }
  // clang-format off
  return window(
    text(" Copy " + std::to_string(file_count) + " selected items ") | bold | hcenter,
  vbox({
            hbox({text(" TO: "), input_destination_path->Render() | xflex_grow, text(" ")}),
            separator(),
            hbox({button_ok->Render() | hcenter, button_cancel->Render() | hcenter}) | hcenter,
            separatorHeavy(),
            op_follow_links->Render() | hcenter,
            op_preserve_relative_links->Render() | hcenter,
            hbox({text("Conflict mode: "), op_conflict_mode->Render()}) | hcenter,
            bytes_filter_row | hcenter,
            separatorHeavy(),
            std::move(file_list) | theme().files_border,
          }),
          BorderStyle::DOUBLE
        );
  // clang-format on
}

void CopyDialog::_clear_operation_state() {
  // _virtual_dir->items.clear();
  // _visited_dirs.clear();
  _discovery_process.reset();
  _filelist_wrapper->DetachAllChildren();
}

CopyDiscoveryProcess::~CopyDiscoveryProcess() {
  _running = false;
  if (_thread.joinable()) { _thread.join(); }
}

CopyDiscoveryProcess::CopyDiscoveryProcess(CopyDialog* parent, Filepath target) {
  _sequence_id             = g_copy_discovery_sequence.fetch_add(1, std::memory_order_relaxed);
  _input_paths             = parent->app->action.arguments;
  _target                  = target;
  _follow_links            = parent->b_follow_links;
  _preserve_relative_links = parent->b_preserve_relative_links;
  _conflict                = parent->_conflict;

  _dir           = std::make_unique<Dir>();
  _dir->path     = _target;
  _dir->path_txt = _target.native();
  _state         = std::make_shared<PanelSharedState>(_dir.get());
  // TODO: filter must be part of parent
  _state->filter = Input(&_state->filter_txt, &(_dir->path_txt), filelist_filter_opt(parent->filter_cursor_pos));
  _files         = DBMenu(&_data_source);
  setup_filelist_datasource(_state, _data_source);
  // Override dataset_size: discovery adds items directly to _dir->items without calling
  // Dir::_calculate(), so stats() would always return 0. Read items.size() directly.
  _data_source.dataset_size = [dir = _dir.get()]() -> DataSize {
    auto sz = (int64_t)dir->items.size();
    return {sz, 0, std::max(0LL, sz - 1)};
  };
  _data_source.on_event = [app = _state, data_source = &_data_source](DSEventContext ctx) -> bool {
    // handle filter only
    return filelist_handle_filter(app.get(), data_source, ctx);
  };
  // Set minimum height of file list directly on DataSource (PanelSharedState::set_min_y
  // is not wired to _data_source.min_y here, unlike the Files dialog)
  size_t min_y  = 20;
  auto   screen = ScreenInteractive::Active();
  if (screen) { min_y = theme().copyfiles_height_screen_portion * screen->dimy(); }
  _data_source.min_y = min_y;
  // start thread
  _thread = std::thread([this]() { this->_run(); });
}

void CopyDiscoveryProcess::_run() {
  std::vector<DirItem> selected;
  selected.reserve(_input_paths->selected.size());
  for (auto& p : _input_paths->selected) {
    if (!_running) break;
    _stat_file(p);
    selected.emplace_back(p);
  }
  if (_running) _discover(selected, _target);
  _running = false;
  // Notify the FTXUI event loop so tick() can detect completion
  auto* screen = ScreenInteractive::Active();
  if (screen) screen->Post(Event::Custom);
}

CopyDiscoveryProgress CopyDiscoveryProcess::get_progress() {
  std::lock_guard<std::mutex> lock(_m);
  return _progress;
}

void CopyDiscoveryProcess::_queue_link(Filepath const& location, Filepath const& destination, boost::filesystem::perms p) {
  std::lock_guard<std::mutex> lock(_m);
  _progress.link_count++;
  auto& link = _dir->items.emplace_back(location, boost::filesystem::symlink_file, p);
  link._set_symlink_target(destination);
}

// item.path_ref() and new_record_path are same file
void CopyDiscoveryProcess::_queue_error(const DirItem& item, Filepath const& new_record_path, std::string error_message) {
  std::lock_guard<std::mutex> lock(_m);
  _progress.error_count++;
  auto& created = _dir->items.emplace_back(DirItem(item.path_ref(), boost::filesystem::status_error, item.perms()));
  created._set_symlink_target(new_record_path);
  created._set_warning(error_message);
}

bool CopyDiscoveryProcess::_queue_dir(const DirItem& item, Filepath const& new_record_path) {
  // detect cyclic dir
  for (auto& visited : _visited_dirs) {
    error_code ec;
    const bool same = boost::filesystem::equivalent(visited.source.path_ref(), item.path_ref(), ec);
    if (ec.failed()) {
      _queue_error(item, new_record_path, "visited syscall failed " + ec.what());
      return false;
    }
    if (same) {
      // dir already copied, create link to it instead
      _queue_link(new_record_path, visited.destination, item.perms());
      return false;
    }
  }
  _visited_dirs.push_back({.source = DirItem(item), .destination = new_record_path});
  // queue create dir command
  std::lock_guard<std::mutex> lock(_m);
  _progress.dir_count++;
  _progress.current_dir = item.path_ref().native();
  _dir->items.push_back(DirItem(new_record_path, boost::filesystem::directory_file, item.perms()));
  return true;
}

void CopyDiscoveryProcess::_stat_file(Filepath const& item_path) {
  std::lock_guard<std::mutex> lock(_m);
  _progress.current_file = item_path.native();
}

void CopyDiscoveryProcess::_queue_file(const DirItem& item, Filepath const& new_record_path) {
  std::lock_guard<std::mutex> lock(_m);
  auto&                       created = _dir->items.emplace_back(item);
  created._set_symlink_target(new_record_path);
  _progress.file_count++;
  _progress.byte_count += item.size();
}

// This traversal should be depth first because we want to create tree like depiction in our list
void CopyDiscoveryProcess::_discover(const std::vector<DirItem>& files, Filepath destination) {
  if (!_running) return;
  // if type is dir path is to be mkdired
  // if type is link path is where to place link and target is link target
  // else path is source file and target is destination file for copy operation
  auto                  place_on_queue = [this, &destination](const DirItem& item) -> void {
    if (!_running) return;
    error_code ec;
    const auto new_record_path = destination / item.path_ref().filename();
    const bool copy_to_self    = boost::filesystem::equivalent(item.path_ref(), new_record_path, ec);
    if (!ec.failed() && copy_to_self) {
      _queue_error(item, new_record_path, "Copy to self");
      return;
    }
    // Act on symlink
    if (item.symlink_ref()) {
      // handle link
      const bool relative = item.symlink_ref()->is_relative();
      if (!_follow_links && _preserve_relative_links && relative) {
        // create relative symlink
        _queue_link(new_record_path, *item.symlink_ref(), item.perms());
        return;
      }
      Filepath symlink_target = resolve_symlink(item.path_ref());
      if (symlink_target.empty()) {
        _queue_error(item, new_record_path, "Cyclic symlink");
        return;
      }
      if (_follow_links) {
        error_code  target_ec;
        file_status target_status = boost::filesystem::status(symlink_target, target_ec);
        if (target_ec.failed()) {
          _queue_error(item, new_record_path, "Invalid symlink target");
          return;
        }
        DirItem target_item(symlink_target, target_status.type(), target_status.permissions());
        if (target_item.type() == boost::filesystem::directory_file) {
          const bool valid = _queue_dir(target_item, new_record_path);
          if (!valid) return;
          std::vector<DirItem> subdir_items;
          for (directory_entry& subdir_item : directory_iterator(target_item.path_ref(), target_ec)) {
            if (!_running) return;
            _stat_file(subdir_item.path());
            error_code  subdir_ec;
            file_status fs = subdir_item.status(subdir_ec);
            subdir_items.emplace_back(subdir_item.path(), fs.type(), fs.permissions());
          }
          _discover(subdir_items, new_record_path);
          return;
        }
        _queue_file(target_item, new_record_path);
        return;
      }
      // create absolute symlink
      Filepath absolute_symlink_target = boost::filesystem::canonical(symlink_target, item.path_ref().parent_path(), ec);
      if (!ec.failed()) { symlink_target = absolute_symlink_target; }
      _queue_link(new_record_path, symlink_target, item.perms());
      return;
    }
    // Act on directory
    if (item.type() == boost::filesystem::directory_file) {
      error_code src_ec;
      Filepath   source_dir = boost::filesystem::canonical(item.path_ref(), src_ec);
      if (!src_ec.failed()) {
        error_code dst_ec;
        Filepath   destination_dir;
        Filepath   parent_path = new_record_path.parent_path();
        Filepath   resolved_parent = boost::filesystem::canonical(parent_path, dst_ec);
        if (!dst_ec.failed()) {
          destination_dir = resolved_parent / new_record_path.filename();
        } else {
          destination_dir = boost::filesystem::absolute(new_record_path, dst_ec);
        }
        if (!dst_ec.failed() && is_subpath(source_dir, destination_dir)) {
          _queue_error(item, new_record_path, "Copy dir into itself");
          return;
        }
      }
      const bool valid = _queue_dir(item, new_record_path);
      if (!valid) return;
      // Recurse into subdir
      std::vector<DirItem> subdir_items;
      error_code           ec;
      for (directory_entry& subdir_item : directory_iterator(item.path_ref(), ec)) {
        if (!_running) return;
        _stat_file(subdir_item.path());
        error_code  ec;
        file_status fs = subdir_item.status(ec);
        subdir_items.emplace_back(subdir_item.path(), fs.type(), fs.permissions());
      }
      _discover(subdir_items, new_record_path);
      return;
    }
    // Act on file
    _queue_file(item, new_record_path);
  };
  for (const auto& item : files) {
    if (!_running) return;
    if (item.type() == boost::filesystem::status_error) {
      _queue_error(item, destination / item.path_ref().filename(), "stat failed");
      continue;
    }
    place_on_queue(item);
  }
};

void CopyDialog::_start_new_discovery() {
  Filepath target(destination_path);
  if (target.empty()) target = app->action.arguments->target;
  destination_path           = target.native();
  app->action.arguments->target = target;
  _clear_operation_state();
  _discovery_process = std::make_shared<CopyDiscoveryProcess>(this, target);
  _filelist_wrapper->Add(_discovery_process->_files);
}

void CopyDialog::OnShow() {
  button_cancel->TakeFocus();
  app->action.arguments->use_focused_as_alternative();
  if (app->action.arguments->selected.empty()) {
    cancel();
    return;
  }
  destination_path       = app->action.arguments->target.native();
  destination_cursor_pos = static_cast<int>(destination_path.size());
  conflict_mode_selected = copy_conflict_to_index(_conflict);
  _start_new_discovery();
}

//
// DeleteDialog
//

DeleteDialog::DeleteDialog(PanelSharedState::P s) : Dialog(std::move(s)) {
  ButtonOption ascii_button;
  ascii_button.transform = ascii_button_transform();
  button_ok              = Button("DELETE", [this] { this->ok(); }, ascii_button);
  button_close           = Button("Cancel", [this] { this->cancel(); }, ascii_button);
  menu                   = Container::Vertical({}, &selected);
  navigation             = CatchEvent(Container::Vertical({
                            Container::Horizontal({button_ok, button_close}),
                            // Following are path items to delete
                            menu,
                          }),
                                      close_on_esc(this));
  renderer               = Renderer(navigation, [&] {
    // simple
    return window(text(" Delete ") | bold | hcenter,
                                vbox({
                    hbox({
                      button_ok->Render() | hcenter | xflex_grow,
                      separator(),
                      button_close->Render() | hcenter | xflex_grow,
                    }),
                    separator(),
                    menu->Render() | vscroll_indicator | yframe,
                  }),
                                BorderStyle::DOUBLE);
  });
}

void DeleteDialog::OnShow() {
  // remove old data
  menu->DetachAllChildren();
  selected = 0;
  app->action.arguments->use_focused_as_alternative();
  // create items
  int selected_count = app->action.arguments->selected.size();
  if (selected_count == 0) {
    cancel();
    return;
  }
  const bool same_dir = app->action.arguments->selected_share_same_dir();
  menu->DetachAllChildren();
  if (same_dir)
    for (int i = 0; i < selected_count; i++) menu->Add(MenuEntry(app->action.arguments->selected.at(i).native()));
  else
    for (int i = 0; i < selected_count; i++) menu->Add(MenuEntry(app->action.arguments->selected.at(i).filename().native()));

  button_close->TakeFocus();
}

void DeleteDialog::ok() {
  // Delete doesn't have modes of operation like Copy. Queue all selected items, ThreadedFileJobs will handle recursion.
  std::vector<DirItem> items;
  for (auto& p : app->action.arguments->selected) { items.emplace_back(p); }
  auto job = std::make_shared<JobSpec>(JobSpec::Type::DELETE, std::move(items));
  file_operations().add_job(job);
  app->dir->clear_selection();
  app->action.close_dialog();
}

void DeleteDialog::cancel() { app->action.close_dialog(); }

//
// MoveDialog
//

MoveDialog::MoveDialog(PanelSharedState::P s) : Dialog(std::move(s)) {
  ButtonOption ascii_button;
  ascii_button.transform = ascii_button_transform();
  button_ok              = Button(" MOVE ", [this] { this->ok(); }, ascii_button);
  button_close           = Button("Cancel", [this] { this->cancel(); }, ascii_button);
  menu                   = Container::Vertical({}, &selected);
  navigation             = CatchEvent(Container::Vertical({
                            Container::Horizontal({button_ok, button_close}),
                            // Following are path items to delete
                            menu,
                          }),
                                      close_on_esc(this));
  renderer               = Renderer(navigation, [&] {
    // simple
    return window(text(" Move ") | bold | hcenter,
                                vbox({
                    hbox({
                      button_ok->Render() | hcenter | xflex_grow,
                      separator(),
                      button_close->Render() | hcenter | xflex_grow,
                    }),
                    separator(),
                    menu->Render() | vscroll_indicator | yframe,
                  }),
                                BorderStyle::DOUBLE);
  });
}

void MoveDialog::OnShow() {
  // remove old data
  menu->DetachAllChildren();
  selected = 0;
  app->action.arguments->use_focused_as_alternative();
  // create items
  int selected_count = app->action.arguments->selected.size();
  if (selected_count == 0) {
    cancel();
    return;
  }
  const bool same_dir = app->action.arguments->selected_share_same_dir();
  menu->DetachAllChildren();
  if (same_dir)
    for (int i = 0; i < selected_count; i++) menu->Add(MenuEntry(app->action.arguments->selected.at(i).native()));
  else
    for (int i = 0; i < selected_count; i++) menu->Add(MenuEntry(app->action.arguments->selected.at(i).filename().native()));

  button_ok->TakeFocus();
}

void MoveDialog::ok() {
  // Delete doesn't have modes of operation like Copy. Queue all selected items, ThreadedFileJobs will handle recursion.
  std::vector<DirItem> items;
  items.reserve(app->action.arguments->selected.size());
  Filepath destination_path = app->action.arguments->target;
  for (auto& p : app->action.arguments->selected) {
    auto& inserted = items.emplace_back(p);
    inserted._set_symlink_target(destination_path / p.filename());
  }
  auto job = std::make_shared<JobSpec>(JobSpec::Type::MOVE, std::move(items));
  file_operations().add_job(job);
  app->dir->clear_selection();
  app->action.close_dialog();
}

void MoveDialog::cancel() { app->action.close_dialog(); }

// ToClipboardDialog
//

ToClipboardDialog::ToClipboardDialog(PanelSharedState::P d) : Dialog(std::move(d)) {
  button_close = Button("OK", [this] { this->app->action.close_dialog(); });
  navigation   = Container::Vertical({button_close});
  renderer     = Renderer(navigation, [this]() -> Element { return this->render(); });
}

void ToClipboardDialog::OnShow() {
  app->action.arguments->use_focused_as_alternative();
  items_copied                          = 0;
  std::vector<Filepath>& selected       = app->action.arguments->selected;
  int                    selected_count = selected.size();
  int                    required_size  = 0;
  for (int i = selected_count - 1; i >= 0; --i) required_size += selected.at(i).size();
  std::string text;
  text.reserve(required_size);
  const bool just_names = app->action.dialog == "NameToClipboard";
  if (just_names) {
    for (int i = selected_count - 1; i >= 0; --i) {
      text += selected.at(i).filename().native();
      text += "\n";
    }
  } else {
    for (int i = selected_count - 1; i >= 0; --i) {
      text += selected.at(i).native();
      text += "\n";
    }
  }
  if (!text.empty() && text.back() == '\n') {
    // remove last newline
    text.pop_back();
  }
  // copy to clipboard
  Err e = push_to_clipboard(text);
  if (e.ok()) items_copied = selected.size();
}

Element ToClipboardDialog::render() {
  const char* what = app->action.dialog == "NameToClipboard" ? " names" : " paths";
  return vbox({
           text(""),
           text(std::to_string(this->items_copied) + what + " copied to clipboard") | theme().clipboard_msg,
           text(""),
           separator(),
           button_close->Render(),
           separator(),
         })
    | border;
}

namespace {

bool wildcard_match_casefold(const std::string& pattern, const std::string& value) {
  auto fold = [](char c) { return static_cast<char>(std::tolower(static_cast<unsigned char>(c))); };
  size_t p = 0, v = 0;
  size_t star = std::string::npos;
  size_t match = 0;
  while (v < value.size()) {
    if (p < pattern.size() && (pattern[p] == '?' || fold(pattern[p]) == fold(value[v]))) {
      ++p;
      ++v;
      continue;
    }
    if (p < pattern.size() && pattern[p] == '*') {
      star = p++;
      match = v;
      continue;
    }
    if (star != std::string::npos) {
      p = star + 1;
      v = ++match;
      continue;
    }
    return false;
  }
  while (p < pattern.size() && pattern[p] == '*') ++p;
  return p == pattern.size();
}

}  // namespace

//
// FindDialog
//

FindDialog::FindDialog(PanelSharedState::P s) : Dialog(std::move(s)) {
  ButtonOption ascii_button;
  ascii_button.transform = ascii_button_transform();

  InputOption root_opt;
  root_opt.multiline       = false;
  root_opt.cursor_position = &root_cursor_pos;

  InputOption pattern_opt;
  pattern_opt.multiline       = false;
  pattern_opt.cursor_position = &pattern_cursor_pos;
  pattern_opt.on_enter        = [this]() { start_search(); };

  input_root    = Input(&root_path, "Search path", root_opt) | showInputCursor(&root_cursor_pos);
  input_pattern = Input(&pattern, "Pattern (*, ?)", pattern_opt) | showInputCursor(&pattern_cursor_pos);
  button_find   = Button(" Find ", [this] { start_search(); }, ascii_button);
  button_open   = Button(" Open ", [this] { open_selected(); }, ascii_button);
  button_close  = Button(" Close ", [this] { cancel(); }, ascii_button);

  _data_source.dataset_size = [this]() -> DataSize {
    std::lock_guard lock(_results_mutex);
    int64_t         total = static_cast<int64_t>(_results.size());
    return {total, 0, std::max(0LL, total - 1)};
  };
  _data_source.move_id_by = [this](int64_t& id, int64_t delta) -> bool {
    std::lock_guard lock(_results_mutex);
    const int64_t   old = id;
    const int64_t   max = std::max(0LL, static_cast<int64_t>(_results.size()) - 1);
    id = std::clamp(id + delta, 0LL, max);
    return id != old;
  };
  _data_source.count_items_before = [](int64_t id) -> int64_t { return id; };
  _data_source.on_event = [this](DSEventContext c) -> bool {
    if (c.event == Event::Return) {
      open_selected();
      return true;
    }
    return c.handled;
  };
  _data_source.transform = [this](DSRenderContext& c) -> Element {
    std::lock_guard lock(_results_mutex);
    if (c.id < 0 || c.id >= static_cast<int64_t>(_results.size())) return text("<invalid>");
    Element row = text(" " + _results.at(c.id).native());
    if (c.focused) {
      row |= c.component_focused ? bgcolor(Color::DarkBlue) : bgcolor(Color::GrayDark);
      row |= ftxui::focus;
    }
    return row;
  };
  _data_source.min_y = 12;
  results_menu       = DBMenu(&_data_source);

  navigation = CatchEvent(Container::Vertical({
                            Container::Horizontal({button_find, button_open, button_close}),
                            input_root,
                            input_pattern,
                            results_menu,
                          }),
                          close_on_esc(this));
  renderer   = Renderer(navigation, [this]() -> Element {
    const std::string title_txt = _running.load(std::memory_order_relaxed)
      ? " Find (running) "
      : " Find ";
    auto title = text(title_txt) | bold | hcenter;
    int64_t matches = 0;
    {
      std::lock_guard lock(_results_mutex);
      matches = static_cast<int64_t>(_results.size());
    }
    std::string info = std::format(" Dirs:{}  Files:{}  Matches:{}  Errors:{} ",
      _dirs_scanned.load(std::memory_order_relaxed),
      _files_scanned.load(std::memory_order_relaxed),
      matches,
      _errors.load(std::memory_order_relaxed));
    if (!status.empty()) info += " | " + status;
    auto content = vbox({
      hbox({
        button_find->Render() | hcenter | xflex_grow,
        separator(),
        button_open->Render() | hcenter | xflex_grow,
        separator(),
        button_close->Render() | hcenter | xflex_grow,
      }),
      separator(),
      hbox({text("Root: "), input_root->Render() | xflex}),
      hbox({text("Mask: "), input_pattern->Render() | xflex}),
      separator(),
      text(info) | dim,
      separator(),
      results_menu->Render() | yflex,
    });
    return window(title, content, BorderStyle::DOUBLE);
  });
}

FindDialog::~FindDialog() {
  stop_search();
}

void FindDialog::OnShow() {
  stop_search();
  root_path = app->dir ? app->dir->path.native() : "";
  pattern.clear();
  status.clear();
  {
    std::lock_guard lock(_results_mutex);
    _results.clear();
  }
  _dirs_scanned.store(0, std::memory_order_relaxed);
  _files_scanned.store(0, std::memory_order_relaxed);
  _errors.store(0, std::memory_order_relaxed);
  _data_source.focused_id = 0;
  input_pattern->TakeFocus();
}

void FindDialog::stop_search() {
  _running.store(false, std::memory_order_relaxed);
  if (_worker.joinable()) _worker.join();
}

void FindDialog::start_search() {
  stop_search();

  Filepath root(root_path);
  if (root.empty()) {
    status = "Root path is empty";
    return;
  }
  boost::system::error_code ec;
  const bool root_exists = boost::filesystem::exists(root, ec);
  const bool root_is_dir = root_exists && !ec.failed() && boost::filesystem::is_directory(root, ec);
  if (ec.failed() || !root_exists || !root_is_dir) {
    status = "Root path must be an existing directory";
    return;
  }

  const std::string local_pattern = pattern.empty() ? "*" : pattern;
  {
    std::lock_guard lock(_results_mutex);
    _results.clear();
  }
  _data_source.focused_id = 0;
  _dirs_scanned.store(0, std::memory_order_relaxed);
  _files_scanned.store(0, std::memory_order_relaxed);
  _errors.store(0, std::memory_order_relaxed);
  status.clear();
  _completed.store(false, std::memory_order_relaxed);
  _running.store(true, std::memory_order_relaxed);

  _worker = std::thread([this, root, local_pattern]() {
    std::deque<Filepath> queue;
    queue.push_back(root);

    while (_running.load(std::memory_order_relaxed) && !queue.empty()) {
      Filepath current = queue.front();
      queue.pop_front();
      _dirs_scanned.fetch_add(1, std::memory_order_relaxed);

      boost::system::error_code it_ec;
      boost::filesystem::directory_iterator end;
      for (boost::filesystem::directory_iterator it(current, it_ec); it != end && !it_ec; it.increment(it_ec)) {
        if (!_running.load(std::memory_order_relaxed)) break;
        const auto entry = *it;
        const auto p = entry.path();

        boost::system::error_code status_ec;
        const auto fs = entry.status(status_ec);
        if (status_ec.failed()) {
          _errors.fetch_add(1, std::memory_order_relaxed);
          continue;
        }

        if (fs.type() == boost::filesystem::file_type::directory_file) {
          queue.push_back(p);
        } else {
          _files_scanned.fetch_add(1, std::memory_order_relaxed);
        }

        const std::string name = p.filename().native();
        if (wildcard_match_casefold(local_pattern, name)) {
          std::lock_guard lock(_results_mutex);
          _results.push_back(p);
        }
      }

      if (it_ec.failed()) _errors.fetch_add(1, std::memory_order_relaxed);
      auto* screen = ScreenInteractive::Active();
      if (screen) screen->Post(Event::Custom);
    }

    _running.store(false, std::memory_order_relaxed);
    _completed.store(true, std::memory_order_relaxed);
    auto* screen = ScreenInteractive::Active();
    if (screen) screen->Post(Event::Custom);
  });
}

void FindDialog::open_selected() {
  Filepath selected;
  {
    std::lock_guard lock(_results_mutex);
    if (_results.empty()) return;
    const int64_t focused = std::clamp(_data_source.focused_id, 0LL, static_cast<int64_t>(_results.size()) - 1);
    selected = _results.at(focused);
  }

  Filepath parent = selected.parent_path();
  app->move_to(parent);
  app->filter_txt.clear();
  app->dir->apply_filter(app->filter_txt);

  if (app->set_focused_index) {
    for (int i = 0; i < static_cast<int>(app->dir->items.size()); ++i) {
      if (app->dir->items.at(i).path_ref() == selected) {
        app->set_focused_index(i);
        break;
      }
    }
  }
  app->action.close_dialog();
}

void FindDialog::cancel() {
  stop_search();
  app->action.close_dialog();
}

//
// NYI
//

Nyi::Nyi(PanelSharedState::P d) : Dialog(std::move(d)) {
  Component nyi_textbox      = Input("", "Dummy text - Not used at all ...");
  Component nyi_button_close = Button("OK", [app = app] { app->action.close_dialog(); });
  navigation                 = Container::Vertical({nyi_textbox, nyi_button_close});
  renderer                   = Renderer(navigation, [nyi_textbox, nyi_button_close, app = app]() -> Element {
    return vbox({
             text(app->action.dialog + " dialog example"),
             separator(),
             nyi_textbox->Render(),
             filler(),
             nyi_button_close->Render(),
           })
      | border | size(HEIGHT, GREATER_THAN, 18);
  });
}

//
// ErrorListDialog
//

ErrorListDialog::ErrorListDialog(std::function<void()> close_dialog) : Dialog(nullptr), close_dialog(close_dialog) {
  ButtonOption ascii_button;
  ascii_button.transform = ascii_button_transform();

  button_hide                     = Button(" Hide ", close_dialog, ascii_button);
  button_clear                    = Button(" Clear ", [this] { this->clear(); }, ascii_button);
  _data_source.dataset_size       = []() -> DataSize { return file_operations().dataset_size(); };
  _data_source.count_items_before = [this](int64_t id) -> int64_t { return file_operations().count_items_before(id); };
  _data_source.move_id_by         = [this](int64_t& id, int64_t delta) -> bool { return file_operations().move_id_by(id, delta); };
  _data_source.on_event           = [this](DSEventContext c) -> bool {
    if (c.event == Event::Return) {
      this->button_hide->TakeFocus();
      return true;
    }
    return c.handled;
  };
  _data_source.transform = [this](DSRenderContext& c) -> Element {
    auto item = file_operations().get_error(c.id);
    auto row  = hbox({text(time_to_string(item.time)), separator(), text(item.message)});
    if (c.focused) {
      if (c.component_focused) {
        row |= color(theme().files_focused_empty) | ftxui::focus;
      } else {
        row |= color(theme().files_unfocused_empty) | ftxui::focus;
      }
    }
    return std::move(row);
  };
  _errors    = DBMenu(&_data_source);
  navigation = CatchEvent(Container::Vertical({
                            Container::Horizontal({button_hide, button_clear}),
                            // Following are path items to delete
                            _errors,
                          }),
                          close_on_esc(this));
  renderer   = Renderer(navigation, [this]() -> Element {
    // add items in render method
    auto s = file_operations().dataset_size();
    return window(hbox({text(" Error History [" + std::to_string(s.total) + "]"), screen_render_time()}) | bold | hcenter,
                    vbox({
                    hbox({
                      button_hide->Render() | hcenter | xflex_grow,
                      separator(),
                      button_clear->Render() | hcenter | xflex_grow,
                    }),
                    separator(),
                    _errors->Render() | theme().files_border,
                  }),
                    BorderStyle::DOUBLE);
  });
}

void ErrorListDialog::clear() {
  file_operations().clear_errors();
  this->close_dialog();
}

void ErrorListDialog::cancel() { this->close_dialog(); }

void ErrorListDialog::OnShow() {
  int  dimy   = 50;
  auto screen = ScreenInteractive::Active();
  if (screen) dimy = screen->dimy();
  _data_source.min_y      = std::round(theme().errorlist_height_screen_portion * dimy);
  const bool initial_show = _data_source.focused_id == 0;
  if (initial_show) { _data_source.focused_id = _data_source.dataset_size().starting_id; }
}

//
// JobListDialog
//

std::string JobListDialog::state_icon(JobState state) {
  switch (state) {
  case JobState::QUEUED:               return "..";
  case JobState::RUNNING:              return ">>";
  case JobState::PAUSED:               return "||";
  case JobState::CANCELLED:            return "XX";
  case JobState::COMPLETED:            return "OK";
  case JobState::COMPLETED_WITH_ERRORS: return "!!";
  }
  return "??";
}

std::string JobListDialog::format_duration(double seconds) {
  if (seconds < 0) return "-";
  if (seconds < 1.0) return std::format("{:.0f}ms", seconds * 1000);
  if (seconds < 60.0) return std::format("{:.1f}s", seconds);
  return std::format("{:.0f}m {:.0f}s", std::floor(seconds / 60), std::fmod(seconds, 60));
}

std::string JobListDialog::format_bytes(double bytes) {
  if (bytes < 1024) return std::format("{:.0f} B", bytes);
  if (bytes < 1024 * 1024) return std::format("{:.1f} KB", bytes / 1024);
  if (bytes < 1024 * 1024 * 1024) return std::format("{:.1f} MB", bytes / (1024 * 1024));
  return std::format("{:.1f} GB", bytes / (1024 * 1024 * 1024));
}

void JobListDialog::rebuild_list() {
  jobs.clear();

  auto jobinfo = file_operations().get_running_job();
  if (jobinfo.job && !jobinfo.job->is_stopped()) {
    jobs.push_back(jobinfo.job);
  }

  auto history = file_operations().get_job_history();
  // Show most recent first
  for (auto it = history.rbegin(); it != history.rend(); ++it) {
    jobs.push_back(*it);
  }

  // Clamp focused_id to valid range
  if (!jobs.empty()) {
    _job_data_source.focused_id = std::clamp(_job_data_source.focused_id, 0LL, (int64_t)jobs.size() - 1);
  } else {
    _job_data_source.focused_id = 0;
  }
}

void JobListDialog::open_detail() {
  auto focused = _job_data_source.focused_id;
  if (jobs.empty() || focused < 0 || focused >= (int64_t)jobs.size()) return;
  detail_job = jobs[focused];
  in_detail  = true;
  view_mode  = 1;

  if (!detail_job) { detail_back_button->TakeFocus(); return; }

  // Start detail items view at current processing point
  _detail_items_data_source.focused_id  = std::max(0, detail_job->_current_item_index);
  _detail_errors_data_source.focused_id = 0;
  detail_back_button->TakeFocus();
}

void JobListDialog::close_detail() {
  in_detail = false;
  view_mode = 0;
  detail_job.reset();
  rebuild_list();
  _job_list->TakeFocus();
}

void JobListDialog::dismiss_selected() {
  auto focused = _job_data_source.focused_id;
  if (jobs.empty() || focused < 0 || focused >= (int64_t)jobs.size()) return;
  auto& job = jobs[focused];
  // Only dismiss stopped jobs
  if (job->is_stopped()) {
    file_operations().dismiss_job(job->_job_id);
    rebuild_list();
  }
}

void JobListDialog::dismiss_all_clean() {
  auto history = file_operations().get_job_history();
  for (auto& j : history) {
    auto s = j->_state.load();
    if (s == JobState::COMPLETED) {
      file_operations().dismiss_job(j->_job_id);
    }
  }
  rebuild_list();
}

JobListDialog::JobListDialog(std::function<void()> close_dialog) : Dialog(nullptr), close_dialog(close_dialog) {
  ButtonOption ascii_button;
  ascii_button.transform = ascii_button_transform();

  // ── Job list view ──────────────────────────────────────────────────
  button_close       = Button(" Close ", close_dialog, ascii_button);
  button_dismiss_all = Button(" Dismiss All Clean ", [this] { this->dismiss_all_clean(); }, ascii_button);

  _job_data_source.dataset_size = [this]() -> DataSize {
    auto sz = (int64_t)jobs.size();
    return {sz, 0, std::max(0LL, sz - 1)};
  };
  _job_data_source.move_id_by = [this](int64_t& id, int64_t delta) -> bool {
    int64_t old_id = id;
    int64_t max_id = std::max(0LL, (int64_t)jobs.size() - 1);
    id = std::clamp(id + delta, 0LL, max_id);
    return id != old_id;
  };
  _job_data_source.count_items_before = [](int64_t id) -> int64_t { return id; };
  _job_data_source.on_event = [this](DSEventContext ctx) -> bool {
    if (ctx.event == Event::Return) {
      open_detail();
      return true;
    }
    return ctx.handled;
  };
  _job_data_source.transform = [this](DSRenderContext& ctx) -> Element {
    if (ctx.id < 0 || ctx.id >= (int64_t)jobs.size()) return text("<invalid>");
    auto& job   = jobs[ctx.id];
    auto  state = job->_state.load();

    const char* type_str = "?";
    switch (job->_type) {
    case JobInstructions::Type::COPY:   type_str = "COPY"; break;
    case JobInstructions::Type::MOVE:   type_str = "MOVE"; break;
    case JobInstructions::Type::DELETE: type_str = "DEL "; break;
    case JobInstructions::Type::ARCHIVE_CREATE: type_str = "ARCH"; break;
    }

    std::string icon    = state_icon(state);
    int items_done      = job->_current_item_index;
    int items_total     = static_cast<int>(job->item_count());
    int errors          = static_cast<int>(job->_errors.size());

    std::string duration = "-";
    if (job->_started_time > 0) {
      double end = job->_finished_time > 0 ? job->_finished_time : Perun::now();
      duration   = format_duration(end - job->_started_time);
    }
    std::string size_str = format_bytes(job->_bytes_total);

    std::string detail;
    if (state == JobState::COMPLETED)            detail = std::format("{} files  {}  {}", items_total, size_str, duration);
    else if (state == JobState::COMPLETED_WITH_ERRORS) detail = std::format("{}/{} files  {} errors", items_done, items_total, errors);
    else if (state == JobState::PAUSED)          detail = std::format("{}/{} files  paused", items_done, items_total);
    else if (state == JobState::CANCELLED)       detail = std::format("{}/{} files  cancelled", items_done, items_total);
    else if (state == JobState::RUNNING)         detail = std::format("{}/{} files  running", items_done, items_total);
    else                                         detail = "queued";

    auto row = hbox({
      text(std::format("[#{}] ", job->_job_id)),
      text(std::string(type_str) + "  " + icon + "  "),
      text(detail) | xflex_grow,
    });

    if (ctx.focused) {
      row |= ctx.component_focused ? bgcolor(Color::DarkBlue) : bgcolor(Color::GrayDark);
      row |= ftxui::focus;
    }
    return row;
  };
  _job_data_source.min_y = 5;
  _job_list = DBMenu(&_job_data_source);

  auto list_view = Container::Vertical({
    Container::Horizontal({button_dismiss_all, button_close}),
    _job_list,
  });

  // ── Detail view ────────────────────────────────────────────────────
  detail_back_button  = Button(" Back ", [this] { this->close_detail(); }, ascii_button);
  detail_close_button = Button(" Close ", close_dialog, ascii_button);

  // Detail items DataSource — shows ALL items; done items are dimmed
  _detail_items_data_source.dataset_size = [this]() -> DataSize {
    if (!detail_job) return {0, 0, 0};
    auto sz = (int64_t)detail_job->_items.size();
    return {sz, 0, std::max(0LL, sz - 1)};
  };
  _detail_items_data_source.move_id_by = [this](int64_t& id, int64_t delta) -> bool {
    if (!detail_job) return false;
    int64_t old_id = id;
    int64_t max_id = std::max(0LL, (int64_t)detail_job->_items.size() - 1);
    id = std::clamp(id + delta, 0LL, max_id);
    return id != old_id;
  };
  _detail_items_data_source.count_items_before = [](int64_t id) -> int64_t { return id; };
  _detail_items_data_source.transform = [this](DSRenderContext& ctx) -> Element {
    if (!detail_job || ctx.id < 0 || ctx.id >= (int64_t)detail_job->_items.size()) return text("<invalid>");
    auto& item   = detail_job->_items[ctx.id];
    bool is_done = ctx.id < detail_job->_current_item_index;

    Element name;
    if (item.type() == boost::filesystem::directory_file) {
      name = text("  / " + item.path_ref().native());
    } else {
      std::string line = "  . " + item.path_ref().native() + "  " + format_bytes(std::max(0LL, item.size()));
      if (item.symlink_ref()) line += "  -> " + item.symlink_ref()->native();
      name = text(line);
    }
    if (is_done) name |= dim;

    if (ctx.focused) {
      name |= ctx.component_focused ? bgcolor(Color::DarkBlue) : bgcolor(Color::GrayDark);
      name |= ftxui::focus;
    }
    return name;
  };
  _detail_items_data_source.min_y = 5;
  _detail_items = DBMenu(&_detail_items_data_source);

  // Detail errors DataSource
  _detail_errors_data_source.dataset_size = [this]() -> DataSize {
    if (!detail_job) return {0, 0, 0};
    auto sz = (int64_t)detail_job->_errors.size();
    return {sz, 0, std::max(0LL, sz - 1)};
  };
  _detail_errors_data_source.move_id_by = [this](int64_t& id, int64_t delta) -> bool {
    if (!detail_job) return false;
    int64_t old_id = id;
    int64_t max_id = std::max(0LL, (int64_t)detail_job->_errors.size() - 1);
    id = std::clamp(id + delta, 0LL, max_id);
    return id != old_id;
  };
  _detail_errors_data_source.count_items_before = [](int64_t id) -> int64_t { return id; };
  _detail_errors_data_source.transform = [this](DSRenderContext& ctx) -> Element {
    if (!detail_job || ctx.id < 0 || ctx.id >= (int64_t)detail_job->_errors.size()) return text("<invalid>");
    auto& err = detail_job->_errors[ctx.id];
    std::string warning = err.warning_ref().value_or("unknown error");
    auto row = vbox({
      text("  X " + err.path_ref().native()),
      text("    " + warning) | dim,
    });
    if (ctx.focused) {
      row |= ctx.component_focused ? bgcolor(Color::DarkBlue) : bgcolor(Color::GrayDark);
      row |= ftxui::focus;
    }
    return row;
  };
  _detail_errors_data_source.min_y = 3;
  _detail_errors = DBMenu(&_detail_errors_data_source);

  auto detail_view = Container::Vertical({
    Container::Horizontal({detail_back_button, detail_close_button}),
    _detail_items,
    _detail_errors,
  });

  // ── Tab to switch views ────────────────────────────────────────────
  tab = Container::Tab({list_view, detail_view}, &view_mode);

  navigation = CatchEvent(tab, [this](Event e) -> bool {
    if (e == theme().key_cancel_dialog) {
      if (in_detail) {
        close_detail();
      } else {
        this->cancel();
      }
      return true;
    }
    // 'd' to dismiss selected job in list view
    if (!in_detail && e == Event::Character('d')) {
      dismiss_selected();
      return true;
    }
    return false;
  });

  renderer = Renderer(navigation, [this]() -> Element {
    if (in_detail && detail_job) {
      return render_detail();
    }
    return render_list();
  });
}

void JobListDialog::cancel() { this->close_dialog(); }

void JobListDialog::OnShow() {
  view_mode = 0;
  in_detail = false;
  detail_job.reset();
  rebuild_list();
}

Element JobListDialog::render_list() {
  auto title = text(" Job History [" + std::to_string(jobs.size()) + "] ") | bold | hcenter;

  auto content = vbox({
    hbox({
      button_dismiss_all->Render() | hcenter | xflex_grow,
      separator(),
      button_close->Render() | hcenter | xflex_grow,
    }),
    separator(),
    jobs.empty() ? (text("  No jobs.") | dim) : _job_list->Render(),
  });

  return window(title, content, BorderStyle::DOUBLE);
}

Element JobListDialog::render_detail() {
  if (!detail_job) return text("No job selected");

  auto  state    = detail_job->_state.load();
  auto  icon     = state_icon(state);
  const char* type_str = "?";
  switch (detail_job->_type) {
  case JobInstructions::Type::COPY:   type_str = "COPY"; break;
  case JobInstructions::Type::MOVE:   type_str = "MOVE"; break;
  case JobInstructions::Type::DELETE: type_str = "DELETE"; break;
  case JobInstructions::Type::ARCHIVE_CREATE: type_str = "ARCHIVE"; break;
  }

  int items_done  = detail_job->_current_item_index;
  int items_total = static_cast<int>(detail_job->item_count());
  int errors      = static_cast<int>(detail_job->_errors.size());
  int remaining   = items_total - items_done;

  std::string duration = "-";
  if (detail_job->_started_time > 0) {
    double end = detail_job->_finished_time > 0 ? detail_job->_finished_time : Perun::now();
    duration = format_duration(end - detail_job->_started_time);
  }

  auto title_text = std::format(" Job #{} -- {} {} ", detail_job->_job_id, type_str, icon);
  if (errors > 0) title_text += std::format("{} errors ", errors);

  Elements info;
  info.push_back(text(std::format("  Items:   {} total, {} done, {} remaining", items_total, items_done, remaining)));
  info.push_back(text(std::format("  Bytes:   {} / {}", format_bytes(detail_job->_bytes_processed), format_bytes(detail_job->_bytes_total))));
  info.push_back(text(std::format("  Time:    {}", duration)));
  info.push_back(text(std::format("  Errors:  {}", errors)));
  info.push_back(separator());

  // Items section — all items shown; done items are dimmed by transform
  Elements items_section;
  if (!detail_job->_items.empty()) {
    items_section.push_back(text(std::format("  -- Items ({} total, {} remaining) --", items_total, remaining)) | bold);
    items_section.push_back(_detail_items->Render());
  }

  // Errors section
  Elements error_section;
  if (!detail_job->_errors.empty()) {
    error_section.push_back(text(std::format("  -- Errors ({}) --", errors)) | bold);
    error_section.push_back(_detail_errors->Render());
  }

  auto content = vbox({
    hbox({
      detail_back_button->Render() | hcenter | xflex_grow,
      separator(),
      detail_close_button->Render() | hcenter | xflex_grow,
    }),
    separator(),
    vbox(std::move(info)),
    vbox(std::move(items_section)) | yflex,
    vbox(std::move(error_section)) | yflex,
  });

  return window(text(title_text) | bold | hcenter, content, BorderStyle::DOUBLE);
}

//
// BookmarksDialog
//

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
    return {size, 0, std::max(0LL, size - 1)};
  };
  _data_source.move_id_by = [this](int64_t& id, int64_t delta) -> bool {
    int64_t old = id;
    int64_t max = std::max(0LL, static_cast<int64_t>(bookmarks.size()) - 1);
    id = std::clamp(id + delta, 0LL, max);
    return id != old;
  };
  _data_source.count_items_before = [](int64_t id) -> int64_t { return id; };
  _data_source.transform = [this](DSRenderContext& c) -> Element {
    if (c.id < 0 || c.id >= static_cast<int64_t>(bookmarks.size())) return text("<invalid>");
    Element row = text(" " + bookmarks.at(c.id).native());
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
  list_menu          = DBMenu(&_data_source);

  navigation = CatchEvent(Container::Vertical({
                            Container::Horizontal({button_add, button_remove, button_open, button_close}),
                            list_menu,
                          }),
                          [this](Event e) -> bool {
                            if (e == theme().key_cancel_dialog) {
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
    _data_source.focused_id = std::clamp(_data_source.focused_id, 0LL, static_cast<int64_t>(bookmarks.size()) - 1);
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
    return {sz, 0, std::max(0LL, sz - 1)};
  };
  _data_source.move_id_by = [this](int64_t& id, int64_t delta) -> bool {
    int64_t old = id;
    int64_t max = std::max(0LL, static_cast<int64_t>(visible_ids.size()) - 1);
    id = std::clamp(id + delta, 0LL, max);
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
  list_menu          = DBMenu(&_data_source);

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
    _data_source.focused_id = std::clamp(_data_source.focused_id, 0LL, static_cast<int64_t>(visible_ids.size()) - 1);
  }
}

void CommandPaletteDialog::run_selected() {
  if (visible_ids.empty()) return;
  const int64_t focused = std::clamp(_data_source.focused_id, 0LL, static_cast<int64_t>(visible_ids.size()) - 1);
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

  const int64_t focused = std::clamp(_data_source.focused_id, 0LL, static_cast<int64_t>(visible_ids.size()) - 1);
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
    return {sz, 0, std::max(0LL, sz - 1)};
  };
  _data_source.move_id_by = [this](int64_t& id, int64_t delta) -> bool {
    int64_t old = id;
    int64_t max = std::max(0LL, static_cast<int64_t>(entries.size()) - 1);
    id = std::clamp(id + delta, 0LL, max);
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
  list_menu          = DBMenu(&_data_source);

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
  const int64_t focused = std::clamp(_data_source.focused_id, 0LL, static_cast<int64_t>(entries.size()) - 1);
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
  const int64_t focused = std::clamp(_data_source.focused_id, 0LL, static_cast<int64_t>(entries.size()) - 1);
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

Commands::Commands() {
  available.reserve(64);
  available.push_back({"select_toggle", theme().key_files_select, "", "Select / Deselect Focused Item", CommandScope::PANEL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"clear_selection", theme().key_clear_selection, "", "Clear Selection", CommandScope::PANEL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"select_all", theme().key_select_all, "", "Select All", CommandScope::PANEL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"enter_dir", theme().key_enter_dir, "", "Enter Directory", CommandScope::PANEL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"leave_dir", theme().key_leave_dir, "", "Leave Directory", CommandScope::PANEL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"toggle_permissions_column", theme().key_toggle_permissions_column, "", "Toggle Permissions Column", CommandScope::PANEL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"toggle_owner_group_column", theme().key_toggle_owner_group_column, "", "Toggle Owner/Group Column", CommandScope::PANEL, CommandKind::EXECUTE_CALLBACK});

  available.push_back({"copy", theme().key_copy, "Copy", "Copy", CommandScope::PANEL, CommandKind::SHOW_DIALOG});
  available.push_back({"move", theme().key_move, "Move", "Move", CommandScope::PANEL, CommandKind::SHOW_DIALOG});
  available.push_back({"delete", theme().key_delete, "Delete", "Delete", CommandScope::PANEL, CommandKind::SHOW_DIALOG});
  available.push_back({"rename", theme().key_rename, "Rename", "Rename", CommandScope::PANEL, CommandKind::SHOW_DIALOG});
  available.push_back({"mkdir", theme().key_mkdir, "Mkdir", "Make Directory", CommandScope::PANEL, CommandKind::SHOW_DIALOG});
  available.push_back({"find", theme().key_find, "Find", "Find", CommandScope::PANEL, CommandKind::SHOW_DIALOG});
  available.push_back({"glob_select", theme().key_glob_select, "GlobSelect", "Select by Glob", CommandScope::PANEL, CommandKind::SHOW_DIALOG});
  available.push_back({"glob_deselect", theme().key_glob_deselect, "GlobDeselect", "Deselect by Glob", CommandScope::PANEL, CommandKind::SHOW_DIALOG});
  available.push_back({"names_to_clipboard", theme().key_names_to_clipboard, "NameToClipboard", "Names to Clipboard", CommandScope::PANEL, CommandKind::SHOW_DIALOG});
  available.push_back({"paths_to_clipboard", theme().key_paths_to_clipboard, "PathToClipboard", "Paths to Clipboard", CommandScope::PANEL, CommandKind::SHOW_DIALOG});

  available.push_back({"switch_panel", theme().key_switch_focused_panel, "", "Switch Focused Panel", CommandScope::GLOBAL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"tab_new", theme().key_new_tab, "", "New Tab in Focused Panel", CommandScope::GLOBAL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"tab_close", theme().key_close_tab, "", "Close Active Tab in Focused Panel", CommandScope::GLOBAL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"tab_next", theme().key_next_tab, "", "Next Tab in Focused Panel", CommandScope::GLOBAL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"tab_prev", theme().key_prev_tab, "", "Previous Tab in Focused Panel", CommandScope::GLOBAL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"toggle_single_panel_mode", theme().key_toggle_single_panel_mode, "", "Toggle Single Panel Full Width", CommandScope::GLOBAL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"refresh_dir", theme().key_refresh_dir, "", "Refresh Directory", CommandScope::GLOBAL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"target_right", theme().key_target_dir_to_focused_item_right, "", "Target Right Panel to Focused Item", CommandScope::GLOBAL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"target_left", theme().key_target_dir_to_focused_item_left, "", "Target Left Panel to Focused Item", CommandScope::GLOBAL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"toggle_errors", theme().key_toggle_error_details, "ErrorList", "Toggle Error List", CommandScope::GLOBAL, CommandKind::SHOW_DIALOG});
  available.push_back({"toggle_job_list", theme().key_toggle_job_list, "JobList", "Toggle Job List", CommandScope::GLOBAL, CommandKind::SHOW_DIALOG});
  available.push_back({"open_bookmarks", theme().key_bookmarks_dialog, "Bookmarks", "Open Bookmarks", CommandScope::GLOBAL, CommandKind::SHOW_DIALOG});
  available.push_back({"edit_theme_colors", theme().key_theme_colors, "ThemeColors", "Edit Theme Colors", CommandScope::GLOBAL, CommandKind::SHOW_DIALOG});
  available.push_back({"open_in_editor", theme().key_open_in_editor, "", "Open in Fresh Editor", CommandScope::GLOBAL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"switch_to_file_commander", theme().key_switch_to_file_commander, "", "Switch to File Commander", CommandScope::GLOBAL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"switch_editor_prev", theme().key_switch_editor_prev, "", "Switch to Previous Editor Session", CommandScope::GLOBAL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"switch_editor_next", theme().key_switch_editor_next, "", "Switch to Next Editor Session", CommandScope::GLOBAL, CommandKind::EXECUTE_CALLBACK});
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
  return true;
}

const Command* Commands::find_panel_by_key(const Event& key) const {
  auto it = std::find_if(available.begin(), available.end(), [&key](const Command& c) {
    return c.key == key && c.scope == CommandScope::PANEL;
  });
  return it == available.end() ? nullptr : &(*it);
}

std::vector<Command> Commands::list_all() const {
  return available;
}

Commands& commands() {
  static Commands _c;
  return _c;
}

}  // namespace ftxui
