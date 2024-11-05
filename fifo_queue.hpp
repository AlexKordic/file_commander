#ifndef _PERUN_QUEUE_HPP_
#define _PERUN_QUEUE_HPP_

#include <condition_variable>
#include <deque>
#include <limits>
#include <mutex>
#include <functional>

namespace Perun {

enum class FifoError {
  OK,
  Destroyed,
  Full,
  Empty,
  NotFound,
  Timeouted,
};

/*
### Overview
The `Perun::FifoQueue` class is a thread-safe, asynchronous message exchange queue that allows pushing and popping elements in a producer-consumer model. It provides both blocking and non-blocking operations for efficient management of concurrent workloads.

### Features
- **Thread-Safe Operations**: All operations on the queue are thread-safe, using a combination of `std::mutex` and `std::condition_variable` for synchronization.
- **Blocking and Non-Blocking Support**: The queue supports blocking (`push`, `pop`) and non-blocking (`try_push`, `try_pop`) operations, offering flexibility in managing tasks.
- **Customizable Maximum Size**: The maximum queue size can be set during instantiation. By default, it has no size limit.
- **Graceful Shutdown**: The queue can be closed using the `close()` method, which stops further operations and unblocks all threads waiting on the queue.
- **Timeout Support**: The `pop()` method has an overload that allows specifying a timeout, providing an upper limit on how long to wait for an element.
- **Conditional Erase**: Elements can be selectively removed from the queue using the `erase_if()` method, based on a predicate function.

### Public Methods

**Constructor**: `FifoQueue(int64_t max_size = std::numeric_limits<int64_t>::max())`
   - Initializes the queue with an optional maximum size. The default is no limit.

**Destructor**: `virtual ~FifoQueue() = default`
   - Default destructor for the queue.

**`FifoError try_push(const T& value)`**
   - Attempts to push a value to the queue without blocking.
   - Returns `FifoError::OK` on success, `FifoError::Full` if the queue is full, or `FifoError::Destroyed` if the queue is closed.

**`FifoError try_push(T&& value)`**
   - Moves a value into the queue without blocking.
   - Returns `FifoError::OK`, `FifoError::Full`, or `FifoError::Destroyed`.

**`FifoError push(const T& value)`**
   - Pushes a value to the queue, blocking if the queue is full until space is available.
   - Returns `FifoError::OK` or `FifoError::Destroyed` if the queue is closed.

**`FifoError push(T&& value)`**
   - Moves a value into the queue, blocking if the queue is full until space is available.
   - Returns `FifoError::OK` or `FifoError::Destroyed`.

**`FifoError try_pop(T& value)`**
   - Attempts to pop a value from the queue without blocking.
   - Returns `FifoError::OK` on success, `FifoError::Empty` if the queue is empty, or `FifoError::Destroyed` if the queue is closed.

**`FifoError pop(T& value)`**
   - Pops a value from the queue, blocking until an element is available.
   - Returns `FifoError::OK` or `FifoError::Destroyed`.

**`FifoError pop(T& value, std::chrono::milliseconds timeout)`**
   - Pops a value from the queue, blocking for a specified timeout.
   - Returns `FifoError::OK`, `FifoError::Timeouted` if the timeout expires, or `FifoError::Destroyed`.

**`void close()`**
    - Closes the queue, preventing further operations and unblocking all waiting threads.

**`FifoError get(T& value, std::function<bool(const T&)> f)`**
    - Searches the queue for an element that satisfies the given predicate function.
    - If a matching element is found, it is removed from the queue and assigned to `value`.
    - This method is useful when you need to find and remove a specific element based on custom criteria.
    - Returns `FifoError::OK` if an element is found and removed, or `FifoError::NotFound` if no matching element is found.

**`bool running()`**
    - Returns `true` if the queue is still valid for use, `false` if it has been closed.

**`void erase_if(std::function<bool(const T&)> f)`**
    - Removes elements from the queue that satisfy the provided predicate function.

**`int64_t size()`**
    - Returns the current number of elements in the queue.

**`FifoError get(T& value, std::function<bool(const T&)> f)`**
    - Searches the queue for an element that satisfies the given predicate function, removes it, and assigns it to `value` if found.
    - Returns `FifoError::OK` on success, or `FifoError::NotFound` if no matching element is found.

### Usage Example
```cpp
#include <iostream>
#include <thread>
#include <chrono>
#include "FifoQueue.h"

int main() {
    Perun::FifoQueue<int> queue(5); // Create a queue with a max size of 5

    // Producer thread
    std::thread producer([&queue]() {
        for (int i = 0; i < 10; ++i) {
            if (queue.push(i) == Perun::FifoError::OK) {
                std::cout << "Pushed: " << i << std::endl;
            } else {
                std::cout << "Failed to push: " << i << std::endl;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    });

    // Consumer thread
    std::thread consumer([&queue]() {
        for (int i = 0; i < 10; ++i) {
            int value;
            if (queue.pop(value, std::chrono::milliseconds(500)) == Perun::FifoError::OK) {
                std::cout << "Popped: " << value << std::endl;
            } else {
                std::cout << "Failed to pop." << std::endl;
            }
        }
    });

    producer.join();
    consumer.join();

    return 0;
}
```

### Error Handling
The `FifoQueue` class uses the `FifoError` enum to indicate the result of operations:
- `FifoError::OK`: Operation completed successfully.
- `FifoError::Destroyed`: The queue is closed, and no further operations are allowed.
- `FifoError::Full`: The queue is full (for non-blocking push operations).
- `FifoError::Empty`: The queue is empty (for non-blocking pop operations).
- `FifoError::NotFound`: No element matching the criteria was found.
- `FifoError::Timeouted`: Timeout occurred while waiting for an element.

### Thread Safety
- The `FifoQueue` class uses `std::mutex` to protect concurrent access to the internal storage (`_storage`).
- `std::condition_variable` is used to manage threads waiting to push to or pop from the queue, allowing efficient blocking and unblocking.

### Notes
- The `close()` method gracefully shuts down the queue, causing all ongoing and subsequent operations to fail with `FifoError::Destroyed`.
- The queue is implemented using a `std::deque<T>` to allow efficient push and pop operations from both ends.

### Limitations
- The queue does not provide priority-based access to elements.
- If the queue is closed while threads are blocked on `push()` or `pop()`, they will be unblocked, and the methods will return `FifoError::Destroyed`.
*/
template <typename T>
class FifoQueue {
public:
  FifoQueue(int64_t max_size = std::numeric_limits<int64_t>::max())
      : max_size(max_size) { }

