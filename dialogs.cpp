
#include "dialogs.hpp"
#include <ftxui/component/component.hpp>
#include <ftxui/dom/elements.hpp>
#include <string>

#include "boost/filesystem/operations.hpp"
#include "commander.h"
#include "file_panel.hpp"
#include "log.hpp"
#include "theme.hpp"

using boost::system::error_code;

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
      text("sel " + std::to_string(s.items_selected) + "/" + std::to_string(s.items_total)),
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
      filter->Render() | ftxui::focus | ftxui::select,
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
CopyDialog::CopyDialog(PanelSharedState::P d) : Dialog(std::move(d)) {
  // [_] follow links `cp -r -L`: always follow symbolic links in SOURCE
  // [x] preserve attributes
  // [x] preserve relative links
  // - detecting cyclic symbolic links
  // - detect when dir is copied into itself
  // - detect when file is copied into itself
  InputOption input_opt;
  input_opt.multiline    = false;
  input_destination_path = Input(&destination_path, "", input_opt);

  button_ok                  = Button("  COPY  ", [this] { this->run_copy(); });
  button_cancel              = Button(" Cancel ", [this] { this->cancel_copy(); });
  op_follow_links            = Checkbox("Follow Links in Source", &b_follow_links);
  op_preserve_attributes     = Checkbox("Preserve attributes", &b_preserve_attributes);
  op_preserve_relative_links = Checkbox("Keep relative links", &b_preserve_relative_links);

  auto close_on_esc = [this](Event event) -> bool {
    if (event == Event::Escape) {
      this->cancel_copy();
      return true;
    }
    return false;
  };

  navigation = CatchEvent(Container::Vertical({
                            input_destination_path,
                            button_ok,
                            op_follow_links,
                            op_preserve_attributes,
                            op_preserve_relative_links,
                            button_cancel,
                          }),
                          close_on_esc);
  renderer   = Renderer(navigation, [this]() -> Element { return this->render(); });
}

void CopyDialog::cancel_copy() { app->action.close_dialog(); }
void CopyDialog::run_copy() { app->action.close_dialog(); }

Element CopyDialog::render() {
  int file_count = app->action.arguments->selected.size();
  // clang-format off
  return window(
    text(" Copy " + std::to_string(file_count) + " selected items ") | bold | hcenter,
  vbox({
            hbox({text(" TO: "), input_destination_path->Render(), text(" ")}),
            // text(""),
            separator(),
            button_ok->Render() | hcenter,
            text(""),
            op_follow_links->Render(),
            op_preserve_attributes->Render(),
            op_preserve_relative_links->Render(),
            text(""),
            button_cancel->Render() | hcenter,
          }),
          BorderStyle::DOUBLE
        );
  // clang-format on
}

void CopyDialog::OnShow() {
  button_ok->TakeFocus();
  app->action.arguments->use_focused_as_alternative();
  destination_path = app->action.arguments->target.native();
}

//
// ToClipboardDialog
//

ToClipboardDialog::ToClipboardDialog(PanelSharedState::P d) : Dialog(std::move(d)) {
  button_close = Button("OK", [this] { this->app->action.close_dialog(); });
  navigation   = Container::Vertical({button_close});
  renderer     = Renderer(navigation, [this]() -> Element { return this->render(); });
}

void ToClipboardDialog::OnShow() {
  items_copied                            = 0;
  std::vector<DirItem::P>& selected       = app->action.arguments->selected;
  int                      selected_count = selected.size();
  int                      required_size  = 0;
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
