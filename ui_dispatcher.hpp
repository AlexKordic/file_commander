#pragma once

#include <chrono>
#include <condition_variable>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>

// Application mailbox. Workers never access the terminal/screen lifecycle.
// Only its owner drains callbacks, on the UI thread. Copied senders are weak.
class UiDispatcher {
  struct State {
    std::mutex mutex;
    std::condition_variable wake;
    std::deque<std::function<void()>> tasks;
    bool suspended = false;
    bool closed = false;
    bool dirty = false;
  };
  std::shared_ptr<State> state = std::make_shared<State>();
 public:
  using Post = std::function<void(std::function<void()>)>;
  ~UiDispatcher() { close(); }
  Post poster() const {
    return [weak = std::weak_ptr<State>(state)](std::function<void()> task) {
      if (auto s = weak.lock()) {
        { std::lock_guard lock(s->mutex);
          if (s->closed) return;
          if (task) s->tasks.push_back(std::move(task));
          s->dirty = true;
        }
        s->wake.notify_one();
      }
    };
  }
  std::function<void()> notifier() const {
    return [post = poster()] { post({}); };
  }
  void suspend() { std::lock_guard lock(state->mutex); state->suspended = true; }
  void resume() {
    { std::lock_guard lock(state->mutex); state->suspended = false; }
    state->wake.notify_one();
  }
  bool drain() {
    std::deque<std::function<void()>> tasks;
    bool dirty;
    { std::lock_guard lock(state->mutex);
      if (state->closed || state->suspended) return false;
      dirty = state->dirty; state->dirty = false;
      tasks.swap(state->tasks);
    }
    for (auto& task : tasks) task();
    return dirty;
  }
  void wait(std::chrono::milliseconds maximum = std::chrono::milliseconds(16)) {
    std::unique_lock lock(state->mutex);
    state->wake.wait_for(lock, maximum, [&] { return state->closed || (!state->suspended && state->dirty); });
  }
  void close() {
    { std::lock_guard lock(state->mutex);
      state->closed = true; state->tasks.clear(); state->dirty = false;
    }
    state->wake.notify_all();
  }
};
