#include "copy_planner.hpp"
#include "file_io_jobs.hpp"
#include "remote_fs.hpp"
#include "sha256.hpp"
#include "support/contracts.hpp"
#include "transfer_journal.hpp"
#include <iostream>
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
