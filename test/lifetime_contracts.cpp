#include <future>
#include <iostream>
#include "fifo_queue.hpp"
#include "file_io_jobs.hpp"
#include "latest_work.hpp"
#include "scheduled_updates.hpp"
#include "support/contracts.hpp"
#include "ui_dispatcher.hpp"
using namespace test;
using namespace Perun;
void latest() {
  for (int i = 0; i < 40; ++i) {
    std::atomic<int>  published = 0;
    std::atomic<bool> cancelled = false;
    Gate              active;
    LatestWork        worker;
    Gate::Release     release{active};
    worker.submit([&](const auto& token) {
      if (active.arrive()) {
        cancelled = token->load();
        if (!*token) published = 1;
      }
    });
    active.await();
    worker.submit([&](const auto&) { published = 2; });
    worker.submit([&](const auto& token) {
      if (!*token) published = 3;
    });
    active.open();
    until([&] { return published == 3; }, "latest pending work not published");
    worker.shutdown();
    require(cancelled && published == 3, "superseded work escaped cancellation");
    worker.submit([&](const auto&) { published = 4; });
    require(published == 3, "post-shutdown submit ran");
  }
  std::atomic<bool> pending = false;
  Gate              active;
  LatestWork        worker;
  Gate::Release     release{active};
  worker.submit([&](const auto&) { active.arrive(); });
  active.await();
  worker.submit([&](const auto&) { pending = true; });
  worker.cancel();
  active.open();
  worker.shutdown();
  require(!pending, "cancelled pending work ran");
}
void mailbox() {
  UiDispatcher::Post late;
  for (int i = 0; i < 40; ++i) {
    UiDispatcher dispatcher;
    late = dispatcher.poster();
    dispatcher.suspend();
    int         calls = 0;
    std::thread a([&] { late([&] { calls += 1; }); }), b([&] { late([&] { calls += 2; }); }), c([&] { late([&] { calls += 4; }); });
    a.join();
    b.join();
    c.join();
    require(!dispatcher.drain() && calls == 0, "suspended completion delivered");
    dispatcher.resume();
    require(dispatcher.drain() && calls == 7, "mixed completion lost");
    late([&] {
      ++calls;
      late([&] { ++calls; });
    });
    dispatcher.drain();
    require(calls == 8, "reentrant task drained in wrong batch");
    dispatcher.drain();
    require(calls == 9, "reentrant task lost");
    late([&] { ++calls; });
    dispatcher.close();
    require(!dispatcher.drain() && calls == 9, "post-close callback executed");
    late([&] { ++calls; });
  }
  late([] { throw std::runtime_error("expired sender ran"); });
}
void queue() {
  for (int cap : {0, 1, 2}) {
    FifoQueue<int> q(cap);
    for (int i = 0; i < cap; ++i) require(q.try_push(i) == FifoError::OK, "queue rejected within limit");
    require(q.try_push(9) == FifoError::Full, "queue exceeded limit");
    std::promise<void> start;
    auto               started = start.get_future();
    auto               writer  = std::async(std::launch::async, [&] {
      start.set_value();
      return q.push(42);
    });
    started.wait();
    q.close();
    require(writer.get() == FifoError::Destroyed, "close failed to wake blocked producer");
    int item;
    for (int i = 0; i < cap; ++i) require(q.pop(item) == FifoError::OK && item == i, "closed queue lost queued item");
    require(q.pop(item) == FifoError::Destroyed, "closed queue waited");
  }
  FifoQueue<int> q(1);
  int            value;
  require(q.pop(value, std::chrono::milliseconds(1)) == FifoError::Timeouted, "empty timeout wrong");
  auto reader = std::async(std::launch::async, [&] { return q.pop(value); });
  q.close();
  require(reader.get() == FifoError::Destroyed, "close did not release consumer");
}
void jobs() {
  Gate            entered;
  FileJobServices services;
  services.clipboard = [&](const auto&) { return entered.arrive() ? Err() : Err("gate timeout"); };
  JobRetention limits;
  limits.pending_count  = 1;
  auto          manager = make_file_jobs(limits, services);
  Gate::Release release{entered};
  auto          make = [] {
    auto p  = std::make_shared<OperationPlan>();
    p->type = OperationType::CLIPBOARD;
    p->steps.push_back({Operation::Kind::ClipboardText, {}, {}, {}, "fixture"});
    return std::make_shared<JobSpec>(p);
  };
  auto active = make();
  manager->add_job(active);
  entered.await();
  auto pending = make();
  auto id      = manager->add_job(pending);
  require(id != 0, "pending slot rejected");
  require(manager->add_job(make()) == 0, "full pending queue did not reject");
  require(manager->cancel(id) == JobError::OK, "queued cancellation failed");
  manager->pause(active->_job_id);
  entered.open();
  manager->shutdown();
  require(pending->_state == JobState::CANCELLED, "cancelled queued job executed");
  require(manager->idle(), "shutdown left active jobs");
}
void scheduler() {
  double           clock     = 10;
  int              callbacks = 0;
  ScheduledUpdates schedule([&] { ++callbacks; }, [&] { return clock; });
  schedule.schedule_at(12);
  schedule.schedule_at(11);
  schedule.schedule_at(11);
  require(!schedule.poll_due() && callbacks == 0, "timer fired early");
  clock = 11;
  require(schedule.poll_due() && callbacks == 1, "duplicate timer coalescing");
  require(!schedule.poll_due(), "timer fired twice");
  schedule.start_periodic(500);
  clock = 11.499;
  require(!schedule.poll_due(), "periodic early");
  clock = 11.5;
  require(schedule.poll_due(), "periodic deadline missed");
  clock = 12;
  require(schedule.poll_due() && callbacks == 3, "periodic/one-shot overlap");
  schedule.stop_periodic();
  clock = 100;
  require(!schedule.poll_due(), "disabled periodic fired");
  std::atomic<int> real = 0;
  ScheduledUpdates threaded([&] { ++real; });
  threaded.start();
  threaded.start();
  threaded.schedule_at(monotonic_now());
  until([&] { return real == 1; }, "threaded scheduler lost wake");
  threaded.stop();
  threaded.stop();
}
int main(int argc, char** argv) {
  try {
    std::string name = argc > 1 ? argv[1] : "all";
#define RUN(n)                                                                                                                                                 \
  if (name == #n || name == "all") {                                                                                                                           \
    n();                                                                                                                                                       \
    found = true;                                                                                                                                              \
  }
    bool found = false;
    RUN(latest) RUN(mailbox) RUN(queue) RUN(jobs) RUN(scheduler) require(found, "unknown lifetime case");
    std::cout << "PASS lifetime " << name << "\n";
  } catch (const std::exception& e) {
    std::cerr << e.what() << "\n";
    return 1;
  }
}
