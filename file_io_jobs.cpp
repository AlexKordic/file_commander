#include "traversal.hpp"

#include "archive.hpp"
#include "fifo_queue.hpp"
#include "file_io_jobs.hpp"
#include "file_metadata.hpp"
#include "log.hpp"
#include "remote_fs.hpp"
#include "transfer_journal.hpp"

#include <algorithm>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <cerrno>
#include <fcntl.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <sys/stdio.h>
#elif defined(__linux__)
#include <sys/syscall.h>
#include <linux/fs.h>
#endif

using boost::filesystem::copy_options;
using boost::system::error_code;

namespace Perun {

constexpr int64_t LARGE_FILE_SIZE_FROM     = 10 * 1024 * 1024;  // 10MB
constexpr auto    PROGRESS_UPDATE_INTERVAL = std::chrono::milliseconds(200);

JobInterface::JobInterface() { updated = [] {}; }

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

std::shared_ptr<const JobSnapshot> JobSpec::snapshot(bool details) {
  std::lock_guard lock(_m);
  if (!details && _completed_summary) return _completed_summary;
  auto view = std::make_shared<JobSnapshot>();
  if (details) static_cast<JobInstructions&>(*view) = static_cast<const JobInstructions&>(*this);
  view->_recovery_note = _recovery_note;
  view->_type = _type; view->_copy_conflict = _copy_conflict; view->_plan = details ? _plan : nullptr;
  view->_item_count = _retained_item_count >= 0 ? _retained_item_count : _items.size(); view->_error_count = _error_count_total;
  view->_details_expired = _details_expired; if(details) view->_step_errors = _step_errors;
  if (_current_item_index >= 0 && _current_item_index < _items.size()) view->_focused_item = _items[_current_item_index];
  view->_job_id = _job_id;
  view->_state = _state.load();
  view->_current_item_index = _current_item_index;
  view->_items_done = _items_done;
  view->_items_failed = _items_failed;
  view->_items_skipped = _items_skipped;
  view->_current_item = _current_item;
  view->_total = _total;
  view->_items_pending = _items_pending;
  view->_queued_time = _queued_time;
  view->_started_time = _started_time;
  view->_finished_time = _finished_time;
  view->_bytes_processed = _bytes_processed;
  view->_bytes_total = _bytes_total;
  if (!details && is_stopped()) _completed_summary = view;
  return view;
}

void JobSpec::_calculate_transfer_stats() {
  const bool current_index_valid = _current_item_index >= 0 && _current_item_index < _items.size();
  if (!current_index_valid) return;
  const DirItem& item = _items.at(_current_item_index);
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
        if (job->is_stopped() || job->_recovery_waiting) {
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

JobSpec::JobSpec(Type t,std::vector<DirItem> items,CopyConflictMode conflict)
  : JobSpec(std::make_shared<const OperationPlan>(legacy_plan(t,items,conflict))) {}
JobSpec::JobSpec(std::shared_ptr<const OperationPlan> plan) {
  if(!plan) throw std::invalid_argument("missing operation plan");
  _plan=std::move(plan);_type=_plan->type;_copy_conflict=_plan->conflict;
  for(const auto& op:_plan->steps) {
    _items.push_back(operation_display(op));
    if(op.kind==Operation::Kind::CopyFile || op.kind==Operation::Kind::MoveEntry || op.kind==Operation::Kind::ArchiveInput) _bytes_total+=std::max(int64_t{0},op.bytes);
  }
}

void JobInstructions::report_error(DirItem item, std::string message) {
  ++_error_count_total;
  if (_errors.size() >= 1024) return;
  if (message.size()>65536) message.resize(65536);
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
      job->_items_done = job->_items.size();
      job->_current_item_index = static_cast<int>(job->_items_done);
    }
    items_deleted.clear();
    job->updated();
  }
};

namespace {
// Never emulate this with exists()+rename(): another creator can win between
// those calls. Unsupported filesystems must fail without replacing anything.
void rename_no_replace(const Filepath& source, const Filepath& destination, error_code& ec) {
  ec.clear();
#if defined(__APPLE__)
  if (::renamex_np(source.c_str(), destination.c_str(), RENAME_EXCL) != 0)
    ec.assign(errno, boost::system::system_category());
#elif defined(__linux__) && defined(SYS_renameat2)
  if (::syscall(SYS_renameat2, AT_FDCWD, source.c_str(), AT_FDCWD, destination.c_str(), RENAME_NOREPLACE) != 0)
    ec.assign(errno, boost::system::system_category());
#else
  ec = make_error_code(boost::system::errc::operation_not_supported);
#endif
}

std::vector<std::string> check_rename_destinations(const OperationPlan& plan) {
  std::vector<std::string> errors(plan.steps.size());
  std::unordered_map<std::string, size_t> destinations;
  for (size_t i = 0; i < plan.steps.size(); ++i) {
    const auto& op = plan.steps[i];
    if (op.kind != Operation::Kind::RenameEntry) continue;
    error_code ec;
    auto parent = boost::filesystem::weakly_canonical(op.destination.parent_path(), ec);
    if (ec) { errors[i] = ec.message(); continue; }
    const auto target = parent / op.destination.filename();
    auto [previous, inserted] = destinations.emplace(target.native(), i);
    if (!inserted) errors[i] = errors[previous->second] = "Multiple entries have the same rename destination";
    const auto status = boost::filesystem::symlink_status(target, ec);
    if (ec && ec != boost::system::errc::no_such_file_or_directory) errors[i] = ec.message();
    else if (op.source.lexically_normal() == op.destination.lexically_normal()) {
      if (!boost::filesystem::exists(status)) errors[i] = "Rename source does not exist";
    }
    else if (boost::filesystem::exists(status))
      errors[i] = "Rename destination already exists; use an unused intermediate name for swaps or cycles";
  }
  return errors;
}

bool transfer_checkpoint(const boost::filesystem::copy_file_options& options, error_code& ec) {
  if ((options.cancel_requested && options.cancel_requested->load()) ||
      (options.checkpoint && !options.checkpoint(options.checkpoint_context))) {
    ec.assign(ECANCELED, boost::system::system_category());
    return false;
  }
  return true;
}

bool copy_move_tree(const Filepath& source, const Filepath& destination,
                    const boost::filesystem::copy_file_options& options, error_code& ec) {
  TraversalCallbacks cb;
  cb.cancelled = [&] { return ec || !transfer_checkpoint(options,ec); };
  auto target = [&](const TraversalEntry& e) { return e.path == source ? destination : destination/e.relative.lexically_relative(source.filename()); };
  cb.error = [&](const Filepath&,const std::string&) { if (!ec) ec=make_error_code(boost::system::errc::io_error); };
  cb.enter = [&](const TraversalEntry& e) {
    auto output=target(e);
    if (e.link_text) boost::filesystem::create_symlink(*e.link_text,output,ec);
    else if (boost::filesystem::is_directory(e.status)) create_private_directory(output,ec);
    else {
      auto nested = options;
      nested.transaction = nullptr; nested.remove_source = nullptr;
      boost::filesystem::copy_file(e.path,output,nested,ec);
    }
    return !ec;
  };
  cb.leave = [&](const TraversalEntry& e) {
    if (ec) return;
    int injected = options.io && options.io->fault ? options.io->fault(options.io->context, "move_metadata") : 0;
    if (injected) ec.assign(injected, boost::system::system_category());
    else copy_entry_metadata(e.path, target(e), ec);
    if (!ec) {
      injected = options.io && options.io->fault ? options.io->fault(options.io->context, "move_metadata_verify") : 0;
      if (injected) ec.assign(injected, boost::system::system_category());
      else verify_entry_metadata(e.path, target(e), ec);
    }
  };
  auto result=traverse({source},{},cb);
  return !ec && !result.cancelled && !result.truncated;
}
}

bool move_by_copy(const Filepath& source, const Filepath& destination,
                  const boost::filesystem::copy_file_options& options, error_code& ec) {
  ec.clear();
  if (!transfer_checkpoint(options, ec)) return false;
  auto parent = destination.parent_path();
  if (parent.empty()) parent = ".";
  const auto staging = parent / boost::filesystem::unique_path(".fc-move-%%%%-%%%%-%%%%");
  if (!create_private_directory(staging, ec) || ec) return false;
  struct Cleanup {
    Filepath root;
    ~Cleanup() { error_code ignored; remove_owned_staging(root, ignored); }
  } cleanup{staging};
  const auto output = staging / "entry";
  if (options.transaction) {
    int error = options.transaction(options.transaction_context, "staging", output, destination);
    if (error) { ec.assign(error,boost::system::system_category()); return false; }
  }
  if (!copy_move_tree(source, output, options, ec) || !transfer_checkpoint(options, ec)) return false;
  auto fault = [&](const char* phase) {
    int error = options.io && options.io->fault ? options.io->fault(options.io->context,phase) : 0;
    if (error) ec.assign(error,boost::system::system_category());
    return error != 0;
  };
  if (options.transaction) {
    int error = options.transaction(options.transaction_context, "commit_ready", output, destination);
    if (error) { ec.assign(error,boost::system::system_category()); return false; }
  }
  if (fault("move_commit")) return false;
  boost::filesystem::rename(output, destination, ec);
  if (ec) return false;
  if (options.transaction) {
    int error = options.transaction(options.transaction_context, "committed", output, destination);
    if (error) { ec.assign(error,boost::system::system_category()); return false; }
  }
  // Commit boundary: the complete destination now exists. Finish source cleanup
  // even if cancellation arrives here, rather than leaving a half-deleted source.
  if (fault("source_remove")) return false;
  if (options.remove_source) {
    int error = options.remove_source(options.transaction_context, source, destination);
    if (error) ec.assign(error,boost::system::system_category());
  } else boost::filesystem::remove_all(source, ec);
  return !ec;
}

class ThreadedFileJobs : public FileJobs {
 public:
  struct UpdateSink {
    std::mutex mutex;
    std::function<void()> callback = [] {};
    EventSink event=[](auto,auto,auto) {};
    void emit(std::string name,std::string detail,uint64_t id=0) {EventSink sink;{std::lock_guard lock(mutex);sink=event;}sink(std::move(name),std::move(detail),id);}
    void notify() { std::function<void()> fn; { std::lock_guard lock(mutex); fn = callback; } fn(); }
  };
  std::shared_ptr<UpdateSink> _updates = std::make_shared<UpdateSink>();
  void set_update_sink(std::function<void()> sink) override {
    std::lock_guard lock(_updates->mutex); _updates->callback = sink ? std::move(sink) : [] {};
  }
  void set_event_sink(EventSink sink) override {std::lock_guard lock(_updates->mutex);_updates->event=sink?std::move(sink):[](auto,auto,auto) {};}
  JobRetention _limits;
  FileJobServices _services;
  ArchiveService& _archives;
  explicit ThreadedFileJobs(JobRetention limits = {},FileJobServices services = {}) : _limits(limits), _services(std::move(services)), _archives(_services.archives?*_services.archives:archive_service()), _queue(std::max(size_t{1},limits.pending_count)) {
    _thread = std::thread([this]() { this->run(); });
  }
  ~ThreadedFileJobs() override { shutdown(); }
  void shutdown() override {
    std::call_once(_shutdown_once, [this] {
      _shutdown = true;
      _queue.close();
      {
        std::lock_guard lock(_m);
        if (_active_job && !_active_job->is_stopped()) {
          _active_job->_shutdown_requested = true;
          _active_job->_cancel_requested = true;
          _active_job->_pause_cv.notify_all();
        }
      }
      if (_thread.joinable()) _thread.join();
      _progress_monitor.stop();
    });
  }
  uint64_t add_job(std::shared_ptr<JobSpec> job) override {
    for(const auto& op:job->_plan->steps) if(auto lease=_archives.lease_for_path(op.source)) job->_archive_leases.push_back(std::move(lease));
    uint64_t id    = _next_job_id.fetch_add(1);
    job->_job_id   = id;
    job->_queued_time = now();
    try { if (!_journal_directory.empty()) job->_journal = TransferJournal::create(_journal_directory, *job); }
    catch (const std::exception& e) { report_error("[Transfer journal] " + std::string(e.what())); return 0; }
    bind_updates(job);
    { std::lock_guard lock(_m); _jobs_by_id[id]=job; }
    ++_outstanding;
    if (_queue.try_push(job) != FifoError::OK) {
      --_outstanding;
      { std::lock_guard lock(_m); _jobs_by_id.erase(id); }
      try { if (job->_journal) job->_journal->dismiss(); } catch (...) {}
      report_error("Job queue is full or closed; submission rejected");
      return 0;
    }
    return id;
  }
  void enable_recovery(const Filepath& directory) override {
    if (!idle() || !_journal_directory.empty()) throw std::runtime_error("Transfer recovery must be initialized before submission");
    _journal_directory = directory;
    uint64_t next = _next_job_id;
    auto restored = TransferJournal::restore(directory, next, [this](auto error) { report_error(std::move(error)); });
    std::lock_guard lock(_m);
    _next_job_id = next;
    for (auto& job : restored) {
      bind_updates(job);
      _jobs_by_id[job->_job_id] = job;
      _job_history.push_back(std::move(job));
    }
    retain_history();
  }

