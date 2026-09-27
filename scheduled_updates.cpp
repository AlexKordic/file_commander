#include "scheduled_updates.hpp"
#include <chrono>
ScheduledUpdates::~ScheduledUpdates() { stop(); }
void ScheduledUpdates::start() {
  if (_running.exchange(true)) return;
  _thread = std::thread([this] { run(); });
}
void ScheduledUpdates::stop() {
  if (!_running.exchange(false)) return;
  _cv.notify_all();
  if (_thread.joinable()) _thread.join();
}
void ScheduledUpdates::schedule_at(double timestamp) {
  std::lock_guard lock(_mutex);
  _timers.push(timestamp);
  _cv.notify_all();
}
void ScheduledUpdates::start_periodic(int interval_ms) {
  std::lock_guard lock(_mutex);
  _period      = std::max(0, interval_ms) / 1000.0;
  _periodic_at = _clock() + _period;
  _cv.notify_all();
}
std::optional<double> ScheduledUpdates::next_locked() const {
  std::optional<double> next;
  if (!_timers.empty()) next = _timers.top();
  if (_period > 0 && (!next || _periodic_at < *next)) next = _periodic_at;
  return next;
}
bool ScheduledUpdates::due_locked(double current) {
  bool due = false;
  while (!_timers.empty() && _timers.top() <= current) {
    due = true;
    _timers.pop();
  }
  if (_period > 0 && _periodic_at <= current) {
    due          = true;
    _periodic_at = current + _period;
  }
  return due;
}
bool ScheduledUpdates::poll_due() {
  bool due;
  {
    std::lock_guard lock(_mutex);
    due = due_locked(_clock());
  }
  if (due) _notify();
  return due;
}
void ScheduledUpdates::run() {
  std::unique_lock lock(_mutex);
  while (_running) {
    if (due_locked(_clock())) {
      lock.unlock();
      _notify();
      lock.lock();
      continue;
    }
    auto next = next_locked();
    if (next) _cv.wait_for(lock, std::chrono::duration<double>(std::max(0.0, *next - _clock())));
    else _cv.wait(lock, [&] { return !_running || next_locked().has_value(); });
  }
}
