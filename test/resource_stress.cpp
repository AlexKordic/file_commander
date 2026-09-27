#include <fcntl.h>
#include <algorithm>
#include <iostream>
#include <set>
#include "application_events.hpp"
#include "file_io_jobs.hpp"
#include "latest_work.hpp"
#include "support/contracts.hpp"
#include "ui_dispatcher.hpp"
#if defined(__APPLE__)
#include <libproc.h>
#endif
using namespace test;
using namespace Perun;
static int descriptors() {
  int n = 0;
  for (int fd = 0; fd < 4096; ++fd)
    if (fcntl(fd, F_GETFD) != -1) ++n;
  return n;
}
static int threads() {
#if defined(__APPLE__)
  proc_taskinfo info{};
  require(proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, sizeof(info)) == sizeof(info), "thread count unavailable");
  return info.pti_threadnum;
#else
  return std::distance(fs::directory_iterator("/proc/self/task"), fs::directory_iterator());
#endif
}
static void cycle(int id) {
  Fixture f;
  write(f / "source", "stress bytes");
  UiDispatcher ui;
  ui.suspend();
  std::atomic<int> sent = 0;
  LatestWork       work;
  work.submit([post = ui.poster(), &sent](const auto&) { post([&sent] { ++sent; }); });
  work.shutdown();
  ui.resume();
  ui.drain();  // Work may be cancelled before start.
  JobRetention limits;
  limits.history_count = 3;
  limits.detail_count  = 1;
  limits.detail_bytes  = 1024;
  limits.event_count   = 4;
  auto jobs            = make_file_jobs(limits);
  jobs->set_update_sink(ui.notifier());
  for (int n = 0; n < 5; ++n) {
    auto plan = std::make_shared<OperationPlan>();
    plan->steps.push_back({Operation::Kind::CopyFile, f / "source", f / ("copy" + std::to_string(n))});
    auto job = std::make_shared<JobSpec>(plan);
    require(jobs->add_job(job) != 0, "paced stress submission rejected");
    until([&] { return jobs->idle(); }, "stress jobs timeout");
    require(read(f / ("copy" + std::to_string(n))) == "stress bytes", "stress bytes corrupted");
  }
  auto history = jobs->get_job_history();
  require(history.size() == 3, "stress history grew");
  size_t details = 0;
  for (auto& job : history) details += !job->snapshot()->_details_expired;
  require(details <= 1, "stress details grew");
  uint64_t cursor = 0;
  auto     events = jobs->events_since(cursor);
  require(events.size() <= 5 && events.front().history_expired, "stress events grew");
  jobs->shutdown();
  ui.close();
}
static void stress() {
  cycle(-1);
  int fd = descriptors(), workers = threads();
  for (int i = 0; i < 30; ++i) {
    cycle(i);
    require(descriptors() == fd, "descriptor leak at cycle " + std::to_string(i));
    require(threads() == workers, "worker leak at cycle " + std::to_string(i));
  }
  std::cout << "PASS stress 30 cycles; descriptors=" << fd << " threads=" << workers << "\n";
}
template <class F> static void measure(const std::string& mechanism, int size, F run) {
  std::vector<double> samples;
  for (int i = 0; i < 9; ++i) {
    auto start = std::chrono::steady_clock::now();
    run();
    samples.push_back(std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count());
  }
  std::sort(samples.begin(), samples.end());
  std::cout << "{\"mechanism\":\"" << mechanism << "\",\"entries\":" << size << ",\"p50_ms\":" << samples[4] << ",\"p95_ms\":" << samples[8]
            << ",\"max_ms\":" << samples.back() << "}\n";
}
static void benchmark() {
  for (int size : {1000, 10000, 100000}) {
    DirectorySnapshot snapshot{"/benchmark", {}};
    for (int i = 0; i < size; ++i) {
      auto name = "item" + std::to_string(i);
      snapshot.items.emplace_back(snapshot.path / name, name, fs::regular_file, fs::owner_read, i, i);
    }
    Dir dir;
    measure("publication", size, [&] { dir.publish(snapshot); });
    for (int percent : {0, 1, 10, 100}) {
      std::unordered_set<std::string> selected;
      for (int i = 0; i < size * percent / 100; ++i) selected.insert(snapshot.items[i].path_ref().native());
      measure("selection_" + std::to_string(percent), size, [&] { dir.restore_selection(selected); });
      require(dir.stats().items_selected == selected.size(), "benchmark selection mismatch");
    }
    std::vector<DirectoryDelta> delta;
    for (int i = 0; i < std::min(size, 512); ++i) delta.push_back({snapshot.items[i].path_ref(), snapshot.items[i]});
    measure("watcher_delta_512", size, [&] { dir.publish_delta(delta); });
  }
  ApplicationEvents bus;
  for (int i = 0; i < 4096; ++i) bus.publish("fixture", std::to_string(i));
  measure("event_poll", 4096, [&] {
    uint64_t cursor = 0;
    require(bus.since(cursor).size() == 4096, "benchmark event count");
  });
}
int main(int argc, char** argv) {
  try {
    require(argc == 2, "stress or benchmark required");
    std::string mode = argv[1];
    if (mode == "stress") stress();
    else if (mode == "benchmark") benchmark();
    else throw std::runtime_error("unknown stress mode");
  } catch (const std::exception& e) {
    std::cerr << e.what() << "\n";
    return 1;
  }
}
