
# FTXUI - Functional Terminal User Interface

FTXUI is a C++ library for building terminal user interfaces. It separates concerns into
three distinct layers: **DOM elements** (what to draw), **Components** (interactive state
and event handling), and **Screen** (the rendering target and main loop).

---

## Core Concepts

### The Two Fundamental Types

FTXUI has two primary abstractions that serve different purposes:

| Type | Alias For | Purpose | Lifetime |
|------|-----------|---------|----------|
| `Element` | `shared_ptr<Node>` | Describes a single frame of visual output | Ephemeral - rebuilt every frame |
| `Component` | `shared_ptr<ComponentBase>` | Manages state, handles events, produces Elements | Persistent - lives across frames |

**Elements** are the "what to draw" - they form an immutable tree describing one frame.
**Components** are the "how to interact" - they persist across frames and produce new Element trees on each render.

---

## Layer 1: DOM Elements

### Element Tree and the Rendering Pipeline

`Element` is a `shared_ptr<Node>`. Nodes form a parent-child tree that goes through
a three-step rendering pipeline:

1. **`ComputeRequirement()`** - Bottom-up pass. Each node tells its parent what size it
   wants (`requirement_.min_x`, `requirement_.min_y`). Leaf nodes (like `text()`) report
   their intrinsic size. Container nodes (like `hbox`, `vbox`) aggregate children.

2. **`SetBox(Box box)`** - Top-down pass. Parent assigns each child its final screen
   rectangle (`box.x_min, y_min, x_max, y_max`). Layout nodes distribute space among
   children based on requirements and flex properties.

3. **`Render(Screen& screen)`** - Top-down pass. Each node writes its pixels into the
   `Screen` buffer using `screen.PixelAt(x, y)`.

### Factory Functions for Elements

Elements are constructed exclusively through factory functions. The actual `Node`
subclass type is erased behind the `Element` (`shared_ptr<Node>`) alias.

```cpp
// Text and separators
Element e = text("Hello");
Element s = separator();
Element sd = separatorDouble();

// Paragraph wraps text
Element p = paragraph("Long text that wraps...");
Element pc = paragraphAlignCenter("Centered text");

// Progress indicators
Element g = gauge(0.75);         // 75% progress bar
Element sp = spinner(4, frame);  // animated spinner
```

### Layout: Arranging Elements

Layout elements take a vector of child Elements and arrange them:

```cpp
// Horizontal layout: children placed left to right
Element row = hbox({text("A"), separator(), text("B")});

// Vertical layout: children stacked top to bottom
Element col = vbox({text("Line 1"), text("Line 2")});

// Depth stacking: children drawn on top of each other (back to front)
// Last child is on top. Used for overlays/dialogs.
Element overlay = dbox({background_content, dialog_on_top});

// Flexbox layout: CSS-like flexible wrapping
Element flex_layout = flexbox({elem1, elem2, elem3}, FlexboxConfig());

// Grid layout: 2D grid of elements
Element grid = gridbox({{cell_00, cell_01}, {cell_10, cell_11}});
```

### Decorators: Transforming Elements

A `Decorator` is `std::function<Element(Element)>`. Decorators wrap an element to modify
its appearance or layout. They compose using the pipe operator `|`:

```cpp
// These two are equivalent:
Element e1 = text("hello") | bold | color(Color::Red);
Element e2 = color(Color::Red, bold(text("hello")));

// The |= operator modifies in place:
Element e = text("hello");
e |= bold;
e |= color(Color::Red);
```

#### Visual decorators:

```cpp
bold(element)            // Bold text
dim(element)             // Dimmed text
inverted(element)        // Swap fg/bg colors
underlined(element)      // Underline text
blink(element)           // Blinking text
strikethrough(element)   // Strikethrough text
color(Color::Red)        // Set foreground color (returns Decorator)
bgcolor(Color::Blue)     // Set background color (returns Decorator)
```

#### Layout decorators:

```cpp
border(element)                  // Draw a border around element
borderDouble(element)            // Double-line border
borderStyled(BorderStyle::HEAVY) // Returns Decorator for a specific border style
window(title_elem, content)      // Border with a title element

// Size constraints
size(WIDTH, GREATER_THAN, 40)    // Minimum width of 40
size(HEIGHT, EQUAL, 10)          // Exact height of 10
size(WIDTH, LESS_THAN, 80)       // Maximum width of 80
```

