#include "copy_planner.hpp"
#include "file_io_jobs.hpp"
#include "remote_fs.hpp"
#include "remote_protocol.hpp"
#include "sha256.hpp"
#include "support/contracts.hpp"
#include "transfer_journal.hpp"
#include <iostream>
#include <sstream>
using namespace Perun;
using test::require;
static void done(FileJobs &jobs, const std::shared_ptr<JobSpec> &job) {
  test::until([&] { return jobs.idle(); }, "Transfer timed out");
  require(job->_state == JobState::COMPLETED, "Transfer failed: " + job->snapshot()->_recovery_note);
}
static std::shared_ptr<JobSpec> copy_job(const Filepath &source, const Filepath &dest) {
  auto plan = std::make_shared<OperationPlan>();
  plan->steps.push_back({Operation::Kind::CopyFile, source, dest, {}, "", RemoteFS::inspect(source).size});
  return std::make_shared<JobSpec>(plan);
}
static void streaming_pipeline_contracts(FileJobs &jobs, const test::Fixture &local, const Filepath &remote) {
  const std::string data(2 * 1024 * 1024 + 17, char(0xac));
  test::write(local / "gap-first", data);
  boost::filesystem::create_directory(local / "gap-dir");
  test::write(local / "gap-dir/second", data);
  boost::filesystem::create_symlink("gap-first", local / "gap-link");
  const auto gate = local / "stream-gate", trace = local / "stream-trace";
  setenv("FC_SSH_FIXTURE_STREAM_GATE", gate.c_str(), 1);
  setenv("FC_SSH_FIXTURE_STREAM_TRACE", trace.c_str(), 1);
  RemoteFS::close_connections();
  auto plan = std::make_shared<OperationPlan>();
  plan->steps = {
      {Operation::Kind::CopyFile, local / "gap-first", remote / "gap-first", {}, "", int64_t(data.size())},
      {Operation::Kind::CreateDirectory, local / "gap-dir", remote / "gap-dir"},
      {Operation::Kind::CreateSymlink, local / "gap-link", remote / "gap-link", Filepath("gap-first")},
      {Operation::Kind::CopyFile, local / "gap-dir/second", remote / "gap-dir/second", {}, "", int64_t(data.size())}};
  auto job = std::make_shared<JobSpec>(plan);
  jobs.add_job(job); done(jobs, job);
  require(boost::filesystem::exists(Filepath(gate.native() + ".entered")) &&
              boost::filesystem::exists(Filepath(gate.native() + ".second-ended")),
          "Second file did not stream while the previous fsync was blocked");
  auto snapshot = job->snapshot();
  require(snapshot->_transfer_written == 2 * data.size() && snapshot->_transfer_verified == 2 * data.size() &&
              snapshot->_transfer_durable == 2 * data.size(), "Pipeline progress did not track written/verified/durable bytes");
  require(RemoteFS::digest(remote / "gap-first") == RemoteFS::digest(local / "gap-first") &&
              RemoteFS::digest(remote / "gap-dir/second") == RemoteFS::digest(local / "gap-dir/second") &&
              RemoteFS::inspect(remote / "gap-link").link == "gap-first", "Pipeline changed files or symbolic links");
  require(RemoteFS::inspect(remote / "gap-dir").mtime_ns == RemoteFS::inspect(local / "gap-dir").mtime_ns,
          "Look-ahead directory metadata was not finalized");
  std::istringstream records(test::read(trace));
  uint64_t time, identity, length, bytes = 0, frames = 0;
  int pid, kind, operation;
  std::string direction;
  while (records >> time >> pid >> direction >> kind >> operation >> identity >> length)
    if (direction == "in" && kind == RemoteFS::Wire::Data && operation == RemoteFS::Wire::opcode("stream_write")) {
      bytes += length; ++frames;
    }
  require(bytes == 2 * data.size() && frames >= 6, "Wire data was expanded, missing or not framed as raw bytes");
  unsetenv("FC_SSH_FIXTURE_STREAM_GATE"); unsetenv("FC_SSH_FIXTURE_STREAM_TRACE");
  RemoteFS::close_connections();

  for (const auto &fault : {"corrupt", "disk-full"}) {
    setenv("FC_SSH_FIXTURE_STREAM_FAULT", fault, 1);
    auto fault_plan = std::make_shared<OperationPlan>();
    for (int n = 0; n < 2; ++n)
      fault_plan->steps.push_back({Operation::Kind::CopyFile, local / "gap-first",
          remote / (std::string(fault) + std::to_string(n)), {}, "", int64_t(data.size())});
    auto failed = std::make_shared<JobSpec>(fault_plan);
    jobs.add_job(failed);
    test::until([&] { return jobs.idle(); }, "Streaming fault did not stop the job");
    require(failed->_state == JobState::PAUSED && !RemoteFS::inspect(fault_plan->steps[0].destination).exists &&
                !RemoteFS::inspect(fault_plan->steps[1].destination).exists &&
                RemoteFS::inspect(local / "gap-first").exists,
            "Corrupt or full destination published output or removed its source");
    unsetenv("FC_SSH_FIXTURE_STREAM_FAULT"); RemoteFS::close_connections();
    jobs.resume(failed->_job_id); done(jobs, failed);
    for (const auto &op : fault_plan->steps)
      require(RemoteFS::digest(op.destination) == RemoteFS::digest(op.source), "Resumed fault published incorrect bytes");
  }
}
static void pending_recovery_contracts(const test::Fixture &local, const Filepath &remote) {
  for (bool replaced : {false, true}) {
    auto prefix = replaced ? "pending-blocked" : "pending";
    auto plan = std::make_shared<OperationPlan>();
    for (int n = 0; n < 2; ++n) {
      const auto name = std::string(prefix) + std::to_string(n);
      test::write(local / name, "complete pending content");
      plan->steps.push_back({Operation::Kind::CopyFile, local / name, remote / name, {}, "", 24});
    }
    auto job = std::make_shared<JobSpec>(plan); job->_job_id = 300;
    auto directory = local / (std::string(prefix) + "-journal");
    boost::filesystem::create_directory(directory);
    auto record = TransferJournal::create(directory, *job); record->prepare_inputs();
    std::vector<Filepath> roots;
    for (int n = 0; n < 2; ++n) {
      auto root = remote / boost::filesystem::unique_path(".fc-copy-%%%%%%%%-%%%%%%%%");
      RemoteFS::mkdir(root); roots.push_back(root);
      record->stage_pending(n, root / "data");
      RemoteFS::write(root / "data", 0, "partial", true);
    }
    record->checkpoint(*job->snapshot(), JobState::RUNNING);
    if (replaced) {
      RemoteFS::rename(roots[1], remote / "replaced-stage-backup");
      RemoteFS::mkdir(roots[1]);
      RemoteFS::write(roots[1] / "unrelated", 0, "keep", true);
    }
    auto recovery = make_file_jobs(); recovery->enable_recovery(directory);
    auto history = recovery->get_job_history();
    require(history.size() == 1 && history[0]->_state == JobState::PAUSED && recovery->idle(),
            "Pending pipeline performed work at startup");
    require(RemoteFS::inspect(roots[0] / "data").exists, "Startup removed pending output without Resume");
    recovery->resume(300);
    test::until([&] { return recovery->idle(); }, "Pending pipeline recovery timed out");
    if (replaced) {
      require(history[0]->_state == JobState::PAUSED &&
                  history[0]->snapshot()->_recovery_note.find("ownership changed") != std::string::npos,
              "Replaced pending stage did not block recovery");
      require(RemoteFS::inspect(roots[0] / "data").exists && RemoteFS::inspect(roots[1] / "unrelated").exists,
              "Recovery cleaned stages before checking all ownership records");
    } else {
      done(*recovery, history[0]);
      for (int n = 0; n < 2; ++n) {
        require(!RemoteFS::inspect(roots[n]).exists, "Resume left incomplete look-ahead output");
        const auto name = std::string(prefix) + std::to_string(n);
        require(RemoteFS::read(remote / name, 0, 100) == "complete pending content", "Resume published partial output");
      }
    }
  }
}
static void metadata_contracts(FileJobs &jobs, const test::Fixture &local, const Filepath &remote) {
  const std::string name = "user.fc.transfer-warning";
  const boost::json::object attrs{{name, "metadata retained on matching platforms"}};
  test::write(local / "attrs-file", "file with metadata");
  RemoteFS::attributes(local / "attrs-file", attrs);
#if defined(__APPLE__)
  const char *other_platform = "linux";
#else
  const char *other_platform = "darwin";
#endif
  RemoteFS::close_connections();
  setenv("FC_SSH_FIXTURE_PLATFORM", other_platform, 1);
  auto warned = [&](const std::shared_ptr<JobSpec> &job, const Filepath &source, const Filepath &target) {
    done(jobs, job);
    require(job->_items_failed == 0 && job->_errors.empty(), "Metadata warning marked the job failed");
    bool found = false;
    for (const auto &error : jobs.get_errors(100))
      found |= error.message.starts_with("[Transfer warning]") &&
               error.message.find(source.native()) != std::string::npos;
    require(found, "Skipped metadata was not reported as a warning: " + source.native());
    require(!RemoteFS::attributes(target).at("attributes").as_object().contains(name),
            "Cross-platform attribute was applied to the target");
    jobs.clear_errors();
  };
  auto copy = [&](const Filepath &source, const Filepath &target) {
    auto job = copy_job(source, target);
    jobs.add_job(job);
    warned(job, source, target);
    require(RemoteFS::digest(source) == RemoteFS::digest(target), "Metadata warning changed file content");
    require(RemoteFS::attributes(source).at("attributes").as_object().at(name) == attrs.at(name),
            "Copy discarded source metadata");
  };
  copy(local / "attrs-file", remote / "attrs-file");
  RemoteFS::attributes(remote / "attrs-file", attrs);
  copy(remote / "attrs-file", local / "attrs-download");

  // CopyPlanner applies directory metadata after its individual file steps.
  boost::filesystem::create_directory(local / "attrs-tree");
  test::write(local / "attrs-tree/child", "directory child");
  RemoteFS::attributes(local / "attrs-tree", attrs);
  auto copy_directory = [&](const Filepath &source, const Filepath &parent) {
    CopyRequest request;
    request.sources = {source};
    request.destination = parent;
    CopyPlanner planner(request);
    test::until([&] { return !planner._running.load(); }, "Metadata discovery timeout");
    auto job = std::make_shared<JobSpec>(planner.take_plan());
    jobs.add_job(job);
    auto target = parent / source.filename();
    warned(job, source, target);
    require(RemoteFS::read(target / "child", 0, 1024) == "directory child", "Directory copy lost content");
  };
  copy_directory(local / "attrs-tree", remote);
  RemoteFS::attributes(remote / "attrs-tree", attrs);
  boost::filesystem::create_directory(local / "attrs-tree-download");
  copy_directory(remote / "attrs-tree", local / "attrs-tree-download");

  // A cross-filesystem directory move uses the recursive staging path instead.
  auto plan = std::make_shared<OperationPlan>();
  plan->type = OperationType::MOVE;
  plan->steps.push_back({Operation::Kind::MoveEntry, local / "attrs-tree", remote / "attrs-moved"});
  auto move = std::make_shared<JobSpec>(plan);
  jobs.add_job(move);
  warned(move, local / "attrs-tree", remote / "attrs-moved");
  require(!RemoteFS::inspect(local / "attrs-tree").exists &&
              RemoteFS::read(remote / "attrs-moved/child", 0, 1024) == "directory child",
          "Metadata warning blocked verified move cleanup");

  // An ACL still blocks publication, even when ordinary xattrs are nonfatal.
  RemoteFS::close_connections();
  setenv("FC_SSH_FIXTURE_ACL", "1", 1);
  auto acl = copy_job(remote / "attrs-file", local / "attrs-acl-blocked");
  jobs.add_job(acl);
  test::until([&] { return jobs.idle(); }, "ACL validation timeout");
  require(acl->_state == JobState::PAUSED && !RemoteFS::inspect(local / "attrs-acl-blocked").exists &&
              acl->snapshot()->_recovery_note.find("Extended ACLs") != std::string::npos,
          "Unsupported ACL was treated as a nonfatal xattr warning");
  unsetenv("FC_SSH_FIXTURE_ACL");
  unsetenv("FC_SSH_FIXTURE_PLATFORM");
  RemoteFS::close_connections();
  jobs.clear_errors();
  auto preserved = copy_job(local / "attrs-file", remote / "attrs-preserved");
  jobs.add_job(preserved);
  done(jobs, preserved);
  require(RemoteFS::attributes(remote / "attrs-preserved").at("attributes").as_object().at(name) ==
              attrs.at(name) && jobs.get_errors(100).empty(),
          "Same-platform metadata was skipped or reported as a warning");
}
int main(int argc, char **argv) {
  std::string host = argc > 1 ? argv[1] : "fixture";
  auto remote = Location::decode("ssh://" + host + "/tmp/" +
                                 boost::filesystem::unique_path("fc-transfer-%%%%%%%%-%%%%%%%%").native())
                    .resource();
  test::Fixture local;
  bool created = false;
  try {
    Sha256 hash;
    hash.update("abc");
    require(hash.finish() == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "SHA-256 known vector failed");
    RemoteFS::mkdir(remote);
    created = true;
    auto jobs = make_file_jobs();
    jobs->enable_recovery(local / "journal");
    std::string data(2 * 1024 * 1024 + 17, 'x');
    data[0] = '\0';
    test::write(local / "alpha", data);
    auto upload = copy_job(local / "alpha", remote / "alpha");
    require(jobs->add_job(upload) > 0, "Upload rejected");
    done(*jobs, upload);
    require(RemoteFS::digest(remote / "alpha") == RemoteFS::digest(local / "alpha"), "Upload digest differs");
    auto download = copy_job(remote / "alpha", local / "download");
    jobs->add_job(download);
    done(*jobs, download);
    require(test::read(local / "download") == data, "Download differs");
    auto onhost = copy_job(remote / "alpha", remote / "onhost");
    jobs->add_job(onhost);
    done(*jobs, onhost);
    auto other =
        Location::decode("ssh://fixture-other" + Location::decode(remote.native()).local.native()).resource();
    if (host == "fixture") {
      auto relay = copy_job(remote / "alpha", other / "relay");
      jobs->add_job(relay);
      done(*jobs, relay);
      require(RemoteFS::digest(other / "relay") == RemoteFS::digest(remote / "alpha"),
              "Cross-host relay differs");
    }
    auto moveplan = std::make_shared<OperationPlan>();
    moveplan->type = OperationType::MOVE;
    moveplan->steps.push_back(
        {Operation::Kind::MoveEntry, local / "download", remote / "moved", {}, "", int64_t(data.size())});
    auto move = std::make_shared<JobSpec>(moveplan);
    jobs->add_job(move);
    done(*jobs, move);
    require(!RemoteFS::inspect(local / "download").exists && RemoteFS::inspect(remote / "moved").exists,
            "Move source cleanup failed");
    RemoteFS::mkdir(remote / "tree");
    RemoteFS::write(remote / "tree/child", 0, "tree data", true);
    RemoteFS::symlink("child", remote / "tree/link");
    CopyRequest request;
    request.sources = {remote / "tree"};
    request.destination = local.root;
    CopyPlanner planner(request);
    test::until([&] { return !planner._running.load(); }, "Remote discovery timeout");
    auto treejob = std::make_shared<JobSpec>(planner.take_plan());
    jobs->add_job(treejob);
    done(*jobs, treejob);
    require(test::read(local / "tree/child") == "tree data" &&
                boost::filesystem::read_symlink(local / "tree/link") == "child",
            "Tree/link copy failed");
    auto offline = copy_job(remote / "alpha", local / "recovered");
    offline->_job_id = 100;
    auto record = TransferJournal::create(local / "resume", *offline);
    record->prepare_inputs();
    record->checkpoint(*offline->snapshot(), JobState::RUNNING);
    {
      auto recovery = make_file_jobs();
      recovery->enable_recovery(local / "resume");
      auto history = recovery->get_job_history();
      require(history.size() == 1 && history[0]->_state == JobState::PAUSED && recovery->idle(),
              "Remote startup did not pause transfer");
      require(!RemoteFS::inspect(local / "recovered").exists, "Startup performed remote transfer");
      recovery->resume(100);
      done(*recovery, history[0]);
    }
    auto drift = copy_job(remote / "alpha", local / "drift");
    drift->_job_id = 200;
    auto driftrecord = TransferJournal::create(local / "drift-journal", *drift);
    driftrecord->prepare_inputs();
    RemoteFS::write(remote / "alpha", 0, "changed");
    {
      auto recovery = make_file_jobs();
      recovery->enable_recovery(local / "drift-journal");
      auto job = recovery->get_job_history().at(0);
      recovery->resume(200);
      test::until([&] { return recovery->idle(); }, "Drift validation timeout");
      require(job->_state == JobState::PAUSED && !RemoteFS::inspect(local / "drift").exists,
              "Changed source copied after Resume");
    }
    auto deletions = std::make_shared<JobSpec>(
        std::make_shared<OperationPlan>(selection_plan(OperationType::DELETE, {remote / "tree"})));
    jobs->add_job(deletions);
    done(*jobs, deletions);
    require(!RemoteFS::inspect(remote / "tree").exists, "Remote delete failed");
    if (host == "fixture") {
      streaming_pipeline_contracts(*jobs, local, remote);
      pending_recovery_contracts(local, remote);
      metadata_contracts(*jobs, local, remote);
      RemoteFS::close_connections();
      setenv("FC_SSH_FIXTURE_DROP_RENAME", (local / "lost-ack").c_str(), 1);
      auto lost = copy_job(local / "alpha", remote / "lost-ack-copy");
      jobs->add_job(lost);
      test::until([&] { return jobs->idle(); }, "Lost acknowledgement timeout");
      require(lost->_state == JobState::PAUSED, "Lost commit reply did not pause transfer");
      require(RemoteFS::inspect(remote / "lost-ack-copy").exists, "Fixture did not commit before disconnect");
      jobs->resume(lost->_job_id);
      done(*jobs, lost);
      require(RemoteFS::digest(remote / "lost-ack-copy") == RemoteFS::digest(local / "alpha"),
              "Commit reconciliation replayed or lost bytes");
      unsetenv("FC_SSH_FIXTURE_DROP_RENAME");
      RemoteFS::close_connections();

      test::write(local / "lost-ack-source", data);
      setenv("FC_SSH_FIXTURE_DROP_RENAME", (local / "lost-move-ack").c_str(), 1);
      auto lost_move_plan = std::make_shared<OperationPlan>();
      lost_move_plan->type = OperationType::MOVE;
      lost_move_plan->steps.push_back({Operation::Kind::MoveEntry,
                                       local / "lost-ack-source",
                                       remote / "lost-ack-move",
                                       {},
                                       "",
                                       int64_t(data.size())});
      auto lost_move = std::make_shared<JobSpec>(lost_move_plan);
      jobs->add_job(lost_move);
      test::until([&] { return jobs->idle(); }, "Lost move acknowledgement timeout");
      require(lost_move->_state == JobState::PAUSED && RemoteFS::inspect(local / "lost-ack-source").exists,
              "Unacknowledged move removed its source before Resume");
      require(RemoteFS::digest(remote / "lost-ack-move") == RemoteFS::digest(local / "lost-ack-source"),
              "Unacknowledged move did not publish complete bytes");
      jobs->resume(lost_move->_job_id);
      done(*jobs, lost_move);
      require(!RemoteFS::inspect(local / "lost-ack-source").exists, "Resumed move did not clean its source");
      for (auto &entry : RemoteFS::list(remote))
        require(!entry.path.filename().native().starts_with(".fc-move-"), "Resumed move left staging behind");
      unsetenv("FC_SSH_FIXTURE_DROP_RENAME");
      RemoteFS::close_connections();
    }
    jobs->shutdown();
    RemoteFS::remove(remote, true);
    created = false;
    RemoteFS::close_connections();
    std::cout << "Remote transfer, tree, move, recovery and drift contracts passed on " << host << "\n";
    return 0;
  } catch (const std::exception &e) {
    std::cerr << e.what() << "\n";
    if (created)
      try {
        RemoteFS::remove(remote, true);
      } catch (...) {
      }
    return 1;
  }
}
