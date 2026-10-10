#pragma once
#include "dialogs.hpp"
#include "theme.hpp"

namespace ftxui {
std::function<Element(const EntryState&)>             ascii_button_transform();
// A one-row button coloured by a theme decorator: " label ", or "[label]" when focused.
ButtonOption                                          theme_button(Decorator Theme::*style);
template <typename THIS> std::function<bool(Event e)> close_on_esc(THIS* self) {
  return [self](Event e) -> bool {
    if (e == keys().key_cancel_dialog) {
      self->cancel();
      return true;
    }
    return false;
  };
}

}  // namespace ftxui