  bool idle() const override { return _outstanding.load() == 0; }
  std::vector<JobEvent> events_since(uint64_t& sequence) override {
    std::lock_guard lock(_m);
    std::vector<JobEvent> result;
    if (!_events.empty() && sequence + 1 < _events.front().sequence) result.push_back({_events.front().sequence-1,0,false,true});
    auto at=std::upper_bound(_events.begin(),_events.end(),sequence,[](uint64_t n,const JobEvent& e){return n<e.sequence;});
    result.insert(result.end(),at,_events.end());
    if (!_events.empty()) sequence = _events.back().sequence;
    return result;
  }
  JobError cancel_job(JobSpec* job) override {
    if (!job || job->is_stopped()) return JobError::NOT_FOUND;
    job->_user_cancel_requested = true;
    if (job->_recovery_waiting) {
      { std::lock_guard lock(job->_m);
        job->_state = JobState::CANCELLED; job->_recovery_waiting = false;
        job->_finished_time = now(); job->_stopped = true;
        job->_recovery_note = "Recovery cancelled; committed files were retained";
      }
      if (job->_journal) {
        try { job->_journal->checkpoint(*job->snapshot(), JobState::CANCELLED); }
        catch (const std::exception& e) { report_error(e.what()); return JobError::RECOVERY_BLOCKED; }
      }
      job->updated();
      return JobError::OK;
    }
    job->_cancel_requested = true;
    job->_pause_cv.notify_all();
    if (job->_journal) {
      try { job->_journal->checkpoint(*job->snapshot(), JobState::CANCELLED); }
      catch (const std::exception& e) { report_error(e.what()); return JobError::RECOVERY_BLOCKED; }
    }
    return JobError::OK;
  }
  JobError pause_job(JobSpec* job) override {
    if (!job) return JobError::NOT_FOUND;
    if (job->_recovery_waiting) return resume(job->_job_id);
    {
      std::lock_guard lock(job->_m);
      if (job->is_stopped()) return JobError::NOT_FOUND;
      job->_pause_requested = !job->_pause_requested.load();
    }
    // Only the worker acknowledges PAUSED/RUNNING at a checkpoint.
    job->_pause_cv.notify_all();
    job->updated();
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
    auto found = _jobs_by_id.find(job_id);
    if (found != _jobs_by_id.end()) if (auto job = found->second.lock()) {
      if (!job->is_stopped()) return;
      try { if (job->_journal) job->_journal->dismiss(); } catch (...) { return; }
    }
    _jobs_by_id.erase(job_id);
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
    if (i < 0 || i >= static_cast<int64_t>(_errors.size())) return JobErrorInfo();
    return _errors.at(i);
  }

