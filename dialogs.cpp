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

bool execute_file_command(PanelSharedState* app,DataSource* data_source,const std::string& id) {
  auto execute_panel_callback = [&]() -> bool {
    const Command* action = commands().find_by_id(id);
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
      const Filepath parent_dir = location_parent(app->dir->path);
      app->filter_txt.clear();
      app->move_to(parent_dir, old_path);
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
      app->move_to(where.path_ref(), {});
      data_source->focused_id = app->dir->offset_vissible(0, 0);
      app->filter_txt.clear();
      return true;
    }
    return false;
  };

  if (execute_panel_callback()) return true;

  const Command* action = commands().find_by_id(id);
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

bool Files::execute_command(const std::string& id) {return execute_file_command(app.get(),&_data_source,id);}
bool filelist_handle_commands(PanelSharedState* app,DataSource* data_source,DSEventContext& ctx) {
  const auto* command=commands().find_panel_by_key(ctx.event);if(!command)return false;
  return app->dispatch_command?app->dispatch_command(command->id):execute_file_command(app,data_source,command->id);
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

  files     = clipped_menu(&_data_source);
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

bool Dialog::submit(OperationPlan plan,std::function<void(const JobSnapshot&)> apply) {
  if(_pending) return false;
  auto generation=++_submission_generation;
  auto job=std::make_shared<JobSpec>(std::make_shared<const OperationPlan>(std::move(plan)));
  job->completed=[this,alive=_alive,generation,post=app->post,apply=std::move(apply)](auto result) {
    post([this,alive,generation,result,apply] {
      if(!alive->load() || generation!=_submission_generation) return;
      _pending.reset();apply(*result);
    });
  };
  _pending=job;
  if(!(app->jobs?*app->jobs:file_operations()).add_job(job)) {_pending.reset();return false;}
  return true;
}
void Dialog::cancel_submission() {
  ++_submission_generation;
  if(_pending) (app->jobs?*app->jobs:file_operations()).cancel_job(_pending.get());
  _pending.reset();
}

void MkdirDialog::OnShow() {
  cancel_submission();
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
  error.clear();
  if (new_dir_name.empty()) { error = "Enter a directory name"; return; }
  const auto dir_path = app->action.arguments->origin / new_dir_name;
  error = archive_mutation_error(dir_path);
  if (!error.empty()) return;
  OperationPlan plan;plan.type=OperationType::MKDIR;
  plan.steps.push_back({Operation::Kind::CreateDirectory,{},dir_path});
  submit(std::move(plan),[this,dir_path](const JobSnapshot& result) {
    if(result._state==JobState::COMPLETED) app->action.close_dialog();
    else error="Cannot create "+dir_path.native()+": "+(result._errors.empty()?"cancelled or failed":result._errors.front().warning_ref().value_or("failed"));
  });
}

void MkdirDialog::cancel() { cancel_submission();app->action.close_dialog(); }

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
  cancel_submission();
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
    rows[i] = std::make_unique<Item>();
    auto& data              = app->action.arguments->selected.at(i);
    rows[i]->content         = data.filename().native();
    rows[i]->cursor_position = 0;
    InputOption style;
    style.multiline           = false;
    style.content             = &(rows.at(i)->content);
    style.placeholder         = "";
    style.cursor_position     = &(rows[i]->cursor_position);
    Component input_field     = Input(style) | showInputCursor(&(rows.at(i)->cursor_position));
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
  if(_pending) return;
  OperationPlan plan;plan.type=OperationType::RENAME;
  for(size_t i=0;i<app->action.arguments->selected.size();++i) {
    auto source=app->action.arguments->selected[i];
    plan.steps.push_back({Operation::Kind::RenameEntry,source,source.parent_path()/rows[i]->content});
  }
  submit(std::move(plan),[this](const JobSnapshot& result) {
    for(int i=static_cast<int>(rows.size())-1;i>=0;--i) {
      if(i>=result._step_errors.size() || !result._step_errors[i].empty()) continue;
      rows.erase(rows.begin()+i);app->action.arguments->selected.erase(app->action.arguments->selected.begin()+i);menu->ChildAt(i)->Detach();
    }
    if(rows.empty()) {app->dir->clear_selection();app->action.close_dialog();}
    else menu->TakeFocus();
  });
}
void RenameDialog::cancel() { cancel_submission();app->action.close_dialog(); }

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
  // _files = clipped_menu(&_data_source);
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
                            if (e == Event::Custom && _confirm_when_ready && _discovery_process && !_discovery_process->_running) {
                              _confirm_when_ready = false;
                              run_copy();
                              return true;
                            }
                            if (e == keys().key_cancel_dialog) {
                              this->cancel();
                              return true;
                            }
                            if (op_conflict_mode->Focused() && e == Event::Character('1')) {
                              conflict_mode_selected = 0;
                              _conflict              = CopyConflict::Replace;
                              return true;
                            }
                            if (op_conflict_mode->Focused() && e == Event::Character('2')) {
                              conflict_mode_selected = 1;
                              _conflict              = CopyConflict::Update;
                              return true;
                            }
                            if (op_conflict_mode->Focused() && e == Event::Character('3')) {
                              conflict_mode_selected = 2;
                              _conflict              = CopyConflict::Skip;
                              return true;
                            }
                            if (e == keys().key_copy) {
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
  if (auto error = archive_mutation_error(target); !error.empty()) {
    _confirm_when_ready = false;
    file_operations().report_error(error);
    return;
  }
  if (_discovery_process->request().conflict != to_job_copy_conflict(_conflict) || _discovery_process->request().destination != target ||
      _discovery_process->request().follow_links != b_follow_links ||
      _discovery_process->request().preserve_relative_links != b_preserve_relative_links ||
      _discovery_process->request().sources != app->action.arguments->selected) {
    _start_new_discovery();
    _confirm_when_ready = true;
    return;
  }
  if (_discovery_process->_running.load()) {
    _confirm_when_ready = true;
    return;
  }
  if (is_archive_file_path(target)) {
    auto plan=selection_plan(OperationType::ARCHIVE_CREATE,app->action.arguments->selected,target);
    plan.conflict=to_job_copy_conflict(_conflict);
    auto job=std::make_shared<JobSpec>(std::make_shared<const OperationPlan>(std::move(plan)));
    _clear_operation_state();
    (app->jobs?*app->jobs:file_operations()).add_job(job);
    app->dir->clear_selection();
    app->action.close_dialog();
    return;
  }

  auto job = std::make_shared<JobSpec>(_discovery_process->take_plan());
  (app->jobs?*app->jobs:file_operations()).add_job(job); // Acquire execution leases before releasing discovery.
  _clear_operation_state();
  app->dir->clear_selection();
  app->action.close_dialog();
}

