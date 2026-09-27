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

static void R13() {
  Fixture f;
  auto source = f.file("source", std::string(2 * 1024 * 1024, 'x'));
  auto destination = f.file("destination", "KEEP");
  std::atomic<bool> cancelled{false};
  fs::copy_file_options options;
  options.cancel_requested = &cancelled; options.bytes_per_second = 1024 * 1024;
  boost::system::error_code ec;
  std::thread cancel([&] { std::this_thread::sleep_for(std::chrono::milliseconds(30)); cancelled = true; });
  bool moved = move_by_copy(source, destination, options, ec);
  cancel.join();
  require(!moved && ec && fs::exists(source) && read_file(destination) == "KEEP", "cancelled move damaged source/destination");
  cancelled = false; options.bytes_per_second = 0;
  auto tree = f.dir("tree"); f.file("tree/child");
  fs::create_symlink(source, tree / "link");
  require(move_by_copy(tree, f.root / "moved", options, ec), "staged recursive move failed");
  require(!fs::exists(tree) && fs::is_symlink(f.root / "moved/link") && fs::exists(source), "move link semantics changed");
  auto archive = f.file("old.7z", "OLD");
  auto fake = f.file("slow-7zr", "#!/bin/sh\nsleep 20\n");
  fs::permissions(fake, fs::owner_all);
  ArchiveService service; service.set_tool_path(fake.string());
  auto start = std::chrono::steady_clock::now();
  std::thread cancel_archive([&] { std::this_thread::sleep_for(std::chrono::milliseconds(40)); cancelled = true; });
  auto result = service.create_archive(archive, {source}, f.root, ArchiveConflict::Replace, &cancelled);
  cancel_archive.join();
  require(!result.ok() && read_file(archive) == "OLD", "cancelled archive replaced old output");
  require(std::chrono::steady_clock::now() - start < std::chrono::seconds(2), "archive subprocess ignored cancellation");
}

static void R14() {
  Fixture f;
  auto source = f.file("source");
  DirItem item(source); item._set_symlink_target(f.root / "moved");
  auto move = std::make_shared<JobSpec>(JobSpec::Type::MOVE, std::vector<DirItem>{item});
  wait_job(file_operations().add_job(move));
  require(move->_items_done == 1 && move->_items_failed == 0, "move completed count wrong");
  auto tree = f.dir("tree"); f.file("tree/child");
  auto del = std::make_shared<JobSpec>(JobSpec::Type::DELETE, std::vector<DirItem>{DirItem(tree)});
  wait_job(file_operations().add_job(del));
  require(del->_items_done == 2 && del->item_count() == 2, "delete count is not finalized attempts");
  DirItem copy(f.root / "moved"); copy._set_symlink_target(f.root / "existing"); f.file("existing");
  auto skip = std::make_shared<JobSpec>(JobSpec::Type::COPY, std::vector<DirItem>{copy}, CopyConflictMode::Skip);
  wait_job(file_operations().add_job(skip));
  require(skip->_items_done == 1 && skip->_items_skipped == 1, "copy skip count wrong");
  DirItem bad(f.root / "missing", fs::status_error, fs::no_perms);
  auto failed = std::make_shared<JobSpec>(JobSpec::Type::COPY, std::vector<DirItem>{bad});
  wait_job(file_operations().add_job(failed));
  require(failed->_items_done == 1 && failed->_items_failed == 1, "copy failure count wrong");
  auto archive_path = f.file("existing.7z", "OLD");
  DirItem input(f.root / "moved"); input._set_symlink_target(archive_path);
  auto arch = std::make_shared<JobSpec>(JobSpec::Type::ARCHIVE_CREATE, std::vector<DirItem>{input}, CopyConflictMode::Skip);
  wait_job(file_operations().add_job(arch));
  require(arch->_items_done == 1 && arch->_items_skipped == 1, "archive skip count wrong");
}