  int64_t error_count() override { std::lock_guard lock(_m);return _errors.size(); }
  JobError cancel(uint64_t id) override { return control(id,true); }
  JobError pause(uint64_t id) override { return control(id,false); }
  JobError resume(uint64_t id) override {
    std::shared_ptr<JobSpec> job;
    { std::lock_guard lock(_m); auto found = _jobs_by_id.find(id); if (found != _jobs_by_id.end()) job = found->second.lock(); }
    if (!job || job->is_stopped()) return JobError::NOT_FOUND;
    if (!job->_recovery_waiting) {
      if (job->_pause_requested) return pause_job(job.get());
      return JobError::OK;
    }
    try {
      std::lock_guard lock(job->_m);
      const bool remote = std::any_of(job->_plan->steps.begin(), job->_plan->steps.end(), [](const auto &op) {
        return is_remote(op.source) || is_remote(op.destination);
      });
      if (remote)
        job->_resume_validate = true;
      else
        job->_journal->prepare_resume(*job);
      job->_recovery_note.clear(); job->_cancel_requested = false; job->_pause_requested = false;
      job->_user_cancel_requested = false; job->_shutdown_requested = false;
      job->_recovery_waiting = false; job->_state = JobState::QUEUED;
      ++_outstanding;
      if (_queue.try_push(job) != FifoError::OK) {
        --_outstanding; job->_recovery_waiting = true; job->_state = JobState::PAUSED;
        throw std::runtime_error("Queue is full or closed; recovered transfer remains paused");
      }
    } catch (const std::exception& e) {
      { std::lock_guard lock(job->_m); job->_recovery_note = e.what(); }
      report_error("[Resume] " + std::string(e.what())); job->updated();
      return JobError::RECOVERY_BLOCKED;
    }
    job->updated(); return JobError::OK;
  }
  JobError control(uint64_t id,bool cancelling) {
    std::shared_ptr<JobSpec> job;
    {std::lock_guard lock(_m);auto found=_jobs_by_id.find(id);if(found!=_jobs_by_id.end()) job=found->second.lock();}
    if(!job) return JobError::NOT_FOUND;
    return cancelling?cancel_job(job.get()):pause_job(job.get());
  }

  void report_error(std::string message) override {
    if(message.size()>65536)message.resize(65536);
    { std::lock_guard lock(_m);double time=now();if(!_errors.empty() && time<=_errors.back().time)time=_errors.back().time+0.00001;
      _errors.emplace_back(message,time);while(_errors.size()>_limits.error_count)_errors.pop_front(); }
    _updates->emit("error_reported",std::move(message));
  }
  void clear_errors() override {
    {std::lock_guard lock(_m);_errors.clear();_err_last_access_index=0;}
    _updates->emit("errors_cleared","0");
  }

