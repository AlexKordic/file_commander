
#include "file_io_jobs.hpp"
#include "fifo_queue.hpp"
#include "log.hpp"

#include <ftxui/component/screen_interactive.hpp>

#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <thread>

using boost::filesystem::copy_options;
using boost::system::error_code;

namespace Perun {

constexpr int64_t LARGE_FILE_SIZE_FROM     = 10 * 1024 * 1024;  // 10MB
constexpr auto    PROGRESS_UPDATE_INTERVAL = std::chrono::milliseconds(200);

JobInterface::JobInterface() {
  updated = []() {
    auto screen = ftxui::ScreenInteractive::Active();
    if (screen) screen->PostEvent(ftxui::Event::Custom);
  };
}

//
// Calculate progress and throughput
//
ProgressInfo::ProgressInfo() {
  start_ts = now();
  last_ts  = start_ts;
}

bool ProgressInfo::update(int64_t new_size, int64_t source_size) {
  if (new_size == current_size) return false;
  double ts    = now();
  Mbps         = ((new_size - current_size) * 8 / 1000000.0) / (ts - last_ts);
  current_size = new_size;
  last_ts      = ts;
  percentage   = 100 * float(current_size) / source_size;
  average_Mbps = (current_size * 8 / 1000000.0) / (ts - start_ts);
  return true;
}

void JobSpec::_calculate_transfer_stats() {
  const bool current_index_valid = _current_item_index >= 0 && _current_item_index < _items.size();
  if (!current_index_valid) return;
  const DirItem& item = _items.at(_current_item_index);
  if (!item.symlink_ref()) return;
  const bool is_large_file   = item.size() > LARGE_FILE_SIZE_FROM;
  int64_t    bytes_processed = _bytes_processed;
  if (is_large_file) {
    // Only for large files we calculate precise progress
    error_code ec;
    int64_t    latest_size = file_size(*item.symlink_ref(), ec);
    // Expect `system:2` error on when file_size was invoked before copy creates a file
    if (ec.failed()) return;
    bytes_processed += latest_size;
    _current_item.update(latest_size, item.size());
  } else {
    _current_item.average_Mbps = _total.average_Mbps;
    _current_item.Mbps         = _total.Mbps;
    _current_item.percentage   = 0;
  }
  _total.update(bytes_processed, _bytes_total);
}

//
// Separate thread to notify UI about progress of file operations
// When Job have blocked on large item do a check for file size to get progress info for large files
//
class ProgressMonitor {
 public:
  ProgressMonitor() {
    _thread = std::thread([this]() { this->run(); });
  }
  ~ProgressMonitor() {
    stop();
    if (_thread.joinable()) _thread.join();
  }
  void stop() {
    _running = false;
    _condition.notify_all();
  }
  void add_job(std::shared_ptr<JobSpec> job) {
    {
      std::unique_lock lock(_m);
      _new_jobs.push_back(std::move(job));
    }
    _condition.notify_all();
  }

 protected:
  volatile bool _running = true;

  std::thread                           _thread;
  std::condition_variable               _condition;
  std::mutex                            _m;
  std::vector<std::shared_ptr<JobSpec>> _new_jobs;

  // not updated by other threads:
  std::vector<std::shared_ptr<JobSpec>> _jobs;

  void run() {
    while (_running) {
      {
        // collect new jobs
        std::unique_lock lock(_m);
        for (auto& job : _new_jobs) { _jobs.push_back(std::move(job)); }
        _new_jobs.clear();
        if (_jobs.empty()) {
          // suspend thread if no jobs
          while (_new_jobs.empty() && _running) { _condition.wait(lock); }
          continue;
        }
      }

      // Do update for each job and then sleep
      std::vector<JobSpec*> updated_jobs;
      for (auto it = _jobs.begin(); it != _jobs.end();) {
        auto&           job = *it;
        std::lock_guard lock(job->_m);
        if (job->is_stopped()) {
          it = _jobs.erase(it);
          continue;
        }
        // Check timing to proceed. This is to reduce number of updates and improve performance
        if (now() >= job->_last_progress_update_time + job->_progress_update_interval) {
          job->_last_progress_update_time = now();
          job->_calculate_transfer_stats();
          updated_jobs.push_back(job.get());
        }
        ++it;
      }
      for (auto job : updated_jobs) { job->updated(); }

      std::this_thread::sleep_for(PROGRESS_UPDATE_INTERVAL);
    }
  }
};

JobSpec::JobSpec(Type t, std::vector<DirItem> items) {
  _type  = t;
  _items = std::move(items);
  for (DirItem const& item : _items) {
    if (item.type() == boost::filesystem::regular_file) { _bytes_total += item.size(); }
  }
}

void JobInstructions::report_error(DirItem item, std::string message) {
  auto& inserted = _errors.emplace_back(item);
  inserted._set_warning(std::move(message));
}

struct DelayedUpdate {
  double interval = 0.2;
  double last_ts  = now();
  bool   is_time_to_update() {
    double ts = now();
    if (ts < last_ts + interval) return false;
    last_ts = ts;
    return true;
  }
};

struct DelayedUpdateDiscovery {
  double  interval     = 0.2;
  double  last_ts      = now();
  int64_t bytes_queued = 0;
  int64_t items_queued = 0;

