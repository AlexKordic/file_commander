// Contracts of the UI-free application model (fc_model) and the facade the
// macOS app imports (fc_engine). Each case runs alone: model_contracts <case>.
#include <cstdlib>
#include <iostream>
#include "app_model.hpp"
#include "fc_engine.hpp"
#include "file_io_jobs.hpp"
#include "pane_model.hpp"
#include "support/contracts.hpp"
#include "ui_dispatcher.hpp"
using namespace test;
using namespace Perun;

namespace {
// Runs posted closures on this thread until the predicate holds.
template <class F> void pump(UiDispatcher& dispatcher, F predicate, const std::string& message) {
  auto end = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (!predicate() && std::chrono::steady_clock::now() < end) {
    dispatcher.drain();
    dispatcher.wait(std::chrono::milliseconds(5));
  }
  dispatcher.drain();
  require(predicate(), message);
}
std::vector<std::string> names(PaneModel& pane) {
  std::vector<std::string> out;
  for (int item : pane.visible_rows()) out.push_back(pane.dir().items[item].filename_ref());
  return out;
}
void world(const Fixture& f) {
  fs::create_directories(f / "photos");
  for (auto name : {"lighthouse.jpg", "night-ferry.jpg", "notes.txt"}) write(f / "photos" / name, name);
  write(f / "README.md", "demo");
}
}  // namespace

void panes() {
  Fixture      f;
  world(f);
  UiDispatcher dispatcher;
  PaneModel    pane(f.root, dispatcher.poster(), {});
  pane.restart_initial_load();
  pump(dispatcher, [&] { return !pane.loading() && pane.dir().items.size() == 2; }, "initial listing missing");
  int photos = -1;
  for (int item : pane.visible_rows())
    if (pane.dir().items[item].filename_ref() == "photos") photos = item;
  require(pane.enter(photos), "entering photos failed");
  pump(dispatcher, [&] { return !pane.loading() && pane.dir().items.size() == 3; }, "photos listing missing");
  pane.set_filter("JPG");
  require(names(pane).size() == 2, "filter must ignore case and hide notes.txt");
  pane.set_filter("");
  require(pane.glob_select("*.JPG", true) == 2 && pane.dir().stats().items_selected == 2, "glob select must match two photos");
  auto args = pane.command_args();
  require(args->selected.size() == 2 && args->selected[0].filename() == "lighthouse.jpg", "selection must be in display order");
  pane.clear_selection();
  pane.set_cursor(pane.visible_rows()[2]);
  require(pane.command_args()->selected.size() == 1 && pane.command_args()->selected[0].filename() == "notes.txt",
          "with nothing selected, commands act on the cursor item");
  pane.set_sort(Orderby::NAME_DESC);
  require(names(pane).front() == "notes.txt" && pane.cursor_item()->filename_ref() == "notes.txt", "sorting keeps the cursor item");
  pane.new_tab(f.root, true);
  pump(dispatcher, [&] { return !pane.loading() && pane.tab_count() == 2 && pane.dir().items.size() == 2; }, "tutorial tab missing");
  require(pane.capture_workspace().tabs.size() == 1, "tutorial tabs are never saved in the workspace");
  pane.close_tutorial_tabs();
  require(pane.tab_count() == 1 && !pane.active().tutorial, "tutorial tabs must close");
  pane.leave();
  pump(dispatcher, [&] { return !pane.loading() && pane.dir().path == f.root; }, "leave must return to the parent");
  require(pane.cursor_item() && pane.cursor_item()->filename_ref() == "photos", "leaving focuses the folder we came from");
}

void commands() {
  Fixture f;
  setenv("XDG_CONFIG_HOME", (f / "config").c_str(), 1);
  world(f);
  UiDispatcher dispatcher;
  AppModel     app(f.root, f / "photos", dispatcher.poster());
  app.pane(0).restart_initial_load();
  app.pane(1).restart_initial_load();
  pump(dispatcher, [&] { return !app.pane(0).loading() && !app.pane(1).loading() && app.pane(1).dir().items.size() == 3; }, "panes not loaded");
  for (const auto& command : app_commands()) require(app.available(command.id) || command.id == "tab_close", "no handler for " + command.id);
  require(app.palette("ssh").front() == "connect_ssh", "typing ssh must rank Connect to Server first");
  require(app.palette("").size() + 1 == app_commands().size(), "the palette lists every visible command");
  app.set_focused_side(1);
  require(app.execute("select_toggle") && app.pane(1).dir().stats().items_selected == 1, "Space marks the cursor item");
  require(app.pane(1).cursor_item()->filename_ref() == "night-ferry.jpg", "Space moves the cursor down");
  require(app.execute("copy"), "copy must open its dialog");
  auto requests = app.take_dialog_requests();
  require(requests.size() == 1 && requests[0].name == "Copy" && requests[0].selected.size() == 1 && requests[0].target == f.root,
          "copy asks for the dialog with the selection and the other pane as target");
  require(app.use_count("copy") == 1, "running a command counts its use");
  app.add_bookmark(f / "photos");
  app.save_settings();
  require(fs::exists(f / "config" / "file_commander" / "settings.json"), "settings must be saved");
}