Element CopyDialog::render() {
  int     file_count       = app->action.arguments->selected.size();
  Element file_list        = text("No files to copy");
  Element bytes_filter_row = text("");

  if (_discovery_process) {
    _discovery_process->publish_preview();
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
            _confirm_when_ready ? text("Preparing copy…") | hcenter : text(""),
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
  _confirm_when_ready = false;
  // _virtual_dir->items.clear();
  _filelist_wrapper->DetachAllChildren();
  _discovery_process.reset();
}

CopyDiscoveryProcess::CopyDiscoveryProcess(CopyDialog* parent, Filepath target)
  : CopyPlanner(CopyRequest{parent->app->action.arguments->selected,target,parent->b_follow_links,parent->b_preserve_relative_links,to_job_copy_conflict(parent->_conflict)},parent->app->notify, parent->app->emit) {
  _dir           = std::make_unique<Dir>();
  _dir->path     = target;
  _dir->path_txt = target.native();
  _state         = std::make_shared<PanelSharedState>(_dir.get());
  // TODO: filter must be part of parent
  _state->filter = Input(&_state->filter_txt, &(_dir->path_txt), filelist_filter_opt(parent->filter_cursor_pos));
  _files         = clipped_menu(&_data_source);
  setup_filelist_datasource(_state, _data_source);
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
}
void CopyDiscoveryProcess::publish_preview() {
  { std::lock_guard lock(_m);
    if(_dir->items.size()==_plan.steps.size()) return;
    for(size_t i=_dir->items.size();i<_plan.steps.size();++i) _dir->items.push_back(operation_display(_plan.steps[i]));
  }
  _dir->apply_filter(_dir->filter.phrase,true);_dir->_calculate();
}

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
  auto job=std::make_shared<JobSpec>(std::make_shared<const OperationPlan>(selection_plan(OperationType::DELETE,app->action.arguments->selected)));
  (app->jobs?*app->jobs:file_operations()).add_job(job);
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
  auto job=std::make_shared<JobSpec>(std::make_shared<const OperationPlan>(selection_plan(OperationType::MOVE,app->action.arguments->selected,app->action.arguments->target)));
  (app->jobs?*app->jobs:file_operations()).add_job(job);
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
  cancel_submission();
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
  OperationPlan plan;plan.type=OperationType::CLIPBOARD;plan.steps.push_back({Operation::Kind::ClipboardText,{}, {}, {},text});
  submit(std::move(plan),[this,count=selected.size()](const JobSnapshot& result){if(result._state==JobState::COMPLETED)items_copied=count;});
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

}  // namespace ftxui