 private:
  Filepath _journal_directory;
  void bind_updates(const std::shared_ptr<JobSpec>& job) {
    job->updated = [updates = _updates, weak=std::weak_ptr<JobSpec>(job)] {
      updates->notify();if(auto job=weak.lock()) {
        auto snapshot=job->snapshot(job->_journal != nullptr);auto state=snapshot->_state.load();
        if (job->_journal) {
          auto persisted = job->_user_cancel_requested ? JobState::CANCELLED
            : job->_shutdown_requested && !job->is_stopped() ? JobState::PAUSED : state;
          try { job->_journal->checkpoint(*snapshot, persisted, false); }
          catch (const std::exception& e) { std::lock_guard lock(job->_m); job->_recovery_note = "Transfer checkpoint failed: " + std::string(e.what()); }
        }
        if(job->_last_notified_state.exchange(state)!=state) {
          const char* names[]={"queued","running","paused","cancelled","completed","completed_with_errors"};
          updates->emit("job_state_changed",names[static_cast<int>(state)],job->_job_id);
        }
        updates->emit("job_progress",std::to_string(snapshot->_items_done),job->_job_id);
      }
    };
  }
  void configure_transaction(boost::filesystem::copy_file_options& options, JobSpec* job) {
    if (!job->_journal) return;
    options.options |= copy_options::synchronize;
    job->_journal_io = _services.file_io.get();
    options.transaction_context = job;
    options.transaction = [](void* context, const char* phase, const Filepath& stage, const Filepath& destination) {
      return static_cast<JobSpec*>(context)->_journal->transaction(phase, stage, destination);
    };
    options.remove_source = [](void* context, const Filepath& source, const Filepath& destination) {
      auto* job = static_cast<JobSpec*>(context);
      return job->_journal->remove_source(source, destination, job->_journal_io);
    };
  }
  void record_event(uint64_t id,bool completed) {
    _events.push_back({++_event_sequence,id,completed});
    while(_events.size()>std::max(size_t{1},_limits.event_count)) _events.pop_front();
  }
  void retain_history() { // manager mutex held; stopped jobs only
    size_t stopped = std::count_if(_job_history.begin(), _job_history.end(), [](const auto& job) { return job->is_stopped(); });
    for (auto it = _job_history.begin(); it != _job_history.end() && stopped > _limits.history_count;) {
      if (!(*it)->is_stopped()) { ++it; continue; }
      try { if ((*it)->_journal) (*it)->_journal->dismiss(); } catch (...) { ++it; continue; }
      _jobs_by_id.erase((*it)->_job_id); it = _job_history.erase(it); --stopped;
    }
    size_t bytes=0,count=0;
    for(auto it=_job_history.rbegin();it!=_job_history.rend();++it) {
      auto& job=**it; std::lock_guard lock(job._m);
      if (!job.is_stopped()) continue;
      job._archive_leases.clear(); // Execution is complete; details only contain display paths.
      if(job._details_expired) continue;
      size_t cost=(job._items.capacity()+job._errors.capacity())*sizeof(DirItem);
      auto measure=[&](const auto& items) {for(const auto& item:items) cost+=item.path_ref().native().size()+item.filename_ref().size()+item.symlink_ref().value_or(Filepath()).native().size()+item.warning_ref().value_or("").size();};
      measure(job._items);measure(job._errors);
      if(job._plan) for(const auto& op:job._plan->steps) cost+=sizeof(Operation)+op.source.native().size()+op.destination.native().size()+op.link_text.native().size()+op.message.size();
      if(++count>_limits.detail_count || cost>_limits.detail_bytes-bytes) {
        job._retained_item_count=job._items.size(); job._details_expired=true;
        std::vector<DirItem>().swap(job._items); std::vector<DirItem>().swap(job._errors); job._completed_summary.reset(); job._plan.reset(); std::vector<std::string>().swap(job._step_errors);
      } else bytes+=cost;
    }
  }
  bool validate_mutation_paths(JobSpec* job) {
    for(const auto& op:job->_plan->steps) {
      std::vector<Filepath> paths;
      if(op.kind==Operation::Kind::MoveEntry || op.kind==Operation::Kind::RenameEntry || op.kind==Operation::Kind::DeleteEntry) paths.push_back(op.source);
      if(!op.destination.empty()) paths.push_back(op.destination);
      for(const auto& path:paths) {
        auto error=_archives.is_cached_path(path)?"Archive contents are read-only; copy files out before editing: "+path.native():std::string();if(error.empty())continue;
        report_error(error);std::lock_guard lock(job->_m);job->report_error(operation_display(op),error);
        job->_items_done=job->_items.size();job->_items_failed=job->_items_done;return false;
      }
    }
    return true;
  }

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
        record_event(_active_job->_job_id,false);
        if (_shutdown.load()) {
          _active_job->_shutdown_requested = true;
          _active_job->_cancel_requested = true;
        }
      }
      _updates->emit("job_started",std::to_string(_active_job->_job_id),_active_job->_job_id);
      _active_job->updated();
      _progress_monitor.add_job(_active_job);
      try {
      if (_active_job->_cancel_requested.load()) {
        _active_job->_state = JobState::CANCELLED;
      } else if (validate_mutation_paths(_active_job.get())) {
        if (std::any_of(_active_job->_plan->steps.begin(), _active_job->_plan->steps.end(),
                        [](const auto &op) { return is_remote(op.source) || is_remote(op.destination); }))
          run_remote(_active_job.get());
        else
          switch (_active_job->_type) {
          case JobSpec::Type::COPY:
            run_copy(_active_job.get());
            break;
          case JobSpec::Type::MOVE:
            run_move(_active_job.get());
            break;
          case JobSpec::Type::DELETE:
            run_delete(_active_job.get());
            break;
          case JobSpec::Type::ARCHIVE_CREATE:
            run_archive_create(_active_job.get());
            break;
          case JobSpec::Type::MKDIR:
          case JobSpec::Type::RENAME:
          case JobSpec::Type::CLIPBOARD:
            run_small(_active_job.get());
            break;
          }
      }
      } catch (const std::exception& e) {
        { std::lock_guard lock(_active_job->_m);
          _active_job->_recovery_note = e.what();
          if (_active_job->_journal) {
            _active_job->_state = JobState::PAUSED;
            _active_job->_recovery_waiting = true;
          } else {
            _active_job->_state = JobState::COMPLETED_WITH_ERRORS;
            _active_job->report_error(DirItem(Filepath()), e.what());
          }
        }
        report_error("[Transfer paused] " + std::string(e.what()));
      }
      if (_active_job->_journal && !_active_job->_user_cancel_requested && (_shutdown || _active_job->_recovery_waiting)) {
        { std::lock_guard lock(_active_job->_m);
          _active_job->_state = JobState::PAUSED; _active_job->_recovery_waiting = true;
          if (_active_job->_recovery_note.empty()) _active_job->_recovery_note = "Interrupted transfer — Resume required";
        }
        try { _active_job->_journal->checkpoint(*_active_job->snapshot(), JobState::PAUSED); }
        catch (const std::exception& e) { report_error(e.what()); }
        { std::lock_guard lock(_m);
          if (std::find(_job_history.begin(), _job_history.end(), _active_job) == _job_history.end()) _job_history.push_back(_active_job);
          --_outstanding;
        }
        _active_job->updated();
        continue;
      }
      {
        std::lock_guard lock(_active_job->_m);
        _active_job->_finished_time = now();
        if (_active_job->_user_cancel_requested) _active_job->_state = JobState::CANCELLED;
        // Determine final state (if not already set by pause/cancel in future steps)
        if (_active_job->_state != JobState::CANCELLED && _active_job->_state != JobState::COMPLETED_WITH_ERRORS) {
          _active_job->_state = _active_job->_errors.empty()
            ? JobState::COMPLETED
            : JobState::COMPLETED_WITH_ERRORS;
        }
        _active_job->_pause_requested = false;
        _active_job->_stopped.store(true, std::memory_order_release);
      }
      if (_active_job->_journal) {
        try { _active_job->_journal->checkpoint(*_active_job->snapshot(), _active_job->_state); }
        catch (const std::exception& e) { report_error("[Transfer journal] " + std::string(e.what())); }
      }
      if (auto completed=std::move(_active_job->completed)) {
        try { completed(_active_job->snapshot()); } catch (const std::exception& e) { report_error(e.what()); }
      }
      // Store in job history directly (under _m, which we already use for _active_job)
      {
        std::lock_guard lock(_m);
        if (std::find(_job_history.begin(), _job_history.end(), _active_job) == _job_history.end()) _job_history.push_back(_active_job);
        record_event(_active_job->_job_id,true);
        retain_history();
        --_outstanding;
      }
      _updates->emit("job_completed",std::to_string(_active_job->_job_id),_active_job->_job_id);
      _active_job->updated();
    }
  }

  void _discover_files(JobSpec* job, std::vector<DirItem>& items, FifoQueue<DirItem>& files, DelayedUpdateDiscovery& update) {
    std::vector<Filepath> roots; for (const auto& item:items) roots.push_back(item.path_ref());
    TraversalCallbacks cb;
    cb.cancelled = [&] { return job->_cancel_requested.load() || !files.running(); };
    cb.error = [&](const Filepath& path,const std::string& message) {
      std::lock_guard lock(job->_m); job->report_error(DirItem(path),"Delete discovery failed: " + message);
    };
    cb.leave = [&](const TraversalEntry& e) {
      if (cb.cancelled()) return;
      DirItem item(e.path); update.file_found(std::max(int64_t{0},item.size()),job); files.push(std::move(item));
    };
    traverse(roots,{},cb);
  }

  void run_remote(JobSpec *job) {
    using namespace RemoteFS;
    if (job->_type == OperationType::ARCHIVE_CREATE || job->_type == OperationType::CLIPBOARD)
      throw std::runtime_error("This operation is not supported in SSH tabs");
    if (job->_resume_validate.exchange(false)) {
      std::lock_guard lock(job->_m);
      job->_journal->prepare_resume(*job);
    }
    if (job->_journal)
      job->_journal->prepare_inputs();
    auto checkpoint = [&] {
      if (job->_cancel_requested || !wait_for_resume(job))
        throw ConnectionError("Transfer interrupted; Resume requires validation");
    };
    auto copy_started = std::chrono::steady_clock::now();
    auto progress = [&](int64_t n) {
      checkpoint();
      auto rate = _transfer_rate.load();
      if (rate) {
        auto deadline = copy_started + std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                                           std::chrono::duration<double>(double(n) / rate));
        while (std::chrono::steady_clock::now() < deadline) {
          checkpoint();
          std::this_thread::sleep_for(std::chrono::milliseconds(20));
        }
      }
      {
        std::lock_guard lock(job->_m);
        job->_copy_bytes = n;
        job->_current_item.current_size = n;
        job->_total.update(int64_t(job->_bytes_processed) + n, int64_t(job->_bytes_total));
      }
      job->updated();
    };
    struct CopiedDirectory {
      Filepath source, destination;
      Metadata metadata;
    };
    std::vector<CopiedDirectory> directories;
    if (job->_journal && job->_resume_index) {
      std::vector<Operation> restored;
      job->_journal->prepare_copy_directories(restored);
      for (auto &op : restored)
        directories.push_back({op.source, op.destination, inspect(op.source, true)});
    }
    std::function<void(const Filepath &, const Filepath &)> copy_tree;
    copy_tree = [&](const Filepath &source, const Filepath &target) {
      checkpoint();
      auto before = inspect(source);
      if (!before.exists)
        throw std::runtime_error("Source is unavailable: " + source.native());
      if (before.directory()) {
        mkdir(target);
        for (auto &entry : list(source, &job->_cancel_requested))
          copy_tree(entry.path, target / entry.path.filename());
      } else if (before.symlink())
        symlink(before.link, target);
      else if ((before.mode & S_IFMT) == S_IFREG) {
        copy_started = std::chrono::steady_clock::now();
        auto l = Location::decode(source.native()), r = Location::decode(target.native());
        if (l.remote() && r.remote() && l.ssh == r.ssh) {
          auto p = params(source);
          p["destination64"] = base64(r.local.native());
          p["checkpoint"] = true;
          request(l.ssh, "copy", std::move(p), &job->_cancel_requested, true, progress);
        } else {
          write(target, 0, "", true);
          uint64_t offset = 0;
          for (;;) {
            checkpoint();
            auto bytes = read(source, offset, 1024 * 1024);
            if (bytes.empty())
              break;
            write(target, offset, bytes);
            offset += bytes.size();
            progress(offset);
          }
        }
        if (digest(source, &job->_cancel_requested) != digest(target, &job->_cancel_requested))
          throw std::runtime_error("Transfer digest mismatch; destination was not published");
      } else
        throw std::runtime_error("SSH transfers support regular files, directories and symbolic links");
      if (inspect(source).stamp() != before.stamp())
        throw std::runtime_error("Source changed while copying; destination was not published");
      auto attrs = attributes(source);
      auto target_attrs = attributes(target);
      if (attrs.at("acl").as_bool())
        throw std::runtime_error("Extended ACLs are not supported in SSH transfers; source retained");
      if (attrs.at("platform") != target_attrs.at("platform")) {
        attrs.at("attributes").as_object().erase(base64("com.apple.provenance"));
      }
      if (!attrs.at("attributes").as_object().empty() && attrs.at("platform") != target_attrs.at("platform"))
        throw std::runtime_error(
            "Extended attributes cannot be translated between these platforms; source retained");
      attributes(target, attrs.at("attributes").as_object());
      metadata(target, before);
      sync(target);
    };
    for (size_t index = job->_resume_index; index < job->_plan->steps.size(); ++index) {
      checkpoint();
      const auto &op = job->_plan->steps[index];
      bool skipped = false;
      if (job->_journal && job->_journal->cleanup_pending()) {
        job->_journal->remove_source(op.source, op.destination);
        job->_journal->cleanup_committed_staging();
      } else {
        if (job->_journal)
          job->_journal->begin_step(index);
        {
          std::lock_guard lock(job->_m);
          job->_current_item.current_size = 0;
          job->_copy_bytes = 0;
        }
        if (op.kind == Operation::Kind::DiscoveryFailure)
          throw std::runtime_error(op.message);
        if (op.kind == Operation::Kind::CreateDirectory) {
          auto existing = inspect(op.destination);
          if (existing.exists && !existing.directory())
            throw std::runtime_error("Directory destination is occupied");
          if (!existing.exists) {
            mkdir(op.destination);
            if (!op.source.empty())
              directories.push_back({op.source, op.destination, inspect(op.source, true)});
          }
        } else if (op.kind == Operation::Kind::DeleteEntry) {
          if (Location::decode(op.source.native()).local == "/")
            throw std::runtime_error("Deleting a filesystem root is forbidden");
          // Recursive removal never follows a final symlink.
          remove(op.source, true);
        } else if (op.kind == Operation::Kind::RenameEntry) {
          rename(op.source, op.destination, false);
        } else {
          auto before = op.source.empty() ? Metadata{} : inspect(op.source);
          auto destination = inspect(op.destination);
          if (op.kind == Operation::Kind::CreateSymlink && op.source.empty()) {
            before.exists = true;
            before.mode = S_IFLNK | 0777;
            before.mtime_ns = int64_t(op.modified) * 1000000000;
          }
          if (op.source == op.destination)
            throw std::runtime_error("Source and destination are the same entry");
          if (before.directory() &&
              Location::decode(op.source.native()).ssh == Location::decode(op.destination.native()).ssh) {
            auto source = RemoteFS::canonical(op.source),
                 parent = RemoteFS::canonical(location_parent(op.destination));
            if (parent == source || path_is_under(source, parent))
              throw std::runtime_error("Cannot copy or move a directory into itself");
          }
          if (op.kind != Operation::Kind::MoveEntry && destination.exists &&
              (job->_copy_conflict == CopyConflictMode::Skip ||
               (job->_copy_conflict == CopyConflictMode::Update && before.mtime_ns <= destination.mtime_ns)))
            skipped = true;
          else {
            if (op.kind == Operation::Kind::MoveEntry && destination.exists)
              throw std::runtime_error("Move destination already exists");
            bool renamed = false;
            if (op.kind == Operation::Kind::MoveEntry) {
              try {
                rename(op.source, op.destination, false);
                renamed = true;
              } catch (const std::system_error &e) {
                if (e.code().value() != EXDEV)
                  throw;
              }
            }
            if (!renamed) {
              if (destination.directory())
                throw std::runtime_error("Cannot replace a directory with a file");
              auto root = location_parent(op.destination) /
                          boost::filesystem::unique_path(op.kind == Operation::Kind::MoveEntry
                                                             ? ".fc-move-%%%%%%%%-%%%%%%%%"
                                                             : ".fc-copy-%%%%%%%%-%%%%%%%%");
              mkdir(root);
              auto stage = root / (op.kind == Operation::Kind::MoveEntry ? "entry" : "data");
              if (job->_journal)
                job->_journal->transaction("staging", stage, op.destination);
              if (op.kind == Operation::Kind::CreateSymlink) {
                symlink(op.link_text.native(), stage);
                metadata(stage, before);
              } else
                copy_tree(op.source, stage);
              checkpoint();
              if (inspect(op.destination).stamp() != destination.stamp())
                throw std::runtime_error("Destination changed before commit; source retained");
              if (job->_journal)
                job->_journal->transaction("commit_ready", stage, op.destination);
              rename(stage, op.destination, destination.exists, &destination);
              if (job->_journal)
                job->_journal->transaction("committed", stage, op.destination);
              if (op.kind == Operation::Kind::MoveEntry) {
                if (!job->_journal)
                  throw std::runtime_error("Cross-filesystem move requires a transfer journal; destination "
                                           "copied and source retained");
                job->_journal->remove_source(op.source, op.destination);
              }
              RemoteFS::remove(root);
            }
          }
        }
      }
      {
        std::lock_guard lock(job->_m);
        ++job->_items_done;
        job->_items_skipped += skipped;
        job->_bytes_processed += skipped ? 0 : std::max(int64_t(0), op.bytes);
        job->_current_item_index = int(index + 1);
        job->_current_item.current_size = 0;
        if (job->_journal)
          job->_journal->finish_step(*job);
      }
      job->updated();
    }
    for (auto it = directories.rbegin(); it != directories.rend(); ++it) {
      auto attrs = attributes(it->source), target = attributes(it->destination);
      if (attrs.at("platform") != target.at("platform"))
        attrs.at("attributes").as_object().erase(base64("com.apple.provenance"));
      if (attrs.at("acl").as_bool() ||
          (!attrs.at("attributes").as_object().empty() && attrs.at("platform") != target.at("platform")))
        throw std::runtime_error(
            "Directory access metadata cannot be preserved over SSH; review the paused copy");
      attributes(it->destination, attrs.at("attributes").as_object());
      metadata(it->destination, it->metadata);
      sync(it->destination);
    }
  }

  void run_delete(JobSpec* job) {
    FifoQueue<DirItem>   files(1024);
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
        report_error("[Delete] " + item.path_ref().native());
        std::lock_guard lock(job->_m);
        job->report_error(item, "Failed to delete file: " + ec.message());
        ++job->_items_failed;
      }
      update.file_deleted(item, job);
    }
    update.flush(job);
    if (discovery_thread.joinable()) discovery_thread.join();
  }

  void run_small(JobSpec* job) {
    const auto rename_errors = check_rename_destinations(*job->_plan);
    {std::lock_guard lock(job->_m);job->_step_errors.assign(job->_plan->steps.size(),"not executed");}
    for(size_t i=0;i<job->_plan->steps.size();++i) {
      if(job->_cancel_requested || !wait_for_resume(job)) {job->_state=JobState::CANCELLED;return;}
      const auto& op=job->_plan->steps[i]; error_code ec;std::string message;
      switch(op.kind) {
        case Operation::Kind::CreateDirectory:
          if(!boost::filesystem::create_directory(op.destination,ec) && !ec) message="already exists";break;
        case Operation::Kind::RenameEntry:
          message = rename_errors[i];
          if (message.empty() && op.source.lexically_normal() != op.destination.lexically_normal()) {
            const auto* io = _services.file_io.get();
            const int fault = io && io->fault ? io->fault(io->context, "rename_commit") : 0;
            if (fault) ec.assign(fault, boost::system::system_category());
            else rename_no_replace(op.source, op.destination, ec);
          }
          break;
        case Operation::Kind::ClipboardText: {auto error=_services.clipboard(op.message);if(!error.ok()) message=error.steps.front();break;}
        default:message="Invalid small operation";break;
      }
      if(ec) message=ec.message();
      if(!message.empty()) report_error(message);
      {std::lock_guard lock(job->_m);job->_step_errors[i]=message;++job->_items_done;job->_current_item_index=i+1;
        if(!message.empty()){++job->_items_failed;job->report_error(operation_display(op),message);}}
      job->updated();
    }
  }

  void run_move(JobSpec* job) {
    DelayedUpdate update;
    for (int i = int(job->_resume_index); i < job->_items.size(); i++) {
      if (job->_cancel_requested.load(std::memory_order_relaxed)) {
        job->_state = JobState::CANCELLED;
        return;
      }
      if (!wait_for_resume(job)) {
        return;
      }
      { std::lock_guard lock(job->_m); job->_current_item_index = i; }
      auto&      item = job->_items.at(i);
      const auto& op=job->_plan->steps.at(i);
      error_code ec;
      const auto* io = _services.file_io.get();
      const bool cleanup = job->_journal && job->_journal->cleanup_pending();
      if (job->_journal && !cleanup) job->_journal->begin_step(size_t(i));
      int injected = io && io->fault ? io->fault(io->context,"move_rename") : 0;
      if (cleanup) {
        int result = job->_journal->remove_source(op.source, op.destination, io);
        if (result) ec.assign(result, boost::system::system_category());
      } else
      if (injected) ec.assign(injected,boost::system::system_category());
      else boost::filesystem::rename(op.source, op.destination, ec);
      if (!ec && !cleanup && io && io->fault) {
        int fault = io->fault(io->context, "move_renamed");
        if (fault) ec.assign(fault, boost::system::system_category());
      }
      if (ec.value() == boost::system::errc::cross_device_link) {
        boost::filesystem::copy_file_options options;
        options.io = _services.file_io.get();
        options.cancel_requested = &job->_cancel_requested;
        options.bytes_per_second = _transfer_rate.load();
        options.bytes_copied = &job->_copy_bytes;
        options.checkpoint = [](void* context) { return wait_for_resume(static_cast<JobSpec*>(context)); };
        options.checkpoint_context = job;
        configure_transaction(options, job);
        move_by_copy(op.source, op.destination, options, ec);
        if (job->_cancel_requested.load() && ec) {
          job->_state = JobState::CANCELLED;
          return;
        }
      }

      if (ec.failed()) {
        // "Failed to move file: Cross-device link"
        report_error("[Move] " + item.path_ref().native());
        std::lock_guard lock(job->_m);
        job->report_error(item, "Failed to move file: " + ec.message());
      }

      {
        std::lock_guard lock(job->_m);
        ++job->_items_done;
        if (ec) ++job->_items_failed;
        else job->_bytes_processed += std::max(int64_t{0}, item.size());
        job->_current_item_index = i + 1;
        if (job->_journal) job->_journal->finish_step(*job);
      }
      if (update.is_time_to_update()) job->updated();
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
    archive_path = job->_plan->steps.front().destination;
    if (archive_path.empty()) {
      report_error("[Archive create] destination missing");
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
    bool skipped = false;
    Err err = _archives.create_archive(archive_path, sources, preferred_cwd, conflict, &job->_cancel_requested, &skipped);
    if (job->_cancel_requested.load()) { job->_state = JobState::CANCELLED; return; }
    if (!err.ok()) {
      report_error("[Archive create] " + err.steps.front());
      std::lock_guard lock(job->_m);
      job->report_error(job->_items.front(), err.steps.front());
    }
    {
      std::lock_guard lock(job->_m);
      job->_items_done = job->_items.size();
      job->_items_failed = err.ok() ? 0 : job->_items_done;
      job->_items_skipped = skipped ? job->_items_done : 0;
      job->_current_item_index = static_cast<int>(job->_items_done);
      if (err.ok() && !skipped) job->_bytes_processed = job->_bytes_total;
    }
  }

  void run_copy(JobSpec* job) {
    error_code       ec;
    std::unique_lock lock(job->_m);
    std::vector<Operation> created_directories;
    std::vector<Filepath> failed_directories;
    Defer restore_access([&] {
      const bool locked = lock.owns_lock();
      if (locked) lock.unlock();
      // Children first: restoring a read-only parent's mode must not prevent
      // populating or finalizing its descendants. Also runs on cancellation.
      for (auto it = created_directories.rbegin(); it != created_directories.rend(); ++it) {
        error_code metadata_error;
        copy_directory_access(it->source, it->destination, metadata_error);
        if (metadata_error) {
          const auto message = "Failed to preserve directory access: " + metadata_error.message();
          report_error(message);
          std::lock_guard guard(job->_m);
          job->report_error(operation_display(*it), message);
          ++job->_items_failed;
        }
      }
      if (locked) lock.lock();
    });
    // _job->_items is not to be modified by other threads
    if (job->_journal && job->_resume_index) job->_journal->prepare_copy_directories(created_directories);
    for (size_t index = job->_resume_index; index < job->_plan->steps.size(); ++index) {
      const auto& op = job->_plan->steps[index];
      auto item=operation_display(op);
      if (job->_cancel_requested.load(std::memory_order_relaxed)) {
        job->_state = JobState::CANCELLED;
        return;
      }
      if (!wait_for_resume_locked(job, lock)) {
        return;
      }
      const auto errors_before = job->_error_count_total;
      bool item_finished = true;
      bool item_skipped = false;
      if (job->_journal) job->_journal->begin_step(index);
      auto execute_item = [&]() {
      if (std::any_of(failed_directories.begin(), failed_directories.end(), [&](const auto& root) { return path_is_under(root, op.destination); })) {
        job->report_error(item, "Copy destination directory could not be secured");
        return;
      }
      if (op.kind == Operation::Kind::DiscoveryFailure) {
        const auto message = op.message;
        job->report_error(item, message);
        lock.unlock();
        report_error("[Discovery] " + item.path_ref().native() + ": " + message);
        lock.lock();
        return;
      }
      if (op.kind == Operation::Kind::CreateDirectory) {
        ec.clear();
        lock.unlock();
        const bool preserve_access = !op.source.empty();
        const bool created = preserve_access ? create_private_directory(op.destination, ec)
                                            : boost::filesystem::create_directory(op.destination, ec);
        if (created && preserve_access) created_directories.push_back(op);
        if (ec.failed()) {
          error_code check_ec;
          const bool already_directory = boost::filesystem::is_directory(op.destination, check_ec);
          if (!preserve_access && !check_ec.failed() && already_directory) { ec.clear(); }
        }
        if (ec.failed()) report_error("[mkdir] " + item.path_ref().native());
        lock.lock();
        if (ec.failed()) {
          failed_directories.push_back(op.destination);
          // report error
          job->report_error(item, "Failed to create directory: " + ec.message());
          // also all items going into this dir may fail now, but we will let them error out individually
        }
        return;
      }
      if (op.kind == Operation::Kind::CreateSymlink) {
        if (op.link_text.empty()) {
          job->report_error(item, "Symlink target not set");
          report_error("[Symlink target not set] " + item.path_ref().native());
          return;
        }
        ec.clear();
        lock.unlock();
        const auto destination = op.destination;
        const auto present = boost::filesystem::symlink_status(destination, ec);
        if (ec == boost::system::errc::no_such_file_or_directory) ec.clear();
        const bool exists = boost::filesystem::exists(present);
        bool skip_link = !ec && exists && job->_copy_conflict == CopyConflictMode::Skip;
        if (!ec && exists && job->_copy_conflict == CopyConflictMode::Update)
          skip_link = item.write_time() <= DirItem(destination).write_time();
        if (skip_link) {
          lock.lock();
          item_skipped = true;
          return;
        }
        auto parent = destination.parent_path();
        if (parent.empty()) parent = ".";
        const auto temporary = parent / boost::filesystem::unique_path(".fc-link-%%%%-%%%%-%%%%");
        if (!ec) boost::filesystem::create_symlink(op.link_text, temporary, ec);
        if (!ec) {
          if (job->_copy_conflict == CopyConflictMode::Skip)
            boost::filesystem::create_hard_link(temporary, destination, ec);
          else
            boost::filesystem::rename(temporary, destination, ec);
          error_code cleanup;
          boost::filesystem::remove(temporary, cleanup);
          if (job->_copy_conflict == CopyConflictMode::Skip && ec == boost::system::errc::file_exists) {
            ec.clear();
            item_skipped = true;
          }
        }
        if (ec.failed()) report_error("[symlink] " + item.path_ref().native());
        lock.lock();
        if (ec.failed()) {
          // report error
          job->report_error(item, "Failed to create symlink: " + ec.message());
        }
        return;
      }
      if (op.destination.empty()) {
        job->report_error(item, "Copy destination not set");
        return;
      }
      auto skip_current_file = [&]() {
        item_skipped = true;
        job->_bytes_total = std::max(0.0, job->_bytes_total - double(std::max(int64_t{0}, item.size())));
        job->_total.update(job->_bytes_processed, job->_bytes_total);
      };
      const Filepath destination_path = op.destination;
      if (job->_copy_conflict != CopyConflictMode::Replace) {
        error_code exists_ec;
        const bool destination_exists = boost::filesystem::exists(destination_path, exists_ec);
        if (exists_ec.failed()) {
          job->report_error(item, "Failed to check destination: " + exists_ec.message());
          return;
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
            return;
          }
          skip_file = src_time <= dst_time;
        }
        if (skip_file) {
          skip_current_file();
          return;
        }
      }
      // else path is source file and target is destination file for copy operation
      // this operation is blocking. progress will be updated by separate thread.
      job->_current_item = ProgressInfo();
      job->_copy_bytes = 0;
      ec.clear();
      lock.unlock();
      boost::filesystem::copy_file_options cfo;
      cfo.io = _services.file_io.get();
      cfo.options = (job->_copy_conflict == CopyConflictMode::Skip)
        ? copy_options::none
        : copy_options::overwrite_existing;
      cfo.bytes_per_second = _transfer_rate;  // TODO: make configurable per-job
      cfo.cancel_requested = &job->_cancel_requested;
      cfo.bytes_copied = &job->_copy_bytes;
      cfo.checkpoint = [](void* context) { return wait_for_resume(static_cast<JobSpec*>(context)); };
      cfo.checkpoint_context = job;
      configure_transaction(cfo, job);
      boost::filesystem::copy_file(op.source, destination_path, cfo, ec);
      if (ec.failed() && job->_cancel_requested.load(std::memory_order_relaxed)) {
        item_finished = false;
        // Cancel during copy_file — only the owned staged output is removed.
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
        report_error("[Copy] " + item.path_ref().native());
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
      };
      execute_item();
      if (!item_finished) return;
      ++job->_items_done;
      if (job->_error_count_total > errors_before) ++job->_items_failed;
      if (item_skipped) ++job->_items_skipped;
      job->_current_item_index = int(index + 1);
      if (job->_journal) job->_journal->finish_step(*job);
    }
  }

  std::shared_ptr<JobSpec>                   _active_job;
  Perun::FifoQueue<std::shared_ptr<JobSpec>> _queue;
  std::atomic<uint64_t>                      _next_job_id{1};
  std::atomic<uint64_t> _outstanding{0};
  uint64_t _event_sequence = 0;
  std::deque<JobEvent> _events;
  std::unordered_map<uint64_t,std::weak_ptr<JobSpec>> _jobs_by_id;
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

std::unique_ptr<FileJobs> make_file_jobs(JobRetention limits,FileJobServices services) { return std::make_unique<ThreadedFileJobs>(limits,std::move(services)); }

FileJobs& file_operations() {
  static ThreadedFileJobs jobs;
  return jobs;
}

}  // namespace Perun
