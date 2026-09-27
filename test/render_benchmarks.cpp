#include <ftxui/component/loop.hpp>
#include <iostream>
#include "app.hpp"
#include "support/allocation_counter.hpp"
#include "support/contracts.hpp"
#include "ui_dispatcher.hpp"
using namespace test;
using namespace ftxui;
int main() {
  try {
    Fixture fixture;
    setenv("XDG_CONFIG_HOME", fixture.root.c_str(), 1);
    UiDispatcher  ui;
    FileCommander app(fixture.root, fixture.root, ui.poster(), [] { return 120; });
    until(
      [&] {
        ui.drain();
        return !app.get_left().loading() && !app.get_right().loading();
      },
      "render benchmark navigation timeout");
    auto interactive = ScreenInteractive::FixedSize(120, 40);
    Loop loop(&interactive, app.renderer);
    app.get_left().navigation->TakeFocus();
    for (int size : {1000, 10000, 100000}) {
      DirectorySnapshot snapshot{fixture.root, {}};
      for (int i = 0; i < size; ++i) {
        auto name = "Ω-item-" + std::to_string(i);
        snapshot.items.emplace_back(fixture.root / name, name, fs::regular_file, fs::owner_read, i, i);
      }
      app.get_left().dir.publish(std::move(snapshot));
      for (int selected : {0, 1, 10, 100}) {
        std::unordered_set<std::string> names;
        for (int i = 0; i < size * selected / 100; ++i) names.insert(app.get_left().dir.items[i].path_ref().native());
        app.get_left().dir.restore_selection(names);
        std::vector<double> times;
        std::vector<size_t> allocations;
        for (int sample = 0; sample < 10; ++sample) {
          auto before = test_allocations.load();
          auto start  = std::chrono::steady_clock::now();
          auto screen = Screen::Create(Dimension::Fixed(120), Dimension::Fixed(40));
          Render(screen, app.renderer->Render());
          double elapsed = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
          auto   count   = test_allocations.load() - before;
          if (sample) {
            times.push_back(elapsed);
            allocations.push_back(count);
          }
        }
        std::sort(times.begin(), times.end());
        std::sort(allocations.begin(), allocations.end());
        std::cout << "{\"mechanism\":\"render\",\"entries\":" << size << ",\"selected_percent\":" << selected << ",\"p50_ms\":" << times[4]
                  << ",\"p95_ms\":" << times[8] << ",\"max_ms\":" << times.back() << ",\"cpp_allocations_p50\":" << allocations[4] << "}\n";
      }
    }
  } catch (const std::exception& e) {
    std::cerr << e.what() << "\n";
    return 1;
  }
}
