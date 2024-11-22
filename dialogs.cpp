
#include "dialogs.hpp"
#include "bfs.hpp"

#include "commander.hpp"
#include "file_panel.hpp"
#include "file_io_jobs.hpp"
#include "log.hpp"
#include "shared_state.hpp"
#include "theme.hpp"

#include <boost/filesystem/file_status.hpp>
#include <boost/filesystem/operations.hpp>
#include <boost/system/detail/error_code.hpp>

#include <ftxui/component/component.hpp>
#include <ftxui/dom/elements.hpp>

#include <memory>
#include <string>

using boost::filesystem::directory_entry;
using boost::filesystem::directory_iterator;
using boost::filesystem::file_status;
using boost::system::error_code;

using Perun::JobSpec;
using Perun::file_operations;

namespace ftxui {

Dialog::Dialog(PanelSharedState::P app) : app(app) {}

//
// Files
//

Files::Files(PanelSharedState::P s) : Dialog(std::move(s)) {
  InputOption input_opt = InputOption::Default();
  input_opt.multiline   = false;
  input_opt.transform   = [](InputState state) {
    if (state.is_placeholder) {
      return state.element | theme().files_path;
    } else {
      return state.element | theme().files_filter_search;
    }
  };
  ButtonOption ascii_button;
  ascii_button.transform = [](const EntryState& s) {
    const std::string t = s.focused ? "[" + s.label + "]" : " " + s.label + " ";
    if (s.focused) return text(t) | theme().sort_button_active;
    return text(t) | theme().sort_button;
  };

  app->filter = Input(&filter_txt, &(app->dir->path_txt), input_opt);
  files       = FileList(app, &filter_txt);
  sort_name   = Button("Name", [dir = app->dir] { dir->sort_toggle_name_direction(); }, ascii_button);
  sort_size   = Button("Size", [dir = app->dir] { dir->sort_toggle_size_direction(); }, ascii_button);
  sort_time   = Button("Date", [dir = app->dir] { dir->sort_toggle_time_direction(); }, ascii_button);

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

  navigation = Container::Vertical({Container::Horizontal({sort_name, sort_size, sort_time}), files});
  renderer   = Renderer(navigation, [filter = app->filter, render_selection = render_selection, files = files]() -> Element {
    return vbox({
      hbox({text(" "), filter->Render() | ftxui::focus | ftxui::select, text(" ")}),
      render_selection(),
      files->Render() | vscroll_indicator | yframe | theme().files_border,
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

  button_ok         = Button("   OK   ", [this] { this->ok(); });
  button_close      = Button(" Cancel ", [this] { this->cancel(); });
  auto close_on_esc = [this](Event event) -> bool {
    if (event == Event::Escape) {
      this->cancel();
      return true;
    }
    return false;
  };

  navigation = CatchEvent(Container::Vertical({
                            textbox,
                            button_ok,
                            button_close,
                          }),
                          close_on_esc);
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
  ascii_button.transform = [](const EntryState& s) {
    const std::string t = s.focused ? "[" + s.label + "]" : " " + s.label + " ";
    if (s.focused) return text(t) | theme().sort_button_active;
    return text(t) | theme().sort_button;
  };
  button_ok    = Button("Rename", [this] { this->ok(); }, ascii_button);
  button_close = Button("Cancel", [this] { this->cancel(); }, ascii_button);
  menu         = Container::Vertical({}, &selected);

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
    // app->dir->refresh();
    app->action.close_dialog();
    return;
  }
  menu->TakeFocus();
}

void RenameDialog::cancel() { app->action.close_dialog(); }

//
// Copy
//

/*
  There is no progress interface in filesystem::copy, see playground.cpp for workaround
*/
CopyDialog::CopyDialog(PanelSharedState::P d, RedrawUI r) : Dialog(std::move(d)), redraw_ui(r) {
  // [_] follow links `cp -r -L`: always follow symbolic links in SOURCE
  // [x] preserve permissions
  // [x] preserve timestamps
  // [x] preserve ownership
  // [x] preserve relative links
  // + detecting cyclic symbolic links
  // + detect when dir is copied into itself
  // + detect when file is copied into itself
  InputOption input_opt  = InputOption::Default();
  input_opt.multiline    = false;
  input_destination_path = Input(&destination_path, "", input_opt);

  button_ok     = Button("  COPY  ", [this] { this->run_copy(); });
  // TODO: add button "open in new tab ⮂ ↱↱↱ 🆕 tab  "
  button_cancel = Button(" Cancel ", [this] { this->cancel_copy(); });
  CheckboxOption checkbox_opt;
  checkbox_opt.on_change     = [this]() { this->OnShow(); };
  op_follow_links            = Checkbox("Follow Links in Source", &b_follow_links, checkbox_opt);
  op_preserve_relative_links = Checkbox("Keep relative links", &b_preserve_relative_links, checkbox_opt);

  input_opt.transform = [](InputState state) {
    if (state.is_placeholder) {
      return state.element | theme().files_path;
    } else {
      return state.element | theme().files_filter_search;
    }
  };
  auto close_on_esc = [this](Event event) -> bool {
    if (event == Event::Escape) {
      this->cancel_copy();
      return true;
    }
    return false;
  };
  _virtual_dir                       = std::make_unique<Dir>();
  _operation_state                   = std::make_shared<PanelSharedState>(_virtual_dir.get());
  _operation_state->commands_enabled = false;
  _operation_state->move_to          = [](Filepath) {};
  _operation_state->get_focused_item = []() -> Filepath const* { return nullptr; };
  _operation_state->filter           = Input(&_filter_text, &(_virtual_dir->path_txt), input_opt);
  files                              = FileList(_operation_state, &_filter_text);

  navigation = CatchEvent(Container::Vertical({
                            input_destination_path,
                            Container::Horizontal({button_ok, button_cancel}),
                            op_follow_links,
                            op_preserve_relative_links,
                            files,
                          }),
                          close_on_esc);
  renderer   = Renderer(navigation, [this]() -> Element { return this->render(); });
}

void CopyDialog::cancel_copy() {
  _clear_operation_state();
  app->action.close_dialog();
}

void CopyDialog::run_copy() {
  auto job = std::make_shared<JobSpec>(JobSpec::Type::COPY, std::move(_virtual_dir->items));
  _clear_operation_state();
  job->_bytes_total = 0;
  for (DirItem const& item : job->_items) {
    if (item.type() == boost::filesystem::regular_file) { job->_bytes_total += item.size(); }
  }
  // whenever job updates, redraw UI
  job->updated = this->redraw_ui;
  file_operations().add_job(job);
  // TODO: add job to CommandProgressPanel
  app->action.close_dialog();
}

Element CopyDialog::render() {
  int file_count  = app->action.arguments->selected.size();
  int bytes_total = 0;
  for (DirItem const& item : _virtual_dir->items) {
    if (item.type() == boost::filesystem::regular_file) { bytes_total += item.size(); }
  }
  // clang-format off
  return window(
    text(" Copy " + std::to_string(file_count) + " selected items ") | bold | hcenter,
  vbox({
            hbox({text(" TO: "), input_destination_path->Render(), text(" ")}),
            // text(""),
            separator(),
            hbox({button_ok->Render() | hcenter, button_cancel->Render() | hcenter}) | hcenter,
            separatorHeavy(),
            op_follow_links->Render() | hcenter,
            op_preserve_relative_links->Render() | hcenter,
            hbox({text("Bytes: "), coloredInt(bytes_total), text(" | Filter: "), _operation_state->filter->Render()}) | hcenter,
            separatorHeavy(),
            files->Render() | vscroll_indicator | yframe,
          }),
          BorderStyle::DOUBLE
        );
  // clang-format on
}

void CopyDialog::_clear_operation_state() {
  _virtual_dir->items.clear();
  _visited_dirs.clear();
}

void CopyDialog::OnShow() {
  _clear_operation_state();
  button_ok->TakeFocus();
  app->action.arguments->use_focused_as_alternative();
  destination_path       = app->action.arguments->target.native();
  _virtual_dir->path     = app->action.arguments->target;
  _virtual_dir->path_txt = app->action.arguments->target.native();
  std::vector<DirItem> selected;
  selected.reserve(app->action.arguments->selected.size());
  for (auto& p : app->action.arguments->selected) { selected.emplace_back(p); }
  _queue_files(selected, app->action.arguments->target);
}

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

// TODO:
//  - preserve owner
// This traversal should be depth first because we want to create tree like depiction in our list
void CopyDialog::_queue_files(const std::vector<DirItem>& files, Filepath destination) {
  std::vector<DirItem>& q = _virtual_dir->items;
  // if type is dir path is to be mkdired
  // if type is link path is where to place link and target is link target
  // else path is source file and target is destination file for copy operation

  auto do_place_link = [&q](Filepath const& location, Filepath const& destination, boost::filesystem::perms p) {
    error_code ec;
    DirItem&   link = q.emplace_back(location, boost::filesystem::symlink_file, p);
    link._set_symlink_target(destination);
  };
  auto place_on_queue = [&, this](const DirItem& item) -> void {
    error_code ec;
    const auto new_record_path = destination / item.path_ref().filename();
    const bool copy_to_self    = boost::filesystem::equivalent(item.path_ref(), new_record_path, ec);
    if (!ec.failed() && copy_to_self) {
      auto& created = q.emplace_back(DirItem(item.path_ref(), boost::filesystem::status_error, item.perms()));
      created._set_symlink_target(destination / item.path_ref().filename());
      created._set_warning("Copy to self");
      return;
    }
    // Act on symlink
    if (item.symlink_ref()) {
      // handle link
      const bool relative = item.symlink_ref()->is_relative();
      if (!b_follow_links && b_preserve_relative_links && relative) {
        // create relative symlink
        do_place_link(new_record_path, *item.symlink_ref(), item.perms());
        return;
      }
      Filepath symlink_target = resolve_symlink(item.path_ref());
      if (symlink_target.empty()) {
        auto& created = q.emplace_back(DirItem(item.path_ref(), boost::filesystem::status_error, item.perms()));
        created._set_symlink_target(new_record_path);
        created._set_warning("Cyclic symlink");
        return;
      }
      if (b_follow_links) {
        // use symlink_target intstead of item, converting symlink to actual dir item
        this->_queue_files({DirItem(symlink_target, item.type(), item.perms())}, new_record_path);
        return;
      }
      // create absolute symlink
      Filepath absolute_symlink_target = boost::filesystem::canonical(symlink_target, item.path_ref().parent_path(), ec);
      if (!ec.failed()) { symlink_target = absolute_symlink_target; }
      do_place_link(new_record_path, symlink_target, item.perms());
      return;
    }
    // Act on directory
    if (item.type() == boost::filesystem::directory_file) {
      // detect cyclic dir
      for (auto& visited : _visited_dirs) {
        if (boost::filesystem::equivalent(visited.source.path_ref(), item.path_ref(), ec)) {
          // dir already copied, create link to it instead
          do_place_link(new_record_path, visited.destination, item.perms());
          return;
        }
      }
      _visited_dirs.push_back({.source = DirItem(item), .destination = new_record_path});
      // queue create dir command
      q.push_back(DirItem(new_record_path, boost::filesystem::directory_file, item.perms()));
      // Recurse into subdir
      std::vector<DirItem> subdir_items;
      error_code           ec;
      for (directory_entry& subdir_item : directory_iterator(item.path_ref(), ec)) {
        error_code  ec;
        file_status fs = subdir_item.status(ec);
        subdir_items.emplace_back(subdir_item.path(), fs.type(), fs.permissions());
      }
      _queue_files(subdir_items, new_record_path);
      return;
    }
    // Act on file
    auto& created = q.emplace_back(item);
    created._set_symlink_target(new_record_path);
  };
  // TODO: prevent dir copy into itself
  // TODO: prevent file copy into itself
  for (auto& item : files) {
    if (item.type() == boost::filesystem::status_error) {
      auto& created = q.emplace_back(item);
      created._set_symlink_target(destination / item.path_ref().filename());
      continue;
    }
    place_on_queue(item);
  }
};

//
// ToClipboardDialog
//

ToClipboardDialog::ToClipboardDialog(PanelSharedState::P d) : Dialog(std::move(d)) {
  button_close = Button("OK", [this] { this->app->action.close_dialog(); });
  navigation   = Container::Vertical({button_close});
  renderer     = Renderer(navigation, [this]() -> Element { return this->render(); });
}

void ToClipboardDialog::OnShow() {
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

Commands::Commands() {
  available.reserve(100);
  // TODO: extract info from structure instead of hardcoded here
  available.push_back({theme().key_mkdir, "Mkdir"});
  available.push_back({theme().key_rename, "Rename"});
  available.push_back({theme().key_copy, "Copy"});
  available.push_back({theme().key_move, "Move"});
  available.push_back({theme().key_delete, "Delete"});
  available.push_back({theme().key_names_to_clipboard, "NameToClipboard"});
  available.push_back({theme().key_paths_to_clipboard, "PathToClipboard"});
  available.push_back({theme().key_find, "Find"});
}

Commands& commands() {
  static Commands _c;
  return _c;
}

}  // namespace ftxui