  virtual ~FifoQueue() = default;
  
  FifoError try_push(T const& value) {
    {
      std::lock_guard guard(_lock);
      if(!_is_valid) return FifoError::Destroyed;
      if(_storage.size() >= max_size) return FifoError::Full;
      _storage.push_back(value);
    }
    _c_pop_blocking_on.notify_one();
    return FifoError::OK;
  }

  FifoError try_push(T&& value) {
    {
      std::lock_guard guard(_lock);
      if(!_is_valid) return FifoError::Destroyed;
      if(_storage.size() >= max_size) return FifoError::Full;
      _storage.emplace_back(std::move(value));
    }
    _c_pop_blocking_on.notify_one();
    return FifoError::OK;
  }

  FifoError push(T const& value) {
    {
      std::unique_lock guard(_lock);
      if(!_is_valid) return FifoError::Destroyed;
      while(_storage.size() >= max_size) {
        // Block until queue is consumed
        _c_push_blockin_on.wait(guard);
        if(!_is_valid) return FifoError::Destroyed;
      }
      _storage.push_back(value);
    }
    _c_pop_blocking_on.notify_one();
    return FifoError::OK;
  }

  FifoError push(T&& value) {
    {
      std::unique_lock guard(_lock);
      if(!_is_valid) return FifoError::Destroyed;
      while(_storage.size() >= max_size) {
        // Block until queue is consumed
        _c_push_blockin_on.wait(guard);
        if(!_is_valid) return FifoError::Destroyed;
      }
      _storage.push_back(std::move(value));
    }
    _c_pop_blocking_on.notify_one();
    return FifoError::OK;
  }

  [[nodiscard]] FifoError try_pop(T& value) {
    {
      std::lock_guard guard(_lock);
      if(!_is_valid) return FifoError::Destroyed;
      if(_storage.empty()) return FifoError::Empty;
      value = std::move(_storage.front());
      _storage.pop_front();
    }
    _c_push_blockin_on.notify_one();
    return FifoError::OK;
  }

  [[nodiscard]] FifoError pop(T& value) {
    {
      std::unique_lock guard(_lock);
      while(_storage.empty()) {
        if(!_is_valid) return FifoError::Destroyed;
        // will release lock in process of waiting and acquire again before return:
        _c_pop_blocking_on.wait(guard);
      }
      if(!_is_valid) return FifoError::Destroyed;
      value = std::move(_storage.front());
      _storage.pop_front();
    }
    _c_push_blockin_on.notify_one();
    return FifoError::OK;
  }

  [[nodiscard]] FifoError
  pop(T& value, std::chrono::milliseconds timeout) {
    {
      auto             deadline = std::chrono::steady_clock::now() + timeout;
      std::unique_lock guard(_lock);
      while(_storage.empty()) {
        if(!_is_valid) return FifoError::Destroyed;
        // will release lock in process of waiting and acquire again before return:
        if(std::cv_status::timeout == _c_pop_blocking_on.wait_until(guard, deadline)) {
          return FifoError::Timeouted;
        }
      }
      if(!_is_valid) return FifoError::Destroyed;
      value = std::move(_storage.front());
      _storage.pop_front();
    }
    _c_push_blockin_on.notify_one();
    return FifoError::OK;
  }

  // After invoking this method put raises exception and get raises exception on empty _storage
  void close() {
    {
      std::lock_guard guard(_lock);
      _is_valid = false;
    }
    _c_pop_blocking_on.notify_all();
    _c_push_blockin_on.notify_all();
  }

  bool running() {
    std::lock_guard guard(_lock);
    return _is_valid;
  }

  void erase_if(std::function<bool(const T&)> f) {
    std::lock_guard guard(_lock);
    std::erase_if(_storage, f);
  }

  int64_t size() {
    std::lock_guard guard(_lock);
    return _storage.size();
  }

  [[nodiscard]] FifoError get(T& value, std::function<bool(const T&)> f) {
    std::lock_guard guard(_lock);
    if(!_is_valid) return FifoError::Destroyed;
    // for (const T& el : _storage) {
    for (auto it = _storage.begin(); it != _storage.end(); ++it) {
      if(f(*it)) {
        value = std::move(*it);
        _storage.erase(it);
        return FifoError::OK;
      }
    }
    return FifoError::NotFound;
  }

  const int64_t max_size;

protected:
  std::mutex              _lock;
  std::condition_variable _c_pop_blocking_on, _c_push_blockin_on;
  std::deque<T>           _storage;
  volatile bool           _is_valid = true;
};

} // namespace Perun

#endif // _PERUN_QUEUE_HPP_