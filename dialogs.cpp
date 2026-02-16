
#include "dialogs.hpp"
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

#include <cmath>
#include <cctype>
#include <format>
#include <memory>
#include <string>

using boost::filesystem::directory_entry;
using boost::filesystem::directory_iterator;
using boost::filesystem::file_status;
using boost::system::error_code;

using Perun::file_operations;
using Perun::JobInstructions;
using Perun::JobSpec;
using Perun::JobState;

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

    Element t = text(data.get_time());
    if (selected) t |= theme().files_selected;

    Element row = hbox({std::move(n), std::move(size), separatorLight(), std::move(t)});
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
  if (ctx.event == theme().key_files_select) {
    app->dir->item_toggle_select(data_source->focused_id);
    data_source->focused_id = app->dir->next_visible(data_source->focused_id);
    return true;
  }
  if (ctx.event == theme().key_clear_selection) {
    app->dir->clear_selection();
    return true;
  }
  if (ctx.event == theme().key_select_all) {
    app->dir->select_all();
    return true;
  }
  if (ctx.event == theme().key_leave_dir) {
    const Filepath old_path   = app->dir->path;
    const Filepath parent_dir = app->dir->path.parent_path();
    app->move_to(parent_dir);
    data_source->focused_id = app->dir->offset_vissible(0, 0);
    app->filter_txt.clear();
    // find our old_path and set it as focused
    for (int i = 0; i < app->dir->items.size(); i++) {
      const DirItem& item = app->dir->items.at(i);
      if (item.path_ref() == old_path) {
        data_source->focused_id = i;
        break;
      }
    }
    return true;
  }
  if (ctx.event == theme().key_enter_dir) {
    if (app->dir->items.empty()) return false;
    DirItem& where = app->dir->items.at(data_source->focused_id);
    if (where.is_dir()) {
      Filepath p = where.path_ref();
      app->move_to(p);
      data_source->focused_id = app->dir->offset_vissible(0, 0);
      app->filter_txt.clear();
      return true;
    }
    return false;
  }

  // check for registered panel dialog actions
  const Command* action = commands().find_panel_dialog_by_key(ctx.event);
  if (action) {
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

Filepath resolve_symlink(Filepath path) {
  std::vector<Filepath> chain;
  error_code            ec;
  for (;;) {
    Filepath symlink_target = boost::filesystem::read_symlink(path, ec);
    if (ec.failed() || symlink_target.empty()) return path;
    for (Filepath& visited : chain) {
      error_code ec;
      if (boost::filesystem::equivalent(visited, symlink_target, ec)) return Filepath();
    }
    chain.push_back(path);
    path = symlink_target;
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
  // [_] follow links `cp -r -L`: always follow symbolic links in SOURCE
  // input_destination_path = Input(&destination_path, "", filelist_filter_opt(destination_cursor_pos));

  button_ok     = Button("  COPY  ", [this] { this->run_copy(); });
  // TODO: add button "open in new tab ⮂ ↱↱↱ 🆕 tab  "
  button_cancel = Button(" Cancel ", [this] { this->cancel(); });
  CheckboxOption checkbox_opt;
  checkbox_opt.on_change     = [this]() { this->OnShow(); };
  op_follow_links            = Checkbox("Follow Links in Source", &b_follow_links, checkbox_opt);
  op_preserve_relative_links = Checkbox("Keep relative links", &b_preserve_relative_links, checkbox_opt);

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
                            // input_destination_path,
                            Container::Horizontal({button_ok, button_cancel}),
                            op_follow_links,
                            op_preserve_relative_links,
                            _filelist_wrapper,
                          }),
                          close_on_esc(this));
  renderer   = Renderer(navigation, [this]() -> Element { return this->render(); });
}

void CopyDialog::cancel() {
  _clear_operation_state();
  app->action.close_dialog();
}

