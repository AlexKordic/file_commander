#include "transfer_journal.hpp"
#include "file_io_jobs.hpp"
#include "file_metadata.hpp"
#include "settings.hpp"
#include "log.hpp"
#include <fcntl.h>
#include <unistd.h>
#include <boost/json.hpp>
#include <algorithm>
#include <fstream>
#include <map>
#include <limits>
#include <cmath>
#include <cstring>
#include <sys/stat.h>

namespace Perun {
namespace {
namespace j = boost::json;
namespace fs = boost::filesystem;
std::string text(const j::value& v) { return std::string(v.as_string()); }
int64_t number(const j::value& v) { return v.to_number<int64_t>(); }
Filepath absolute_path(const Filepath& p) { return p.empty() ? p : fs::absolute(p).lexically_normal(); }

j::object stamp(const Filepath& path, bool follow = false) {
  struct stat s{};
  const auto rc = follow ? ::stat(path.c_str(), &s) : ::lstat(path.c_str(), &s);
  if (rc != 0) {
    if (errno == ENOENT || errno == ENOTDIR) return {{"exists", false}};
    throw std::runtime_error("Cannot inspect recovery path: " + path.native());
  }
#if defined(__APPLE__)
  auto m = s.st_mtimespec, c = s.st_ctimespec;
#else
  auto m = s.st_mtim, c = s.st_ctim;
#endif
  j::object out{{"exists", true}, {"dev", uint64_t(s.st_dev)}, {"ino", uint64_t(s.st_ino)},
    {"mode", uint64_t(s.st_mode)}, {"size", int64_t(s.st_size)}, {"uid", uint64_t(s.st_uid)},
    {"gid", uint64_t(s.st_gid)}, {"mtime", int64_t(m.tv_sec)}, {"mtime_ns", int64_t(m.tv_nsec)},
    {"ctime", int64_t(c.tv_sec)}, {"ctime_ns", int64_t(c.tv_nsec)}};
  if (S_ISLNK(s.st_mode)) out["link"] = fs::read_symlink(path).native();
  return out;
}
bool exists(const j::object& s) { return s.at("exists").as_bool(); }
bool directory(const j::object& s) { return exists(s) && (number(s.at("mode")) & S_IFMT) == S_IFDIR; }
bool identity(const j::object& a, const j::object& b) {
  return exists(a) && exists(b) && a.at("dev") == b.at("dev") && a.at("ino") == b.at("ino")
    && (number(a.at("mode")) & S_IFMT) == (number(b.at("mode")) & S_IFMT);
}
bool unchanged(j::object a, j::object b, bool renamed = false) {
  if (renamed) { a.erase("ctime"); a.erase("ctime_ns"); b.erase("ctime"); b.erase("ctime_ns"); }
  return a == b;
}
j::array tree(const Filepath& path, bool follow = false, bool recursive = true) {
  j::array out;
  auto root = stamp(path, follow);
  out.emplace_back(j::object{{"relative", ""}, {"stamp", root}});
  if (recursive && directory(root)) {
    std::map<std::string, j::object> children;
    for (fs::recursive_directory_iterator i(path), end; i != end; ++i)
      children.emplace(i->path().lexically_relative(path).native(), stamp(i->path()));
    for (auto& [name, state] : children) out.emplace_back(j::object{{"relative", name}, {"stamp", std::move(state)}});
  }
  return out;
}
bool matches_tree(const Filepath& path, const j::array& expected, bool renamed = false, bool follow = false, bool recursive = true) {
  auto actual = tree(path, follow, recursive);
  if (actual.size() != expected.size()) return false;
  for (size_t i = 0; i < actual.size(); ++i) {
    const auto& a = actual[i].as_object(); const auto& b = expected[i].as_object();
    if (a.at("relative") != b.at("relative") || !unchanged(a.at("stamp").as_object(), b.at("stamp").as_object(), renamed && i == 0)) return false;
  }
  return true;
}
j::object anchor(Filepath path) {
  path = path.parent_path();
  while (!path.empty()) {
    auto s = stamp(path, true);
    if (exists(s)) return {{"path", path.native()}, {"stamp", std::move(s)}};
    auto parent = path.parent_path(); if (parent == path) break; path = parent;
  }
  return {};
}
void check_anchor(const j::object& a) {
  if (!a.empty() && !identity(a.at("stamp").as_object(), stamp(text(a.at("path")), true)))
    throw std::runtime_error("Transfer parent or mounted volume changed; review it before starting a new transfer");
}
j::object read(const Filepath& path, uint64_t limit = 64 * 1024 * 1024) {
  if (fs::file_size(path) > limit) throw std::runtime_error("Transfer journal exceeds size limit");
  std::ifstream in(path.native());
  if (!in) throw std::runtime_error("Cannot read transfer journal");
  auto o = j::parse(std::string(std::istreambuf_iterator<char>(in), {})).as_object();
  if (number(o.at("version")) != 1) throw std::runtime_error("Unsupported transfer journal version");
  return o;
}
void save(const Filepath& path, const j::object& o) {
  auto bytes = j::serialize(o) + "\n";
  if (bytes.size() > 64 * 1024 * 1024) throw std::runtime_error("Transfer journal exceeds size limit");
  SettingsStore::atomic_write(path, bytes);
}
void sync_path(const Filepath& path) {
  const auto s = stamp(path);
  if (!exists(s)) return;
  if ((number(s.at("mode")) & S_IFMT) == S_IFLNK) return;
  int fd = ::open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) throw std::runtime_error("Cannot open transfer path for durability: " + path.native());
  const int result = ::fsync(fd), error = errno;
  ::close(fd);
  if (result != 0) throw std::runtime_error("Cannot flush transfer path: " + path.native() + ": " + std::strerror(error));
}
void sync_tree(const Filepath& path, const j::array& entries) {
  for (auto i = entries.rbegin(); i != entries.rend(); ++i) {
    const auto relative = text(i->as_object().at("relative"));
    sync_path(relative.empty() ? path : path / relative);
  }
  sync_path(path.parent_path());
}
j::object encode(const Operation& op) {
  return {{"kind", int(op.kind)}, {"source", absolute_path(op.source).native()}, {"destination", absolute_path(op.destination).native()},
    {"link", op.link_text.native()}, {"message", op.message}, {"bytes", op.bytes},
    {"modified", int64_t(op.modified)}, {"permissions", uint64_t(op.permissions)}};
}
Operation decode(const j::object& o) {
  auto k = number(o.at("kind"));
  if (k < 0 || k > int(Operation::Kind::ClipboardText)) throw std::runtime_error("Invalid recovery operation");
  Operation op{static_cast<Operation::Kind>(k), text(o.at("source")), text(o.at("destination")), text(o.at("link")),
    text(o.at("message")), number(o.at("bytes")), std::time_t(number(o.at("modified"))),
    static_cast<DirItem::Perms>(number(o.at("permissions")))};
  if ((!op.source.empty() && !op.source.is_absolute()) || (!op.destination.empty() && !op.destination.is_absolute()))
    throw std::runtime_error("Recovery operations require absolute paths");
  if (op.source != op.source.lexically_normal() || op.destination != op.destination.lexically_normal())
    throw std::runtime_error("Recovery paths must be normalized");
  return op;
}
void validate_tree(const j::array& entries) {
  std::string previous;
  for (size_t i = 0; i < entries.size(); ++i) {
    const auto& entry = entries[i].as_object();
    const auto relative = text(entry.at("relative")); const Filepath path(relative);
    if ((i == 0 && !relative.empty()) || (i > 0 && (relative.empty() || relative <= previous)) || path.is_absolute() ||
        (!path.empty() && path != path.lexically_normal())) throw std::runtime_error("Invalid recovery tree path");
    for (const auto& part : path) if (part == "..") throw std::runtime_error("Recovery tree escapes its root");
    entry.at("stamp").as_object().at("exists").as_bool();
    previous = relative;
  }
}
bool terminal(JobState state) {
  return state == JobState::CANCELLED || state == JobState::COMPLETED || state == JobState::COMPLETED_WITH_ERRORS;
}
}

