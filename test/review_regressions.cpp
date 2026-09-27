#include "app.hpp"

#include <fstream>
#include <iostream>
#include <thread>

namespace fs = boost::filesystem;
using namespace Perun;
using namespace ftxui;

static void require(bool condition, const std::string& message) {
  if (!condition) throw std::runtime_error(message);
}

struct Fixture {
  Filepath root = fs::temp_directory_path() / fs::unique_path("fc-regression-%%%%-%%%%-%%%%");
  Fixture() { fs::create_directories(root); }
  ~Fixture() { boost::system::error_code ec; fs::remove_all(root, ec); }
  Filepath dir(const std::string& name) { auto p = root / name; fs::create_directories(p); return p; }
  Filepath file(const std::string& name, const std::string& content = "fixture") {
    auto p = root / name;
    fs::create_directories(p.parent_path());
    std::ofstream out(p.string(), std::ios::binary);
    out << content;
    return p;
  }
};

static void wait_job(uint64_t id) {
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
  while (std::chrono::steady_clock::now() < deadline) {
    for (auto& job : file_operations().get_job_history()) if (job->_job_id == id) return;
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  throw std::runtime_error("job did not finish");
}

static void R01() {
  Fixture f;
  auto outside = f.dir("outside");
  auto valuable = f.file("outside/valuable", "KEEP");
  auto tree = f.dir("tree");
  fs::create_directory_symlink(outside, tree / "external");
  fs::create_directory_symlink(tree, tree / "cycle");
  fs::create_directory_symlink(outside, f.root / "selected_link");
  auto run = [](Filepath p) {
    auto job = std::make_shared<JobSpec>(JobSpec::Type::DELETE, std::vector<DirItem>{DirItem(p)});
    wait_job(file_operations().add_job(job));
    require(job->_errors.empty(), "delete reported an error");
  };
  run(f.root / "selected_link");
  require(fs::exists(valuable), "selected symlink deleted its target contents");
  run(tree);
  require(!fs::exists(tree) && fs::exists(valuable), "nested/cyclic symlink escaped delete tree");
}

static std::string read_file(const Filepath& path) {
  std::ifstream input(path.string(), std::ios::binary);
  return std::string(std::istreambuf_iterator<char>(input), {});
}

static void R02() {
  Fixture f;
  auto destination = f.file("destination", "KEEP");
  std::atomic<bool> cancelled{true};
  fs::copy_file_options options;
  options.options = fs::copy_options::overwrite_existing;
  options.cancel_requested = &cancelled;
  boost::system::error_code ec;
  fs::copy_file(f.root / "missing", destination, options, ec);
  require(ec && read_file(destination) == "KEEP", "failed copy removed untouched destination");
  fs::copy_file(destination, destination, options, ec);
  require(ec && read_file(destination) == "KEEP", "self-copy damaged destination");
  auto source = f.file("source", std::string(1024 * 1024, 'x'));
  cancelled = false;
  options.bytes_per_second = 1024 * 1024;
  std::thread cancel([&] { std::this_thread::sleep_for(std::chrono::milliseconds(30)); cancelled = true; });
  fs::copy_file(source, destination, options, ec);
  cancel.join();
  require(ec && read_file(destination) == "KEEP", "in-flight cancel replaced old destination");
  cancelled = false;
  options.bytes_per_second = 0;
  require(fs::copy_file(source, destination, options, ec), "successful replacement failed");
  require(!ec && read_file(destination) == read_file(source), "replacement contents differ");
  require(std::distance(fs::directory_iterator(f.root), fs::directory_iterator()) == 2, "staged output leaked");
}

static void R03() {
  Fixture f;
  auto source = f.file("input", "data");
  auto archive = f.file("existing.7z", "OLD");
  ArchiveService service;
  service.set_tool_path("/usr/bin/false");
  require(!service.create_archive(archive, {source}, f.root).ok(), "failed tool reported success");
  require(read_file(archive) == "OLD", "failed tool removed old archive");
  require(service.create_archive(archive, {source}, f.root, ArchiveConflict::Skip).ok(), "Skip invoked failing tool");
  require(read_file(archive) == "OLD", "Skip changed archive");
  require(!service.create_archive(archive, {archive}, f.root).ok(), "archive allowed self-input");
  require(read_file(archive) == "OLD", "self-input damaged archive");
  require(!service.create_archive(archive, {source}, f.root, ArchiveConflict::Update).ok(), "ambiguous archive Update accepted");
  require(std::distance(fs::directory_iterator(f.root), fs::directory_iterator()) == 2, "archive staging leaked");
}

static PanelSharedState::P copy_state(Dir& dir, Filepath source, Filepath target) {
  auto state = std::make_shared<PanelSharedState>(&dir);
  state->action.arguments = std::make_shared<CommandArgs>();
  state->action.arguments->origin = source.parent_path();
  state->action.arguments->selected = {source};
  state->action.arguments->target = target;
  return state;
}

static void R04() {
  Fixture f;
  auto source = f.file("src/a", "NEW");
  auto old = f.dir("old");
  f.file("old/a", "KEEP");
  Dir dir; dir.move_to(source.parent_path());
  for (int method = 0; method < 2; ++method) {
    auto target = f.dir("new" + std::to_string(method));
    auto state = copy_state(dir, source, old);
    CopyDialog dialog(state);
    dialog.OnShow(); dialog._discovery_process->_thread.join();
    dialog.destination_path = target.string();
    if (method == 0) dialog.navigation->OnEvent(theme().key_copy);
    else { dialog.button_ok->TakeFocus(); dialog.button_ok->OnEvent(Event::Return); }
    require(dialog._confirm_when_ready, "edited target was not rediscovered");
    dialog._discovery_process->_thread.join();
    auto before = file_operations().get_job_history().size();
    dialog.navigation->OnEvent(Event::Custom);
    for (int i = 0; file_operations().get_job_history().size() == before && i < 2000; ++i)
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    require(read_file(old / "a") == "KEEP", "copy modified obsolete target");
    require(read_file(target / "a") == "NEW", "copy did not use edited target");
  }
}

static void R05() {
  const auto before = file_operations().get_job_history().size();
  Fixture f;
  auto source = f.dir("src");
  auto destination = f.dir("dst");
  for (int i = 0; i < 600; ++i) f.file("src/entry" + std::to_string(i));
  Dir dir; dir.move_to(source);
  auto state = copy_state(dir, source, destination);
  CopyDialog dialog(state);
  dialog.OnShow();
  dialog.run_copy(); // May still be discovering: must never queue a partial plan.
  while (dialog._discovery_process && dialog._discovery_process->_running.load()) {
    dialog._discovery_process->publish_preview();
    dialog.render();
    std::this_thread::yield();
  }
  if (dialog._discovery_process) dialog.navigation->OnEvent(Event::Custom);
  for (int i = 0; file_operations().get_job_history().size() == before && i < 2000; ++i)
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  require(fs::is_directory(destination / "src"), "directory was not copied");
  require(std::distance(fs::directory_iterator(destination / "src"), fs::directory_iterator()) == 600,
          "early confirmation lost undiscovered files");
}

static void R06() {
  Fixture f;
  auto first = f.file("a"); auto second = f.file("b");
  Dir dir; dir.move_to(f.root);
  auto state = copy_state(dir, first, f.root);
  state->action.arguments->selected.push_back(second);
  RenameDialog dialog(state); dialog.OnShow();
  dialog.rows[0]->content = "renamed_a";
  dialog.rows[1]->content = "missing/b";
  auto* stable = dialog.rows[1].get();
  dialog.ok();
  require(dialog.rows.size() == 1 && dialog.rows[0].get() == stable, "failed rename row lost stable address");
  dialog.menu->ChildAt(0)->OnEvent(Event::Character('X'));
  require(dialog.rows[0]->content == "Xmissing/b", "surviving input no longer edits its row");
  dialog.rows[0]->content = "renamed_b";
  dialog.ok();
  require(fs::exists(f.root / "renamed_a") && fs::exists(f.root / "renamed_b"), "rename retry failed");
}

static void R07() {
  Fixture f;
  for (int i = 0; i < 100; ++i) {
    auto watcher = FileChangeFunnel::create(f.root, [](UpdatedFiles) {});
    watcher.reset();
  }
}

static void R08() {
  Fixture f;
  std::mutex mutex;
  std::vector<std::function<void()>> posted;
  auto post = [&](std::function<void()> work) { std::lock_guard lock(mutex); posted.push_back(std::move(work)); };
  auto panel = std::make_unique<Panel>(f.root, [&](Panel*) { return f.root; }, post);
  f.file("trigger");
  bool received = false;
  for (int i = 0; i < 1000; ++i) {
    { std::lock_guard lock(mutex); received = !posted.empty(); }
    if (received) break;
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  require(received, "watcher did not post a test callback");
  panel.reset();
  // All queued work must become harmless after destruction.
  for (auto& callback : posted) callback();
}

static void R09() {
  Fixture f;
  auto tree = f.dir("tree");
  for (int i = 0; i < 1000; ++i) f.file("tree/entry" + std::to_string(i));
  auto job = std::make_shared<JobSpec>(JobSpec::Type::DELETE, std::vector<DirItem>{DirItem(tree)});
  auto id = file_operations().add_job(job);
  auto frozen = job->snapshot();
  const auto initial_size = frozen->_items.size();
  JobListDialog dialog([] {}); dialog.OnShow();
  for (int i = 0; !job->is_stopped() && i < 3000; ++i) {
    dialog.rebuild_list();
    if (!dialog.jobs.empty()) { dialog.open_detail(); dialog.renderer->Render(); }
    require(frozen->_items.size() == initial_size, "published job snapshot mutated");
    std::this_thread::yield();
  }
  wait_job(id);
  require(job->snapshot()->is_stopped(), "completion not published in snapshot");
}

static void R10() {
  Fixture f;
  auto source = f.file("source");
  for (auto type : {JobSpec::Type::COPY, JobSpec::Type::MOVE, JobSpec::Type::DELETE}) {
    auto manager = make_file_jobs();
    DirItem item(source); item._set_symlink_target(f.root / "destination");
    auto paused = std::make_shared<JobSpec>(type, std::vector<DirItem>{item});
    paused->_pause_requested = true;
    manager->add_job(paused);
    auto queued = std::make_shared<JobSpec>(JobSpec::Type::COPY, std::vector<DirItem>{item});
    manager->add_job(queued);
    for (int i = 0; paused->_state != JobState::PAUSED && i < 1000; ++i)
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    require(paused->_state == JobState::PAUSED, "job never reached pause checkpoint");
    auto start = std::chrono::steady_clock::now();
    manager->shutdown();
    require(std::chrono::steady_clock::now() - start < std::chrono::seconds(2), "paused shutdown too slow");
    require(paused->is_stopped() && queued->is_stopped(), "shutdown did not finalize jobs");
    require(paused->_state == JobState::CANCELLED && queued->_state == JobState::CANCELLED, "shutdown left nonterminal jobs");
    require(fs::exists(source) && !fs::exists(f.root / "destination"), "shutdown executed queued work");
  }
}

static void R11() {
  Fixture f;
  auto source = f.dir("unreadable"); f.file("unreadable/hidden");
  auto destination = f.dir("destination");
  Dir dir; dir.move_to(f.root);
  auto state = copy_state(dir, source, destination);
  fs::permissions(source, fs::no_perms);
  CopyDialog dialog(state); dialog.OnShow(); dialog._discovery_process->_thread.join();
  fs::permissions(source, fs::owner_all);
  auto plan = dialog._discovery_process->take_items();
  require(dialog._discovery_process->get_progress().error_count > 0, "unreadable directory silently omitted");
  dialog.cancel();
  auto job = std::make_shared<JobSpec>(JobSpec::Type::COPY, std::move(plan));
  wait_job(file_operations().add_job(job));
  require(job->_state == JobState::COMPLETED_WITH_ERRORS && !job->_errors.empty(), "discovery failure became clean success");
  DirItem missing(f.root / "missing", fs::status_error, fs::no_perms); missing._set_warning("missing source");
  auto second = std::make_shared<JobSpec>(JobSpec::Type::COPY, std::vector<DirItem>{missing});
  wait_job(file_operations().add_job(second));
  require(second->_state == JobState::COMPLETED_WITH_ERRORS, "explicit discovery error was dropped");
}

static void R12() {
  Fixture f;
  auto source = f.file("source", std::string(1024 * 1024, 'x'));
  DirItem item(source); item._set_symlink_target(f.root / "destination");
  auto job = std::make_shared<JobSpec>(JobSpec::Type::COPY, std::vector<DirItem>{item});
  file_operations().set_transfer_rate(1024 * 1024);
  auto id = file_operations().add_job(job);
  while (job->_copy_bytes.load() == 0 && !job->is_stopped()) std::this_thread::yield();
  file_operations().pause_job(job.get());
  for (int i = 0; job->_state != JobState::PAUSED && i < 1000; ++i)
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  require(job->_state == JobState::PAUSED && !job->is_stopped(), "pause was not acknowledged during final file");
  auto bytes = job->_copy_bytes.load();
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  require(job->_copy_bytes.load() == bytes, "paused copy kept writing");
  file_operations().pause_job(job.get());
  wait_job(id);
  file_operations().set_transfer_rate(0);
  require(job->_state == JobState::COMPLETED && !job->_pause_requested, "finished job remained paused");
  require(read_file(f.root / "destination") == read_file(source), "resumed copy contents differ");
  require(file_operations().pause_job(job.get()) == JobError::NOT_FOUND, "terminal job accepted pause");
}

int main(int argc, char** argv) {
  const std::vector<std::pair<std::string, void (*)()>> tests = {{"R01", R01}, {"R02", R02}, {"R03", R03}, {"R04", R04}, {"R05", R05}, {"R06", R06}, {"R07", R07}, {"R08", R08}, {"R09", R09}, {"R10", R10}, {"R11", R11}, {"R12", R12}};
  try {
    bool matched = false;
    for (const auto& [id, run] : tests) {
      if (argc > 1 && id != argv[1]) continue;
      matched = true;
      run();
      std::cout << "PASS " << id << std::endl;
    }
    require(matched, "unknown regression id");
  } catch (const std::exception& e) {
    std::cerr << "FAIL: " << e.what() << std::endl;
    return 1;
  }
}
