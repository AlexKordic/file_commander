#pragma once
#include "bfs.hpp"
#include <functional>
#include <memory>
#include <vector>
namespace RemoteFS { struct Entry; }

namespace Perun {
struct JobSpec;
struct JobSnapshot;
struct Operation;
enum class JobState;

class TransferJournal {
  struct Impl;
  std::unique_ptr<Impl> impl;
  explicit TransferJournal(std::unique_ptr<Impl>);
 public:
  ~TransferJournal();
  static std::shared_ptr<TransferJournal> create(const Filepath& directory, const JobSpec&);
  static std::vector<std::shared_ptr<JobSpec>> restore(const Filepath& directory,
      uint64_t& next_id, const std::function<void(std::string)>& error);
  void begin_step(size_t index);
  // Look-ahead staging is recorded before any data is sent. Only the ordered
  // commit worker activates a step; future files never advance the prefix.
  void stage_pending(size_t index, const Filepath& stage);
  void directory_pending(size_t index, const Filepath& destination);
  bool owns_pending_directory(size_t index) const;
  void pending_phase(size_t index, const char* phase);
  void prepare_inputs();            // Remote inspection belongs on the worker, never startup/UI.
  int64_t operation_bytes(size_t index) const;
  int64_t total_bytes() const;
  std::vector<RemoteFS::Entry> source_entries(size_t index) const;
  static std::vector<RemoteFS::Entry> snapshot_source(const Operation&);
  void validate_source(size_t index) const;
  void refresh_inputs(size_t index); // After an earlier operation changed this step's namespace.
  void finish_step(const JobSpec&); // job mutex held
  void checkpoint(const JobSnapshot&, JobState, bool force = true);
  // Only explicit Resume calls this: validate remaining work, reconcile proven
  // commits, then remove an owned incomplete staging tree when it is safe.
  void prepare_resume(JobSpec&); // job mutex held
  void prepare_copy_directories(std::vector<Operation>&);
  bool cleanup_pending() const;
  void cleanup_committed_staging(); // Identity checked; only an empty directory is removed.
  int transaction(const char* phase, const Filepath& stage, const Filepath& destination,
                  const std::vector<RemoteFS::Entry>* verified = nullptr);
  int remove_source(const Filepath& source, const Filepath& destination,
                    const boost::filesystem::copy_file_io_hooks* io = nullptr);
  void dismiss();
};
}