  bool file_found(int64_t file_size, JobSpec* job) {
    double ts = now();
    bytes_queued += file_size;
    items_queued++;
    if (ts < last_ts + interval) return false;
    last_ts = ts;
    flush(job);
    return true;
  }
  void flush(JobSpec* job) {
    {
      std::lock_guard lock(job->_m);
      job->_bytes_total += bytes_queued;
      job->_items_pending += items_queued;
      bytes_queued = 0;
      items_queued = 0;
    }
    job->updated();
  }
};

struct DelayedUpdateDelete {
  double               interval = 0.1;
  double               last_ts  = now();
  std::vector<DirItem> items_deleted;

  void file_deleted(DirItem file, JobSpec* job) {
    double ts = now();
    // bytes_queued += std::max(0ll, file.size());
    items_deleted.push_back(std::move(file));
    if (ts < last_ts + interval) return;
    last_ts = ts;
    flush(job);
  }
  void flush(JobSpec* job) {
    {
      std::lock_guard lock(job->_m);
      for (auto& item : items_deleted) {
        job->_bytes_processed += std::max(0ll, item.size());
        job->_items.emplace_back(std::move(item));
      }
      job->_current_item_index = job->_items.size() - 1;
    }
    items_deleted.clear();
    job->updated();
  }
};

class ThreadedFileJobs : public FileJobs {
 public:
  ThreadedFileJobs() {
    _thread = std::thread([this]() { this->run(); });
  }
  virtual ~ThreadedFileJobs() {
    _queue.close();
    _thread.join();
  }
  uint64_t add_job(std::shared_ptr<JobSpec> job) override {
    uint64_t id    = _next_job_id.fetch_add(1);
    job->_job_id   = id;
    job->_queued_time = now();
    _queue.push(std::move(job));
    return id;
  }
  JobError cancel_job(JobSpec* job) override {
    if (!job) return JobError::NOT_FOUND;
    job->_cancel_requested = true;
    return JobError::OK;
  }
  RunningJobsInfo get_running_job() override {
    std::shared_ptr<JobSpec> active;
    {
      std::lock_guard lock(_m);
      active = _active_job;
    }
    return {std::move(active), _queue.size()};
  }

  void drain_completed_jobs() override {
    std::shared_ptr<JobSpec> job;
    while (_completed_queue.try_pop(job) == FifoError::OK) {
      // Step 2: just drain to prevent accumulation.
      // Future steps add: summaries, inspectable jobs, scripting events.
    }
  }

  std::deque<JobErrorInfo> get_errors(int count) override {
    std::deque<JobErrorInfo> r;
    std::lock_guard          lock(_m);
    int                      i = 0;
    for (auto it = _errors.rbegin(); it != _errors.rend(); ++it, ++i) {
      if (i >= count) break;
      r.push_back(*it);
    }
    return r;
  }

  JobErrorInfo get_error(int64_t i) override {
    std::lock_guard lock(_m);
    if (_errors.empty()) return JobErrorInfo();
    return _errors.at(i);
  }

  ftxui::DataSize dataset_size() override {
    std::lock_guard lock(_m);
    return {static_cast<int64_t>(_errors.size()), 0, static_cast<int64_t>(_errors.size() - 1)};
  }
  int64_t count_items_before(int64_t i) override { return i; }
  bool    move_id_by(int64_t& i, int64_t offset) override {
    std::lock_guard lock(_m);
    const int64_t   initial = i;
    const int64_t   size    = static_cast<int64_t>(_errors.size());
    if (size == 0) return false;
    i = std::max(0LL, std::min(i + offset, size - 1));
    // return false when offset would go out of bounds.
    return i != initial;
  }

  void report_error(std::string message) override {
    constexpr double epsilon = 0.00001;
    std::lock_guard  lock(_m);
    double           time = now();
    if (!_errors.empty() && time <= _errors.back().time) {
      // Creating always increasing time order, giving each error unique time
      time = _errors.back().time + epsilon;
    }
    _errors.emplace_back(std::move(message), time);
  }

