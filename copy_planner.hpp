#pragma once
#include <mutex>
#include <thread>
#include "archive.hpp"
#include "operation.hpp"

struct CopyRequest {
  std::vector<Filepath>   sources;
  Filepath                destination;
  bool                    follow_links = false, preserve_relative_links = true;
  Perun::CopyConflictMode conflict = Perun::CopyConflictMode::Replace;
};
struct CopyDiscoveryProgress {
  int64_t     byte_count = 0, file_count = 0, dir_count = 0, link_count = 0, error_count = 0;
  std::string current_file, current_dir;
};
class CopyPlanner {
 public:
  explicit CopyPlanner(CopyRequest, std::function<void()> notify = [] {}, std::function<void(std::string, std::string, uint64_t)> emit = [](auto, auto, auto) {});
  ~CopyPlanner();
  CopyDiscoveryProgress                       get_progress();
  const CopyRequest&                          request() const { return _request; }
  std::shared_ptr<const Perun::OperationPlan> take_plan();
  std::vector<DirItem>                        take_items();  // Legacy consumer adapter.
  std::atomic<bool>                           _running{true};
  std::thread                                 _thread;
  uint64_t                                    _sequence_id = 0;

 protected:
  std::mutex            _m;
  Perun::OperationPlan  _plan;
  CopyDiscoveryProgress _progress;

 private:
  CopyRequest                                             _request;
  std::vector<ArchiveLease>                               _leases;
  std::function<void()>                                   _notify;
  std::function<void(std::string, std::string, uint64_t)> _emit;
  void                                                    run();
};
