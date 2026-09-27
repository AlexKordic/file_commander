#pragma once
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <vector>

struct ApplicationEvent {
  uint64_t    sequence = 0, request_id = 0;
  std::string name, detail;
};
class ApplicationEvents {
  std::mutex                   mutex;
  std::deque<ApplicationEvent> events;
  uint64_t                     sequence = 0;

 public:
  void publish(std::string name, std::string detail = {}, uint64_t request = 0) {
    std::lock_guard lock(mutex);
    events.push_back({++sequence, request, std::move(name), std::move(detail)});
    while (events.size() > 4096) events.pop_front();
  }
  std::vector<ApplicationEvent> since(uint64_t& cursor) {
    std::lock_guard               lock(mutex);
    std::vector<ApplicationEvent> out;
    if (!events.empty() && cursor + 1 < events.front().sequence) out.push_back({events.front().sequence - 1, 0, "event_history_expired", "resync application state"});
    for (const auto& event : events)
      if (event.sequence > cursor) out.push_back(event);
    cursor = sequence;
    return out;
  }
};