  void clear_errors() override {
    std::lock_guard lock(_m);
    _errors.clear();
    _err_last_access_index = 0;
  }

 private:
  void run() {
    while (true) {
      std::shared_ptr<JobSpec> job;
      FifoError                err = _queue.pop(job);
      if (err == FifoError::Destroyed) { break; }
      job->_started_time = now();
      job->_state        = JobState::RUNNING;
      job->_total        = ProgressInfo();
      {
        std::lock_guard lock(_m);
        _active_job = std::move(job);
      }
      _progress_monitor.add_job(_active_job);
      switch (_active_job->_type) {
      case JobSpec::Type::COPY: run_copy(_active_job.get()); break;
      case JobSpec::Type::MOVE: run_move(_active_job.get()); break;
      case JobSpec::Type::DELETE: run_delete(_active_job.get()); break;
      }
      _active_job->_finished_time = now();
      // Determine final state (if not already set by pause/cancel in future steps)
      if (_active_job->_state == JobState::RUNNING) {
        _active_job->_state = _active_job->_errors.empty()
          ? JobState::COMPLETED
          : JobState::COMPLETED_WITH_ERRORS;
      }
      // Transfer to completed queue for UI to drain
      _completed_queue.push(_active_job);
      _active_job->updated();
    }
  }

  void _discover_files(JobSpec* job, std::vector<DirItem>& items, FifoQueue<DirItem>& files, DelayedUpdateDiscovery& update) {
    error_code ec;
    for (DirItem const& item : items) {
      if (item.type() == boost::filesystem::file_type::directory_file) {
        std::vector<DirItem> subdir_items;
        for (boost::filesystem::directory_entry& subdir_item : boost::filesystem::directory_iterator(item.path_ref(), ec)) { subdir_items.emplace_back(DirItem(subdir_item.path())); }
        _discover_files(job, subdir_items, files, update);
        // push parent dir item last
      }
      update.file_found(std::max(0ll, item.size()), job);
      files.push(item);
    }
  }

  void run_delete(JobSpec* job) {
    FifoQueue<DirItem>   files;
    std::vector<DirItem> initial_items;
    {
      std::lock_guard lock(job->_m);
      initial_items = std::move(job->_items);
      job->_items.clear();
    }
    // discovery thread.
    std::thread         discovery_thread([job, &initial_items, &files, this]() {
      DelayedUpdateDiscovery update;
      job->_items_pending = 0;
      _discover_files(job, initial_items, files, update);
      update.flush(job);
      files.close();
    });
    // delete thread.
    DelayedUpdateDelete update;
    error_code          ec;
    while (true) {
      if (job->_cancel_requested.load(std::memory_order_relaxed)) {
        job->_state = JobState::CANCELLED;
        files.close();  // signal discovery thread to stop
        break;
      }
      DirItem   item("", boost::filesystem::file_type::status_error, boost::filesystem::perms::no_perms);
      FifoError err = files.pop(item);
      if (err == FifoError::Destroyed) { break; }
      boost::filesystem::remove(item.path_ref(), ec);
      if (ec.failed()) {
        file_operations().report_error("[Delete] " + item.path_ref().native());
        std::lock_guard lock(job->_m);
        job->report_error(item, "Failed to delete file: " + ec.message());
      }
      update.file_deleted(item, job);
    }
    update.flush(job);
    if (discovery_thread.joinable()) discovery_thread.join();
  }

  void run_move(JobSpec* job) {
    DelayedUpdate update;
    for (int i = 0; i < job->_items.size(); i++) {
      if (job->_cancel_requested.load(std::memory_order_relaxed)) {
        job->_state = JobState::CANCELLED;
        return;
      }
      auto&      item = job->_items.at(i);
      error_code ec;
      boost::filesystem::rename(item.path_ref(), *item.symlink_ref(), ec);
      if (ec.value() == boost::system::errc::cross_device_link) {
        // We need to copy instead of move.
        copy_options op = copy_options::overwrite_existing | copy_options::recursive | copy_options::copy_symlinks;
        boost::filesystem::copy(item.path_ref(), *item.symlink_ref(), op, ec);
        if (ec.failed()) {
          file_operations().report_error("[Move copy cross_device_link] " + item.path_ref().native());
          std::lock_guard lock(job->_m);
          job->report_error(item, "Failed to copy file: " + ec.message());
          continue;
        }
        // now delete original
        boost::filesystem::remove_all(item.path_ref(), ec);
        if (ec.failed()) {
          file_operations().report_error("[Move remove source cross_device_link] " + item.path_ref().native());
          std::lock_guard lock(job->_m);
          job->report_error(item, "Failed to remove source file: " + ec.message());
          continue;
        }
      }
      if (ec.failed()) {
        // "Failed to move file: Cross-device link"
        file_operations().report_error("[Move] " + item.path_ref().native());
        std::lock_guard lock(job->_m);
        job->report_error(item, "Failed to move file: " + ec.message());
      }

      if (update.is_time_to_update()) {
        {
          std::lock_guard lock(job->_m);
          job->_current_item_index = i;
        }
        job->updated();
      }
    }
  }

