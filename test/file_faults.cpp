#include <sys/stat.h>
#include <unistd.h>
#include <iostream>
#include "file_io_jobs.hpp"
#include "settings.hpp"
#include "support/contracts.hpp"
using namespace test;
using namespace Perun;
struct Fault {
  std::string phase;
  int         error = EIO, reads = 0, writes = 0;
  bool        retry = false, short_write = false, zero = false, exdev = false;
  static int  boundary(void* opaque, const char* phase) {
    auto& f = *static_cast<Fault*>(opaque);
    if (f.exdev && std::string(phase) == "move_rename") return EXDEV;
    return f.phase == phase ? f.error : 0;
  }
  static std::ptrdiff_t input(void* opaque, int fd, void* bytes, size_t count) {
    auto& f = *static_cast<Fault*>(opaque);
    ++f.reads;
    if (f.phase == "read" || (f.retry && f.reads == 1)) {
      errno = f.retry ? EINTR : f.error;
      return -1;
    }
    return ::read(fd, bytes, count);
  }
  static std::ptrdiff_t output(void* opaque, int fd, const void* bytes, size_t count) {
    auto& f = *static_cast<Fault*>(opaque);
    ++f.writes;
    if (f.zero) return 0;
    if (f.phase == "write" || (f.retry && f.writes == 1)) {
      errno = f.retry ? EINTR : f.error;
      return -1;
    }
    return ::write(fd, bytes, f.short_write ? std::min(count, size_t{7}) : count);
  }
  boost::filesystem::copy_file_io_hooks hooks() { return {this, input, output, boundary}; }
};
static void no_staging(const Fixture& f) {
  for (fs::directory_iterator it(f.root), end; it != end; ++it)
    require(it->path().filename().string().find("fc-copy-") == std::string::npos && it->path().filename().string().find(".fc-move-") == std::string::npos,
            "owned staging leaked");
}
void copy_faults() {
  Fixture     f;
  std::string payload(65539, 'x');
  payload[31] = '\0';
  write(f / "src", payload);
  write(f / "neighbor", "keep");
  for (auto phase : {"open", "read", "write", "flush", "close", "commit", "zero", "retry", "short", "success"}) {
    Fault fault;
    fault.phase                 = phase;
    fault.error                 = std::string(phase) == "write" ? ENOSPC : EIO;
    fault.zero                  = fault.phase == "zero";
    fault.retry                 = fault.phase == "retry";
    fault.short_write           = fault.phase == "short";
    auto                  hooks = fault.hooks();
    fs::copy_file_options options;
    options.io      = &hooks;
    options.options = fs::copy_options::overwrite_existing | fs::copy_options::synchronize;
    write(f / "dst", "old");
    boost::system::error_code ec;
    bool                      result  = fs::copy_file(f / "src", f / "dst", options, ec);
    bool                      success = fault.retry || fault.short_write || fault.phase == "success";
    require(result == success && bool(ec) != success, "copy outcome: " + fault.phase);
    require(read(f / "dst") == (success ? payload : "old"), "destination changed before commit: " + fault.phase);
    require(read(f / "src") == payload && read(f / "neighbor") == "keep", "source/neighbor changed");
    no_staging(f);
    if (fault.retry) require(fault.reads > 1 && fault.writes > 1, "EINTR did not retry");
    if (fault.short_write) require(fault.writes > 100, "short writes not exercised");
  }
}
void long_names() {
  Fixture f;
  const long limit = ::pathconf(f.root.c_str(), _PC_NAME_MAX);
  require(limit > 0 && limit <= 4096, "cannot determine fixture filename limit");
  write(f / "source", "complete payload");
  std::string name(static_cast<size_t>(limit), 'n');
  auto destination = f / name;
  for (auto phase : {"success", "commit"}) {
    write(destination, "old");
    Fault fault;
    fault.phase = phase;
    auto hooks = fault.hooks();
    fs::copy_file_options options;
    options.io = &hooks;
    options.options = fs::copy_options::overwrite_existing;
    boost::system::error_code ec;
    const bool copied = fs::copy_file(f / "source", destination, options, ec);
    const bool success = fault.phase == "success";
    require(copied == success && bool(ec) != success, "NAME_MAX copy outcome");
    require(read(destination) == (success ? "complete payload" : "old"), "NAME_MAX commit preservation");
    no_staging(f);
  }
}
void settings_faults() {
  Fixture f;
  for (auto phase : {"open", "write", "flush", "close", "commit", "zero", "retry", "short"}) {
    Fault fault;
    fault.phase       = phase;
    fault.zero        = fault.phase == "zero";
    fault.retry       = fault.phase == "retry";
    fault.short_write = fault.phase == "short";
    auto hooks        = fault.hooks();
    write(f / "settings", "old");
    bool failed = false;
    try {
      SettingsStore::atomic_write(f / "settings", std::string(40, 'n'), {}, &hooks);
    } catch (const std::exception&) { failed = true; }
    bool success = fault.retry || fault.short_write;
    require(failed != success, "settings outcome: " + fault.phase);
    require(read(f / "settings") == (success ? std::string(40, 'n') : "old"), "settings replacement corrupted old file");
    require(std::distance(fs::directory_iterator(f.root), fs::directory_iterator()) == 1, "settings staging leaked");
  }
}
void move_faults() {
  for (auto phase : {"read", "write", "move_commit", "source_remove", "success"}) {
    Fixture f;
    write(f / "source", "complete payload");
    write(f / "destination", "old");
    Fault fault;
    fault.phase           = phase;
    fault.exdev           = true;
    auto            hooks = std::make_shared<fs::copy_file_io_hooks>(fault.hooks());
    FileJobServices services;
    services.file_io = hooks;
    auto jobs        = make_file_jobs({}, services);
    auto plan        = std::make_shared<OperationPlan>();
    plan->type       = OperationType::MOVE;
    plan->steps.push_back({Operation::Kind::MoveEntry, f / "source", f / "destination"});
    auto job = std::make_shared<JobSpec>(plan);
    jobs->add_job(job);
    until([&] { return jobs->idle(); }, "move fault job timed out");
    bool success = fault.phase == "success", committed = success || fault.phase == "source_remove";
    require(job->_state == (success ? JobState::COMPLETED : JobState::COMPLETED_WITH_ERRORS), "move state: " + fault.phase);
    auto snapshot = job->snapshot();
    require(snapshot->_items_done == 1 && snapshot->_items_failed == !success, "move counters");
    require(fs::exists(f / "source") != success, "source deleted before complete move");
    require(read(f / "destination") == (committed ? "complete payload" : "old"), "move commit boundary violated");
    no_staging(f);
  }
}
void partial_copy() {
  Fixture f;
  write(f / "first", "one");
  write(f / "second", "two");
  fs::create_directory(f / "out");
  write(f / "out/second", "old");
  int  commits   = 0;
  auto hooks     = std::make_shared<fs::copy_file_io_hooks>();
  hooks->context = &commits;
  hooks->fault   = [](void* p, const char* phase) { return std::string(phase) == "commit" && ++*static_cast<int*>(p) == 2 ? EACCES : 0; };
  FileJobServices services;
  services.file_io = hooks;
  auto jobs        = make_file_jobs({}, services);
  auto plan        = std::make_shared<OperationPlan>();
  plan->steps      = {{Operation::Kind::CopyFile, f / "first", f / "out/first"}, {Operation::Kind::CopyFile, f / "second", f / "out/second"}};
  auto job         = std::make_shared<JobSpec>(plan);
  jobs->add_job(job);
  until([&] { return jobs->idle(); }, "partial copy timeout");
  require(job->_state == JobState::COMPLETED_WITH_ERRORS && job->snapshot()->_items_done == 2 && job->snapshot()->_items_failed == 1, "partial copy counters");
  require(read(f / "out/first") == "one" && read(f / "out/second") == "old" && read(f / "second") == "two", "partial completed subset incorrect");
}
int exdev() {
  const char* configured = std::getenv("FC_TEST_EXDEV_ROOT");
  Filepath    other      = configured ? configured : "/dev/shm";
  Fixture     source;
  struct stat first {
  }, second{};
  if (::stat(source.root.c_str(), &first) != 0 || ::stat(other.c_str(), &second) != 0 || first.st_dev == second.st_dev) {
    std::cout << "SKIP EXDEV: need writable FC_TEST_EXDEV_ROOT on a different st_dev\n";
    return std::getenv("FC_REQUIRE_EXDEV") ? 1 : 77;
  }
  Fixture destination(other);
  write(source / "file", std::string("real\0EXDEV", 10));
  auto plan  = std::make_shared<OperationPlan>();
  plan->type = OperationType::MOVE;
  plan->steps.push_back({Operation::Kind::MoveEntry, source / "file", destination / "file"});
  auto jobs = make_file_jobs();
  auto job  = std::make_shared<JobSpec>(plan);
  jobs->add_job(job);
  until([&] { return jobs->idle(); }, "EXDEV move timeout");
  require(job->_state == JobState::COMPLETED && !fs::exists(source / "file") && read(destination / "file") == std::string("real\0EXDEV", 10),
          "real EXDEV move failed");
  return 0;
}
int main(int argc, char** argv) {
  try {
    std::string name = argc > 1 ? argv[1] : "all";
    if (name == "exdev") return exdev();
    require(name == "all" || name == "copy" || name == "long_names" || name == "settings" || name == "move" || name == "partial", "unknown file fault case");
    if (name == "copy" || name == "all") copy_faults();
    if (name == "long_names" || name == "all") long_names();
    if (name == "settings" || name == "all") settings_faults();
    if (name == "move" || name == "all") move_faults();
    if (name == "partial" || name == "all") partial_copy();
    std::cout << "PASS file faults " << name << "\n";
  } catch (const std::exception& error) {
    std::cerr << error.what() << "\n";
    return 1;
  }
}
