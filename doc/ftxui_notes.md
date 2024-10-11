
# Concepts

Svaki primer `ScreenInteractive`a ima 2 faze:
- Skup interaktivnih komponenti
- Funckiju koja dodaje elemente kako bi napravio finalni render komponenti

----

A `ScreenInteractive` defines a main loop that renders a component.

A `Component` is a shared pointer to a `ComponentBase`. The latter defines:
- `ComponentBase`::Render(): How to render the interface.
- `ComponentBase`::OnEvent(): How to react to events.
- `ComponentBase`::Add(): Construct a parent/child relationship between two components. The tree of component is used to define how to navigate using the keyboard.

`Element` are used to render a single frame.

`Component` are used to render dynamic user interface, producing multiple frame, and updating its state on events.