void CopyDialog::run_copy() {
  if (!_discovery_process) return;
  auto job = std::make_shared<JobSpec>(JobSpec::Type::COPY, std::move(_discovery_process->_dir->items));
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
            hbox({text(" TO: "), text(destination_path), text(" ")}),
            separator(),
            hbox({button_ok->Render() | hcenter, button_cancel->Render() | hcenter}) | hcenter,
            separatorHeavy(),
            op_follow_links->Render() | hcenter,
            op_preserve_relative_links->Render() | hcenter,
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
  _input_paths             = parent->app->action.arguments;
  _target                  = target;
  _follow_links            = parent->b_follow_links;
  _preserve_relative_links = parent->b_preserve_relative_links;

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
    _stat_file(p);
    selected.emplace_back(p);
  }
  _discover(selected, _target);
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
  std::vector<DirItem>& q              = _dir->items;
  // if type is dir path is to be mkdired
  // if type is link path is where to place link and target is link target
  // else path is source file and target is destination file for copy operation
  auto                  place_on_queue = [this, &destination, &q](const DirItem& item) -> void {
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
        // use symlink_target intstead of item, converting symlink to actual dir item
        this->_discover({DirItem(symlink_target, item.type(), item.perms())}, new_record_path);
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
      const bool valid = _queue_dir(item, new_record_path);
      if (!valid) return;
      // Recurse into subdir
      std::vector<DirItem> subdir_items;
      error_code           ec;
      for (directory_entry& subdir_item : directory_iterator(item.path_ref(), ec)) {
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
  for (auto& item : files) {
    if (item.type() == boost::filesystem::status_error) {
      _queue_error(item, destination / item.path_ref().filename(), "stat failed");
      continue;
    }
    place_on_queue(item);
  }
};

void CopyDialog::_start_new_discovery() {
  _discovery_process = std::make_shared<CopyDiscoveryProcess>(this, app->action.arguments->target);
  _filelist_wrapper->Add(_discovery_process->_files);
}

void CopyDialog::OnShow() {
  _clear_operation_state();
  button_cancel->TakeFocus();
  app->action.arguments->use_focused_as_alternative();
  if (app->action.arguments->selected.empty()) {
    cancel();
    return;
  }
  destination_path = app->action.arguments->target.native();
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
  std::function<void(const std::string&)> execute_command
) : Dialog(nullptr),
    close_dialog(std::move(close_dialog)),
    list_commands(std::move(list_commands)),
    execute_command(std::move(execute_command)) {
  ButtonOption ascii_button;
  ascii_button.transform = ascii_button_transform();
  button_run             = Button(" Run ", [this] { run_selected(); }, ascii_button);
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
                            Container::Horizontal({button_run, button_close}),
                            input_filter,
                            list_menu,
                          }),
                          close_on_esc(this));
  renderer   = Renderer(navigation, [this]() -> Element {
    auto title = text(" Command Palette [" + std::to_string(visible_ids.size()) + "] ") | bold | hcenter;
    auto content = vbox({
      hbox({
        button_run->Render() | hcenter | xflex_grow,
        separator(),
        button_close->Render() | hcenter | xflex_grow,
      }),
      separator(),
      input_filter->Render(),
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

//
// Commands
//

Commands::Commands() {
  available.reserve(64);
  available.push_back({"copy", theme().key_copy, "Copy", "Copy", CommandScope::PANEL, CommandKind::SHOW_DIALOG});
  available.push_back({"move", theme().key_move, "Move", "Move", CommandScope::PANEL, CommandKind::SHOW_DIALOG});
  available.push_back({"delete", theme().key_delete, "Delete", "Delete", CommandScope::PANEL, CommandKind::SHOW_DIALOG});
  available.push_back({"rename", theme().key_rename, "Rename", "Rename", CommandScope::PANEL, CommandKind::SHOW_DIALOG});
  available.push_back({"mkdir", theme().key_mkdir, "Mkdir", "Make Directory", CommandScope::PANEL, CommandKind::SHOW_DIALOG});
  available.push_back({"find", theme().key_find, "Find", "Find", CommandScope::PANEL, CommandKind::SHOW_DIALOG});
  available.push_back({"names_to_clipboard", theme().key_names_to_clipboard, "NameToClipboard", "Names to Clipboard", CommandScope::PANEL, CommandKind::SHOW_DIALOG});
  available.push_back({"paths_to_clipboard", theme().key_paths_to_clipboard, "PathToClipboard", "Paths to Clipboard", CommandScope::PANEL, CommandKind::SHOW_DIALOG});

  available.push_back({"switch_panel", theme().key_switch_focused_panel, "", "Switch Focused Panel", CommandScope::GLOBAL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"refresh_dir", theme().key_refresh_dir, "", "Refresh Directory", CommandScope::GLOBAL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"target_right", theme().key_target_dir_to_focused_item_right, "", "Target Right Panel to Focused Item", CommandScope::GLOBAL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"target_left", theme().key_target_dir_to_focused_item_left, "", "Target Left Panel to Focused Item", CommandScope::GLOBAL, CommandKind::EXECUTE_CALLBACK});
  available.push_back({"toggle_errors", theme().key_toggle_error_details, "ErrorList", "Toggle Error List", CommandScope::GLOBAL, CommandKind::SHOW_DIALOG});
  available.push_back({"toggle_job_list", theme().key_toggle_job_list, "JobList", "Toggle Job List", CommandScope::GLOBAL, CommandKind::SHOW_DIALOG});
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

const Command* Commands::find_panel_dialog_by_key(const Event& key) const {
  auto it = std::find_if(available.begin(), available.end(), [&key](const Command& c) {
    return c.key == key && c.scope == CommandScope::PANEL && c.kind == CommandKind::SHOW_DIALOG;
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
