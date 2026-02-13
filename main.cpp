
#include "app.hpp"
#include "scripting.hpp"

#include <ftxui/component/loop.hpp>

#include <iostream>

// cache logs issued in current screen loop, and flush them at the end of screen loop
class LogAdapter {
 public:
  explicit LogAdapter(ScreenInteractive& screen) {
    print_log  = l.produce;
    flush_logs = screen.WithRestoredIO([&] {
      printing = false;
      for (const auto& x : log_queue) { print_log(x.first, x.second); }
      log_queue.clear();
    });
    l.produce  = [this, &screen](std::string const& txt, const char level) {
      log_queue.push_back(std::make_pair(txt, level));
      if (printing == false) {
        printing = true;
        screen.Post(flush_logs);
      }
    };
  }
  ~LogAdapter() {
    l.produce = print_log;
    for (const auto& x : log_queue) { print_log(x.first, x.second); }
  }

 protected:
  bool printing = false;

  std::vector<std::pair<std::string, char>>                     log_queue;
  std::function<void(std::string const& txt, const char level)> print_log;
  std::function<void()>                                         flush_logs;
};

void set_console_size(int width, int height) { std::cout << "\e[8;" << height << ";" << width << "t"; }

int main(int argc, char** argv) {
  // For debugging
  // set_console_size(140, 60);
  // -------------

  auto screen = ScreenInteractive::Fullscreen();

  // for (int i = 0; i < 50; ++i) {
  //   file_operations().report_error("[DBG] " + std::to_string(i) + " INITIAL single line item");
  // }
  // std::thread([&]() {
  //   for (int i = 0; true; ++i) {
  //     std::this_thread::sleep_for(std::chrono::seconds(1));
  //     file_operations().report_error("[LIVE DBG] " + std::to_string(i) + " single line item");
  //     screen.Post(Event::Custom);
  //   }
  // }).detach();

  auto cwd = boost::filesystem::current_path();

  // Check for "run script.lua" mode
  const bool        lua_mode = argc > 2 && std::string(argv[1]) == "run";
  const std::string lua_script_path = lua_mode ? argv[2] : "";

  auto left_path  = (!lua_mode && argc > 1) ? boost::filesystem::path(argv[1]) : cwd;
  auto right_path = (!lua_mode && argc > 2) ? boost::filesystem::path(argv[2]) : cwd;

  auto exec = [&screen](std::function<void()> f) -> void {
    screen.Post(f);
    screen.Post(Event::Custom);
  };
  // auto          redraw = [&screen]() -> void { screen.Post(Event::Custom); };
  auto          dimx = [&screen]() -> int { return screen.dimx(); };
  FileCommander app(left_path, right_path, exec, dimx);

  LogAdapter adapt_logs(screen);

  screen.TrackMouse(false);

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
    ftxui::Loop loop(&screen, app.renderer);
    while (!loop.HasQuitted()) {
      loop.RunOnceBlocking();
      scripting.tick();   // first call starts coroutine; thereafter checks waits
      if (scripting.finished()) {
        // Lua script completed (success or error) — exit loop
        // Give one more frame for error display, then quit
        screen.Post(ftxui::Event::Custom);
        screen.Exit();
      }
    }
    scripting.cleanup();
  } else {
    // Normal mode — no Lua
    screen.Loop(app.renderer);
  }

  return 0;
}
