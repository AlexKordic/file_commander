#include "fc_engine.hpp"

#include "app_model.hpp"
#include "archive.hpp"
#include "file_io_jobs.hpp"
#include "location.hpp"
#include "remote_fs.hpp"
#include "sevenzip.hpp"
#include "settings.hpp"
#include "workspace.hpp"

#include <atomic>
#include <cstdlib>
#include <deque>
#include <format>
#include <map>
#include <mutex>

using Perun::file_operations;
using Perun::JobSnapshot;
using Perun::JobSpec;
using Perun::JobState;
using Perun::OperationPlan;
using Perun::OperationType;
using Perun::Operation;

namespace fce {
namespace {

// The main-thread mailbox: workers queue closures and wake the app once.
struct Mailbox {
  std::mutex                        mutex;
  std::deque<std::function<void()>> tasks;
  std::atomic<bool>                 woken{false};
  std::atomic<bool>                 closed{false};
  void (*wake)(void*) = nullptr;
  void* context       = nullptr;

  void signal() {
    if (closed.load()) return;
    if (!woken.exchange(true) && wake) wake(context);
  }
  void post(std::function<void()> task) {
    if (closed.load()) return;
    {
      std::lock_guard lock(mutex);
      if (task) tasks.push_back(std::move(task));
    }
    signal();
  }
  void run() {
    woken.store(false);
    std::deque<std::function<void()>> now;
    {
      std::lock_guard lock(mutex);
      now.swap(tasks);
    }
    for (auto& task : now) task();
  }
};

struct Engine {
  std::shared_ptr<Mailbox>                      mailbox = std::make_shared<Mailbox>();
  std::unique_ptr<WorkspaceLease>               lease;
  std::unique_ptr<AppModel>                     app;
  std::map<uint64_t, std::shared_ptr<CopySession>> copies;
  uint64_t                                      next_copy = 1;
  std::unique_ptr<FindSession>                  find;
  std::string                                   find_status;
  std::vector<AttachRequest>                    attaches;
  std::atomic<uint64_t>                         jobs_revision{1}, errors_revision{1};
};

Engine& engine() {
  static Engine instance;
  return instance;
}

AppModel& app() { return *engine().app; }

std::function<void(std::function<void()>)> poster() {
  return [weak = std::weak_ptr<Mailbox>(engine().mailbox)](std::function<void()> task) {
    if (auto mailbox = weak.lock()) mailbox->post(std::move(task));
  };
}

LocationKind kind_of(const Location& location) {
  if (location.remote()) return LocationKind::Remote;
  if (location.read_only()) return LocationKind::Archive;
  return LocationKind::Local;
}

std::string tab_title(const Location& location) {
  const bool  archive_root = location.read_only() && (location.internal.empty() || location.internal == "/" || location.internal == ".");
  Filepath    shown = archive_root ? location.archives.back() : location.read_only() ? location.internal : location.local;
  std::string title = shown.filename().native();
  if (title.empty() || title == ".") title = shown.native();
  if (title.empty()) title = "/";
  if (location.remote()) title = location.ssh + ":" + title;
  return title;
}

FileKind kind_of(const DirItem& item) {
  using boost::filesystem::file_type;
  switch (item.type()) {
  case file_type::regular_file: return FileKind::Regular;
  case file_type::directory_file: return FileKind::Directory;
  case file_type::symlink_file: return FileKind::Symlink;
  case file_type::block_file: return FileKind::Block;
  case file_type::character_file: return FileKind::Character;
  case file_type::fifo_file: return FileKind::Fifo;
  case file_type::socket_file: return FileKind::Socket;
  case file_type::status_error: return FileKind::Error;
  case file_type::file_not_found: return FileKind::NotFound;
  default: return FileKind::Unknown;
  }
}

RowInfo row_info(const DirItem& item, int64_t index) {
  RowInfo out;
  out.item          = index;
  out.name          = item.filename_ref();
  out.path          = item.path_ref().native();
  out.kind          = kind_of(item);
  out.is_dir        = item.is_dir();
  out.is_executable = !item.is_dir() && item.is_exe();
  out.selected      = item.selected();
  out.is_link       = item.symlink_ref().has_value();
  if (item.symlink_ref()) out.link_target = item.symlink_ref()->native();
  if (item.warning_ref()) out.warning = *item.warning_ref();
  out.permissions = item.perms_string();
  out.owner       = item.owner_string();
  out.group       = item.group_string();
  out.size        = item.size();
  out.modified    = int64_t(item.write_time());
  out.date        = item.get_time();
  return out;
}

std::vector<Filepath> paths(const StringList& in) {
  std::vector<Filepath> out;
  out.reserve(in.size());
  for (const auto& p : in) out.emplace_back(p);
  return out;
}

std::vector<std::string> strings(const std::vector<Filepath>& in) {
  std::vector<std::string> out;
  out.reserve(in.size());
  for (const auto& p : in) out.push_back(p.native());
  return out;
}

const char* state_name(JobState state) {
  switch (state) {
  case JobState::QUEUED: return "queued";
  case JobState::RUNNING: return "running";
  case JobState::PAUSED: return "paused";
  case JobState::CANCELLED: return "cancelled";
  case JobState::COMPLETED: return "completed";
  case JobState::COMPLETED_WITH_ERRORS: return "completed_with_errors";
  }
  return "unknown";
}

const char* type_name(OperationType type) {
  switch (type) {
  case OperationType::COPY: return "COPY";
  case OperationType::MOVE: return "MOVE";
  case OperationType::DELETE: return "DELETE";
  case OperationType::ARCHIVE_CREATE: return "ARCHIVE";
  case OperationType::MKDIR: return "MKDIR";
  case OperationType::RENAME: return "RENAME";
  case OperationType::CLIPBOARD: return "CLIPBOARD";
  }
  return "?";
}

JobInfo job_info(const JobSnapshot& job) {
  JobInfo out;
  out.id              = job._job_id;
  out.type            = type_name(job._type);
  out.state           = state_name(job._state.load());
  out.stopped         = job.is_stopped();
  out.items_done      = job._items_done;
  out.items_total     = job.item_count();
  out.items_failed    = job._items_failed;
  out.items_skipped   = job._items_skipped;
  out.errors          = job._error_count;
  // Copies count the file in progress too, as the progress bar does.
  out.bytes_done      = std::max<double>(job._bytes_processed, job._type == OperationType::COPY ? double(job._total.current_size) : 0.0);
  out.bytes_total     = job._bytes_total;
  out.mbps            = job._total.Mbps;
  out.average_mbps    = job._total.average_Mbps;
  out.current_percent = job._current_item.percentage;
  if (job._type == OperationType::COPY) out.percent = job._total.percentage;
  else if (job._type == OperationType::DELETE && job._bytes_total > 0) out.percent = 100.0 * job._bytes_processed / job._bytes_total;
  else if (out.items_total > 0) out.percent = 100.0 * double(job._items_done) / double(out.items_total);
  else out.percent = job.is_stopped() ? 100 : 0;
  out.percent = std::clamp(out.percent, 0.0, 100.0);
  if (job._focused_item) out.current = job._focused_item->path_ref().native();
  out.recovery_note = job._recovery_note;
  for (const auto& error : job._step_errors)
    if (!error.empty()) {
      out.first_error = error;
      break;
    }
  if (out.first_error.empty() && !job._errors.empty()) out.first_error = job._errors.front().warning_ref().value_or("");
  out.queued   = job._queued_time;
  out.started  = job._started_time;
  out.finished = job._finished_time;
  return out;
}

std::shared_ptr<JobSpec> find_job(uint64_t id) {
  auto running = file_operations().get_running_job();
  if (running.job && running.job->_job_id == id) return running.job;
  for (auto& job : file_operations().get_job_history())
    if (job->_job_id == id) return job;
  return nullptr;
}

SubmitResult submit(OperationPlan plan) {
  auto job = std::make_shared<JobSpec>(std::make_shared<const OperationPlan>(std::move(plan)));
  auto id  = file_operations().add_job(job);
  ++engine().jobs_revision;  // A queued job changes the queue even when nothing runs.
  if (!id) return {"The job queue is full; try again when a job finishes", 0};
  return {"", id};
}

}  // namespace

void set_wake(void (*wake)(void*), void* context) {
  engine().mailbox->wake    = wake;
  engine().mailbox->context = context;
}

std::string profile_dir() { return SettingsStore::path("").parent_path().native(); }

bool started() { return engine().app != nullptr; }

StartResult start(const StartOptions& options) {
  auto& e = engine();
  if (e.app) return {false, "File Commander is already running"};
  try {
    e.lease = std::make_unique<WorkspaceLease>(SettingsStore::path("workspace.lock"));
  } catch (const std::exception& error) { return {false, error.what()}; }
  auto mailbox = e.mailbox;
  file_operations().set_update_sink([weak = std::weak_ptr<Mailbox>(mailbox), &e] {
    ++e.jobs_revision;
    if (auto m = weak.lock()) m->signal();
  });
  if (options.recovery) {
    try {
      file_operations().enable_recovery(SettingsStore::path("transfers"));
    } catch (const std::exception& error) {
      e.lease.reset();
      return {false, std::string("Transfer recovery unavailable: ") + error.what()};
    }
  }
  if (!options.tool_dir.empty()) {
    if (boost::filesystem::exists(Filepath(options.tool_dir) / "7z.so")) SevenZip::set_library_path(Filepath(options.tool_dir) / "7z.so");
    if (!std::getenv("FC_FRESH_BIN")) setenv("FC_FRESH_BIN", (options.tool_dir + "/fresh").c_str(), 1);
  }
  const char* home    = std::getenv("HOME");
  const bool  explicit_paths = !options.left.empty() || !options.right.empty();
  Filepath    fallback = home ? Filepath(home) : boost::filesystem::current_path();
  Filepath    left     = options.left.empty() ? fallback : Filepath(options.left);
  Filepath    right    = options.right.empty() ? (options.left.empty() ? fallback : Filepath(options.left)) : Filepath(options.right);
  e.app                = std::make_unique<AppModel>(left, right, poster());
  auto emit            = [weak = std::weak_ptr<ApplicationEvents>(e.app->events), wm = std::weak_ptr<Mailbox>(mailbox), &e](std::string name, std::string detail, uint64_t request) {
    if (name == "error_reported" || name == "errors_cleared") ++e.errors_revision;
    if (name.rfind("job_", 0) == 0) ++e.jobs_revision;
    if (auto bus = weak.lock()) bus->publish(std::move(name), std::move(detail), request);
    if (auto m = wm.lock()) m->signal();
  };
  file_operations().set_event_sink(emit);
  e.app->editor().set_attach_handler([&e](const EditorManager::AttachRequest& request, std::string&) {
    e.attaches.push_back({request.cwd.native(), request.argv, request.environment, request.scene_socket});
    return true;
  });
  const bool restore = options.restore && !explicit_paths;
  e.app->load_settings(restore);
  e.app->enable_workspace(restore);
  e.app->pane(0).restart_initial_load();
  e.app->pane(1).restart_initial_load();
  return {true, ""};
}

void stop() {
  auto& e = engine();
  if (!e.app) return;
  e.find.reset();
  e.copies.clear();
  e.app->checkpoint_workspace(true);
  e.app->save_settings();
  file_operations().shutdown();
  e.mailbox->closed = true;
  e.app.reset();
  e.lease.reset();
}

Changes drain() {
  auto&   e = engine();
  Changes out;
  if (!e.app) return out;
  e.mailbox->run();
  e.app->tick();
  out.left_revision      = e.app->pane(0).revision();
  out.right_revision     = e.app->pane(1).revision();
  out.layout_revision    = e.app->layout_revision();
  out.jobs_revision      = e.jobs_revision.load();
  out.errors_revision    = e.errors_revision.load();
  out.bookmarks_revision = e.app->bookmarks_revision();
  for (auto& request : e.app->take_dialog_requests())
    out.dialogs.push_back({request.name, request.side, strings(request.selected), request.focused.native(), request.origin.native(), request.target.native()});
  out.notices  = e.app->take_notices();
  out.attaches = std::exchange(e.attaches, {});
  return out;
}

PaneInfo pane(int side) {
  PaneInfo out;
  if (!started()) return out;
  auto&       p        = app().pane(side);
  const auto& dir      = p.dir();
  auto        location = p.location();
  out.path             = dir.path_txt.empty() ? location.display() : dir.path_txt;
  out.encoded          = location.encode();
  out.kind             = kind_of(location);
  out.read_only        = location.read_only();
  out.filter           = p.active().filter;
  out.remote_error     = p.active().remote_error;
  out.sort             = int(dir.order_by);
  out.loading          = p.loading();
  out.loading_unattended = p.loading_unattended();
  out.load_ms          = p.last_load_ms();
  auto stats           = const_cast<Dir&>(dir).stats();
  out.items_total      = stats.items_total;
  out.items_visible    = stats.items_visible;
  out.items_selected   = stats.items_selected;
  out.bytes_selected   = stats.bytes_selected;
  out.bytes_total      = stats.bytes_total;
  out.largest_item     = stats.largest_item_bytes;
  if (auto* item = p.cursor_item()) out.cursor_row = p.row_of_item(int(item - dir.items.data()));
  out.show_permissions = p.active().permissions;
  out.show_owner_group = p.active().owner_group;
  out.active_tab       = p.active_tab_index();
  for (int i = 0; i < p.tab_count(); ++i) {
    auto    tab_location = p.tab_location(i);
    TabInfo tab;
    tab.title        = tab_title(tab_location);
    tab.path         = tab_location.display();
    tab.encoded      = tab_location.encode();
    tab.kind         = kind_of(tab_location);
    tab.tutorial     = p.tab(i).tutorial;
    tab.remote_error = p.tab(i).remote_error;
    out.tabs.push_back(std::move(tab));
  }
  out.revision         = p.revision();
  out.content_revision = p.content_revision();
  out.marks_revision   = p.marks_revision();
  return out;
}

int  focused_side() { return started() ? app().focused_side() : 0; }
void set_focused_side(int side) {
  if (started()) app().set_focused_side(side);
}
bool single_pane() { return started() && app().single_pane(); }
void set_single_pane(bool on) {
  if (started()) app().set_single_pane(on);
}

int64_t row_count(int side) { return started() ? int64_t(app().pane(side).visible_rows().size()) : 0; }

namespace {
int item_at(int side, int64_t row) {
  const auto& rows = app().pane(side).visible_rows();
  return row >= 0 && row < int64_t(rows.size()) ? rows[size_t(row)] : -1;
}
}  // namespace

RowInfo row(int side, int64_t row) {
  if (!started()) return {};
  int item = item_at(side, row);
  if (item < 0) return {};
  return row_info(app().pane(side).dir().items[item], item);
}

std::vector<RowInfo> rows(int side, int64_t from, int64_t count) {
  std::vector<RowInfo> out;
  if (!started()) return out;
  for (int64_t r = from; r < from + count; ++r) {
    int item = item_at(side, r);
    if (item < 0) break;
    out.push_back(row_info(app().pane(side).dir().items[item], item));
  }
  return out;
}

int64_t row_named(int side, const std::string& name) {
  if (!started()) return -1;
  auto&       p    = app().pane(side);
  const auto& rows = p.visible_rows();
  for (size_t r = 0; r < rows.size(); ++r)
    if (p.dir().items[rows[r]].filename_ref() == name) return int64_t(r);
  return -1;
}

IndexList selected_rows(int side) {
  IndexList out;
  if (!started()) return out;
  auto&       p    = app().pane(side);
  const auto& rows = p.visible_rows();
  for (size_t r = 0; r < rows.size(); ++r)
    if (p.dir().items[rows[r]].selected()) out.push_back(int64_t(r));
  return out;
}

void set_cursor(int side, int64_t row) {
  if (!started()) return;
  int item = item_at(side, row);
  if (item >= 0) app().pane(side).set_cursor(item);
}
void toggle_row(int side, int64_t row) {
  if (!started()) return;
  int item = item_at(side, row);
  if (item >= 0) app().pane(side).toggle_select(item);
}
void set_row_selected(int side, int64_t row, bool selected) {
  if (!started()) return;
  int item = item_at(side, row);
  if (item >= 0) app().pane(side).set_selected(item, selected);
}
void set_selected_rows(int side, const IndexList& rows) {
  if (!started()) return;
  auto& p = app().pane(side);
  std::vector<bool> wanted(p.dir().items.size(), false);
  for (auto r : rows) {
    int item = item_at(side, r);
    if (item >= 0) wanted[size_t(item)] = true;
  }
  for (size_t i = 0; i < wanted.size(); ++i) p.set_selected(int(i), wanted[i]);
}
void select_all(int side) {
  if (started()) app().pane(side).select_all();
}
void clear_selection(int side) {
  if (started()) app().pane(side).clear_selection();
}
int glob_select(int side, const std::string& pattern, bool select) { return started() ? app().pane(side).glob_select(pattern, select) : 0; }
void set_filter(int side, const std::string& text) {
  if (started()) app().pane(side).set_filter(text);
}
void set_sort(int side, int sort) {
  if (!started()) return;
  app().pane(side).set_sort(Orderby(std::clamp(sort, 0, 5)));
  app().settings_changed();
}
void set_columns(int side, bool permissions, bool owner_group) {
  if (!started()) return;
  app().pane(side).set_columns(permissions, owner_group);
  app().settings_changed();
}
bool open_row(int side, int64_t row) {
  if (!started()) return false;
  int item = item_at(side, row);
  return item >= 0 && app().pane(side).enter(item);
}
void go_up(int side) {
  if (started()) app().pane(side).leave();
}
void navigate(int side, const std::string& location, const std::string& focus) {
  if (started()) app().pane(side).move_to(Filepath(location), Filepath(focus));
}
void refresh(int side) {
  if (started()) app().pane(side).refresh();
}
void stop_loading(int side) {
  if (started()) app().pane(side).cancel_loading();
}
void switch_tab(int side, int index) {
  if (started()) app().pane(side).switch_to_tab(index);
}
void new_tab(int side, const std::string& location, bool tutorial) {
  if (!started()) return;
  if (location.empty()) app().pane(side).new_tab(std::nullopt, tutorial);
  else app().pane(side).new_tab(Filepath(location), tutorial);
}
void close_tab(int side, int index) {
  if (started()) app().pane(side).close_tab(index);
}
void move_tab(int side, int from, int to) {
  if (started()) app().pane(side).move_tab(from, to);
}
void close_tutorial_tabs() {
  if (!started()) return;
  app().pane(0).close_tutorial_tabs();
  app().pane(1).close_tutorial_tabs();
}

void set_keep_tutorial_tabs(bool keep) {
  if (started()) app().keep_tutorial_tabs = keep;
}
void adopt_tutorial_tabs(const std::string& prefix) {
  if (!started()) return;
  app().pane(0).adopt_tutorial_tabs(prefix);
  app().pane(1).adopt_tutorial_tabs(prefix);
}

std::vector<CommandInfo> commands() {
  std::vector<CommandInfo> out;
  for (const auto& c : app_commands())
    out.push_back({c.id, c.title, c.menu, c.scope, c.dialog, c.commander_key, c.mac_key, c.help, c.hidden, started() ? app().use_count(c.id) : 0});
  return out;
}
bool                     command_available(const std::string& id) { return started() && app().available(id); }
bool                     execute(const std::string& id) { return started() && app().execute(id); }
std::vector<std::string> palette(const std::string& query) { return started() ? app().palette(query) : std::vector<std::string>{}; }

uint64_t copy_discover(const CopyOptions& options) {
  auto&       e = engine();
  CopyRequest request;
  request.sources                 = paths(options.sources);
  request.destination             = Filepath(options.destination);
  request.follow_links            = options.follow_links;
  request.preserve_relative_links = options.keep_relative_links;
  request.conflict                = options.conflict == 1 ? Perun::CopyConflictMode::Update
                                    : options.conflict == 2 ? Perun::CopyConflictMode::Skip
                                                            : Perun::CopyConflictMode::Replace;
  auto mailbox = std::weak_ptr<Mailbox>(e.mailbox);
  auto events  = std::weak_ptr<ApplicationEvents>(e.app->events);
  auto session = std::make_shared<CopySession>(
    request, [mailbox] { if (auto m = mailbox.lock()) m->signal(); },
    [events, mailbox](std::string name, std::string detail, uint64_t id) {
      if (auto bus = events.lock()) bus->publish(std::move(name), std::move(detail), id);
      if (auto m = mailbox.lock()) m->signal();
    });
  auto id = e.next_copy++;
  e.copies[id] = session;
  return id;
}

DiscoveryInfo discovery(uint64_t id) {
  auto& e  = engine();
  auto  at = e.copies.find(id);
  if (at == e.copies.end()) return {};
  auto          progress = at->second->get_progress();
  DiscoveryInfo out;
  out.valid   = true;
  out.running = at->second->_running.load();
  out.bytes   = progress.byte_count;
  out.files   = progress.file_count;
  out.dirs    = progress.dir_count;
  out.links   = progress.link_count;
  out.errors  = progress.error_count;
  out.current = progress.current_file.empty() ? progress.current_dir : progress.current_file;
  out.steps   = int64_t(at->second->step_count());
  return out;
}

std::vector<PreviewRow> discovery_preview(uint64_t id, int64_t from, int64_t count) {
  std::vector<PreviewRow> out;
  auto&                   e  = engine();
  auto                    at = e.copies.find(id);
  if (at == e.copies.end()) return out;
  for (auto& item : at->second->preview(size_t(std::max<int64_t>(0, from)), size_t(std::max<int64_t>(0, count)))) {
    PreviewRow r;
    r.source = item.path_ref().native();
    r.kind   = item.is_dir() ? "folder" : item.symlink_ref() ? "link" : "file";
    r.bytes  = item.size();
    if (item.warning_ref()) r.message = *item.warning_ref();
    out.push_back(std::move(r));
  }
  return out;
}

void discovery_cancel(uint64_t id) { engine().copies.erase(id); }

std::string copy_start(uint64_t id, int side) {
  auto& e  = engine();
  auto  at = e.copies.find(id);
  if (at == e.copies.end()) return "The copy was cancelled";
  auto session = at->second;
  if (session->_running.load()) return "Still preparing the copy";
  const auto& request = session->request();
  if (auto error = archive_mutation_error(request.destination); !error.empty()) return error;
  if (is_archive_file_path(request.destination)) {
    auto plan     = Perun::selection_plan(OperationType::ARCHIVE_CREATE, request.sources, request.destination);
    plan.conflict = request.conflict;
    auto result   = submit(std::move(plan));
    if (!result.error.empty()) return result.error;
  } else {
    auto job = std::make_shared<JobSpec>(session->take_plan());
    if (!file_operations().add_job(job)) return "The job queue is full; try again when a job finishes";  // Leases are taken before discovery is released.
    ++e.jobs_revision;
  }
  e.copies.erase(id);
  if (started()) app().pane(side).clear_selection();
  return "";
}

SubmitResult submit_move(const StringList& sources, const std::string& target, int side) {
  if (auto error = archive_mutation_error(Filepath(target)); !error.empty()) return {error, 0};
  auto result = submit(Perun::selection_plan(OperationType::MOVE, paths(sources), Filepath(target)));
  if (result.error.empty() && started()) app().pane(side).clear_selection();
  return result;
}

SubmitResult submit_delete(const StringList& sources, int side) {
  for (const auto& s : sources)
    if (auto error = archive_mutation_error(Filepath(s)); !error.empty()) return {error, 0};
  auto result = submit(Perun::selection_plan(OperationType::DELETE, paths(sources)));
  if (result.error.empty() && started()) app().pane(side).clear_selection();
  return result;
}

SubmitResult submit_mkdir(const std::string& folder, const std::string& name) {
  if (name.empty()) return {"Enter a folder name", 0};
  if (name.find('/') != std::string::npos) return {"A folder name can't contain /", 0};
  auto path = Filepath(folder) / name;
  if (auto error = archive_mutation_error(path); !error.empty()) return {error, 0};
  OperationPlan plan;
  plan.type = OperationType::MKDIR;
  plan.steps.push_back({Operation::Kind::CreateDirectory, {}, path});
  return submit(std::move(plan));
}

SubmitResult submit_rename(const StringList& sources, const StringList& names) {
  if (sources.size() != names.size() || sources.empty()) return {"Nothing to rename", 0};
  OperationPlan plan;
  plan.type = OperationType::RENAME;
  for (size_t i = 0; i < sources.size(); ++i) {
    if (names[i].empty() || names[i].find('/') != std::string::npos) return {"Enter a valid name for " + Filepath(sources[i]).filename().native(), 0};
    Filepath source(sources[i]);
    if (auto error = archive_mutation_error(source); !error.empty()) return {error, 0};
    plan.steps.push_back({Operation::Kind::RenameEntry, source, location_parent(source) / names[i]});
  }
  return submit(std::move(plan));
}

void copy_to_clipboard(int side, bool names) {
  if (started()) app().copy_to_clipboard(side, names);
}

std::string find_start(const std::string& root, const std::string& pattern) {
  auto& e = engine();
  if (!e.find) {
    auto mailbox = std::weak_ptr<Mailbox>(e.mailbox);
    auto events  = std::weak_ptr<ApplicationEvents>(e.app->events);
    e.find       = std::make_unique<FindSession>([mailbox] { if (auto m = mailbox.lock()) m->signal(); },
                                           [events, mailbox](std::string name, std::string detail, uint64_t id) {
                                             if (auto bus = events.lock()) bus->publish(std::move(name), std::move(detail), id);
                                             if (auto m = mailbox.lock()) m->signal();
                                           });
  }
  e.find_status = e.find->start(Filepath(root), pattern);
  return e.find_status;
}

void find_stop() {
  if (engine().find) engine().find->stop();
}

FindInfo find_info() {
  FindInfo out;
  auto&    e = engine();
  out.status = e.find_status;
  if (!e.find) return out;
  out.running   = e.find->running();
  out.truncated = e.find->truncated();
  out.dirs      = e.find->dirs();
  out.files     = e.find->files();
  out.errors    = e.find->errors();
  out.matches   = int64_t(e.find->result_count());
  return out;
}

std::vector<std::string> find_results(int64_t from, int64_t count) {
  if (!engine().find) return {};
  return strings(engine().find->results(size_t(std::max<int64_t>(0, from)), size_t(std::max<int64_t>(0, count))));
}

void find_reveal(int side, const std::string& path) {
  if (!started()) return;
  Filepath target(path);
  auto&    p = app().pane(side);
  p.set_filter("");
  p.move_to(location_parent(target), target);
}

std::vector<JobInfo> jobs() {
  std::vector<JobInfo> out;
  auto                 running = file_operations().get_running_job();
  if (running.job && !running.job->is_stopped()) out.push_back(job_info(*running.job->snapshot(false)));
  auto history = file_operations().get_job_history();
  for (auto it = history.rbegin(); it != history.rend(); ++it) {
    auto id = (*it)->_job_id;
    if (std::none_of(out.begin(), out.end(), [id](const JobInfo& j) { return j.id == id; })) out.push_back(job_info(*(*it)->snapshot(false)));
  }
  return out;
}

RunningJob running_job() {
  RunningJob out;
  auto       running = file_operations().get_running_job();
  out.queued         = running.queued_jobs;
  if (!running.job || running.job->is_stopped()) return out;
  out.present = true;
  out.job     = job_info(*running.job->snapshot(false));
  return out;
}

JobDetail job_detail(uint64_t id) {
  JobDetail out;
  auto      job = find_job(id);
  if (!job) return out;
  auto snapshot = job->snapshot(true);
  out.info      = job_info(*snapshot);
  out.expired   = snapshot->_details_expired;
  for (const auto& item : snapshot->_items) out.items.push_back(item.path_ref().native());
  for (const auto& item : snapshot->_errors) out.errors.push_back(item.path_ref().native() + ": " + item.warning_ref().value_or("failed"));
  for (const auto& error : snapshot->_step_errors)
    if (!error.empty()) out.errors.push_back(error);
  return out;
}

namespace {
std::string job_error(Perun::JobError error) {
  switch (error) {
  case Perun::JobError::OK: return "";
  case Perun::JobError::NOT_FOUND: return "The job no longer exists";
  case Perun::JobError::CANCELLED: return "The job was cancelled";
  case Perun::JobError::RECOVERY_BLOCKED: return "Resume is blocked; see the job details";
  }
  return "Unknown job error";
}
}  // namespace

std::string pause_job(uint64_t id) { return job_error(file_operations().pause(id)); }
std::string resume_job(uint64_t id) { return job_error(file_operations().resume(id)); }
std::string cancel_job(uint64_t id) { return job_error(file_operations().cancel(id)); }
void        dismiss_job(uint64_t id) { file_operations().dismiss_job(id); }
uint64_t    transfer_rate() { return file_operations().transfer_rate(); }
void        set_transfer_rate(uint64_t bytes_per_second, bool persist) {
  if (started()) app().set_transfer_rate(bytes_per_second, persist);
  else file_operations().set_transfer_rate(bytes_per_second);
}

std::vector<ErrorInfo> errors(int count) {
  std::vector<ErrorInfo> out;
  for (auto& e : file_operations().get_errors(count)) out.push_back({e.message, e.time});
  return out;
}
int64_t error_count() { return file_operations().error_count(); }
void    clear_errors() { file_operations().clear_errors(); }
void    report_error(const std::string& message) { file_operations().report_error(message); }

std::vector<BookmarkInfo> bookmarks() {
  std::vector<BookmarkInfo> out;
  if (!started()) return out;
  for (const auto& b : app().bookmarks()) out.push_back({tab_title(b), b.display(), b.encode(), kind_of(b)});
  return out;
}
void add_bookmark(const std::string& location) {
  if (started()) app().add_bookmark(Filepath(location));
}
void remove_bookmark(const std::string& encoded) {
  if (started()) app().remove_bookmark(Filepath(encoded));
}

std::string open_in_editor() { return started() ? app().open_in_editor() : "Not started"; }
std::string switch_to_editor() { return started() ? app().switch_to_editor() : "Not started"; }
RestartResult restart_editor(bool allow_legacy) {
  RestartResult out;
  if (!started()) return out;
  auto result = app().editor().prepare_restart(app().pane(app().focused_side()).dir().path, allow_legacy, out.error);
  out.status  = result == EditorManager::RestartResult::Ready ? 0 : result == EditorManager::RestartResult::NeedsLegacyConfirmation ? 1 : 2;
  return out;
}
void set_editor_session(const std::string& session_store, const StringList& environment) {
  if (!started()) return;
  auto& editor = app().editor();
  editor.set_extra_environment(environment);
  editor.set_last_session_id("");
  editor.set_session_store(Filepath(session_store.empty() ? SettingsStore::path("editor_session.json").native() : session_store));
}
void set_editor_switch_key(const std::string& key) {
  if (started()) app().editor().set_switch_key(key);
}
void set_editor_scene_attach(bool on) {
  if (started()) app().editor().set_scene_attach(on);
}

int ssh_authenticate(const std::string& host) {
  try {
    return RemoteFS::authenticate(host);
  } catch (const std::exception& e) {
    report_error(e.what());
    return 255;
  }
}

std::string ssh_open(const std::string& host, const std::string& path) {
  if (!started()) return "Not started";
  try {
    app().open_ssh(host, path.empty() ? "/" : path);
    return "";
  } catch (const std::exception& e) { return e.what(); }
}

void set_endpoint_command(const std::string& host, const std::string& command) { RemoteFS::set_endpoint_command(host, command); }

EventBatch events_since(uint64_t cursor) {
  EventBatch out;
  out.cursor = cursor;
  if (!started()) return out;
  for (auto& e : app().events->since(out.cursor)) out.events.push_back({e.sequence, e.request_id, e.name, e.detail});
  return out;
}

std::string format_bytes(double bytes) {
  if (bytes < 1024) return std::format("{:.0f} B", bytes);
  if (bytes < 1024 * 1024) return std::format("{:.1f} KB", bytes / 1024);
  if (bytes < 1024.0 * 1024 * 1024) return std::format("{:.1f} MB", bytes / (1024 * 1024));
  return std::format("{:.1f} GB", bytes / (1024.0 * 1024 * 1024));
}

std::string display_location(const std::string& encoded) {
  try {
    return Location::decode(encoded).display();
  } catch (...) { return encoded; }
}

}  // namespace fce
