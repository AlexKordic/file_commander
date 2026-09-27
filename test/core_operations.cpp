#include <fstream>
#include <iostream>
#include <thread>
#include "copy_planner.hpp"
#include "file_io_jobs.hpp"
using namespace Perun;
namespace fs = boost::filesystem;
static void check(bool ok, const char* message) {
  if (!ok) throw std::runtime_error(message);
}
static void wait(FileJobs& manager) {
  auto until = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (!manager.idle() && std::chrono::steady_clock::now() < until) std::this_thread::sleep_for(std::chrono::milliseconds(1));
  check(manager.idle(), "headless job timed out");
}
int main() {
  auto root = fs::temp_directory_path() / fs::unique_path("fc-core-%%%%-%%%%-%%%%");
  fs::create_directories(root / "src");
  fs::create_directory(root / "dst");
  struct Cleanup {
    Filepath p;
    ~Cleanup() {
      boost::system::error_code ec;
      fs::remove_all(p, ec);
    }
  } cleanup{root};
  try {
    std::ofstream(root.string() + "/src/file") << "typed copy";
    CopyPlanner planner({{root / "src"}, root / "dst"});
    planner._thread.join();
    auto plan = planner.take_plan();
    check(plan && plan->steps.size() == 2, "headless discovery failed");
    check(plan->steps[0].kind == Operation::Kind::CreateDirectory && plan->steps[1].kind == Operation::Kind::CopyFile, "typed steps incorrect");
    std::string     clipboard;
    FileJobServices services;
    services.clipboard = [&](const auto& text) {
      clipboard = text;
      return Err();
    };
    auto first = make_file_jobs({}, services), second = make_file_jobs();
    first->set_event_sink({}); // Detaching observers must leave execution usable.
    auto job = std::make_shared<JobSpec>(plan);
    first->add_job(job);
    wait(*first);
    check(fs::exists(root / "dst/src/file") && job->_state == JobState::COMPLETED, "headless copy failed");
    std::ifstream copied((root / "dst/src/file").string(), std::ios::binary);
    check(std::string(std::istreambuf_iterator<char>(copied), {}) == "typed copy", "headless copy changed bytes");
    auto summary = job->snapshot(false);
    check(summary->_error_count == 0 && summary->_items_failed == 0 && summary->_items_skipped == 0 && summary->_items_done == 2,
          "headless copy counters disagree with the plan");
    OperationPlan failed;
    failed.steps.push_back({Operation::Kind::CopyFile, root / "missing", root / "dst/missing"});
    first->add_job(std::make_shared<JobSpec>(std::make_shared<const OperationPlan>(failed)));
    wait(*first);
    check(first->error_count() == 1 && second->error_count() == 0, "independent managers cross-reported errors");
    OperationPlan clip;
    clip.type = OperationType::CLIPBOARD;
    clip.steps.push_back({Operation::Kind::ClipboardText, {}, {}, {}, "injected text"});
    first->add_job(std::make_shared<JobSpec>(std::make_shared<const OperationPlan>(clip)));
    wait(*first);
    check(clipboard == "injected text", "injected clipboard service was bypassed");
    first->shutdown();
    second->shutdown();
    std::cout << "PASS headless operation services\n";
  } catch (const std::exception& e) {
    std::cerr << e.what() << "\n";
    return 1;
  }
}
