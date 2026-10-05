#include <sys/stat.h>
#include <sys/xattr.h>
#include <fcntl.h>
#include <unistd.h>
#include <iostream>
#include "file_io_jobs.hpp"
#include "copy_planner.hpp"
#include "log.hpp"
#include "settings.hpp"
#include "support/contracts.hpp"
#if defined(__APPLE__)
#include <sys/acl.h>
#endif
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
void rename_conflicts() {
  Fixture f;
  auto jobs = make_file_jobs();
  auto run = [&](std::vector<Operation> steps, size_t failures, FileJobs* manager = nullptr) {
    auto plan = std::make_shared<OperationPlan>();
    plan->type = OperationType::RENAME;
    plan->steps = std::move(steps);
    auto job = std::make_shared<JobSpec>(plan);
    auto& executor = manager ? *manager : *jobs;
    executor.add_job(job);
    until([&] { return executor.idle(); }, "rename conflict timeout");
    require(job->snapshot()->_items_failed == failures, "rename failure accounting");
    require(job->_state == (failures ? JobState::COMPLETED_WITH_ERRORS : JobState::COMPLETED), "rename outcome");
  };
  write(f / "A", "original A"); write(f / "B", "original B");
  run({{Operation::Kind::RenameEntry, f / "A", f / "B"}, {Operation::Kind::RenameEntry, f / "B", f / "A"}}, 2);
  require(read(f / "A") == "original A" && read(f / "B") == "original B", "rename swap lost original bytes");
  run({{Operation::Kind::RenameEntry, f / "A", f / "new"}, {Operation::Kind::RenameEntry, f / "B", f / "new"}}, 2);
  require(read(f / "A") == "original A" && read(f / "B") == "original B" && !fs::exists(f / "new"), "duplicate targets mutated originals");
  fs::create_symlink("missing", f / "dangling");
  run({{Operation::Kind::RenameEntry, f / "A", f / "dangling"}}, 1);
  require(fs::read_symlink(f / "dangling") == Filepath("missing") && read(f / "A") == "original A", "rename replaced dangling destination");
  const auto late = f / "late";
  auto hooks = std::make_shared<fs::copy_file_io_hooks>();
  hooks->context = const_cast<Filepath*>(&late);
  hooks->fault = [](void* context, const char* phase) {
    if (std::string(phase) == "rename_commit") write(*static_cast<Filepath*>(context), "competing creator");
    return 0;
  };
  FileJobServices services; services.file_io = hooks;
  auto racing = make_file_jobs({}, services);
  run({{Operation::Kind::RenameEntry, f / "A", late}}, 1, racing.get());
  require(read(late) == "competing creator" && read(f / "A") == "original A", "rename clobbered late destination");
  run({{Operation::Kind::RenameEntry, f / "A", f / "A"}}, 0);
  run({{Operation::Kind::RenameEntry, f / "absent", f / "absent"}}, 1);
  run({{Operation::Kind::RenameEntry, f / "A", f / "renamed"}}, 0);
  require(!fs::exists(f / "A") && read(f / "renamed") == "original A", "ordinary rename failed");
}
#if defined(__APPLE__)
void fixture_acl(const Filepath& path, acl_tag_t tag) {
  acl_t acl = ::acl_init(1);
  require(acl != nullptr, "ACL fixture allocation");
  Defer free_acl([&] { ::acl_free(acl); });
  acl_entry_t entry;
  const unsigned char qualifier[16] = {0x42, 0x11, 0x77, 0x22, 0x35, 0x65, 0x11, 0x45, 0x83, 0x55, 0x77, 0x55, 0x15, 0x25, 0x99, 0x81};
  require(::acl_create_entry(&acl, &entry) == 0 && ::acl_set_tag_type(entry, tag) == 0 && ::acl_set_qualifier(entry, qualifier) == 0, "ACL fixture entry");
  acl_permset_t permissions;
  acl_flagset_t flags;
  require(::acl_get_permset(entry, &permissions) == 0 && ::acl_add_perm(permissions, ACL_READ_DATA) == 0, "ACL fixture permissions");
  require(::acl_get_flagset_np(entry, &flags) == 0 && ::acl_add_flag_np(flags, ACL_ENTRY_DIRECTORY_INHERIT) == 0, "ACL fixture inheritance");
  require(::acl_set_file(path.c_str(), ACL_TYPE_EXTENDED, acl) == 0, "ACL fixture publication");
}
std::vector<char> access_acl(const Filepath& path) {
  auto acl = ::acl_get_file(path.c_str(), ACL_TYPE_EXTENDED);
  require(acl != nullptr, "ACL fixture read");
  Defer free_acl([&] { ::acl_free(acl); });
  std::vector<char> bytes(static_cast<size_t>(::acl_size(acl)));
  require(::acl_copy_ext(bytes.data(), acl, bytes.size()) >= 0, "ACL fixture serialization");
  return bytes;
}
bool empty_acl(const Filepath& path) {
  auto acl = ::acl_get_file(path.c_str(), ACL_TYPE_EXTENDED);
  if (!acl) return errno == ENOENT;
  Defer free_acl([&] { ::acl_free(acl); });
  acl_entry_t entry;
  return ::acl_get_entry(acl, ACL_FIRST_ENTRY, &entry) != 0;
}
#endif
void directory_access() {
  Fixture f;
  fs::create_directories(f / "source/readonly");
  fs::create_directory(f / "out");
  write(f / "source/readonly/secret", "private bytes");
  fs::permissions(f / "source", static_cast<fs::perms>(0700));
  fs::permissions(f / "source/readonly", static_cast<fs::perms>(0550));
  Defer cleanup([&] {
    for (const auto& name : {"source", "source/readonly", "out/source", "out/source/readonly"}) {
      boost::system::error_code ec; fs::permissions(f / name, fs::owner_all, ec);
    }
  });
#if defined(__APPLE__)
  fixture_acl(f / "source", ACL_EXTENDED_DENY);
  fixture_acl(f / "out", ACL_EXTENDED_ALLOW);
#endif
  struct Observation { Filepath root; bool secure = false; } observation{f / "out/source"};
  auto hooks = std::make_shared<fs::copy_file_io_hooks>();
  hooks->context = &observation;
  hooks->fault = [](void* opaque, const char* phase) {
    if (std::string(phase) != "open") return 0;
    auto& observed = *static_cast<Observation*>(opaque);
    observed.secure = (fs::status(observed.root).permissions() & 0777) == 0700 &&
                      (fs::status(observed.root / "readonly").permissions() & 0777) == 0700;
#if defined(__APPLE__)
    observed.secure = observed.secure && empty_acl(observed.root) && empty_acl(observed.root / "readonly");
#endif
    return 0;
  };
  FileJobServices services; services.file_io = hooks;
  auto jobs = make_file_jobs({}, services);
  CopyPlanner planner({{f / "source"}, f / "out"}); planner._thread.join();
  auto plan = planner.take_plan();
  // Legacy discovery consumers must preserve source/destination identity too.
  auto roundtrip = legacy_plan(OperationType::COPY, legacy_plan_items(*plan), CopyConflictMode::Replace);
  require(roundtrip.steps.front().source == f / "source" && roundtrip.steps.front().destination == f / "out/source", "legacy directory identity lost");
  auto job = std::make_shared<JobSpec>(plan);
  jobs->add_job(job); until([&] { return jobs->idle(); }, "directory access copy timeout");
  require(job->_state == JobState::COMPLETED && observation.secure, "payload copied before securing new directories");
  require((fs::status(f / "out/source").permissions() & 0777) == 0700 &&
          (fs::status(f / "out/source/readonly").permissions() & 0777) == 0550, "directory mode was not preserved");
  require(read(f / "out/source/readonly/secret") == "private bytes", "read-only source directory prevented population");
#if defined(__APPLE__)
  require(access_acl(f / "source") == access_acl(f / "out/source"), "directory ACL was not preserved");
#endif
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
  for (auto phase : {"read", "write", "move_metadata", "move_metadata_verify", "move_commit", "source_remove", "success"}) {
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
void set_attribute(const Filepath& path, const char* name, const std::string& value) {
#if defined(__APPLE__)
  const auto result = ::setxattr(path.c_str(), name, value.data(), value.size(), 0, XATTR_NOFOLLOW);
#else
  const auto result = ::lsetxattr(path.c_str(), name, value.data(), value.size(), 0);
#endif
  require(result == 0, "set metadata fixture xattr");
}
std::string attribute(const Filepath& path, const char* name) {
  std::vector<char> bytes(200000);
#if defined(__APPLE__)
  auto size = ::getxattr(path.c_str(), name, bytes.data(), bytes.size(), 0, XATTR_NOFOLLOW);
#else
  auto size = ::lgetxattr(path.c_str(), name, bytes.data(), bytes.size());
#endif
  require(size >= 0, "read moved xattr");
  return {bytes.data(), static_cast<size_t>(size)};
}
struct stat entry_stat(const Filepath& path) {
  struct stat info {};
  require(::lstat(path.c_str(), &info) == 0, "metadata stat");
  return info;
}
void same_metadata(const struct stat& before, const Filepath& after) {
  auto info = entry_stat(after);
  require((before.st_mode & 07777) == (info.st_mode & 07777) && before.st_uid == info.st_uid && before.st_gid == info.st_gid, "move access metadata lost");
#if defined(__APPLE__)
  auto a = before.st_mtimespec, b = info.st_mtimespec;
#else
  auto a = before.st_mtim, b = info.st_mtim;
#endif
  require(a.tv_sec == b.tv_sec && a.tv_nsec == b.tv_nsec, "move modification time lost");
}
void silent_metadata_failures() {
  std::vector<std::string> changes = {"mtime", "mode", "xattr"};
#if defined(__APPLE__)
  changes.push_back("acl"); changes.push_back("resourcefork");
#endif
  for (auto& change : changes) {
    Fixture f;
    write(f / "source", "original"); write(f / "destination", "old");
    fs::permissions(f / "source", static_cast<fs::perms>(0640));
    set_attribute(f / "source", "user.fc-test", "original");
#if defined(__APPLE__)
    fixture_acl(f / "source", ACL_EXTENDED_DENY);
    set_attribute(f / "source", "com.apple.ResourceFork", "original");
#endif
    struct Mutation { Filepath root; std::string kind; bool changed = false; } mutation{f.root, change};
    auto hooks = std::make_shared<fs::copy_file_io_hooks>(); hooks->context = &mutation;
    hooks->fault = [](void* context, const char* phase) {
      if (std::string(phase) == "move_rename") return EXDEV;
      if (std::string(phase) != "move_metadata_verify") return 0;
      auto& m = *static_cast<Mutation*>(context);
      for (fs::directory_iterator it(m.root), end; it != end; ++it) {
        if (!it->path().filename().string().starts_with(".fc-move-")) continue;
        auto path = it->path() / "entry";
        if (m.kind == "mode") fs::permissions(path, static_cast<fs::perms>(0600));
        if (m.kind == "mtime") { const timespec times[] = {{946684800, 0}, {946684800, 0}}; ::utimensat(AT_FDCWD, path.c_str(), times, 0); }
        if (m.kind == "xattr") set_attribute(path, "user.fc-test", "changed!");
#if defined(__APPLE__)
        if (m.kind == "acl") fixture_acl(path, ACL_EXTENDED_ALLOW);
        if (m.kind == "resourcefork") set_attribute(path, "com.apple.ResourceFork", "changed!");
#endif
        m.changed = true;
      }
      return 0; // Simulate an OS metadata API reporting success after losing data.
    };
    FileJobServices services; services.file_io = hooks;
    auto jobs = make_file_jobs({}, services);
    auto plan = std::make_shared<OperationPlan>(); plan->type = OperationType::MOVE;
    plan->steps.push_back({Operation::Kind::MoveEntry, f / "source", f / "destination"});
    auto job = std::make_shared<JobSpec>(plan); jobs->add_job(job);
    until([&] { return jobs->idle(); }, "silent metadata error timeout");
    require(mutation.changed && job->_state == JobState::COMPLETED_WITH_ERRORS, "silent metadata loss accepted: " + change);
    require(read(f / "source") == "original" && read(f / "destination") == "old", "silent metadata error lost original: " + change);
    no_staging(f);
  }
}
void immutable_staging_cleanup() {
#if defined(__APPLE__)
  Fixture f;
  write(f / "source", "locked source");
  Defer unlock([&] { ::chflags((f / "source").c_str(), 0); });
  require(::chflags((f / "source").c_str(), UF_IMMUTABLE) == 0, "immutable source fixture");
  Fault fault; fault.exdev = true; fault.phase = "move_commit";
  FileJobServices services; services.file_io = std::make_shared<fs::copy_file_io_hooks>(fault.hooks());
  auto jobs = make_file_jobs({}, services);
  auto plan = std::make_shared<OperationPlan>(); plan->type = OperationType::MOVE;
  plan->steps.push_back({Operation::Kind::MoveEntry, f / "source", f / "destination"});
  auto job = std::make_shared<JobSpec>(plan); jobs->add_job(job);
  until([&] { return jobs->idle(); }, "immutable staging cleanup timeout");
  require(job->_state == JobState::COMPLETED_WITH_ERRORS && read(f / "source") == "locked source", "immutable rollback lost source");
  require((entry_stat(f / "source").st_flags & UF_IMMUTABLE) != 0, "cleanup modified source flags");
  no_staging(f);
#endif
}
void move_metadata() {
  Fixture f;
  fs::create_directories(f / "source/child");
  write(f / "source/child/file", "metadata payload");
  write(f / "outside", "do not follow");
  fs::create_symlink("../../outside", f / "source/child/link");
  fs::create_symlink(f / "outside", f / "source/child/absolute");
  fs::permissions(f / "source", static_cast<fs::perms>(0750));
  fs::permissions(f / "source/child/file", static_cast<fs::perms>(0640));
  set_attribute(f / "source/child/file", "user.fc-test", "file attribute");
  set_attribute(f / "source", "user.fc-test", "directory attribute");
#if defined(__APPLE__)
  set_attribute(f / "source/child/file", "com.apple.ResourceFork", std::string(150000, 'r'));
  fixture_acl(f / "source", ACL_EXTENDED_DENY);
  fixture_acl(f / "source/child/file", ACL_EXTENDED_DENY);
  const auto directory_acl = access_acl(f / "source"), file_acl = access_acl(f / "source/child/file");
#endif
  const timespec times[] = {{946684800, 123456789}, {946684801, 987654321}};
  for (auto name : {"source/child/file", "source/child/link", "source/child", "source", "outside"})
    require(::utimensat(AT_FDCWD, (f / name).c_str(), times, AT_SYMLINK_NOFOLLOW) == 0, "timestamp fixture");
  auto root_info = entry_stat(f / "source"), child_info = entry_stat(f / "source/child"), file_info = entry_stat(f / "source/child/file"),
       link_info = entry_stat(f / "source/child/link"), outside_info = entry_stat(f / "outside");
  const auto absolute_info = entry_stat(f / "source/child/absolute");
  Fault fault; fault.exdev = true;
  FileJobServices services; services.file_io = std::make_shared<fs::copy_file_io_hooks>(fault.hooks());
  auto jobs = make_file_jobs({}, services);
  auto run = [&] {
    auto plan = std::make_shared<OperationPlan>(); plan->type = OperationType::MOVE;
    plan->steps.push_back({Operation::Kind::MoveEntry, f / "source", f / "destination"});
    auto job = std::make_shared<JobSpec>(plan); jobs->add_job(job);
    until([&] { return jobs->idle(); }, "move metadata timeout");
    return job;
  };
  // Failure after restoring a read-only child's metadata must clean staging.
  fs::permissions(f / "source/child", static_cast<fs::perms>(0550));
  fault.phase = "move_commit";
  require(run()->_state == JobState::COMPLETED_WITH_ERRORS, "metadata rollback state");
  require(read(f / "source/child/file") == "metadata payload" && !fs::exists(f / "destination"), "metadata rollback damaged originals");
  no_staging(f);
  fs::permissions(f / "source/child", static_cast<fs::perms>(child_info.st_mode & 07777));
  fault.phase.clear();
  require(run()->_state == JobState::COMPLETED && !fs::exists(f / "source"), "metadata move failed");
  require(read(f / "destination/child/file") == "metadata payload", "metadata move payload");
  same_metadata(root_info, f / "destination"); same_metadata(child_info, f / "destination/child");
  same_metadata(file_info, f / "destination/child/file"); same_metadata(link_info, f / "destination/child/link");
  same_metadata(outside_info, f / "outside");
  same_metadata(absolute_info, f / "destination/child/absolute");
  require(fs::read_symlink(f / "destination/child/link") == Filepath("../../outside"), "move followed symlink");
  require(attribute(f / "destination/child/file", "user.fc-test") == "file attribute" &&
          attribute(f / "destination", "user.fc-test") == "directory attribute", "move xattrs lost");
#if defined(__APPLE__)
  require(attribute(f / "destination/child/file", "com.apple.ResourceFork") == std::string(150000, 'r'), "resource fork lost");
  require(access_acl(f / "destination") == directory_acl && access_acl(f / "destination/child/file") == file_acl, "move ACL lost");
#endif
  no_staging(f);
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
    require(name == "all" || name == "copy" || name == "long_names" || name == "rename" || name == "directory_access" || name == "settings" || name == "move" || name == "move_metadata" || name == "partial", "unknown file fault case");
    if (name == "copy" || name == "all") copy_faults();
    if (name == "long_names" || name == "all") long_names();
    if (name == "rename" || name == "all") rename_conflicts();
    if (name == "directory_access" || name == "all") directory_access();
    if (name == "settings" || name == "all") settings_faults();
    if (name == "move" || name == "all") move_faults();
    if (name == "move_metadata" || name == "all") { move_metadata(); silent_metadata_failures(); immutable_staging_cleanup(); }
    if (name == "partial" || name == "all") partial_copy();
    std::cout << "PASS file faults " << name << "\n";
  } catch (const std::exception& error) {
    std::cerr << error.what() << "\n";
    return 1;
  }
}
