#include "file_io_jobs.hpp"
#include "transfer_journal.hpp"
#include "support/contracts.hpp"
#include <iostream>
#include <boost/json.hpp>
#include <sys/wait.h>
#include <unistd.h>

using namespace Perun;
using namespace test;
static std::string executable;

static std::shared_ptr<JobSpec> copy_job(const Filepath& source, const Filepath& destination) {
  auto plan = std::make_shared<OperationPlan>();
  plan->steps.push_back({Operation::Kind::CopyFile, source, destination, {}, "", int64_t(fs::file_size(source))});
  return std::make_shared<JobSpec>(plan);
}
static std::shared_ptr<JobSpec> by_id(FileJobs& jobs, uint64_t id) {
  for (auto& job : jobs.get_job_history()) if (job->_job_id == id) return job;
  throw std::runtime_error("Recovered job missing");
}
static void paused(FileJobs& jobs, size_t count) {
  require(jobs.idle(), "Recovered jobs entered the execution queue");
  auto history = jobs.get_job_history(); require(history.size() == count, "Recovery lost jobs");
  for (auto& job : history) require(job->_state == JobState::PAUSED && !job->is_stopped(), "Interrupted job not paused");
}
static void states() {
  Fixture f;
  auto journal = f / "journal";
  for (int i = 0; i < 3; ++i) {
    auto source = f / ("source" + std::to_string(i)); write(source, "bytes");
    auto job = copy_job(source, f / ("dest" + std::to_string(i))); job->_job_id = i + 1;
    auto record = TransferJournal::create(journal, *job);
    record->checkpoint(*job->snapshot(), static_cast<JobState>(i)); // queued, running, paused
  }
  {
    auto jobs = make_file_jobs(); jobs->enable_recovery(journal); paused(*jobs, 3);
    std::this_thread::sleep_for(std::chrono::milliseconds(250));
    for (int i = 0; i < 3; ++i) require(!fs::exists(f / ("dest" + std::to_string(i))), "Startup performed transfer IO");
    require(jobs->resume(1) == JobError::OK, "Explicit resume rejected");
    until([&] { return jobs->idle(); }, "Resumed copy did not finish");
    require(read(f / "dest0") == "bytes", "Resumed copy bytes wrong");
    require(by_id(*jobs, 2)->_state == JobState::PAUSED && by_id(*jobs, 3)->_state == JobState::PAUSED, "Resume affected other jobs");
    write(f / "source1", "changed source");
    require(jobs->resume(2) == JobError::RECOVERY_BLOCKED && !fs::exists(f / "dest1"), "Changed source was copied");
    jobs->dismiss_job(3); require(by_id(*jobs, 3)->_state == JobState::PAUSED, "Dismiss silently cancelled paused work");
    require(jobs->cancel(2) == JobError::OK, "Cannot cancel recovered job");
  }
  auto restarted = make_file_jobs(); restarted->enable_recovery(journal);
  require(by_id(*restarted, 1)->_state == JobState::COMPLETED, "Completed transfer became runnable");
  require(by_id(*restarted, 2)->_state == JobState::CANCELLED, "Cancelled transfer became runnable");
  require(by_id(*restarted, 3)->_state == JobState::PAUSED, "Paused transfer changed state");
}

