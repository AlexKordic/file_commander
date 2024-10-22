
#include "dialogs.hpp"

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
  renderer  = Renderer(navigation, [filter = state->filter, render_selection = render_selection, files = files]() -> Element {
    return vbox({
      filter->Render() | ftxui::focus | ftxui::select,
      render_selection(),
      files->Render() | vscroll_indicator | yframe | theme().files_border,
    });
  });
  files->TakeFocus();
  return Err();
}

Nyi::Nyi(PanelSharedState::P s) {
  Component nyi_textbox      = Input("", "Dummy text - Not used at all ...");
  Component nyi_button_close = Button("OK", [s] { s->action.close_dialog(); });
  navigation                  = Container::Vertical({nyi_textbox, nyi_button_close});
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
