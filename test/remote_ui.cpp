#include "app.hpp"
#include "remote_fs.hpp"
#include "support/contracts.hpp"
#include <deque>
#include <iostream>
using test::require;
struct Ui {
  std::mutex mutex;
  std::deque<std::function<void()>> callbacks;
  void post(std::function<void()> f) {
    std::lock_guard lock(mutex);
    callbacks.push_back(std::move(f));
  }
  void drain() {
    for (;;) {
      std::function<void()> f;
      {
        std::lock_guard lock(mutex);
        if (callbacks.empty())
          return;
        f = std::move(callbacks.front());
        callbacks.pop_front();
      }
      f();
    }
  }
  template <class F> void wait(F done) {
    test::until(
        [&] {
          drain();
          return done();
        },
        "Remote panel update timed out");
  }
};
int main() {
  test::Fixture local;
  Ui ui;
  auto remote = Location::decode("ssh://fixture" + (local / "remote").native()).resource();
  try {
    RemoteFS::mkdir(remote);
    RemoteFS::write(remote / "alpha.txt", 0, "alpha", true);
    RemoteFS::write(remote / "beta.txt", 0, "beta", true);
    Panel panel(remote, [](Panel *) { return Filepath(); }, [&](auto f) { ui.post(std::move(f)); });
    ui.wait([&] { return !panel.loading() && panel.dir.items.size() == 2; });
    require(panel.dir.path == remote && panel.dir.path_txt.starts_with("ssh://fixture/"),
            "Panel lost SSH identity");
    RemoteFS::write(remote / "gamma.txt", 0, "gamma", true);
    ui.wait([&] { return panel.dir.items.size() == 3; });
    panel.new_tab();
    panel.move_to(local.root);
    ui.wait([&] { return !panel.loading() && panel.dir.path == local.root; });
    auto saved = panel.capture_workspace();
    require(saved.tabs.size() == 2 && saved.tabs[0].path == remote.native(),
            "Workspace lost inactive remote tab");
    panel.switch_to_tab(0);
    ui.wait([&] { return !panel.loading() && panel.dir.path == remote && panel.dir.items.size() == 3; });
    auto restored = panel.capture_workspace();
    Panel restarted(
        local.root, [](Panel *) { return Filepath(); }, [&](auto f) { ui.post(std::move(f)); }, {}, true);
    restarted.restore_workspace(restored);
    ui.wait([&] { return !restarted.loading() && restarted.dir.path == remote; });
    require(restarted.dir.items.size() == 3, "Restart did not restore remote listing");
    auto offline = Location::decode("ssh://fixture-offline/tmp/never-local").resource();
    restarted.move_to(offline);
    ui.wait([&] { return !restarted.loading() && !restarted.remote_error.empty(); });
    require(restarted.dir.path == offline && restarted.dir.items.empty(),
            "Offline remote tab fell back to local contents");
    RemoteFS::remove(remote, true);
    RemoteFS::close_connections();
    std::cout << "Remote panels, polling, tabs, workspace restore and offline identity passed\n";
    return 0;
  } catch (const std::exception &e) {
    std::cerr << e.what() << "\n";
    return 1;
  }
}
