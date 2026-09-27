
#include "file_io_jobs.hpp"
#include "archive.hpp"
#include "fifo_queue.hpp"
#include "log.hpp"

#include <ftxui/component/screen_interactive.hpp>

#include <algorithm>
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

std::shared_ptr<const JobSnapshot> JobSpec::snapshot() {
  std::lock_guard lock(_m);
  auto view = std::make_shared<JobSnapshot>();
  static_cast<JobInstructions&>(*view) = static_cast<const JobInstructions&>(*this);
  view->_job_id = _job_id;
  view->_state = _state.load();
  view->_current_item_index = _current_item_index;
  view->_current_item = _current_item;
  view->_total = _total;
  view->_items_pending = _items_pending;
  view->_queued_time = _queued_time;
  view->_started_time = _started_time;
  view->_finished_time = _finished_time;
  view->_bytes_processed = _bytes_processed;
  view->_bytes_total = _bytes_total;
  return view;
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
    const int64_t latest_size = _copy_bytes.load(std::memory_order_relaxed);
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
    { std::lock_guard lock(_m); _running = false; }
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
  std::atomic<bool> _running{true};

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
        if (job->_state.load() == JobState::PAUSED) {
          ++it;
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

JobSpec::JobSpec(Type t, std::vector<DirItem> items, CopyConflictMode copy_conflict) {
  _type          = t;
  _items         = std::move(items);
  _copy_conflict = copy_conflict;
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
    // bytes_queued += std::max(int64_t{0}, file.size());
    items_deleted.push_back(std::move(file));
    if (ts < last_ts + interval) return;
    last_ts = ts;
    flush(job);
  }
  void flush(JobSpec* job) {
    {
      std::lock_guard lock(job->_m);
      for (auto& item : items_deleted) {
        job->_bytes_processed += std::max(int64_t{0}, item.size());
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
  ~ThreadedFileJobs() override { shutdown(); }
  void shutdown() override {
    std::call_once(_shutdown_once, [this] {
      _shutdown = true;
      _queue.close();
      {
        std::lock_guard lock(_m);
        if (_active_job) cancel_job(_active_job.get());
      }
      if (_thread.joinable()) _thread.join();
      _progress_monitor.stop();
    });
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
    job->_pause_cv.notify_all();
    return JobError::OK;
  }
  JobError pause_job(JobSpec* job) override {
    if (!job) return JobError::NOT_FOUND;
    const bool was_paused = job->_pause_requested.load(std::memory_order_relaxed);
    const bool pause_now  = !was_paused;
    bool       notify_ui  = false;
    job->_pause_requested.store(pause_now, std::memory_order_relaxed);

    if (pause_now) {
      // Make pause observable immediately in UI/state APIs.
      if (job->_state.load(std::memory_order_relaxed) == JobState::RUNNING) {
        job->_state = JobState::PAUSED;
        notify_ui   = true;
      }
    } else {
      // Resume and wake workers that are waiting at a pause checkpoint.
      if (job->_state.load(std::memory_order_relaxed) == JobState::PAUSED) {
        job->_state = JobState::RUNNING;
        notify_ui   = true;
      }
      job->_pause_cv.notify_all();
    }

    if (notify_ui) { job->updated(); }
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

  std::vector<std::shared_ptr<JobSpec>> get_job_history() override {
    std::lock_guard lock(_m);
    return _job_history;
  }

  void dismiss_job(uint64_t job_id) override {
    std::lock_guard lock(_m);
    _job_history.erase(
      std::remove_if(_job_history.begin(), _job_history.end(),
        [job_id](const auto& j) { return j->_job_id == job_id; }),
      _job_history.end());
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
    i = std::max(int64_t{0}, std::min(i + offset, size - 1));
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
      {
        std::lock_guard lock(job->_m);
        job->_started_time = now();
        job->_state = JobState::RUNNING;
        job->_total = ProgressInfo();
      }
      {
        std::lock_guard lock(_m);
        _active_job = std::move(job);
        if (_shutdown.load()) _active_job->_cancel_requested = true;
      }
      _progress_monitor.add_job(_active_job);
      if (_active_job->_cancel_requested.load()) {
        _active_job->_state = JobState::CANCELLED;
      } else switch (_active_job->_type) {
      case JobSpec::Type::COPY: run_copy(_active_job.get()); break;
      case JobSpec::Type::MOVE: run_move(_active_job.get()); break;
      case JobSpec::Type::DELETE: run_delete(_active_job.get()); break;
      case JobSpec::Type::ARCHIVE_CREATE: run_archive_create(_active_job.get()); break;
      }
      {
        std::lock_guard lock(_active_job->_m);
        _active_job->_finished_time = now();
        // Determine final state (if not already set by pause/cancel in future steps)
        if (_active_job->_state == JobState::RUNNING) {
          _active_job->_state = _active_job->_errors.empty()
            ? JobState::COMPLETED
            : JobState::COMPLETED_WITH_ERRORS;
        }
        _active_job->_stopped.store(true, std::memory_order_release);
      }
      // Store in job history directly (under _m, which we already use for _active_job)
      {
        std::lock_guard lock(_m);
        _job_history.push_back(_active_job);
      }
      _active_job->updated();
    }
  }

  void _discover_files(JobSpec* job, std::vector<DirItem>& items, FifoQueue<DirItem>& files, DelayedUpdateDiscovery& update) {
    error_code ec;
    for (DirItem const& item : items) {
      // Inspect the entry itself: a directory symlink must be unlinked, never
      // traversed. Recheck here instead of trusting an earlier followed stat.
      const auto entry_status = boost::filesystem::symlink_status(item.path_ref(), ec);
      if (ec.failed()) {
        std::lock_guard lock(job->_m);
        job->report_error(item, "Failed to inspect deletion target: " + ec.message());
        continue;
      }
      if (boost::filesystem::is_directory(entry_status)) {
        std::vector<DirItem> subdir_items;
        for (boost::filesystem::directory_entry& subdir_item : boost::filesystem::directory_iterator(item.path_ref(), ec)) { subdir_items.emplace_back(DirItem(subdir_item.path())); }
        _discover_files(job, subdir_items, files, update);
        // push parent dir item last
      }
      update.file_found(std::max(int64_t{0}, item.size()), job);
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
      job->_items_pending = 0;
    }
    // discovery thread.
    std::thread         discovery_thread([job, &initial_items, &files, this]() {
      DelayedUpdateDiscovery update;
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
      if (!wait_for_resume(job)) {
        files.close();
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
      if (!wait_for_resume(job)) {
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

  void run_archive_create(JobSpec* job) {
    if (job->_items.empty()) {
      job->_state = JobState::COMPLETED_WITH_ERRORS;
      return;
    }

    Filepath archive_path;
    if (job->_items.front().symlink_ref()) archive_path = *job->_items.front().symlink_ref();
    if (archive_path.empty()) {
      file_operations().report_error("[Archive create] destination missing");
      std::lock_guard lock(job->_m);
      job->report_error(job->_items.front(), "Archive destination not set");
      return;
    }

    std::vector<Filepath> sources;
    sources.reserve(job->_items.size());
    for (const auto& item : job->_items) {
      if (job->_cancel_requested.load(std::memory_order_relaxed)) {
        job->_state = JobState::CANCELLED;
        return;
      }
      if (!wait_for_resume(job)) return;
      sources.push_back(item.path_ref());
      {
        std::lock_guard lock(job->_m);
        job->_current_item_index = static_cast<int>(sources.size()) - 1;
      }
      job->updated();
    }

    Filepath preferred_cwd = sources.front().parent_path();
    const auto conflict = job->_copy_conflict == CopyConflictMode::Skip ? ArchiveConflict::Skip
      : job->_copy_conflict == CopyConflictMode::Update ? ArchiveConflict::Update : ArchiveConflict::Replace;
    Err err = archive_service().create_archive(archive_path, sources, preferred_cwd, conflict);
    if (!err.ok()) {
      file_operations().report_error("[Archive create] " + err.steps.front());
      std::lock_guard lock(job->_m);
      job->report_error(job->_items.front(), err.steps.front());
    }
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
      if (!wait_for_resume_locked(job, lock)) {
        return;
      }
      Defer update_progress([&]() { job->_current_item_index++; });
      // if type is dir path is to be mkdired
      // if type is link path is where to place link and symlink_ref is link target
      // else path is source file and symlink_ref is destination file for copy operation
      if (item.type() == boost::filesystem::file_type::status_error) {
        const auto message = item.warning_ref().value_or("Discovery failed");
        job->report_error(item, message);
        lock.unlock();
        file_operations().report_error("[Discovery] " + item.path_ref().native() + ": " + message);
        lock.lock();
        continue;
      }
      if (item.type() == boost::filesystem::file_type::directory_file) {
        ec.clear();
        lock.unlock();
        boost::filesystem::create_directory(item.path_ref(), ec);
        if (ec.failed()) {
          error_code check_ec;
          const bool already_directory = boost::filesystem::is_directory(item.path_ref(), check_ec);
          if (!check_ec.failed() && already_directory) { ec.clear(); }
        }
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
          file_operations().report_error("[Symlink target not set] " + item.path_ref().native());
          continue;
        }
        ec.clear();
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
      if (!item.symlink_ref()) {
        job->report_error(item, "Copy destination not set");
        continue;
      }
      auto skip_current_file = [&]() {
        job->_bytes_total = std::max(0.0, job->_bytes_total - double(std::max(int64_t{0}, item.size())));
        job->_total.update(job->_bytes_processed, job->_bytes_total);
      };
      const Filepath destination_path = *item.symlink_ref();
      if (job->_copy_conflict != CopyConflictMode::Replace) {
        error_code exists_ec;
        const bool destination_exists = boost::filesystem::exists(destination_path, exists_ec);
        if (exists_ec.failed()) {
          job->report_error(item, "Failed to check destination: " + exists_ec.message());
          continue;
        }
        bool skip_file = false;
        if (destination_exists && job->_copy_conflict == CopyConflictMode::Skip) {
          skip_file = true;
        } else if (destination_exists && job->_copy_conflict == CopyConflictMode::Update) {
          error_code src_time_ec;
          error_code dst_time_ec;
          auto       src_time = boost::filesystem::last_write_time(item.path_ref(), src_time_ec);
          auto       dst_time = boost::filesystem::last_write_time(destination_path, dst_time_ec);
          if (src_time_ec.failed() || dst_time_ec.failed()) {
            job->report_error(item, "Failed to compare file times");
            continue;
          }
          skip_file = src_time <= dst_time;
        }
        if (skip_file) {
          skip_current_file();
          continue;
        }
      }
      // else path is source file and target is destination file for copy operation
      // this operation is blocking. progress will be updated by separate thread.
      job->_current_item = ProgressInfo();
      job->_copy_bytes = 0;
      ec.clear();
      lock.unlock();
      boost::filesystem::copy_file_options cfo;
      cfo.options = (job->_copy_conflict == CopyConflictMode::Skip)
        ? copy_options::none
        : copy_options::overwrite_existing;
      cfo.bytes_per_second = _transfer_rate;  // TODO: make configurable per-job
      cfo.cancel_requested = &job->_cancel_requested;
      cfo.bytes_copied = &job->_copy_bytes;
      boost::filesystem::copy_file(item.path_ref(), destination_path, cfo, ec);
      if (ec.failed() && job->_cancel_requested.load(std::memory_order_relaxed)) {
        // Cancel during copy_file — boost already removed partial dest file.
        // Don't report as an error; set CANCELLED and exit.
        lock.lock();
        job->_state = JobState::CANCELLED;
        return;
      }
      lock.lock();
      const bool exists_conflict = ec.failed() && job->_copy_conflict == CopyConflictMode::Skip
        && ec.value() == boost::system::errc::file_exists;
      if (exists_conflict) {
        skip_current_file();
      } else if (ec.failed()) {
        file_operations().report_error("[Copy] " + item.path_ref().native());
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
  std::atomic<uint64_t>                      _next_job_id{1};
  std::vector<std::shared_ptr<JobSpec>>      _job_history;  // drained completed/paused/cancelled jobs
  std::deque<JobErrorInfo>                   _errors;
  int64_t                                    _err_last_access_index = 0;

  ProgressMonitor _progress_monitor;

  // TODO: use map of thread pools, with configured sizes for each device. NVMe devices should have more threads than HDDs.
  std::thread _thread;
  std::mutex  _m;

  std::atomic<uint64_t> _transfer_rate{0};
  std::atomic<bool> _shutdown{false};
  std::once_flag _shutdown_once;

  static bool wait_for_resume(JobSpec* job) {
    if (!job->_pause_requested.load(std::memory_order_relaxed)) return true;

    std::unique_lock lock(job->_m);
    job->_state = JobState::PAUSED;
    lock.unlock();
    job->updated();
    lock.lock();
    job->_pause_cv.wait(lock, [job] {
      return !job->_pause_requested.load(std::memory_order_relaxed)
        || job->_cancel_requested.load(std::memory_order_relaxed);
    });
    if (job->_cancel_requested.load(std::memory_order_relaxed)) {
      job->_state = JobState::CANCELLED;
      return false;
    }
    job->_state = JobState::RUNNING;
    lock.unlock();
    job->updated();
    return true;
  }

  static bool wait_for_resume_locked(JobSpec* job, std::unique_lock<std::mutex>& lock) {
    if (!job->_pause_requested.load(std::memory_order_relaxed)) return true;
    job->_state = JobState::PAUSED;
    lock.unlock();
    job->updated();
    lock.lock();
    job->_pause_cv.wait(lock, [job] {
      return !job->_pause_requested.load(std::memory_order_relaxed)
        || job->_cancel_requested.load(std::memory_order_relaxed);
    });
    if (job->_cancel_requested.load(std::memory_order_relaxed)) {
      job->_state = JobState::CANCELLED;
      return false;
    }
    job->_state = JobState::RUNNING;
    lock.unlock();
    job->updated();
    lock.lock();
    return true;
  }
};

std::unique_ptr<FileJobs> make_file_jobs() { return std::make_unique<ThreadedFileJobs>(); }

FileJobs& file_operations() {
  static ThreadedFileJobs jobs;
  return jobs;
}

}  // namespace Perun