struct TransferJournal::Impl {
  mutable std::recursive_mutex mutex;
  Filepath plan_path, state_path;
  j::object plan, state;
  bool dismissed = false;
  std::chrono::steady_clock::time_point last_progress{};
  void save() { if (!dismissed) ::Perun::save(state_path, state); }
  size_t index() const { return size_t(number(state.at("next"))); }
  std::string phase() const { return text(state.at("phase")); }
  Operation op() const { return decode(plan.at("steps").as_array().at(index()).as_object().at("operation").as_object()); }
  const j::object& input() const { return plan.at("steps").as_array().at(index()).as_object(); }
  void stats(const JobStats& job, const std::vector<DirItem>& errors) {
    state["done"] = job._items_done; state["failed"] = job._items_failed; state["skipped"] = job._items_skipped;
    state["bytes"] = job._bytes_processed; state["total"] = job._bytes_total;
    state["partial"] = job._current_item.current_size;
    j::array list; for (const auto& e : errors)
      list.emplace_back(j::object{{"path", e.path_ref().native()}, {"message", e.warning_ref().value_or("")}});
    state["errors"] = std::move(list);
  }
  void apply(JobSpec& job) const {
    job._resume_index = index(); job._current_item_index = int(index());
    job._items_done = number(state.at("done")); job._items_failed = number(state.at("failed"));
    job._items_skipped = number(state.at("skipped"));
    job._bytes_processed = state.at("bytes").to_number<double>();
    job._bytes_total = state.at("total").to_number<double>();
    job._current_item.current_size = number(state.at("partial"));
    job._total.update(int64_t(job._bytes_processed) + job._current_item.current_size, int64_t(job._bytes_total));
    job._errors.clear(); job._error_count_total = 0;
    for (const auto& value : state.at("errors").as_array()) {
      const auto& e = value.as_object(); job.report_error(DirItem(text(e.at("path"))), text(e.at("message")));
    }
  }
  void complete_proven_commit() {
    const auto operation = op();
    state["next"] = index() + 1;
    state["done"] = number(state.at("done")) + 1;
    state["bytes"] = state.at("bytes").to_number<double>() + std::max(int64_t(0), operation.bytes);
    state["partial"] = 0; state["phase"] = "ready";
    save();
  }
};

