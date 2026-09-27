#pragma once
#include "log.hpp"
#include <atomic>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <optional>
#include <queue>
#include <thread>
#include <vector>

// Headless timer owner. Tests can advance an injected monotonic clock and call
// poll_due without a thread; production uses the same decision path in run().
class ScheduledUpdates {
 public:
  using Clock=std::function<double()>;
  explicit ScheduledUpdates(std::function<void()> notify=[] {}, Clock clock=Perun::monotonic_now)
      : _notify(std::move(notify)),_clock(std::move(clock)) {}
  ~ScheduledUpdates();
  void start();
  void stop();
  void schedule_at(double timestamp);
  void start_periodic(int interval_ms);
  void stop_periodic() {start_periodic(0);}
  bool poll_due();
  void clock_changed() {_cv.notify_all();}
 private:
  std::function<void()> _notify;
  Clock _clock;
  std::priority_queue<double,std::vector<double>,std::greater<double>> _timers;
  std::mutex _mutex;
  std::condition_variable _cv;
  std::atomic<bool> _running{false};
  double _period=0,_periodic_at=0;
  std::thread _thread;
  std::optional<double> next_locked() const;
  bool due_locked(double current);
  void run();
};