struct Crash {
  std::string phase;
  int commits = 0;
  bool cross_device = false;
  static int fault(void* context, const char* phase) {
    auto& c = *static_cast<Crash*>(context);
    if (c.cross_device && std::string_view(phase) == "move_rename") return EXDEV;
    if (c.phase == "second_commit" && std::string_view(phase) == "commit" && ++c.commits == 2) _exit(91);
    if (c.phase == phase) _exit(91);
    return 0;
  }
};
static int child(const Filepath& root, const std::string& kind, const std::string& phase) {
  Crash crash{phase, 0, kind == "move"};
  auto hooks = std::make_shared<fs::copy_file_io_hooks>(); hooks->context = &crash; hooks->fault = Crash::fault;
  FileJobServices services; services.file_io = hooks;
  auto jobs = make_file_jobs({}, services); jobs->enable_recovery(root / "journal");
  if (kind == "resume") {
    require(jobs->resume(1) == JobError::OK, "Child resume rejected");
  } else if (kind == "directory") {
    auto plan = std::make_shared<OperationPlan>();
    plan->steps.push_back({Operation::Kind::CreateDirectory, root / "source", root / "destination"});
    plan->steps.push_back({Operation::Kind::CopyFile, root / "source/a", root / "destination/a", {}, "", 5});
    plan->steps.push_back({Operation::Kind::CopyFile, root / "source/b", root / "destination/b", {}, "", 6});
    require(jobs->add_job(std::make_shared<JobSpec>(plan)) != 0, "Directory copy rejected");
  } else if (kind == "copy") {
    auto job = copy_job(root / "source", root / "destination");
    if (phase == "second_commit") {
      auto plan = std::make_shared<OperationPlan>(*job->_plan);
      plan->steps.push_back({Operation::Kind::CopyFile, root / "source2", root / "destination2", {}, "", 6});
      job = std::make_shared<JobSpec>(plan);
    }
    require(jobs->add_job(job) != 0, "Child copy rejected");
  } else {
    auto plan = std::make_shared<OperationPlan>(); plan->type = OperationType::MOVE;
    plan->steps.push_back({Operation::Kind::MoveEntry, root / "source", root / "destination", {}, "", 12});
    require(jobs->add_job(std::make_shared<JobSpec>(plan)) != 0, "Child move rejected");
  }
  until([&] { return jobs->idle(); }, "Child timed out");
  for (const auto& e : jobs->get_errors(100)) std::cerr << e.message << '\n';
  return 2; // The specified fault must terminate the child first.
}
static void crash_child(const Filepath& root, const std::string& kind, const std::string& phase) {
  pid_t pid = fork(); require(pid >= 0, "fork failed");
  if (pid == 0) { execl(executable.c_str(), executable.c_str(), "--child", root.c_str(), kind.c_str(), phase.c_str(), nullptr); _exit(127); }
  int status; require(waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 91, "Crash boundary was not reached: " + phase);
}
static void copies(const std::string& phase) {
  Fixture f; write(f / "source", "FIRST"); write(f / "source2", "SECOND");
  crash_child(f.root, "copy", phase);
  if (phase == "second_commit") write(f / "destination", "USER_CHANGED_COMPLETED_ITEM");
  auto jobs = make_file_jobs(); jobs->enable_recovery(f / "journal"); paused(*jobs, 1);
  require(jobs->resume(1) == JobError::OK, "Copy recovery rejected: " + by_id(*jobs, 1)->snapshot()->_recovery_note);
  until([&] { return jobs->idle(); }, "Copy recovery timeout");
  auto job = by_id(*jobs, 1);
  require(job->_state == JobState::COMPLETED, "Resumed copy failed: " + job->snapshot()->_recovery_note);
  require(read(f / "destination") == (phase == "second_commit" ? "USER_CHANGED_COMPLETED_ITEM" : "FIRST"), "Completed item replayed or destination lost");
  if (phase == "second_commit") require(read(f / "destination2") == "SECOND" && job->_items_done == 2, "Remaining item not resumed");
}
static void moves(const std::string& phase, bool changed = false, bool repeat = false) {
  Fixture f; fs::create_directory(f / "source");
  write(f / "source/a", "AAAAAA"); write(f / "source/b", "BBBBBB");
  crash_child(f.root, phase == "move_renamed" ? "rename" : "move", phase);
  if (repeat) crash_child(f.root, "resume", "recovery_source_item");
  if (changed) write(f / "destination/a", "USER_CHANGED_DESTINATION");
  auto jobs = make_file_jobs(); jobs->enable_recovery(f / "journal"); paused(*jobs, 1);
  const bool source_before = fs::exists(f / "source");
  auto result = jobs->resume(1);
  if (changed) {
    require(result == JobError::RECOVERY_BLOCKED, "Changed committed destination accepted");
    require(fs::exists(f / "source") == source_before, "Blocked recovery removed the source");
    require(read(f / "destination/a") == "USER_CHANGED_DESTINATION", "Blocked recovery overwrote destination");
  } else {
    require(result == JobError::OK, "Move resume rejected: " + by_id(*jobs, 1)->snapshot()->_recovery_note);
    until([&] { return jobs->idle(); }, "Move recovery timeout");
    auto job = by_id(*jobs, 1);
    require(job->_state == JobState::COMPLETED && !fs::exists(f / "source"), "Move cleanup failed: " + job->snapshot()->_recovery_note);
    require(read(f / "destination/a") == "AAAAAA" && read(f / "destination/b") == "BBBBBB", "Move recovery lost bytes");
  }
}
static void shutdown_recovery() {
  Fixture f; write(f / "source", std::string(1024 * 1024, 'x'));
  {
    auto jobs = make_file_jobs(); jobs->enable_recovery(f / "journal"); jobs->set_transfer_rate(128 * 1024);
    auto first = copy_job(f / "source", f / "first");
    jobs->add_job(first); jobs->add_job(copy_job(f / "source", f / "second"));
    until([&] { return first->_copy_bytes > 0; }, "Copy never started");
    jobs->pause(first->_job_id);
    until([&] { return first->_state == JobState::PAUSED; }, "Pause not acknowledged");
    jobs->shutdown();
  }
  auto jobs = make_file_jobs(); jobs->enable_recovery(f / "journal"); paused(*jobs, 2);
  require(!fs::exists(f / "first") && !fs::exists(f / "second"), "Shutdown committed incomplete data");
  require(jobs->resume(2) == JobError::OK, "Queued transfer cannot resume");
  until([&] { return jobs->idle(); }, "Queued resume timed out");
  require(by_id(*jobs, 1)->_state == JobState::PAUSED, "Resuming queued job resumed previous active job");
}