TransferJournal::TransferJournal(std::unique_ptr<Impl> value) : impl(std::move(value)) {}
TransferJournal::~TransferJournal() = default;

std::shared_ptr<TransferJournal> TransferJournal::create(const Filepath& directory, const JobSpec& job) {
  auto p = std::make_unique<Impl>();
  p->plan_path = directory / (std::to_string(job._job_id) + ".plan.json");
  p->state_path = directory / (std::to_string(job._job_id) + ".state.json");
  if (fs::exists(p->plan_path)) throw std::runtime_error("Transfer journal identity already exists");
  j::array steps;
  for (const auto& original : job._plan->steps) {
    const auto op = decode(encode(original));
    steps.emplace_back(j::object{{"operation", encode(op)},
      {"source", op.source.empty() ? j::array{} : tree(op.source, op.kind == Operation::Kind::CopyFile, op.kind == Operation::Kind::MoveEntry)},
      {"destination", op.destination.empty() ? j::object{} : stamp(op.destination)},
      {"source_anchor", op.source.empty() ? j::object{} : anchor(op.source)},
      {"destination_anchor", op.destination.empty() ? j::object{} : anchor(op.destination)}});
  }
  p->plan = {{"version", 1}, {"id", job._job_id}, {"type", int(job._type)},
    {"conflict", int(job._copy_conflict)}, {"steps", std::move(steps)}};
  p->state = {{"version", 1}, {"next", 0}, {"phase", "ready"}, {"state", int(JobState::QUEUED)}, {"directories", j::array{}}};
  p->stats(job, job._errors);
  save(p->plan_path, p->plan); p->save();
  return std::shared_ptr<TransferJournal>(new TransferJournal(std::move(p)));
}