#### Flexibility decorators (how elements share remaining space):

```cpp
flex(element)         // Expand and shrink as needed (both axes)
flex_grow(element)    // Expand if space available, don't shrink below minimum
flex_shrink(element)  // Shrink if needed, don't expand beyond minimum

xflex(element)        // flex on X axis only
xflex_grow(element)   // flex_grow on X axis only
yflex(element)        // flex on Y axis only

filler()              // Invisible expandable spacer element
nothing(element)      // Identity decorator, pass-through
```

#### Frame / scrolling decorators:

```cpp
frame(element)            // Scrollable area (both axes), follows focus
xframe(element)           // Horizontal scroll only
yframe(element)           // Vertical scroll only
vscroll_indicator(element) // Add vertical scroll indicator
hscroll_indicator(element) // Add horizontal scroll indicator

// Focus markers - tell a frame which child to scroll to
focus(element)    // This element is focused AND selected
select(element)   // This element is selected (but not focused)
```

#### Alignment / centering:

```cpp
hcenter(element)      // Center horizontally
vcenter(element)      // Center vertically
center(element)       // Center both axes
align_right(element)  // Align to right side
```

### Writing Custom Nodes

To create custom rendering behavior, subclass `Node` (or the helper `NodeDecorator`
for wrapping a single child). Override the three pipeline methods as needed:

```cpp
class MyCustomNode : public Node {
public:
  explicit MyCustomNode(Elements children) : Node(std::move(children)) {}

  void ComputeRequirement() override {
    // Report desired size
    requirement_.min_x = 10;
    requirement_.min_y = 1;
  }

  void SetBox(Box box) override {
    // Store assigned box, propagate to children
    Node::SetBox(box);
  }

  void Render(Screen& screen) override {
    // Write directly to screen pixels
    for (int x = box_.x_min; x <= box_.x_max; ++x) {
      screen.PixelAt(x, box_.y_min).character = "#";
      screen.PixelAt(x, box_.y_min).foreground_color = Color::Red;
    }
  }
};

// Expose via factory function, erasing the concrete type:
Element my_custom(Elements children) {
  return ftxui::make_shared<MyCustomNode>(std::move(children));
}
```

For decorators that wrap a single child, use `NodeDecorator`:

```cpp
class NodeDecorator : public Node {
public:
  explicit NodeDecorator(Element child) : Node({std::move(child)}) {}
  void ComputeRequirement() override {
    Node::ComputeRequirement();
    requirement_ = children_[0]->requirement(); // Pass through child's requirements
  }
  void SetBox(Box box) override {
    Node::SetBox(box);
    children_[0]->SetBox(box);  // Give child the same box
  }
};
```

This project defines several custom nodes this way:

- **`ColoredInt`** - Renders an integer with different colors per digit group
  (thousands, millions, etc). Directly writes colored characters to `Screen`.
- **`BgGaugeLeft`** - A decorator that paints a partial background fill from left
  to right, used for size-relative bars behind filenames.
- **`ShowInputCursor`** - A decorator that inverts a pixel at the cursor position,
  providing visible cursor rendering.
- **`ClearUnder`** - A decorator that clears all pixels in its box before rendering
  its child. Used with `dbox` to ensure dialog overlays have a clean background.

---

## Layer 2: Components

### ComponentBase

`ComponentBase` is the base class for interactive elements. A `Component` is a
`shared_ptr<ComponentBase>`. Components are:

- **Persistent** - they live across frames, maintaining state
- **Tree-structured** - parent/child relationships define keyboard navigation
- **Not copyable/movable** - always managed via shared pointers

The key virtual methods:

```cpp
class ComponentBase {
  virtual Element Render();           // Produce the visual output for this frame
  virtual bool OnEvent(Event);        // Handle keyboard/mouse event; return true if consumed
  virtual Component ActiveChild();    // Which child currently has focus
  virtual bool Focusable() const;     // Can this component receive focus?
  virtual void SetActiveChild(ComponentBase* child);  // Set which child is active
};
```

**Focus model**: A component is "focused" when the entire chain of `ActiveChild()` from
the root down to this component's ancestors all point toward it. `TakeFocus()` configures
all ancestors to make this component the focused one.

### Component Hierarchy and Navigation

The component tree determines keyboard navigation order. When a container receives an
arrow key event it doesn't handle, it moves focus to the next/previous child:

```cpp
// Add child to parent
parent->Add(child_component);

// Remove child from parent
child_component->Detach();

// Remove all children
parent->DetachAllChildren();

// Query
parent->ChildCount();
parent->ChildAt(0);

// Focus management
component->TakeFocus();     // Make this the focused component
component->Focused();       // Is this currently focused?
component->Active();        // Is this the active child of its parent?
```

### Built-in Components (Factory Functions)

#### Containers - grouping components for navigation:

```cpp
// Vertical: Up/Down arrows navigate between children
Component c = Container::Vertical({child1, child2, child3});

// Horizontal: Left/Right arrows navigate between children
Component c = Container::Horizontal({child1, child2, child3});

// Tab: Only one child shown at a time, switched by external int*
int active_tab = 0;
Component c = Container::Tab({page1, page2, page3}, &active_tab);

// Stacked: All children rendered via dbox (depth stacking), events go to last child first
Component c = Container::Stacked({background, overlay});
```

#### Interactive widgets:

```cpp
// Button
Component btn = Button("Click me", []{ /* on_click */ });
Component btn = Button("Styled", on_click, ButtonOption::Simple());

// Input (text field)
std::string content;
Component input = Input(&content, "placeholder");
Component input = Input(&content, InputOption{.multiline = false});

// Checkbox
bool checked = false;
Component cb = Checkbox("Option", &checked);

// Radiobox
int selected = 0;
Component rb = Radiobox({"A", "B", "C"}, &selected);

// Menu (selectable list)
int selected = 0;
Component menu = Menu({"Item 1", "Item 2"}, &selected);

// Slider
int value = 50;
Component s = Slider("Volume", &value, 0, 100, 1);

// Dropdown
int selected = 0;
Component dd = Dropdown({"Option A", "Option B"}, &selected);
```

#### Layout components:

```cpp
// Resizable split - two components with draggable divider
int split_size = 40;
Component split = ResizableSplitRight(right_panel, left_panel, &split_size);

// Also available: ResizableSplitLeft, ResizableSplitTop, ResizableSplitBottom
// Or the general form:
ResizableSplitOption opt;
opt.main = right_component;
opt.back = left_component;
opt.main_size = &size;
opt.direction = Direction::Right;
opt.separator_func = []() -> Element { return separatorDouble(); };
Component split = ResizableSplit(opt);
```

### The Renderer Wrapper

`Renderer` is the critical bridge between Components and Elements. It wraps a component
(for its event/focus behavior) while replacing its `Render()` with a custom lambda that
returns Elements:

```cpp
// Renderer with a child component (child handles events/focus, lambda handles rendering)
Component renderer = Renderer(child_component, [child_component]() -> Element {
  return vbox({
    text("Header"),
    separator(),
    child_component->Render(),  // Delegate rendering to child
  });
});

// Renderer without a child (no focus/event handling, just rendering)
Component static_display = Renderer([]() -> Element {
  return text("Static content");
});

// Renderer with focus awareness
Component aware = Renderer([](bool focused) -> Element {
  if (focused) return text("I'm focused!") | bold;
  return text("Not focused");
});
```

**Why Renderer exists**: Components that contain interactive children need to both
(a) delegate events to children (via the component tree) and (b) control how children
are visually arranged (via the Element tree). `Renderer(child, render_lambda)` accomplishes
both: the child component participates in the focus/event tree, while the lambda produces
the final Element tree for display.

### CatchEvent Wrapper

`CatchEvent` intercepts events before they reach a component. The handler lambda returns
`true` to consume the event (preventing it from reaching the wrapped component) or `false`
to let it pass through:

```cpp
Component guarded = CatchEvent(inner_component, [](Event event) -> bool {
  if (event == Event::Escape) {
    // Handle escape ourselves
    do_something();
    return true;   // Event consumed, won't reach inner_component
  }
  return false;    // Let event pass through to inner_component
});
```

### Other Component Decorators

```cpp
// Maybe: conditionally show/hide a component
Component c = Maybe(inner, &show_flag);
Component c = Maybe(inner, [&]{ return should_show; });

// Modal: show a modal dialog on top of main
Component c = Modal(main, dialog, &show_modal);

// Hoverable: track mouse hover state
bool is_hovered = false;
Component c = Hoverable(inner, &is_hovered);

// Collapsible: expandable/collapsible section
Component c = Collapsible("Section Title", content, false);
```

