
# Concepts

Svaki primer `ScreenInteractive`a ima 2 faze:
- Skup interaktivnih komponenti povezanih u parent<>child veze
- Funckiju koja dodaje elemente kako bi napravio finalni render komponenti

Pogledaj `flexbox_gallery.cpp`. Postoji `main_container` i `main_renderer`. 
- main_container definise strukturu navigacije. Ko je desno od koga itd.
- main_renderer uzima root kontejner i definise funkciju koja ce da renderuje elemente.

> Da li treba Component da sklapa elemente???
???

## Element Nesting using shared pointers

`Element` is shared_ptr of `Node`.

When constructing nodes `Element` is always returned erasing actual type.

Elements are composed easily in parent-child tree.

Only factory functions are exposed. If an interface is needed separate object is defined and passed to factory function.

## Decorators

????



----

A `ScreenInteractive` defines a main loop that renders a component.

A `Component` is a shared pointer to a `ComponentBase`. The latter defines:
- `ComponentBase`::Render(): How to render the interface.
- `ComponentBase`::OnEvent(): How to react to events.
- `ComponentBase`::Add(): Construct a parent/child relationship between two components. The tree of component is used to define how to navigate using the keyboard.

`Element` are used to render a single frame.

`Component` are used to render dynamic user interface, producing multiple frame, and updating its state on events.

# Interested people

I made it as a subcomponent for a directory browser widget that I'm currently working on. 
  - https://github.com/ArthurSonzogni/FTXUI/discussions/593#discussioncomment-6632945
  - https://github.com/mr-mocap/cli-6502-playground/blob/master/app/ui/components/list.hpp

# How to

Change focus https://github.com/ArthurSonzogni/FTXUI/discussions/895

Scrollable requirements https://github.com/ArthurSonzogni/FTXUI/discussions/757

Termina app example https://github.com/ArthurSonzogni/FTXUI/discussions/886

?? https://github.com/cosargozukirmizi/tui-prevth

there is hyperlink element decorator

File open dialog https://github.com/mr-mocap/cli-6502-playground/blob/master/app/ui/components/directorybrowser.cpp

`screen_interactive.PostEvent(Event::Custom);` // Cause a new frame to be drawn.


