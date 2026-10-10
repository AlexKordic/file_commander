#pragma once

// State and workers behind dialogs, shared by every interface: copy
// discovery, Find, and palette ranking. Nothing here draws.

#include "copy_planner.hpp"
#include "traversal.hpp"

#include <atomic>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// A copy discovery that also exposes the planned steps for a preview list.
class CopySession : public CopyPlanner {
 public:
  using CopyPlanner::CopyPlanner;
  // Steps planned so far, as display items, from `from` on.
  std::vector<DirItem> preview(size_t from, size_t count);
  size_t               step_count();
};

// A recursive name search below one directory, on its own thread.
class FindSession {
 public:
  using Notify = std::function<void()>;
  using Emit   = std::function<void(std::string, std::string, uint64_t)>;
  FindSession(Notify notify, Emit emit);
  ~FindSession();
  // Empty when the search started; otherwise why it could not.
  std::string start(const Filepath& root, std::string pattern);
  void        stop();
  bool        running() const { return _running.load(); }
  bool        truncated() const { return _truncated.load(); }
  int64_t     dirs() const { return _dirs.load(); }
  int64_t     files() const { return _files.load(); }
  int64_t     errors() const { return _errors.load(); }
  uint64_t    sequence() const { return _sequence; }
  size_t      result_count();
  std::vector<Filepath> results(size_t from, size_t count);

 private:
  Notify                _notify;
  Emit                  _emit;
  std::thread           _worker;
  std::atomic<bool>     _running{false}, _truncated{false};
  std::atomic<int64_t>  _dirs{0}, _files{0}, _errors{0};
  uint64_t              _sequence = 0;
  std::mutex            _mutex;
  std::vector<Filepath> _results;
};

// Palette ranking: higher is better, -1 when the query doesn't match.
int palette_score(const std::string& query_lower, const std::string& text_lower);
std::string lower_ascii(std::string text);