std::vector<std::shared_ptr<JobSpec>> TransferJournal::restore(const Filepath& directory, uint64_t& next_id,
    const std::function<void(std::string)>& error) {
  std::vector<std::shared_ptr<JobSpec>> jobs;
  if (!fs::exists(directory)) return jobs;
  for (fs::directory_iterator i(directory), end; i != end; ++i) {
    const auto name = i->path().filename().native();
    if (!name.ends_with(".plan.json")) continue;
    try {
      uint64_t id = std::stoull(name.substr(0, name.size() - 10));
      if (id == 0 || id == std::numeric_limits<uint64_t>::max() || name != std::to_string(id) + ".plan.json")
        throw std::runtime_error("Invalid journal filename");
      next_id = std::max(next_id, id + 1); // Even a corrupt record reserves its ID.
      auto p = std::make_unique<Impl>(); p->plan_path = i->path();
      p->state_path = directory / (std::to_string(id) + ".state.json");
      p->plan = read(p->plan_path);
      if (p->plan.at("id").to_number<uint64_t>() != id) throw std::runtime_error("Journal ID mismatch");
      auto plan = std::make_shared<OperationPlan>();
      auto type = number(p->plan.at("type")), conflict = number(p->plan.at("conflict"));
      if (type < 0 || type > int(OperationType::CLIPBOARD) || conflict < 0 || conflict > 2)
        throw std::runtime_error("Invalid recovered operation type");
      plan->type = static_cast<OperationType>(type); plan->conflict = static_cast<CopyConflictMode>(conflict);
      for (const auto& step : p->plan.at("steps").as_array()) {
        plan->steps.push_back(decode(step.as_object().at("operation").as_object()));
        validate_tree(step.as_object().at("source").as_array());
      }
      auto job = std::make_shared<JobSpec>(plan); job->_job_id = id;
      if (fs::exists(p->state_path)) p->state = read(p->state_path);
      else {
        p->state = {{"version", 1}, {"next", 0}, {"phase", "ready"}, {"state", int(JobState::QUEUED)}, {"directories", j::array{}}};
        p->stats(*job, {});
      }
      if (number(p->state.at("next")) < 0 || p->index() > plan->steps.size()) throw std::runtime_error("Invalid recovery progress");
      const auto phase = p->phase();
      if (phase != "ready" && phase != "executing" && phase != "staging" && phase != "commit_ready" && phase != "committed" && phase != "source_remove")
        throw std::runtime_error("Invalid recovery phase");
      if (phase != "ready" && p->index() == plan->steps.size()) throw std::runtime_error("Missing recovery operation");
      for (const auto key : {"done", "failed", "skipped", "partial"})
        if (number(p->state.at(key)) < 0) throw std::runtime_error("Invalid recovery counts");
      if (number(p->state.at("done")) > int64_t(plan->steps.size())) throw std::runtime_error("Invalid recovery item count");
      for (const auto key : {"bytes", "total"})
        if (!std::isfinite(p->state.at(key).to_number<double>()) || p->state.at(key).to_number<double>() < 0)
          throw std::runtime_error("Invalid recovery byte count");
      if (p->state.contains("stage_root")) {
        auto root = Filepath(text(p->state.at("stage_root")));
        auto stage = Filepath(text(p->state.at("stage")));
        // The last completed operation can still have a staging record.
        auto index = phase == "ready" && p->index() ? p->index() - 1 : p->index();
        const auto op = plan->steps.at(index);
        const auto prefix = op.kind == Operation::Kind::MoveEntry ? ".fc-move-" : ".fc-copy-";
        if (root.parent_path() != op.destination.parent_path() || !root.filename().native().starts_with(prefix) ||
            stage.parent_path() != root || stage.filename() != (op.kind == Operation::Kind::MoveEntry ? "entry" : "data"))
          throw std::runtime_error("Invalid recovery staging path");
      }
      for (const auto& value : p->state.at("directories").as_array()) {
        const auto n = number(value.as_object().at("index"));
        if (n < 0 || size_t(n) >= p->index() || plan->steps.at(size_t(n)).kind != Operation::Kind::CreateDirectory)
          throw std::runtime_error("Invalid recovered directory ownership");
      }
      if (p->state.contains("output")) validate_tree(p->state.at("output").as_array());
      auto state = number(p->state.at("state"));
      if (state < 0 || state > int(JobState::COMPLETED_WITH_ERRORS)) throw std::runtime_error("Invalid recovery state");
      p->apply(*job);
      job->_state = terminal(static_cast<JobState>(state)) ? static_cast<JobState>(state) : JobState::PAUSED;
      job->_stopped = terminal(job->_state);
      if (job->_stopped) job->_finished_time = now();
      else {
        job->_recovery_waiting = true;
        job->_recovery_note = "Interrupted transfer — paused until Resume";
        p->state["state"] = int(JobState::PAUSED); p->save();
      }
      job->_journal = std::shared_ptr<TransferJournal>(new TransferJournal(std::move(p)));
      jobs.push_back(std::move(job));
    } catch (const std::exception& e) { error("[Transfer recovery] " + name + ": " + e.what() + "; record retained"); }
  }
  std::sort(jobs.begin(), jobs.end(), [](const auto& a, const auto& b) { return a->_job_id < b->_job_id; });
  return jobs;
}

