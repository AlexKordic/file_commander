#include "app.hpp"
#include "scripting.hpp"
#include "ui_dispatcher.hpp"
#include "traversal.hpp"
#include <ftxui/component/loop.hpp>

#include <fstream>
#include <future>
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

struct EnvOverride {
  std::string key;
  std::optional<std::string> previous;
  EnvOverride(std::string name, const std::string& value) : key(std::move(name)) {
    if (auto old = std::getenv(key.c_str())) previous = old;
    setenv(key.c_str(), value.c_str(), 1);
  }
  ~EnvOverride() { if (previous) setenv(key.c_str(), previous->c_str(), 1); else unsetenv(key.c_str()); }
};

struct UiQueue {
  std::mutex mutex;
  std::vector<std::function<void()>> posted;
  void post(std::function<void()> f) { std::lock_guard lock(mutex); posted.push_back(std::move(f)); }
  void drain() {
    std::vector<std::function<void()>> ready;
    { std::lock_guard lock(mutex); ready.swap(posted); }
    for (auto& f : ready) f();
  }
  void wait(Panel& panel) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (panel.loading() && std::chrono::steady_clock::now() < deadline) {
      drain(); std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    require(!panel.loading(), "panel load did not finish");
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
  UiQueue ui;
  auto panel = std::make_unique<Panel>(f.root, [&](Panel*) { return f.root; }, [&](auto work) { ui.post(std::move(work)); });
  ui.wait(*panel);
  f.file("trigger");
  bool received = false;
  for (int i = 0; i < 1000; ++i) {
    { std::lock_guard lock(ui.mutex); received = !ui.posted.empty(); }
    if (received) break;
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  require(received, "watcher did not post a test callback");
  panel.reset();
  // All queued work must become harmless after destruction.
  ui.drain();
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

static void R18() {
  Fixture f; auto source = f.file("src/a"); auto dest = f.dir("dest");
  Dir dir; dir.move_to(source.parent_path());
  CopyDialog dialog(copy_state(dir, source, dest));
  dialog.OnShow(); dialog._discovery_process->_thread.join();
  dialog.destination_path.clear(); dialog.destination_cursor_pos = 0;
  dialog.input_destination_path->TakeFocus();
  for (char digit : std::string("123")) dialog.navigation->OnEvent(Event::Character(digit));
  require(dialog.destination_path == "123", "destination digits were consumed");
  require(dialog.conflict_mode_selected == 0, "typing changed conflict policy");
  dialog.op_conflict_mode->TakeFocus(); dialog.navigation->OnEvent(Event::Character('3'));
  require(dialog.conflict_mode_selected == 2, "focused option shortcut stopped working");
  dialog.cancel();
}

static void R19() {
  Fixture f; f.file("keep"); f.file("other");
  Dir dir; dir.move_to(f.root); dir.apply_filter("keep");
  require(dir.stats().items_visible == 1, "initial filter failed");
  f.file("keep-new"); f.file("excluded"); dir.refresh(); dir.apply_filter("keep");
  require(dir.stats().items_visible == 2 && dir.stats().items_total == 4, "refresh lost filter");
  for (auto& item : dir.items) require(item.visible() == (item.filename_ref().find("keep") != std::string::npos), "visibility disagrees with phrase");
}

static void R20() {
  Fixture f; auto first = f.dir("first"); auto second = f.dir("second");
  f.file("first/keep"); f.file("first/remove");
  UiQueue ui;
  Panel panel(first, [&](Panel*) { return second; }, [&](auto work) { ui.post(std::move(work)); });
  ui.wait(panel);
  auto state = panel.get_shared_state(); state->filter_txt = "keep"; panel.dir.apply_filter("keep");
  for (int i = 0; i < panel.dir.items.size(); ++i) if (panel.dir.items[i].filename_ref() == "keep") {
    panel.dir.item_toggle_select(i); state->set_focused_index(i);
  }
  panel.new_tab(); panel.move_to(second); ui.wait(panel);
  f.file("first/keep-new"); fs::remove(first / "remove");
  panel.switch_to_tab(0); ui.wait(panel);
  require(panel.dir.items.size() == 2 && panel.dir.stats().items_visible == 2, "inactive tab did not reconcile changes/filter");
  require(panel.dir.take_selected()->selected == std::vector<Filepath>{first / "keep"}, "surviving selection lost");
  require(*state->get_focused_item() == first / "keep", "surviving focus lost");
}

static void R21() {
  Fixture f; auto old = f.dir("old"); auto current = f.dir("current");
  f.file("current/a", "KEEP");
  Dir dir; dir.move_to(current);
  auto changes = std::make_unique<std::vector<DirItemUpdated>>();
  changes->emplace_back((old / "a").c_str(), DirItemUpdated::Event::Removed);
  dir.partial_refresh(std::move(changes));
  require(dir.items.size() == 1 && dir.items.front().path_ref() == current / "a", "old-directory removal damaged current model");
  f.file("old/a", "DIFFERENT");
  changes = std::make_unique<std::vector<DirItemUpdated>>();
  changes->emplace_back((old / "a").c_str(), DirItemUpdated::Event::Modified);
  dir.partial_refresh(std::move(changes));
  require(dir.items.front().size() == 4, "old-directory metadata applied to current entry");
}

static void R22() {
  Fixture f; auto root = f.dir("watched");
  UiQueue ui;
  Panel panel(root, [&](Panel*) { return f.root; }, [&](auto work) { ui.post(std::move(work)); });
  ui.wait(panel);
  f.file("watched/new");
  auto changes = std::make_unique<std::vector<DirItemUpdated>>();
  changes->emplace_back(root.c_str(), DirItemUpdated::Event::Rescan);
  panel.apply_changes(std::move(changes)); ui.wait(panel);
  require(panel.dir.items.size() == 1, "rescan did not reconcile directory");
  fs::remove_all(root);
  changes = std::make_unique<std::vector<DirItemUpdated>>();
  changes->emplace_back(root.c_str(), DirItemUpdated::Event::WatchInvalidated);
  panel.apply_changes(std::move(changes)); ui.wait(panel);
  require(panel.dir.path == f.root && panel.update_funnel, "invalidated root did not recover/rearm");
}

static void R23() {
  Fixture f; auto left = f.dir("left"); auto right = f.dir("right");
  f.file("left/a"); f.file("right/b");
  UiQueue ui;
  FileCommander app(left, right, [&](auto work) { ui.post(std::move(work)); }, [] { return 100; });
  ui.wait(app.get_left()); ui.wait(app.get_right());
  auto interactive = ScreenInteractive::FixedSize(100, 30);
  Loop active_screen(&interactive, app.renderer);
  app.get_left().navigation->TakeFocus();
  app.set_single_panel_mode(true);
  auto rendered = [&] {
    auto screen = Screen::Create(Dimension::Fixed(100), Dimension::Fixed(30));
    Render(screen, app.renderer->Render());
    return screen.ToString();
  };
  require(rendered().find("Hidden Right:") != std::string::npos, "single view did not render");
  app.navigation->OnEvent(theme().key_switch_focused_panel);
  require(app.single_panel_mode() && &app.focused_panel() == &app.get_right(), "Tab did not switch single panel");
  require(app.get_right().navigation->Focused(), "shown panel lost focus ancestry");
  require(rendered().find("Hidden Left:") != std::string::npos, "Tab restored split presentation");
  app.navigation->OnEvent(Event::TabReverse);
  require(rendered().find("Hidden Left:") != std::string::npos, "reverse Tab restored split presentation");
  app.execute_palette_command("switch_panel");
  require(rendered().find("Hidden Right:") != std::string::npos, "palette switch restored split presentation");
  app.set_single_panel_mode(false);
  require(rendered().find("Hidden ") == std::string::npos, "split layout was not restored");
}

static void R24() {
  Fixture f; auto origin = f.dir("origin");
  Dir dir; dir.move_to(origin);
  auto state = copy_state(dir, origin / "unused", f.root);
  state->action.arguments->origin = origin;
  int closed = 0; state->action.close_dialog = [&] { ++closed; };
  MkdirDialog dialog(state);
  for (const auto& name : {"", "missing/child"}) {
    dialog.new_dir_name = name; dialog.ok();
    require(!dialog.error.empty() && closed == 0, "invalid mkdir closed without an error");
  }
  f.file("origin/existing"); dialog.new_dir_name = "existing"; dialog.ok();
  require(!dialog.error.empty() && closed == 0, "existing file was not reported");
  fs::permissions(origin, fs::owner_read | fs::owner_exe); dialog.new_dir_name = "denied"; dialog.ok();
  fs::permissions(origin, fs::owner_all);
  require(!dialog.error.empty() && closed == 0, "permission failure was not reported");
  dialog.new_dir_name = "created"; dialog.ok();
  require(dialog.error.empty() && closed == 1 && fs::is_directory(origin / "created"), "valid mkdir failed");
  fs::remove_all(origin); dialog.new_dir_name = "vanished"; dialog.ok();
  require(!dialog.error.empty() && closed == 1, "vanished origin was not reported");
}

static void R25() {
  Fixture f; auto slow = f.dir("slow"); auto fast = f.dir("fast");
  f.file("slow/stale"); f.file("fast/current");
  {
    auto screen = ScreenInteractive::FixedSize(100, 30);
    auto root = Container::Vertical({});
    Loop loop(&screen, root);
    std::atomic<bool> posted{false};
    Panel startup(fast, [&](Panel*) { return fast; }, [&](auto work) {
      screen.Post(std::move(work));
      screen.Post(Event::Custom);
      posted = true;
    });
    root->Add(startup.navigation);
    for (int i = 0; i < 500 && !posted; ++i) std::this_thread::sleep_for(std::chrono::milliseconds(2));
    require(posted && startup.loading(), "startup worker did not finish before first event pass");
    loop.RunOnce();
    require(!startup.loading() && startup.dir.items.size() == 1, "initial directory publication was lost");
  }
  std::atomic<bool> entered{false};
  UiQueue ui;
  Panel panel(f.root, [&](Panel*) { return f.root; }, [&](auto work) { ui.post(std::move(work)); },
    [&](Dir& result, const Filepath& path, const std::atomic<bool>* cancelled) {
      if (path == slow) {
        entered = true;
        while (!cancelled->load()) std::this_thread::sleep_for(std::chrono::milliseconds(2));
      }
      return result.move_to(path, cancelled);
    });
  ui.wait(panel);
  auto start = std::chrono::steady_clock::now(); panel.move_to(slow);
  require(std::chrono::steady_clock::now() - start < std::chrono::milliseconds(100), "navigation blocked UI");
  for (int i = 0; i < 500 && !entered; ++i) std::this_thread::sleep_for(std::chrono::milliseconds(2));
  require(entered && panel.loading(), "slow scan did not start");
  {
    auto interactive = ScreenInteractive::FixedSize(100, 30);
    Loop active_screen(&interactive, panel.navigation);
    auto screen = Screen::Create(Dimension::Fixed(100), Dimension::Fixed(30));
    Render(screen, panel.render());
    require(screen.ToString().find("Esc: cancel") != std::string::npos, "loading view could not redraw");
  }
  panel.navigation->OnEvent(Event::Escape);
  require(!panel.loading(), "Escape did not cancel loading");
  panel.move_to(fast); ui.wait(panel);
  require(panel.dir.path == fast && panel.dir.items.size() == 1, "superseded scan replaced current directory");
  auto tool = f.file("slow-tool", "#!/bin/sh\nsleep 20\n");
  fs::permissions(tool, fs::owner_all);
  auto archive = f.file("slow.7z");
  auto previous_tool = archive_service().tool_path(); archive_service().set_tool_path(tool.string());
  start = std::chrono::steady_clock::now();
  require(panel.enter_archive(archive), "archive load was not scheduled");
  require(std::chrono::steady_clock::now() - start < std::chrono::milliseconds(100), "archive entry blocked UI");
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  panel.move_to(fast); ui.wait(panel);
  archive_service().set_tool_path(previous_tool);
  require(panel.dir.path == fast && !panel.loading(), "cancelled archive changed panel");
}

static void R26() {
  Fixture f; auto input = f.file("source/input", "ORIGINAL"); auto archive = f.root / "bundle.7z";
  auto& service = archive_service();
  require(service.create_archive(archive, {input}, input.parent_path()).ok(), "archive fixture creation failed");
  const auto archive_bytes = read_file(archive);
  Filepath cache;
  require(service.extract_to_cache(archive, cache).ok(), "archive fixture extraction failed");
  require(service.is_cached_path(cache / "input"), "cache ownership was not recognized");
  auto alias = f.root / "alias"; fs::create_directory_symlink(cache, alias);
  require(service.is_cached_path(alias / "new"), "cache alias bypassed read-only check");
  UiQueue ui;
  FileCommander app(cache, f.root, [&](auto work) { ui.post(std::move(work)); }, [] { return 100; });
  ui.wait(app.get_left()); ui.wait(app.get_right()); app.get_left().navigation->TakeFocus();
  for (const auto& command : {"Mkdir", "Rename", "Delete", "Move"}) {
    app.get_left().execute_dialog_command(command);
    require(app.get_left()._active_dialog_name.empty(), "archive mutation dialog was enabled");
  }
  std::string error;
  require(!app.open_in_editor(error) && !error.empty(), "archive editor was enabled");
  Dir dir; dir.move_to(cache);
  auto state = copy_state(dir, cache / "input", f.root);
  MkdirDialog mkdir(state); mkdir.new_dir_name = "created"; mkdir.ok();
  require(!mkdir.error.empty() && !fs::exists(cache / "created"), "mkdir modified cache");
  RenameDialog rename(state); rename.OnShow(); rename.rows[0]->content = "renamed"; rename.ok();
  require(fs::exists(cache / "input") && !fs::exists(cache / "renamed"), "rename modified cache");
  for (auto type : {JobSpec::Type::DELETE, JobSpec::Type::MOVE, JobSpec::Type::COPY, JobSpec::Type::ARCHIVE_CREATE}) {
    DirItem item(type == JobSpec::Type::COPY || type == JobSpec::Type::ARCHIVE_CREATE ? input : cache / "input");
    item._set_symlink_target(type == JobSpec::Type::MOVE ? f.root / "moved" : cache / "new");
    auto job = std::make_shared<JobSpec>(type, std::vector<DirItem>{item});
    wait_job(file_operations().add_job(job));
    require(job->snapshot()->_state == JobState::COMPLETED_WITH_ERRORS, "job bypassed archive read-only guard");
  }
  auto copy_state_in = copy_state(dir, input, cache);
  CopyDialog copy(copy_state_in); copy.OnShow(); copy._discovery_process->_thread.join();
  copy.run_copy(); require(copy._discovery_process != nullptr, "copy into cache was submitted"); copy.cancel();
  DirItem item(cache / "input"); item._set_symlink_target(f.root / "extracted");
  auto job = std::make_shared<JobSpec>(JobSpec::Type::COPY, std::vector<DirItem>{item});
  wait_job(file_operations().add_job(job));
  require(read_file(f.root / "extracted") == "ORIGINAL", "copy-out was blocked");
  require(read_file(cache / "input") == "ORIGINAL" && read_file(archive) == archive_bytes, "archive or cache changed");
}

static void R27() {
  Fixture f; auto input = f.file("input", "first version"); auto archive = f.root / "bundle.7z";
  ArchiveService first;
  require(first.create_archive(archive, {input}, f.root).ok(), "archive fixture failed");
  Filepath root1, root2, root3;
  {
    ArchiveService second;
    Err error1, error2;
    std::thread a([&] { error1 = first.extract_to_cache(archive, root1); });
    std::thread b([&] { error2 = second.extract_to_cache(archive, root2); });
    a.join(); b.join();
    require(error1.ok() && error2.ok() && root1 != root2, "service instances shared an extraction root");
    require(read_file(root1 / "input") == "first version" && read_file(root2 / "input") == "first version", "concurrent extraction damaged cache");
    f.file("input", "a longer second version");
    require(second.create_archive(archive, {input}, f.root).ok(), "archive replacement failed");
    require(second.extract_to_cache(archive, root3).ok() && root3 != root2, "changed archive reused active root");
    require(read_file(root1 / "input") == "first version" && read_file(root2 / "input") == "first version", "re-extraction removed a live source");
    require(read_file(root3 / "input") == "a longer second version", "new extraction was stale");
  }
  require(fs::exists(root1 / "input") && !fs::exists(root2) && !fs::exists(root3), "service cleanup crossed ownership boundary");
}

static void R28() {
  Fixture f;
  int result = 0;
  EditorManager manager([&](const std::function<int()>&) { return result; }, [](const std::string&) {});
  std::string error;
  for (const auto& name : {"a", "b", "c"}) require(manager.open_directory_new_session(f.dir(name), error), "session fixture failed");
  const auto sessions = manager.sessions();
  for (int i = 0; i < 6; ++i) {
    require(manager.switch_next(error), "next failed");
    require(manager.last_session_id() == sessions[i % 3].id, "next skipped a live session");
  }
  for (int i = 0; i < 6; ++i) {
    require(manager.switch_prev(error), "previous failed");
    require(manager.last_session_id() == sessions[(4 - i % 3) % 3].id, "previous skipped a live session");
  }
  result = 7; require(!manager.switch_next(error), "failed attach was accepted");
  result = 0; require(manager.switch_next(error), "dead session prevented cycling");
  require(manager.last_session_id() == sessions[1].id, "known failed session remained in cycle");
  require(manager.switch_prev(error) && manager.last_session_id() == sessions[2].id, "reverse cycle failed around dead session");
}

static void R29() {
  Fixture f; EnvOverride config("XDG_CONFIG_HOME", f.root.string());
  UiQueue ui;
  FileCommander app(f.root, f.root, [&](auto work) { ui.post(std::move(work)); }, [] { return 100; });
  ui.wait(app.get_left()); ui.wait(app.get_right());
  std::map<std::string, std::string> original;
  for (const auto& command : commands().list_all()) original[command.id] = event_to_token(command.key);
  std::string error;
  for (const auto& permutation : std::vector<std::map<std::string, std::string>>{
      {{"copy", "f6"}, {"move", "f5"}},
      {{"copy", "f6"}, {"move", "f8"}, {"delete", "f5"}}}) {
    require(app.apply_key_bindings(permutation, error), "valid permutation was rejected: " + error);
    app.save_settings();
    require(app.apply_key_bindings(original, error), "default restoration failed");
    app.load_settings(false);
    for (const auto& [id, token] : permutation) require(commands().find_by_id(id)->key == event_from_string(token), "saved permutation was lost");
    require(app.apply_key_bindings(original, error), "default restoration failed");
  }
  for (const auto& invalid : std::vector<std::map<std::string, std::string>>{
      {{"copy", "f6"}}, {{"copy", "f1"}}, {{"copy", "not-a-key"}}, {{"copy", "f6"}, {"unknown", "f5"}}}) {
    require(!app.apply_key_bindings(invalid, error) && !error.empty(), "invalid mapping was accepted");
    for (const auto& [id, token] : original) require(commands().find_by_id(id)->key == event_from_string(token), "invalid mapping partially mutated bindings");
  }
}

static void R31() {
  Fixture f; auto source = f.file("source", std::string(512 * 1024, 'x'));
  auto manager = make_file_jobs(); manager->set_transfer_rate(512 * 1024);
  DirItem first(source); first._set_symlink_target(f.root / "first");
  std::vector<uint64_t> ids;
  ids.push_back(manager->add_job(std::make_shared<JobSpec>(JobSpec::Type::COPY, std::vector<DirItem>{first})));
  for (int i = 0; i < 19; ++i) ids.push_back(manager->add_job(std::make_shared<JobSpec>(JobSpec::Type::DELETE, std::vector<DirItem>{})));
  require(!manager->idle(), "queued jobs reported idle");
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (!manager->idle() && std::chrono::steady_clock::now() < deadline) std::this_thread::sleep_for(std::chrono::milliseconds(2));
  require(manager->idle(), "queue did not drain");
  uint64_t cursor = 0; auto events = manager->events_since(cursor);
  require(events.size() == 40, "transitions between polls were lost");
  for (size_t i = 0; i < ids.size(); ++i) {
    require(events[2*i].job_id == ids[i] && !events[2*i].completed, "start identity mismatch");
    require(events[2*i+1].job_id == ids[i] && events[2*i+1].completed, "completion identity mismatch");
    require(events[2*i+1].sequence == 2*i+2, "event sequence mismatch");
  }
  require(manager->events_since(cursor).empty(), "events replayed after cursor");
  manager->shutdown();
  UiQueue ui;
  FileCommander app(f.root, f.root, [&](auto work) { ui.post(std::move(work)); }, [] { return 100; });
  ui.wait(app.get_left()); ui.wait(app.get_right()); app.get_left().navigation->TakeFocus();
  auto interactive = ScreenInteractive::FixedSize(100, 30);
  Loop loop(&interactive, app.renderer);
  const auto before = file_operations().get_job_history().size();
  file_operations().set_transfer_rate(512 * 1024);
  for (int i = 0; i < 2; ++i) {
    DirItem item(source); item._set_symlink_target(f.root / ("queued" + std::to_string(i)));
    file_operations().add_job(std::make_shared<JobSpec>(JobSpec::Type::COPY, std::vector<DirItem>{item}));
  }
  auto script = f.file("wait.lua", "fc.cmd('select_all'); assert(fc.wait_event('selection_changed', 1000)); assert(fc.wait_for_jobs(5000)); assert(#fc.job_history() >= " + std::to_string(before + 2) + ")");
  LuaScripting lua(app, app.renderer); require(lua.setup(script.string()), "Lua setup failed");
  deadline = std::chrono::steady_clock::now() + std::chrono::seconds(7);
  while (!lua.finished() && std::chrono::steady_clock::now() < deadline) {
    ui.drain(); loop.RunOnce(); lua.tick(); std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  file_operations().set_transfer_rate(0);
  require(lua.finished() && lua.exit_code() == 0, "Lua first-action event or all-jobs wait failed");
  require(fs::exists(f.root / "queued0") && fs::exists(f.root / "queued1"), "Lua wait returned before both copies");
}

static void R35() {
  Fixture f;
  auto background_workers = make_file_jobs(); // SIGPIPE must also be safe with other live threads.
#ifdef __APPLE__
  const auto helper_name = "pbcopy";
#else
  const auto helper_name = "wl-copy";
#endif
  const auto capture = f.root / "captured";
  auto helper = f.file(helper_name, "#!/bin/sh\n/bin/cat > '" + capture.string() + "'\n");
  fs::permissions(helper, fs::owner_all);
  EnvOverride path("PATH", f.root.string());
  const std::string payload = "first line\nUnicode: café\n";
  require(push_to_clipboard(payload).ok() && read_file(capture) == payload, "clipboard roundtrip failed");
  require(push_to_clipboard("").ok() && read_file(capture).empty(), "empty clipboard write failed");
  f.file(helper_name, "#!/bin/sh\n/bin/cat >/dev/null\nexit 23\n");
  require(!push_to_clipboard(payload).ok(), "nonzero helper exit was ignored");
  f.file(helper_name, "#!/bin/sh\nexit 7\n");
  require(!push_to_clipboard(std::string(1024 * 1024, 'x')).ok(), "closed helper pipe was accepted");
  fs::remove(helper);
  require(!push_to_clipboard(payload).ok(), "missing helper was reported as success");
}

static void R37() {
  for (bool selective_get : {false, true}) {
    FifoQueue<int> queue(1); require(queue.push(1) == FifoError::OK, "queue setup failed");
    std::promise<FifoError> result;
    auto done = result.get_future();
    std::thread producer([&] { result.set_value(queue.push(2)); });
    const bool blocked = done.wait_for(std::chrono::milliseconds(20)) == std::future_status::timeout;
    int removed = 0;
    bool matched = true;
    if (selective_get) matched = queue.get(removed, [](int value) { return value == 1; }) == FifoError::OK && removed == 1;
    else queue.erase_if([](int value) { return value == 1; });
    const bool woke = done.wait_for(std::chrono::seconds(1)) == std::future_status::ready;
    if (!woke) queue.close();
    producer.join();
    require(blocked && matched && woke && done.get() == FifoError::OK, "selective removal did not release blocked producer");
    int value = 0; require(queue.try_pop(value) == FifoError::OK && value == 2, "producer did not fill freed capacity");
  }
}

static void AR01() {
  Fixture f; auto slow = f.dir("slow"); f.file("slow/item");
  UiDispatcher dispatcher;
  auto screen = ScreenInteractive::FixedSize(100, 30);
  auto root = Container::Vertical({}); Loop loop(&screen, root);
  std::atomic<bool> entered{false}, release{false}, finished{false}, posted{false};
  Panel panel(f.root, [&](Panel*) { return f.root; },
    [&, post = dispatcher.poster()](auto fn) { post(std::move(fn)); if (finished) posted = true; },
    [&](Dir& result, const Filepath& path, const std::atomic<bool>* cancelled) {
      if (path == slow) { entered = true; while (!release && !cancelled->load()) std::this_thread::sleep_for(std::chrono::milliseconds(1)); }
      auto error = result.move_to(path, cancelled); if (path == slow) finished = true; return error;
    });
  root->Add(panel.navigation);
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (panel.loading() && std::chrono::steady_clock::now() < deadline) { dispatcher.drain(); std::this_thread::sleep_for(std::chrono::milliseconds(1)); }
  require(!panel.loading(), "initial mailbox load failed");
  panel.move_to(slow);
  auto jobs = make_file_jobs(); jobs->set_update_sink(dispatcher.notifier());
  dispatcher.suspend();
  screen.WithRestoredIO([&] {
    release = true;
    jobs->add_job(std::make_shared<JobSpec>(JobSpec::Type::DELETE, std::vector<DirItem>{}));
    while ((!posted || !jobs->idle()) && std::chrono::steady_clock::now() < deadline) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    require(posted && jobs->idle(), "work did not finish during suspension");
    require(!dispatcher.drain() && panel.loading(), "suspended dispatcher ran callbacks");
  })();
  dispatcher.resume(); require(dispatcher.drain(), "resume lost dirty state");
  require(!panel.loading() && panel.dir.path == slow, "terminal handoff lost directory completion");
  jobs->shutdown();
  int delivered = 0;
  dispatcher.suspend(); dispatcher.poster()([&] { ++delivered; }); dispatcher.resume(); dispatcher.drain(); dispatcher.drain();
  require(delivered == 1, "completion delivered more than once");
  { auto gone = std::make_unique<Panel>(f.root, [&](Panel*) { return f.root; }, dispatcher.poster()); }
  dispatcher.drain(); // Destroyed panel's generation/lifetime guards discard its publication.
  dispatcher.poster()([&] { ++delivered; }); auto late = dispatcher.poster();
  dispatcher.close(); late([&] { ++delivered; }); dispatcher.drain();
  require(delivered == 1, "closed dispatcher delivered callbacks");
}

static void AR02() {
  Fixture f; auto left=f.dir("left"), right=f.dir("right"); EnvOverride config("XDG_CONFIG_HOME",f.dir("config").native());
  UiQueue queue;
  for (int order=0;order<6;++order) {
    AppSettings saved; saved.left.path=left.native(); saved.right.path=right.native();
    saved.left.sort=static_cast<Orderby>(order); saved.right.sort=static_cast<Orderby>(5-order);
    SettingsStore::save(SettingsStore::path(),saved);
    FileCommander app(left,right,[&](auto fn){queue.post(std::move(fn));},[]{return 100;},{},true);
    app.load_settings(true); app.start_initial_navigation(); queue.wait(app.get_left()); queue.wait(app.get_right());
    require(app.get_left().dir.order_by==saved.left.sort && app.get_right().dir.order_by==saved.right.sort,"startup discarded saved order");
    app.get_left().move_to(left); app.get_left().dir.order_by=Orderby::TIME_DESC; queue.wait(app.get_left());
    require(app.get_left().dir.order_by==Orderby::TIME_DESC,"refresh discarded newer view state");
    SettingsStore::atomic_write(SettingsStore::path(),R"({"version":1,"left_sort":"NAME_ASC","single_panel_mode":"wrong"})");
    app.load_settings(false);
    require(app.get_left().dir.order_by==Orderby::TIME_DESC,"invalid settings partially applied");
  }
  auto path=f.file("atomic/settings.json","previous"); bool failed=false;
  try { SettingsStore::atomic_write(path,"replacement",[](auto&,auto&){throw std::runtime_error("injected rename failure");}); }
  catch (...) { failed=true; }
  std::ifstream in(path.string()); std::string actual; in>>actual;
  require(failed && actual=="previous","failed save replaced previous settings");
  require(std::distance(fs::directory_iterator(path.parent_path()),fs::directory_iterator())==1,"failed save leaked temporary file");
  SettingsStore::atomic_write(path,R"({"version":2})"); failed=false;
  try { SettingsStore::load(path); } catch (...) {failed=true;}
  require(failed,"unknown settings version accepted");
}

static void AR03() {
  Fixture f; auto root=f.dir("source"), dst=f.dir("target"); f.file("source/match.txt");
  fs::create_directory_symlink(root,root/"self1"); fs::create_directory_symlink(root,root/"self2");
  fs::create_symlink("absent",root/"dangling"); fs::create_symlink("match.txt",root/"chain");
  Dir dir; dir.move_to(root); auto state=copy_state(dir,root,dst);
  FindDialog find(state); find.OnShow(); find.pattern="match.txt"; find.start_search(); find._worker.join();
  require(find._dirs_scanned==1 && find._results.size()==1,"Find followed directory link cycle");
  for (bool follow:{false,true}) {
    CopyDialog copy(state); copy.b_follow_links=follow; copy.OnShow(); copy._discovery_process->_thread.join();
    auto progress=copy._discovery_process->get_progress();
    require(progress.dir_count==1 && progress.file_count==(follow?2:1),"copy link policy changed");
    require(progress.link_count==(follow?2:4),"copy did not preserve links / cycle aliases");
    require(progress.error_count==(follow?1:0),"dangling-link policy changed");
  }
  auto deep=f.dir("deep"); for (int i=0;i<120;++i) { deep/="d"; fs::create_directory(deep); }
  size_t seen=0; TraversalCallbacks cb; cb.enter=[&](auto&){++seen;return true;};
  auto result=traverse({f.root/"deep"},{},cb); require(seen==121 && !result.truncated,"iterative deep walk incomplete");
  seen=0; result=traverse({f.root/"deep"},{false,20,1024},cb); require(result.truncated && seen==20,"entry limit ignored");
  seen=0; cb.cancelled=[&]{return seen>=10;}; result=traverse({root},{},cb); // Small tree completes below the cancellation threshold.
  result=traverse({f.root/"deep"},{},cb); require(result.cancelled && seen==10,"walk cancellation ignored");
  auto job=std::make_shared<JobSpec>(JobSpec::Type::DELETE,std::vector<DirItem>{DirItem(root)});
  wait_job(file_operations().add_job(job)); require(!fs::exists(root) && fs::exists(dst),"delete followed links or failed postorder");
}

int main(int argc, char** argv) {
  const std::vector<std::pair<std::string, void (*)()>> tests = {{"AR03", AR03}, {"AR02", AR02}, {"AR01", AR01}, {"R01", R01}, {"R02", R02}, {"R03", R03}, {"R04", R04}, {"R05", R05}, {"R06", R06}, {"R07", R07}, {"R08", R08}, {"R09", R09}, {"R10", R10}, {"R11", R11}, {"R12", R12}, {"R13", R13}, {"R14", R14}, {"R15", R15}, {"R16", R16}, {"R17", R17}, {"R18", R18}, {"R19", R19}, {"R20", R20}, {"R21", R21}, {"R22", R22}, {"R23", R23}, {"R24", R24}, {"R25", R25}, {"R26", R26}, {"R27", R27}, {"R28", R28}, {"R29", R29}, {"R31", R31}, {"R35", R35}, {"R37", R37}};
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
