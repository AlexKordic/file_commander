
#include "dialogs.hpp"
#include <ftxui/dom/elements.hpp>

#include "commander.h"
#include "file_panel.hpp"
#include "theme.hpp"

namespace ftxui {

Err Files::init(PanelSharedState::P s_) {
  state                 = std::move(s_);
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
  state->filter_text = filter_txt;

  state->filter = Input(&filter_txt, &(state->dir->path_txt), input_opt);
  files         = FileList(state);
  sort_name     = Button("Name", [dir = state->dir] { dir->sort_toggle_name_direction(); }, ascii_button);
  sort_size     = Button("Size", [dir = state->dir] { dir->sort_toggle_size_direction(); }, ascii_button);
  sort_time     = Button("Date", [dir = state->dir] { dir->sort_toggle_time_direction(); }, ascii_button);

  auto render_selection = [state = state, sort_name = sort_name, sort_size = sort_size, sort_time = sort_time]() -> Element {
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
  renderer   = Renderer(navigation, [filter = state->filter, render_selection = render_selection, files = files]() -> Element {
    return vbox({
      filter->Render() | ftxui::focus | ftxui::select,
      render_selection(),
      files->Render() | vscroll_indicator | yframe | theme().files_border,
    });
  });
  files->TakeFocus();
  return Err();
}

MkdirDialog::MkdirDialog(PanelSharedState::P s) : app(std::move(s)) {
  InputOption textbox_opt;
  textbox_opt.on_change = [this]() { this->error.clear(); };
  textbox_opt.on_enter  = [this]() { this->ok(); };
  textbox               = Input(&new_dir_name, "Name for new directory", textbox_opt);

  button_ok    = Button("OK", [this] { this->ok(); });
  button_close = Button("Cancel", [this] { this->cancel(); });

  navigation = Container::Vertical({
    textbox,
    button_ok,
    button_close,
  });
  renderer   = Renderer(navigation, [this]() -> Element { return this->render(); });
}

void MkdirDialog::OnShow(std::shared_ptr<CommandArgs> data) {
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
  e.push_back(button_ok->Render());
  e.push_back(button_close->Render());
  return vbox(std::move(e)) | border | size(HEIGHT, GREATER_THAN, 18) | center;
}

void MkdirDialog::ok() {
  // Create dir
  auto dir_path = app->action.arguments->origin;
  dir_path /= new_dir_name;
  if (boost::filesystem::exists(dir_path)) {
    // Display error
    error = "Name conflict";
    return;
  }
  boost::filesystem::create_directory(dir_path);
  // Close dialog
  app->dir->refresh();
  app->action.close_dialog();
}

void MkdirDialog::cancel() { app->action.close_dialog(); }

Nyi::Nyi(PanelSharedState::P s) {
  Component nyi_textbox      = Input("", "Dummy text - Not used at all ...");
  Component nyi_button_close = Button("OK", [s] { s->action.close_dialog(); });
  navigation                 = Container::Vertical({nyi_textbox, nyi_button_close});
  renderer                   = Renderer(navigation, [nyi_textbox, nyi_button_close, s]() -> Element {
    return vbox({
             text(s->action.dialog + " dialog example"),
             separator(),
             nyi_textbox->Render(),
             filler(),
             nyi_button_close->Render(),
           })
      | border | size(HEIGHT, GREATER_THAN, 18) | center;
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
