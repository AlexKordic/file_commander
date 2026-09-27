
#include "app.hpp"
#include "scripting.hpp"
#include "ui_dispatcher.hpp"

#include <ftxui/component/loop.hpp>

#include <iostream>

// cache logs issued in current screen loop, and flush them at the end of screen loop
class LogAdapter {
  struct State {
    std::mutex mutex;
    std::vector<std::pair<std::string, char>> records;
    bool scheduled = false;
    bool closed = false;
    std::function<void(std::string const&, char)> print;
  };
  std::shared_ptr<State> state = std::make_shared<State>();
 public:
  LogAdapter(ScreenInteractive& screen, UiDispatcher& dispatcher) {
    state->print = l.produce;
    auto flush = [state = state, &screen, &dispatcher] {
      std::vector<std::pair<std::string, char>> records;
      { std::lock_guard lock(state->mutex);
        if (state->closed) return;
        state->scheduled = false;
        records.swap(state->records);
      }
      dispatcher.suspend();
      Defer resume([&] { dispatcher.resume(); });
      screen.WithRestoredIO([&] { for (const auto& [text, level] : records) state->print(text, level); })();
    };
    l.produce = [state = state, post = dispatcher.poster(), flush](const std::string& text, char level) {
      { std::lock_guard lock(state->mutex);
        if (state->closed) return;
        state->records.emplace_back(text, level);
        if (state->scheduled) return;
        state->scheduled = true;
      }
      post(flush);
    };
  }
  ~LogAdapter() {
    l.produce = state->print;
    std::lock_guard lock(state->mutex);
    state->closed = true;
    for (const auto& [text, level] : state->records) state->print(text, level);
  }
};

void set_console_size(int width, int height) { std::cout << "\e[8;" << height << ";" << width << "t"; }

int main(int argc, char** argv) {
  // For debugging
  // set_console_size(140, 60);
  // -------------

  auto screen = ScreenInteractive::Fullscreen();
  auto cwd = boost::filesystem::current_path();

  // Check for "run script.lua" mode
  const bool        lua_mode = argc > 2 && std::string(argv[1]) == "run";
  const std::string lua_script_path = lua_mode ? argv[2] : "";

  auto left_path  = (!lua_mode && argc > 1) ? boost::filesystem::path(argv[1]) : cwd;
  auto right_path = (!lua_mode && argc > 2) ? boost::filesystem::path(argv[2]) : cwd;

  UiDispatcher dispatcher;
  auto exec = dispatcher.poster();
  file_operations().set_update_sink(dispatcher.notifier());
  // auto          redraw = [&screen]() -> void { screen.Post(Event::Custom); };
  auto          dimx = [&screen]() -> int { return screen.dimx(); };
  auto run_with_restored_io = [&screen, &dispatcher](std::function<int()> fn) -> int {
    dispatcher.suspend();
    Defer resume([&] { dispatcher.resume(); });
    int rc = -1;
    auto wrapped = screen.WithRestoredIO([&]() { rc = fn(); });
    wrapped();
    return rc;
  };
  // FTXUI drops posts until its loop is installed. Activate it before the
  // panels can launch their initial directory workers.
  auto root = Container::Vertical({});
  ftxui::Loop loop(&screen, root);
  FileCommander app(left_path, right_path, exec, dimx, run_with_restored_io, true);
  root->Add(app.renderer);
  if (!lua_mode) {
    const bool explicit_panel_paths = argc > 1;
    app.load_settings(!explicit_panel_paths);
  }

  app.start_initial_navigation();

  LogAdapter adapt_logs(screen, dispatcher);

  // screen.TrackMouse(false);

  int exit_code = 0;
  if (lua_mode) {
    LuaScripting scripting(app, app.renderer);

    auto fire = [&scripting](const std::string& n, const std::string& d) {
      scripting.fire_event(n, d);
    };
    // Wire all three DialogOverlay instances
    app.on_event             = fire;
    app.get_left().on_event  = fire;
    app.get_right().on_event = fire;

    if (!scripting.setup(lua_script_path)) return 1;

    // Explicit Loop — Lua tick() runs after every render pass
    while (!loop.HasQuitted()) {
      if (dispatcher.drain()) screen.Post(Event::Custom);
      loop.RunOnce();
      scripting.tick();   // first call starts coroutine; thereafter checks waits
      dispatcher.wait();
    }
    exit_code = scripting.exit_code();
    scripting.cleanup();
  } else {
    // Normal mode — no Lua
    while (!loop.HasQuitted()) {
      if (dispatcher.drain()) screen.Post(Event::Custom);
      loop.RunOnce();
      dispatcher.wait();
    }
    app.save_settings();
  }

  file_operations().shutdown();
  dispatcher.close();
  return exit_code;
}