### Component Pipe Operator

Components also support `|` and `|=` for decoration, similar to Elements:

```cpp
// Element decorator applied to component (wraps Render output)
Component c = my_component | border;

// Component decorator applied to component
Component c = my_component | CatchEvent(handler);
```

---

## Layer 3: ScreenInteractive

`ScreenInteractive` owns the main loop. It handles terminal I/O, dispatches events to
components, and triggers rendering.

### Construction

```cpp
auto screen = ScreenInteractive::Fullscreen();              // Uses full terminal
auto screen = ScreenInteractive::FullscreenAlternateScreen(); // Alt screen buffer
auto screen = ScreenInteractive::FitComponent();            // Size fits content
auto screen = ScreenInteractive::FixedSize(80, 24);         // Fixed dimensions
auto screen = ScreenInteractive::TerminalOutput();          // Appends to terminal output
```

### The Main Loop

```cpp
screen.Loop(root_component);
// Blocks until screen.Exit() is called.
```

The loop cycle:
1. Wait for an event (keyboard, mouse, resize, posted task, animation)
2. Dispatch the event to the root component via `OnEvent()`
3. Call `root_component->Render()` to get the Element tree
4. Run the three-phase rendering pipeline on the Element tree
5. Diff the result with the previous frame and emit minimal terminal escape sequences
6. Repeat

### Posting Tasks from Other Threads

FTXUI is single-threaded for rendering. To update the UI from background threads,
post tasks to the screen's event queue:

```cpp
// Post a callable to run on the UI thread
screen.Post([&]{ update_some_state(); });

// Trigger a new frame to be drawn (without any state change)
screen.PostEvent(Event::Custom);

// Common pattern: post state change + trigger redraw
screen.Post([&]{
  data = new_data;
});
screen.Post(Event::Custom);

// Or combined:
auto exec = [&screen](std::function<void()> f) {
  screen.Post(f);
  screen.Post(Event::Custom);
};
```

### WithRestoredIO

When the screen is active, terminal settings are modified (raw mode, alternate screen,
etc). `WithRestoredIO` temporarily restores the original terminal state, which is
essential for printing logs or running subprocesses:

```cpp
auto print_safely = screen.WithRestoredIO([&]{
  std::cout << "This prints to the real terminal" << std::endl;
});
// Later, call print_safely() and it will restore IO, print, then re-enter raw mode
screen.Post(print_safely);
```

### Querying Screen State

```cpp
ScreenInteractive* active = ScreenInteractive::Active(); // Currently active screen (or nullptr)
int width = screen.dimx();    // Terminal width
int height = screen.dimy();   // Terminal height
```

---

## Patterns Used In This Project

### Pattern 1: Navigation Tree vs Render Tree

This is the most important architectural pattern in the project. The **navigation tree**
(Component hierarchy) and the **render tree** (Element hierarchy) are separate:

- The **navigation tree** defines which components exist, how focus moves between them
  with keyboard, and who receives events.
- The **render tree** defines how things look on screen, built fresh each frame from
  the `Render()` lambda.

A component can participate in the navigation tree for event handling while being visually
positioned anywhere in the render tree. The `Renderer(navigation_root, render_lambda)`
pattern connects them.

Example from `FileCommander`:

```cpp
// Navigation tree: Tab container switches between main view and overlay dialogs
navigation = Container::Tab({}, &_active_dialog);

// Left and right panels get their own combined component where
// navigation is separate from rendering:
Component left_combined  = Renderer(left.navigation,
                                     [this]() -> Element { return left.render(); });
Component right_combined = Renderer(right.navigation,
                                     [this]() -> Element { return right.render(); });

// ResizableSplit handles layout, CatchEvent adds global shortcuts
Component both_panels = CatchEvent(ResizableSplit(split), global_shortcuts);

// Add to navigation tree
navigation->Add(both_panels);

// Final renderer: navigation tree handles events, lambda handles layout
renderer = Renderer(navigation, [this]() -> Element {
  Elements el;
  el.push_back(both_panels->Render() | yflex | bgcolor(...) | color(...));
  if (has_job) el.push_back(progress_bar.render());
  for (auto& err : errors) el.push_back(text(err.message) | theme().recent_error);
  return vbox(std::move(el));
});
```

### Pattern 2: Dialog Overlay System

Dialogs are layered on top of the main content using `Container::Tab` for navigation
switching and `dbox` for visual stacking:

```cpp
// Container::Tab({}, &_active_dialog) acts as a focus router.
// When _active_dialog == 0, events go to the main document.
// When _active_dialog == 1, events go to the overlay dialog.
navigation = Container::Tab({}, &_active_dialog);
navigation->Add(main_document->navigation);  // index 0

// To show a dialog:
void show_dialog(std::string name) {
  _active_dialog = 1;
  // Remove old dialog children, add new dialog
  auto dialog = _overlay_dialogs.at(name);
  navigation->Add(dialog->navigation);
  _overlay_renderer = dialog->renderer;
  dialog->OnShow();
}

// In the render function, use dbox for visual stacking:
Element render() {
  Element document = _main_document->renderer->Render();
  if (!_overlay_renderer) return document;
  return dbox({
    document,                                                          // Background
    _overlay_renderer->Render() | yflex | clear_under_colors | center, // Dialog on top
  });
}
```

The `clear_under_colors` decorator (custom Node) erases background pixels before
drawing the dialog, ensuring the dialog has a clean canvas even though `dbox` draws
children on the same area.

### Pattern 3: Dynamic Component Tree Manipulation

Components can be added and removed at runtime using `Add()`, `Detach()`, and
`DetachAllChildren()`. The project uses this extensively for dialogs whose content
changes:

```cpp
// RenameDialog: creates one Input per selected file, adds them dynamically
void RenameDialog::OnShow() {
  menu->DetachAllChildren();  // Clear old items
  rows.clear();
  for (int i = 0; i < selected_count; i++) {
    Component input_field = Input(style);
    Component old_to_new = Renderer(input_field, [...]() -> Element { ... });
    menu->Add(old_to_new);   // Add new item to navigation tree
  }
  menu->TakeFocus();
}

// On successful rename, remove items:
void RenameDialog::ok() {
  for (int i = count - 1; i >= 0; --i) {
    if (rename_succeeded) {
      menu->ChildAt(i)->Detach();  // Remove from navigation tree
    }
  }
}
```

### Pattern 4: Cross-Thread UI Updates

Background threads (file watchers, file operations) post updates to the UI thread:

```cpp
// ExecuteOnUiThread wraps screen.Post() + Event::Custom
auto exec = [&screen](std::function<void()> f) -> void {
  screen.Post(f);              // Queue the function for UI thread
  screen.Post(Event::Custom);  // Trigger a redraw
};

// File change watcher posts from a background thread:
update_funnel = FileChangeFunnel::create(where, [this](UpdatedFiles changes) {
  pending_changes.push(std::move(changes));       // Thread-safe queue
  this->run_on_ui([this]() {                      // Runs on UI thread
    while (true) {
      UpdatedFiles batch;
      if (this->pending_changes.try_pop(batch) != FifoError::OK) return;
      this->dir.partial_refresh(std::move(batch)); // Safe to modify UI state
    }
  });
});
```

### Pattern 5: Custom Element Composition with `|`

The `|` operator on Elements allows fluent decorator chaining, heavily used for styling:

```cpp
// File entry rendering with conditional decorators:
Element n = text(data.filename_ref());
n = n | xflex_grow | highlight;              // Expand and apply background gauge
if (selected) n |= theme().files_selected;   // Conditional gold+bold
if (!focused && !selected) n |= filetype_color(data);  // Type-based color

Element row = hbox({n, size_elem, separatorLight(), time_elem});
if (focused) row |= ftxui::focus;  // Tell parent frame to scroll here
if (hovered) row |= theme().files_hovered;
```

### Pattern 6: Theme as Decorator Provider

The `Theme` struct centralizes all visual configuration. It stores both raw `Color`
values and pre-built `Decorator` values, so they can be applied directly with `|`:

```cpp
struct Theme {
  // Raw colors for custom use
  Color files_focused_full;
  Color files_focused_empty;

  // Pre-built decorators for direct application
  Decorator files_selected;   // = color(Color::Gold1) | bold
  Decorator files_border;     // = borderStyled(Color::DarkOliveGreen3Ter)
  Decorator files_focused;    // = bold
  Decorator recent_error;     // = color(Color::LightPink3) | bold
  // ...
};

// Usage:
element | theme().files_selected;
element | theme().recent_error;
```

### Pattern 7: Entry/Item Transform Functions