void TransferJournal::begin_step(size_t index) {
  std::lock_guard lock(impl->mutex);
  impl->state["next"] = index;
  impl->state["phase"] = "executing";
  if (!terminal(static_cast<JobState>(number(impl->state.at("state"))))) impl->state["state"] = int(JobState::RUNNING);
  impl->state.erase("stage"); impl->state.erase("stage_root"); impl->state.erase("stage_identity"); impl->state.erase("output");
  impl->save();
}

void TransferJournal::finish_step(const JobSpec& job) {
  std::lock_guard lock(impl->mutex);
  const auto op = impl->op();
  if (!op.destination.empty()) sync_path(op.destination.parent_path());
  if (op.kind == Operation::Kind::MoveEntry && !op.source.empty()) sync_path(op.source.parent_path());
  if (op.kind == Operation::Kind::CreateDirectory && !exists(impl->input().at("destination").as_object())) {
    auto s = stamp(op.destination);
    if (directory(s)) impl->state.at("directories").as_array().emplace_back(
      j::object{{"index", impl->index()}, {"stamp", std::move(s)}});
  }
  impl->state["next"] = size_t(job._current_item_index);
  impl->state["phase"] = "ready";
  impl->stats(job, job._errors); impl->state["partial"] = 0;
  impl->save();
}

void TransferJournal::checkpoint(const JobSnapshot& job, JobState state, bool force) {
  std::lock_guard lock(impl->mutex);
  if (impl->dismissed) return;
  if (terminal(static_cast<JobState>(number(impl->state.at("state")))) && !terminal(state)) return;
  if (job._current_item_index < int(impl->index())) return; // Ignore a stale progress-monitor snapshot.
  auto now = std::chrono::steady_clock::now();
  if (!force && now - impl->last_progress < std::chrono::seconds(1)) return;
  impl->last_progress = now;
  impl->stats(job, job._errors); impl->state["state"] = int(state); impl->save();
}

int TransferJournal::transaction(const char* phase, const Filepath& stage, const Filepath& destination) {
  std::lock_guard lock(impl->mutex);
  // Exceptions are caught by the synchronous worker; no C ABI boundary is crossed.
  impl->state["phase"] = phase;
  if (std::string_view(phase) == "staging") {
    impl->state["stage"] = stage.native(); impl->state["stage_root"] = stage.parent_path().native();
    impl->state["stage_identity"] = stamp(stage.parent_path());
  } else if (std::string_view(phase) == "commit_ready") {
    auto output = tree(stage);
    sync_tree(stage, output);
    impl->state["output"] = std::move(output);
  } else if (std::string_view(phase) == "committed") sync_path(destination.parent_path());
  impl->save();
  return 0;
}

bool TransferJournal::cleanup_pending() const {
  std::lock_guard lock(impl->mutex);
  return impl->phase() == "committed" || impl->phase() == "source_remove";
}

