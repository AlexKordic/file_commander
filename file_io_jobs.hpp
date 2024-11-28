#ifndef _PERUN_FILE_IO_H_
#define _PERUN_FILE_IO_H_

#include "commander.hpp"
#include "fifo_queue.hpp"

#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <vector>

namespace Perun {

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
  enum class Type { COPY, MOVE, DELETE };

  Type                 _type;
  std::vector<DirItem> _items;
  std::vector<DirItem> _errors;

  void report_error(DirItem item, std::string message);
};
struct JobStats {
  // use this index to find current item in _items vector and display file name and path
  int          _current_item_index = 0;
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
struct JobInterface {
  std::mutex            _m;
  // interface for updating UI
  std::function<void()> updated;
};

// Specifies single operation to be performed on a set of files.
// Operation steps are defined in advance and FileJobs will execute them in order
struct JobSpec : JobInstructions, JobStats, JobInterface {
  JobSpec(Type t, std::vector<DirItem> items);

  int64_t item_count() const { return _items_pending > 0 ? _items_pending : _items.size(); }
  // Not in FileJobs books
  bool    is_stopped() const { return _started_time > 0 && _finished_time > 0; };

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
  double      time;
};

// Manages a queue of file operation jobs to be performed in separate thread.
// Jobs are executed in order and can be cancelled.
// When a job is cancelled or completed reference to it is removed.
// Caller needs to keep track of job history if needed.
class FileJobs {
 public:
  virtual ~FileJobs() = default;

  // Add a new job to the queue
  virtual FifoError add_job(std::shared_ptr<JobSpec> job) = 0;
  virtual JobError  cancel_job(JobSpec* job)              = 0;

  virtual RunningJobsInfo get_running_job() = 0;

  virtual std::deque<JobErrorInfo> get_errors(int count)              = 0;
  virtual std::deque<JobErrorInfo> get_errors(double after_this_time) = 0;

  virtual void report_error(std::string message) = 0;
  virtual void clear_errors()                    = 0;
};

FileJobs& file_operations();

}  // namespace Perun

#endif  // _PERUN_FILE_IO_H_