FTXUI components like `Button`, `Input`, `Checkbox` accept a `transform` function in
their options. This function receives the component's state and returns an Element,
giving full control over appearance:

```cpp
// Custom button appearance using transform
std::function<Element(const EntryState&)> ascii_button_transform() {
  return [](const EntryState& s) -> Element {
    const std::string t = s.focused ? "[" + s.label + "]" : " " + s.label + " ";
    if (s.focused) return text(t) | theme().sort_button_active;
    return text(t) | theme().sort_button;
  };
}
ButtonOption opt;
opt.transform = ascii_button_transform();
Component btn = Button("Name", on_click, opt);

// Custom input appearance
InputOption input_opt;
input_opt.transform = [](InputState state) {
  if (state.is_placeholder) return state.element | theme().files_path;
  return state.element | theme().files_filter_search;
};
```

### Pattern 8: LogAdapter with WithRestoredIO

Since FTXUI takes over the terminal, stdout/stderr are not usable normally. The
`LogAdapter` captures log messages and flushes them using `WithRestoredIO`:

```cpp
class LogAdapter {
  explicit LogAdapter(ScreenInteractive& screen) {
    print_log  = l.produce;       // Save original log function
    flush_logs = screen.WithRestoredIO([&] {
      // This runs with terminal temporarily restored
      for (const auto& x : log_queue) { print_log(x.first, x.second); }
      log_queue.clear();
    });
    l.produce = [this, &screen](std::string const& txt, const char level) {
      log_queue.push_back({txt, level});
      if (!printing) {
        printing = true;
        screen.Post(flush_logs);  // Schedule flush on UI thread
      }
    };
  }
};
```

---

## Event Handling

Events flow from `ScreenInteractive` -> root component -> down the active child chain.
Each component can consume the event by returning `true` from `OnEvent()`.

### Event Types

```cpp
Event::ArrowUp, Event::ArrowDown, Event::ArrowLeft, Event::ArrowRight
Event::Return, Event::Escape, Event::Tab, Event::TabReverse
Event::Backspace, Event::Delete
Event::Character('a'), Event::Character(' ')
Event::CtrlA, Event::CtrlC, ..., Event::CtrlZ
Event::AltA, ..., Event::AltZ
Event::F1, ..., Event::F12
Event::Custom  // User-defined event, used to trigger redraws
// Mouse events via event.is_mouse() and event.mouse()
```

### Event Handling Order in This Project

1. `CatchEvent` wrappers intercept first (global shortcuts at `FileCommander` level)
2. `Container::Tab` routes to the active child based on `_active_dialog` index
3. The active child's `OnEvent()` processes or delegates further
4. Unhandled events bubble back up

---

## Summary: How It All Fits Together

```
ScreenInteractive::Loop(root_component)
      |
      v
  [Event Loop]
      |
      +-- Event arrives (keyboard/mouse/posted task)
      |       |
      |       v
      |   root_component->OnEvent(event)
      |       |
      |       +-- CatchEvent handler (global shortcuts)
      |       +-- Container::Tab routes to active panel or dialog
      |       +-- Panel's navigation routes to file list or overlay
      |       +-- Leaf component (Input, Button, etc.) handles event
      |
      +-- root_component->Render()
              |
              v
          Renderer lambda builds Element tree:
              vbox({
                both_panels->Render() | yflex | bgcolor | color,
                progress_bar.render(),
                error_lines...
              })
              |
              v
          Element tree goes through:
            1. ComputeRequirement() -- bottom up
            2. SetBox()             -- top down
            3. Render(Screen&)      -- top down, writes pixels
              |
              v
          Screen diffs with previous frame
          Emits terminal escape sequences
```

---

## Links

- [FTXUI GitHub](https://github.com/ArthurSonzogni/FTXUI)
- [Change focus discussion](https://github.com/ArthurSonzogni/FTXUI/discussions/895)
- [Scrollable requirements](https://github.com/ArthurSonzogni/FTXUI/discussions/757)
- [Terminal app example](https://github.com/ArthurSonzogni/FTXUI/discussions/886)
- [File open dialog example](https://github.com/mr-mocap/cli-6502-playground/blob/master/app/ui/components/directorybrowser.cpp)
- [Directory browser component](https://github.com/ArthurSonzogni/FTXUI/discussions/593#discussioncomment-6632945)
- Hyperlink element decorator available via `hyperlink("url", element)`
- Force redraw: `screen.PostEvent(Event::Custom);`