void TransferJournal::prepare_resume(JobSpec& job) {
  std::lock_guard lock(impl->mutex);
  if (job._type != OperationType::COPY && job._type != OperationType::MOVE)
    throw std::runtime_error("This operation cannot resume safely. Cancel recovery and start a new operation after reviewing its files.");
  if (impl->index() < job._plan->steps.size() && impl->phase() != "ready") {
    const auto op = impl->op();
    const auto& input = impl->input();
    check_anchor(input.at("source_anchor").as_object()); check_anchor(input.at("destination_anchor").as_object());
    bool committed = impl->state.contains("output") && matches_tree(op.destination, impl->state.at("output").as_array(), true);
    if (op.kind == Operation::Kind::MoveEntry && !exists(stamp(op.source)) &&
        matches_tree(op.destination, input.at("source").as_array(), true)) {
      impl->complete_proven_commit(); // Same-filesystem rename completed before the journal update.
    } else if (committed) {
      if (op.kind == Operation::Kind::MoveEntry) {
        impl->state["phase"] = "committed";
        // Source cleanup is deferred to the worker after explicit Resume.
      } else impl->complete_proven_commit();
    } else if (impl->phase() == "committed" || impl->phase() == "source_remove") {
      throw std::runtime_error("Committed destination changed; source cleanup is blocked. Review files, then cancel recovery or start a new transfer.");
    } else if (!unchanged(stamp(op.destination), input.at("destination").as_object())) {
      throw std::runtime_error("Destination changed during interruption; completion is uncertain. Review files before restarting the transfer.");
    }
  }
  for (size_t i = impl->index(); i < job._plan->steps.size(); ++i) {
    const auto& input = impl->plan.at("steps").as_array()[i].as_object();
    const auto op = decode(input.at("operation").as_object());
    check_anchor(input.at("source_anchor").as_object()); check_anchor(input.at("destination_anchor").as_object());
    if (i == impl->index() && cleanup_pending()) continue;
    if (!op.source.empty() && !matches_tree(op.source, input.at("source").as_array(), false, op.kind == Operation::Kind::CopyFile, op.kind == Operation::Kind::MoveEntry))
      throw std::runtime_error("Source changed or is unavailable: " + op.source.native() + ". Cancel recovery and start a new transfer after reviewing it.");
    if (!op.destination.empty() && !unchanged(stamp(op.destination), input.at("destination").as_object()))
      throw std::runtime_error("Destination conflict: " + op.destination.native() + ". Resolve it before Resume, or cancel and start a new transfer.");
    if (op.kind == Operation::Kind::CopyFile && ::access(op.source.c_str(), R_OK) != 0)
      throw std::runtime_error("Source is not readable: " + op.source.native());
    if (!op.destination.empty()) {
      auto parent = op.destination.parent_path();
      while (!parent.empty() && !exists(stamp(parent, true))) parent = parent.parent_path();
      bool owned = false;
      for (const auto& value : impl->state.at("directories").as_array()) {
        const auto& saved = value.as_object();
        const auto step = decode(impl->plan.at("steps").as_array().at(size_t(number(saved.at("index")))).as_object().at("operation").as_object());
        if (step.destination == parent && identity(stamp(parent), saved.at("stamp").as_object())) owned = true;
      }
      if (!owned && ::access(parent.c_str(), W_OK | X_OK) != 0)
        throw std::runtime_error("Destination directory is not writable: " + parent.native());
    }
  }
  // Only remove a private staging tree after explicit Resume and an identity check.
  if (!cleanup_pending() && impl->state.contains("stage_root")) {
    auto root = Filepath(text(impl->state.at("stage_root")));
    auto current = stamp(root);
    if (exists(current)) {
      if (!identity(current, impl->state.at("stage_identity").as_object())) throw std::runtime_error("Recovery staging ownership changed; cleanup blocked");
      // Graceful shutdown restored original directory permissions. Temporarily
      // allow cleanup of our staging child, then restore access before returning.
      auto parent = root.parent_path(); const auto previous = fs::status(parent).permissions();
      bool restore_access = false;
      for (const auto& value : impl->state.at("directories").as_array()) {
        const auto& saved = value.as_object();
        const auto step = decode(impl->plan.at("steps").as_array().at(size_t(number(saved.at("index")))).as_object().at("operation").as_object());
        if (step.destination == parent && identity(stamp(parent), saved.at("stamp").as_object())) {
          fs::permissions(parent, fs::add_perms | fs::owner_all); restore_access = true; break;
        }
      }
      boost::system::error_code ec; remove_owned_staging(root, ec);
      if (restore_access) fs::permissions(parent, previous);
      if (ec) throw std::runtime_error("Cannot clean interrupted staging: " + ec.message());
    }
  }
  impl->apply(job);
  impl->state["state"] = int(JobState::QUEUED); impl->save();
}

