#ifndef _PERUN_FILE_IO_H_
#define _PERUN_FILE_IO_H_

#include "commander.hpp"
#include "archive.hpp"
#include "fifo_queue.hpp"

#include <ftxui/component/component_options.hpp>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <vector>

namespace Perun {

enum class CopyConflictMode {
  Replace,
  Update,
  Skip,
};

enum class JobState {
  QUEUED,
  RUNNING,
  PAUSED,
  CANCELLED,
  COMPLETED,
  COMPLETED_WITH_ERRORS,
};

struct ProgressInfo {
  int64_t current_size = 0;
  double  start_ts;
  double  last_ts;

  float Mbps         = 0;
  float average_Mbps = 0;
  float percentage   = 0;

  ProgressInfo();
  bool update(int64_t new_size, int64_t source_size);
};

struct JobInstructions {
  enum class Type { COPY, MOVE, DELETE, ARCHIVE_CREATE };

  Type                 _type;
  std::vector<DirItem> _items;
  std::vector<DirItem> _errors;
  CopyConflictMode     _copy_conflict = CopyConflictMode::Replace;

  void report_error(DirItem item, std::string message);
};
struct JobStats {
  std::atomic<JobState> _state{JobState::QUEUED};

  // use this index to find current item in _items vector and display file name and path
  int          _current_item_index = 0;
  int64_t      _items_done = 0; // finalized attempts, including failed/skipped
  int64_t      _items_failed = 0;
  int64_t      _items_skipped = 0;
  ProgressInfo _current_item;
  ProgressInfo _total;
  int64_t      _items_pending = -1;

  // Reducing update frequency logic:
  double       _last_progress_update_time = 0;
  const double _progress_update_interval  = 0.2;

  double _queued_time     = -1;
  double _started_time    = -1;
  double _finished_time   = -1;
  double _bytes_processed = 0;
  double _bytes_total     = 0;
};
// Published under the job mutex; observers retain an immutable view for a frame.
struct JobSnapshot : JobInstructions, JobStats {
  uint64_t _job_id = 0;
  int64_t item_count() const { return _items_pending > 0 ? _items_pending : _items.size(); }
  bool is_stopped() const { return _finished_time > 0; }
};

struct JobInterface {
  std::mutex            _m;
  // interface for updating UI
  std::function<void()> updated;

  JobInterface();
};

// Specifies single operation to be performed on a set of files.
// Operation steps are defined in advance and FileJobs will execute them in order
struct JobSpec : JobInstructions, JobStats, JobInterface {
  std::vector<ArchiveLease> _archive_leases;
  uint64_t           _job_id = 0;
  std::atomic<bool>  _cancel_requested{false};
  std::atomic<uint64_t> _copy_bytes{0};
  std::atomic<bool> _stopped{false};
  std::atomic<bool>  _pause_requested{false};
  std::condition_variable _pause_cv;

  JobSpec(Type t, std::vector<DirItem> items, CopyConflictMode copy_conflict = CopyConflictMode::Replace);

  int64_t item_count() const { return _items_pending > 0 ? _items_pending : _items.size(); }
  // Not in FileJobs books
  bool    is_stopped() const { return _stopped.load(std::memory_order_acquire); };
  std::shared_ptr<const JobSnapshot> snapshot();

  void _calculate_transfer_stats();
};

// If your job is not listed then its completed or canceled. Check your books.
// struct JobList {
//   std::vector<std::shared_ptr<JobSpec>> in_progress;
// };

enum class JobError {
  OK,
  NOT_FOUND,
  CANCELLED,
};

struct RunningJobsInfo {
  std::shared_ptr<JobSpec> job;  // will this be list of jobs soon?
  int64_t                  queued_jobs = 0;
};

struct JobErrorInfo {
  std::string message;
  double      time = -1.0;

  bool valid() const { return time != -1.0; }
};

struct JobEvent {
  uint64_t sequence;
  uint64_t job_id;
  bool completed;
};

// Manages a queue of file operation jobs to be performed in separate thread.
// Jobs are executed in order and can be cancelled.
// When a job is cancelled or completed reference to it is removed.
// Caller needs to keep track of job history if needed.
class FileJobs {
 public:
  virtual ~FileJobs() = default;
  virtual void shutdown() = 0;
  virtual void set_update_sink(std::function<void()> sink) = 0;

  // Add a new job to the queue. Returns assigned job ID.
  virtual uint64_t add_job(std::shared_ptr<JobSpec> job) = 0;
  virtual JobError cancel_job(JobSpec* job)              = 0;
  virtual JobError pause_job(JobSpec* job)               = 0;

  virtual RunningJobsInfo get_running_job() = 0;
  virtual bool idle() const = 0;
  virtual std::vector<JobEvent> events_since(uint64_t& sequence) = 0;

  /// Get all jobs in history (completed, paused, cancelled, errored).
  virtual std::vector<std::shared_ptr<JobSpec>> get_job_history() = 0;

  /// Dismiss (remove) a job from history by ID.
  virtual void dismiss_job(uint64_t job_id) = 0;
  // TODO: review later
  virtual void set_transfer_rate(uint64_t bytes_per_second) = 0;

  virtual std::deque<JobErrorInfo> get_errors(int count) = 0;

  virtual JobErrorInfo get_error(int64_t i) = 0;
  virtual ftxui::DataSize dataset_size() = 0;
  virtual int64_t count_items_before(int64_t i) = 0;
  virtual bool move_id_by(int64_t& i, int64_t delta) = 0;

  virtual void report_error(std::string message) = 0;
  virtual void clear_errors()                    = 0;
};

// Copy into an owned sibling staging tree, commit, then remove the source.
// Cancellation before commit preserves both source and previous destination.
bool move_by_copy(const Filepath& source, const Filepath& destination,
                  const boost::filesystem::copy_file_options& options, boost::system::error_code& ec);
std::unique_ptr<FileJobs> make_file_jobs();
FileJobs& file_operations();

}  // namespace Perun

#endif  // _PERUN_FILE_IO_H_