void rate() {
  Fixture f;
  write(f / "big.bin", std::string(3 * 1024 * 1024, 'x'));
  auto jobs = make_file_jobs();
  jobs->set_transfer_rate(512 * 1024);
  require(jobs->transfer_rate() == 512 * 1024, "rate must be readable");
  auto start = std::chrono::steady_clock::now();
  OperationPlan plan;
  plan.type = OperationType::COPY;
  plan.steps.push_back({Operation::Kind::CopyFile, f / "big.bin", f / "out.bin", {}, {}, 3 * 1024 * 1024});
  auto job = std::make_shared<JobSpec>(std::make_shared<const OperationPlan>(std::move(plan)));
  require(jobs->add_job(job) != 0, "copy not queued");
  std::this_thread::sleep_for(std::chrono::milliseconds(400));
  require(!job->is_stopped(), "a 3 MiB copy at 512 KiB/s must still run");
  jobs->set_transfer_rate(0);  // Lifting the limit applies within the running file.
  until([&] { return job->is_stopped(); }, "copy did not finish after lifting the limit");
  auto seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
  require(seconds < 3.0, "a raised limit must apply mid-file, took " + std::to_string(seconds) + " s");
  require(fs::file_size(f / "out.bin") == 3 * 1024 * 1024, "copy incomplete");
  jobs->shutdown();
}

void engine() {
  Fixture f;
  setenv("XDG_CONFIG_HOME", (f / "config").c_str(), 1);
  world(f);
  static std::atomic<int> wakes{0};
  fce::set_wake([](void*) { ++wakes; }, nullptr);
  fce::StartOptions options;
  options.left  = f.root.native();
  options.right = (f / "photos").native();
  auto started  = fce::start(options);
  require(started.ok, "engine start failed: " + started.error);
  auto settle = [](auto predicate, const std::string& message) {
    auto end = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (!predicate() && std::chrono::steady_clock::now() < end) {
      fce::drain();
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    require(predicate(), message);
  };
  settle([] { return !fce::pane(1).loading && fce::row_count(1) == 3; }, "right pane not listed");
  require(wakes > 0, "workers must wake the app");
  require(fce::row(1, 0).name == "lighthouse.jpg" && !fce::row(1, 0).is_dir, "rows must describe items");
  require(fce::row_named(1, "notes.txt") == 2, "rows can be found by name");
  fce::set_focused_side(1);
  require(fce::glob_select(1, "*.jpg", true) == 2, "glob through the facade");
  auto made = fce::submit_mkdir((f / "photos").native(), "2026");
  require(made.error.empty() && made.job, "mkdir must be queued");
  settle([&] { return fce::job_detail(made.job).info.state == "completed"; }, "mkdir job must complete");
  fce::refresh(1);
  settle([&] { return fce::row_named(1, "2026") >= 0; }, "the new folder must be listed");
  auto second = fce::start(options);
  require(!second.ok, "a second start must be refused");
  fce::stop();
  require(!fce::started(), "engine must stop");
}

// 100,000 entries: the listing must load, and filtering and sorting must stay
// interactive (the app re-reads rows lazily, so the model is what costs).
void large() {
  Fixture f;
  fs::create_directories(f / "big");
  for (int i = 0; i < 100000; ++i) {
    std::ofstream(((f / "big") / ("file-" + std::to_string(i) + (i % 10 ? ".txt" : ".jpg"))).string());
  }
  UiDispatcher dispatcher;
  PaneModel    pane(f / "big", dispatcher.poster(), {});
  auto         start = std::chrono::steady_clock::now();
  pane.restart_initial_load();
  auto end = std::chrono::steady_clock::now() + std::chrono::seconds(30);
  while ((pane.loading() || pane.dir().items.size() < 100000) && std::chrono::steady_clock::now() < end) {
    dispatcher.drain();
    dispatcher.wait(std::chrono::milliseconds(5));
  }
  require(pane.dir().items.size() == 100000, "100,000 entries must load");
  auto ms = [](auto from) { return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - from).count(); };
  std::cout << "load " << ms(start) << " ms\n";
  auto t = std::chrono::steady_clock::now();
  pane.set_filter("jpg");
  auto rows = pane.visible_rows().size();
  double filter = ms(t);
  std::cout << "filter " << filter << " ms, " << rows << " rows\n";
  require(rows == 10000, "the filter must leave the .jpg files");
  require(filter < 100, "filtering 100,000 entries took " + std::to_string(filter) + " ms");
  t = std::chrono::steady_clock::now();
  pane.set_sort(Orderby::NAME_DESC);
  double sort = ms(t);
  std::cout << "sort " << sort << " ms\n";
  require(sort < 500, "sorting 100,000 entries took " + std::to_string(sort) + " ms");
}

int main(int argc, char** argv) {
  try {
    std::string name = argc > 1 ? argv[1] : "all";
    bool        found = false;
#define RUN(n)                                                                                                                                                 \
  if (name == #n || name == "all") {                                                                                                                           \
    n();                                                                                                                                                       \
    found = true;                                                                                                                                              \
  }
    RUN(panes) RUN(commands) RUN(rate) RUN(engine)
    if (name == "large") {  // Not part of "all": it writes 100,000 files.
      large();
      found = true;
    }
    require(found, "unknown model case");
    std::cout << "PASS model " << name << "\n";
  } catch (const std::exception& e) {
    std::cerr << e.what() << "\n";
    return 1;
  }
}