void TransferJournal::prepare_copy_directories(std::vector<Operation>& out) {
  std::lock_guard lock(impl->mutex);
  for (const auto& value : impl->state.at("directories").as_array()) {
    const auto& saved = value.as_object();
    const auto& step = impl->plan.at("steps").as_array().at(size_t(number(saved.at("index")))).as_object();
    auto op = decode(step.at("operation").as_object());
    if (!op.source.empty() && !matches_tree(op.source, step.at("source").as_array(), false, false, false))
      throw std::runtime_error("Source directory changed; restoring its access settings is unsafe: " + op.source.native());
    if (!identity(stamp(op.destination), saved.at("stamp").as_object())) throw std::runtime_error("Created destination directory was replaced; Resume blocked");
    fs::permissions(op.destination, fs::add_perms | fs::owner_all);
    out.push_back(std::move(op));
  }
}

int TransferJournal::remove_source(const Filepath& source, const Filepath& destination,
                                  const fs::copy_file_io_hooks* io) {
  std::lock_guard lock(impl->mutex);
  if (!matches_tree(destination, impl->state.at("output").as_array(), true))
    throw std::runtime_error("Committed destination changed; source removal blocked");
  const auto& expected = impl->input().at("source").as_array();
  std::map<std::string, const j::object*> outputs;
  for (const auto& entry : impl->state.at("output").as_array())
    outputs.emplace(text(entry.as_object().at("relative")), &entry.as_object().at("stamp").as_object());
  auto verify = [&](const j::object& entry) {
    auto relative = text(entry.at("relative"));
    auto path = relative.empty() ? source : source / relative;
    auto current = stamp(path); const auto& original = entry.at("stamp").as_object();
    if (!exists(current)) return;
    bool same = directory(original) ? identity(current, original) && current.at("mode") == original.at("mode") : unchanged(current, original);
    if (!same) throw std::runtime_error("Source changed during move cleanup: " + path.native());
  };
  for (const auto& value : expected) verify(value.as_object());
  impl->state["phase"] = "source_remove"; impl->save();
  // Children precede parents. remove(), unlike remove_all(), refuses unexpected
  // new directory contents. Missing entries from an interrupted cleanup are OK.
  for (auto it = expected.rbegin(); it != expected.rend(); ++it) {
    const auto& entry = it->as_object(); verify(entry);
    auto relative = text(entry.at("relative"));
    auto path = relative.empty() ? source : source / relative;
    if (exists(stamp(path))) {
      const auto target = relative.empty() ? destination : destination / relative;
      const auto found = outputs.find(relative);
      if (found == outputs.end() || !unchanged(stamp(target), *found->second, relative.empty()))
        throw std::runtime_error("Destination changed during move cleanup: " + target.native());
      fs::remove(path);
      sync_path(path.parent_path());
      if (io && io->fault) { int error = io->fault(io->context, "recovery_source_item"); if (error) return error; }
    }
  }
  return 0;
}

void TransferJournal::dismiss() {
  std::lock_guard lock(impl->mutex);
  // Remove the plan first: a crash between removals cannot resurrect a dismissed job.
  fs::remove(impl->plan_path); fs::remove(impl->state_path);
  impl->dismissed = true;
  sync_path(impl->plan_path.parent_path());
}
}