static void R15() {
  Fixture f;
  auto source = f.dir("src"); auto dest = f.dir("dest");
  fs::create_symlink("missing", source / "dangling");
  fs::create_symlink("cycle_b", source / "cycle_a");
  fs::create_symlink("cycle_a", source / "cycle_b");
  auto target = f.dir("target");
  fs::create_directory_symlink(target, source / "directory_link");
  Dir dir; dir.move_to(source);
  require(dir.items.size() == 4, "dangling/cyclic links disappeared from listing");
  require(DirItem(source / "directory_link").is_dir(), "valid directory link lost navigation");
  auto changes = std::make_unique<std::vector<DirItemUpdated>>();
  changes->emplace_back((source / "dangling").c_str(), DirItemUpdated::Event::Modified);
  dir.partial_refresh(std::move(changes));
  require(dir.items.size() == 4, "partial refresh removed dangling link");
  auto state = copy_state(dir, source / "dangling", dest);
  CopyDialog dialog(state); dialog.OnShow(); dialog._discovery_process->_thread.join();
  auto job = std::make_shared<JobSpec>(JobSpec::Type::COPY, dialog._discovery_process->take_items());
  dialog.cancel(); wait_job(file_operations().add_job(job));
  require(fs::is_symlink(dest / "dangling") && fs::read_symlink(dest / "dangling") == "missing", "preserve copy lost dangling link text");
}

static void R16() {
  Fixture f;
  auto source = f.dir("src"); auto dest = f.dir("dst");
  f.file("src/real", "CHAIN");
  fs::create_symlink("real", source / "c");
  fs::create_symlink("c", source / "b");
  fs::create_symlink("b", source / "a");
  Dir dir; dir.move_to(source);
  auto state = copy_state(dir, source / "a", dest);
  CopyDialog dialog(state); dialog.b_follow_links = true;
  dialog.OnShow(); dialog._discovery_process->_thread.join();
  require(dialog._discovery_process->get_progress().error_count == 0, "valid chain classified as cycle");
  auto job = std::make_shared<JobSpec>(JobSpec::Type::COPY, dialog._discovery_process->take_items());
  dialog.cancel(); wait_job(file_operations().add_job(job));
  require(read_file(dest / "a") == "CHAIN" && !fs::is_symlink(dest / "a"), "follow chain did not materialize data");
  fs::create_symlink("loop", source / "loop");
  state->action.arguments->selected = {source / "loop"};
  dialog.OnShow(); dialog._discovery_process->_thread.join();
  require(dialog._discovery_process->get_progress().error_count == 1, "real cycle was not detected");
  dialog.cancel();
}

static void R17() {
  Fixture f;
  auto target = f.file("target", "KEEP");
  auto destination = f.root / "link";
  fs::create_symlink(target, destination);
  auto run = [&](CopyConflictMode mode, std::time_t source_time) {
    DirItem link(destination, fs::symlink_file, fs::owner_all);
    link._set_symlink_target("missing-new-target"); link._set_write_time(source_time);
    auto job = std::make_shared<JobSpec>(JobSpec::Type::COPY, std::vector<DirItem>{link}, mode);
    wait_job(file_operations().add_job(job));
    require(job->_errors.empty(), "link conflict reported an error");
    return job;
  };
  run(CopyConflictMode::Replace, std::time(nullptr));
  require(fs::read_symlink(destination) == "missing-new-target" && read_file(target) == "KEEP", "replace followed old link");
  auto skipped = run(CopyConflictMode::Skip, std::time(nullptr));
  require(skipped->_items_skipped == 1 && fs::is_symlink(destination), "Skip failed for dangling link");
  fs::remove(destination); f.file("link", "OLD"); fs::last_write_time(destination, std::time(nullptr) + 100);
  run(CopyConflictMode::Update, std::time(nullptr));
  require(read_file(destination) == "OLD", "Update replaced newer destination");
  fs::last_write_time(destination, 1);
  run(CopyConflictMode::Update, std::time(nullptr));
  require(fs::is_symlink(destination), "Update did not replace older regular destination with link");
}

int main(int argc, char** argv) {
  const std::vector<std::pair<std::string, void (*)()>> tests = {{"R01", R01}, {"R02", R02}, {"R03", R03}, {"R04", R04}, {"R05", R05}, {"R06", R06}, {"R07", R07}, {"R08", R08}, {"R09", R09}, {"R10", R10}, {"R11", R11}, {"R12", R12}, {"R13", R13}, {"R14", R14}, {"R15", R15}, {"R16", R16}, {"R17", R17}};
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
