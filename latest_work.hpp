#pragma once

#include <atomic>
#include <condition_variable>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>

// One running request and at most one pending replacement. All work owns its
// inputs; UI publication must check the request token and recipient lifetime.
class LatestWork {
 public:
  using Token = std::shared_ptr<std::atomic<bool>>;
  using Work = std::function<void(const Token&)>;
  LatestWork() : _thread([this] { run(); }) {}
  ~LatestWork() { shutdown(); }
  void submit(Work work) {
    std::lock_guard lock(_mutex);
    if (_stopping) return;
    if (_token) _token->store(true);
    _token = std::make_shared<std::atomic<bool>>(false);
    _pending = std::move(work);
    _wake.notify_one();
  }
  void cancel() {
    std::lock_guard lock(_mutex);
    if (_token) _token->store(true);
    _pending = {};
  }
  void shutdown() {
    {
      std::lock_guard lock(_mutex);
      _stopping = true;
      if (_token) _token->store(true);
      _pending = {};
      _wake.notify_one();
    }
    if (_thread.joinable()) _thread.join();
  }
 private:
  void run() {
    for (;;) {
      Work work;
      Token token;
      {
        std::unique_lock lock(_mutex);
        _wake.wait(lock, [&] { return _stopping || bool(_pending); });
        if (_stopping) return;
        work = std::move(_pending);
        _pending = {};
        token = _token;
      }
      work(token);
    }
  }
  std::mutex _mutex;
  std::condition_variable _wake;
  Work _pending;
  Token _token;
  bool _stopping = false;
  std::thread _thread;
};