static void directory_recovery() {
  Fixture f; fs::create_directory(f / "source");
  write(f / "source/a", "FIRST"); write(f / "source/b", "SECOND");
  fs::permissions(f / "source", fs::owner_read | fs::owner_exe);
  crash_child(f.root, "directory", "second_commit");
  write(f / "destination/a", "USER_CHANGED_COMPLETED_ITEM");
  {
    auto jobs = make_file_jobs(); jobs->enable_recovery(f / "journal"); paused(*jobs, 1);
    require(jobs->resume(1) == JobError::OK, "Directory resume rejected");
    until([&] { return jobs->idle(); }, "Directory resume timeout");
    require(by_id(*jobs, 1)->_state == JobState::COMPLETED, "Directory copy failed: " + by_id(*jobs, 1)->snapshot()->_recovery_note);
    require(read(f / "destination/a") == "USER_CHANGED_COMPLETED_ITEM" && read(f / "destination/b") == "SECOND", "Directory recovery replayed completed data");
    require(fs::status(f / "destination").permissions() == fs::status(f / "source").permissions(), "Recovered directory access not restored");
  }
  fs::permissions(f / "source", fs::owner_all); fs::permissions(f / "destination", fs::owner_all);
}
static void cancel_live() {
  Fixture f; write(f / "source", std::string(1024 * 1024, 'x'));
  {
    auto jobs = make_file_jobs(); jobs->enable_recovery(f / "journal"); jobs->set_transfer_rate(128 * 1024);
    auto job = copy_job(f / "source", f / "destination"); jobs->add_job(job);
    until([&] { return job->_copy_bytes > 0; }, "Cancellation copy never started");
    require(jobs->cancel(1) == JobError::OK, "Explicit cancel failed"); jobs->shutdown();
  }
  auto jobs = make_file_jobs(); jobs->enable_recovery(f / "journal");
  require(by_id(*jobs, 1)->_state == JobState::CANCELLED, "Explicit cancellation recovered as paused");
  require(jobs->resume(1) == JobError::NOT_FOUND && !fs::exists(f / "destination"), "Cancelled job resumed");
  auto job = by_id(*jobs, 1); jobs->dismiss_job(1); job->updated();
  require(!fs::exists(f / "journal/1.plan.json") && !fs::exists(f / "journal/1.state.json"), "Dismissed journal resurrected");
}
static void invalid_recovery() {
  Fixture f; write(f / "source", "source");
  auto job = copy_job(f / "source", f / "destination"); job->_job_id = 1;
  auto journal = TransferJournal::create(f / "journal", *job);
  auto state = boost::json::parse(read(f / "journal/1.state.json")).as_object();
  state["phase"] = "unknown";
  write(f / "journal/1.state.json", boost::json::serialize(state));
  auto jobs = make_file_jobs(); jobs->enable_recovery(f / "journal");
  require(jobs->idle() && jobs->get_job_history().empty() && jobs->error_count() > 0, "Corrupt recovery not reported");
  require(fs::exists(f / "journal/1.plan.json") && !fs::exists(f / "destination"), "Corrupt record destroyed or executed");
  auto next = copy_job(f / "source", f / "next"); require(jobs->add_job(next) == 2, "Corrupt journal ID reused");
  until([&] { return jobs->idle(); }, "Following copy timed out");
}
static void blocked_recovery() {
  Fixture f; fs::create_directory(f / "parent"); write(f / "source", "source");
  auto job = copy_job(f / "source", f / "parent/destination"); job->_job_id = 1;
  auto journal = TransferJournal::create(f / "journal", *job);
  fs::rename(f / "parent", f / "old_parent"); fs::create_directory(f / "parent");
  auto jobs = make_file_jobs(); jobs->enable_recovery(f / "journal"); paused(*jobs, 1);
  require(jobs->resume(1) == JobError::RECOVERY_BLOCKED && !fs::exists(f / "parent/destination"), "Replaced parent or volume accepted");
  jobs->shutdown();
  auto restart = make_file_jobs(); restart->enable_recovery(f / "journal"); paused(*restart, 1);
}
static void unsupported_recovery() {
  Fixture f; fs::create_directory(f / "source"); write(f / "source/retained", "do not delete");
  auto plan = std::make_shared<OperationPlan>(selection_plan(OperationType::DELETE, {f / "source"}));
  auto job = std::make_shared<JobSpec>(plan); job->_job_id = 1;
  auto journal = TransferJournal::create(f / "journal", *job);
  job->_items_done = 3; // Some discovered children were deleted before interruption.
  journal->checkpoint(*job->snapshot(), JobState::RUNNING);
  auto jobs = make_file_jobs(); jobs->enable_recovery(f / "journal"); paused(*jobs, 1);
  require(by_id(*jobs, 1)->_items_done == 3, "Discovered delete progress was lost");
  require(jobs->resume(1) == JobError::RECOVERY_BLOCKED, "Interrupted delete was replayed");
  require(read(f / "source/retained") == "do not delete", "Startup or Resume deleted unverified files");
  require(jobs->cancel(1) == JobError::OK, "Unsupported recovery cannot be cancelled");
}

int main(int argc, char** argv) {
  try {
    executable = fs::absolute(argv[0]).native();
    if (argc == 5 && std::string(argv[1]) == "--child") return child(argv[2], argv[3], argv[4]);
    require(argc == 2, "Recovery case required");
    std::string name = argv[1];
    if (name == "states") states();
    else if (name == "copy_before_commit") copies("commit");
    else if (name == "copy_after_commit") copies("committed");
    else if (name == "copy_progress") copies("second_commit");
    else if (name == "move_rename") moves("move_renamed");
    else if (name == "move_commit") moves("source_remove");
    else if (name == "move_cleanup") moves("recovery_source_item", false, true);
    else if (name == "move_conflict") moves("source_remove", true);
    else if (name == "shutdown") shutdown_recovery();
    else if (name == "directory") directory_recovery();
    else if (name == "cancel") cancel_live();
    else if (name == "invalid") invalid_recovery();
    else if (name == "blocked") blocked_recovery();
    else if (name == "unsupported") unsupported_recovery();
    else throw std::runtime_error("Unknown recovery case");
    std::cout << "PASS transfer recovery " << name << '\n';
  } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