  void set_transfer_rate(uint64_t bytes_per_second) override {
    _transfer_rate = bytes_per_second;
  }

  void run_copy(JobSpec* job) {
    error_code       ec;
    std::unique_lock lock(job->_m);
    // _job->_items is not to be modified by other threads
    for (auto& item : job->_items) {
      if (job->_cancel_requested.load(std::memory_order_relaxed)) {
        job->_state = JobState::CANCELLED;
        return;
      }
      Defer update_progress([&]() { job->_current_item_index++; });
      // if type is dir path is to be mkdired
      // if type is link path is where to place link and symlink_ref is link target
      // else path is source file and symlink_ref is destination file for copy operation
      if (item.type() == boost::filesystem::file_type::status_error) { continue; }
      if (item.type() == boost::filesystem::file_type::directory_file) {
        lock.unlock();
        boost::filesystem::create_directory(item.path_ref(), ec);
        if (ec.failed()) file_operations().report_error("[mkdir] " + item.path_ref().native());
        lock.lock();
        if (ec.failed()) {
          // report error
          job->report_error(item, "Failed to create directory: " + ec.message());
          // also all items going into this dir may fail now, but we will let them error out individually
        }
        continue;
      }
      if (item.type() == boost::filesystem::file_type::symlink_file) {
        if (!item.symlink_ref()) {
          job->report_error(item, "Symlink target not set");
          lock.unlock();
          if (ec.failed()) file_operations().report_error("[Symlink target not set] " + item.path_ref().native());
          lock.lock();
          continue;
        }
        lock.unlock();
        // create_symlink(target, link_path): creates link_path pointing to target
        // item.path_ref()    = where to create the new symlink (link_path)
        // item.symlink_ref() = what the symlink points to (target)
        boost::filesystem::create_symlink(*item.symlink_ref(), item.path_ref(), ec);
        if (ec.failed()) file_operations().report_error("[symlink] " + item.path_ref().native());
        lock.lock();
        if (ec.failed()) {
          // report error
          job->report_error(item, "Failed to create symlink: " + ec.message());
        }
        continue;
      }
      // else path is source file and target is destination file for copy operation
      // this operation is blocking. progress will be updated by separate thread.
      job->_current_item = ProgressInfo();
      lock.unlock();
      boost::filesystem::copy_file_options cfo;
      cfo.options = copy_options::overwrite_existing;
      cfo.bytes_per_second = _transfer_rate;  // TODO: make configurable per-job
      cfo.cancel_requested = &job->_cancel_requested;
      boost::filesystem::copy_file(item.path_ref(), *item.symlink_ref(), cfo, ec);
      if (ec.failed() && job->_cancel_requested.load(std::memory_order_relaxed)) {
        // Cancel during copy_file — boost already removed partial dest file.
        // Don't report as an error; set CANCELLED and exit.
        lock.lock();
        job->_state = JobState::CANCELLED;
        return;
      }
      if (ec.failed()) file_operations().report_error("[Copy] " + item.path_ref().native());
      lock.lock();
      if (ec.failed()) {
        job->report_error(item, "Failed to copy file: " + ec.message());
        job->_bytes_total -= item.size();
      } else {
        job->_bytes_processed += item.size();
      }
      job->_total.update(job->_bytes_processed, job->_bytes_total);
      // invoke callback
      if (now() > job->_last_progress_update_time + job->_progress_update_interval) {
        job->_last_progress_update_time = now();
        lock.unlock();
        job->updated();
        lock.lock();
      }
    }
  }

  std::shared_ptr<JobSpec>                   _active_job;
  Perun::FifoQueue<std::shared_ptr<JobSpec>> _queue;
  Perun::FifoQueue<std::shared_ptr<JobSpec>> _completed_queue;
  std::atomic<uint64_t>                      _next_job_id{1};
  std::deque<JobErrorInfo>                   _errors;
  int64_t                                    _err_last_access_index = 0;

  ProgressMonitor _progress_monitor;

  // TODO: use map of thread pools, with configured sizes for each device. NVMe devices should have more threads than HDDs.
  std::thread _thread;
  std::mutex  _m;

  std::atomic<uint64_t> _transfer_rate{0};
};

FileJobs& file_operations() {
  static ThreadedFileJobs jobs;
  return jobs;
}

}  // namespace Perun
