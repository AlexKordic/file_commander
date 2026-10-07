#include "copy_planner.hpp"
#include "remote_fs.hpp"
#include "traversal.hpp"
#include <unordered_set>
using namespace Perun;
namespace {
std::atomic<uint64_t> sequence{1};
Filepath              resolve_link(Filepath current) {
  std::unordered_set<std::string> chain;
  for (;;) {
    boost::system::error_code ec;
    auto                      parent   = boost::filesystem::canonical(current.parent_path(), ec);
    auto                      identity = ec ? current.lexically_normal() : parent / current.filename();
    if (!chain.insert(identity.native()).second) return {};
    auto target = boost::filesystem::read_symlink(current, ec);
    if (ec || target.empty()) return current;
    current = (target.is_relative() ? current.parent_path() / target : target).lexically_normal();
  }
}
}  // namespace
CopyPlanner::CopyPlanner(CopyRequest request, std::function<void()> notify, std::function<void(std::string, std::string, uint64_t)> emit) : _request(std::move(request)), _notify(std::move(notify)), _emit(std::move(emit)) {
  _sequence_id   = sequence.fetch_add(1);
  _plan.conflict = _request.conflict;
  for (const auto& p : _request.sources)
    if (auto lease = archive_service().lease_for_path(p)) _leases.push_back(std::move(lease));
  _thread = std::thread([this] { run(); });
}
CopyPlanner::~CopyPlanner() {
  _running = false;
  if (_thread.joinable()) _thread.join();
}
CopyDiscoveryProgress CopyPlanner::get_progress() {
  std::lock_guard lock(_m);
  return _progress;
}
std::shared_ptr<const OperationPlan> CopyPlanner::take_plan() {
  if (_running) return {};
  if (_thread.joinable()) _thread.join();
  std::lock_guard lock(_m);
  return std::make_shared<const OperationPlan>(std::move(_plan));
}
std::vector<DirItem> CopyPlanner::take_items() {
  auto plan = take_plan();
  return plan ? legacy_plan_items(*plan) : std::vector<DirItem>{};
}
void CopyPlanner::run() {
  auto append = [&](Operation op) {
    std::lock_guard lock(_m);
    switch (op.kind) {
    case Operation::Kind::CopyFile:
      ++_progress.file_count;
      _progress.byte_count += op.bytes;
      break;
    case Operation::Kind::CreateDirectory: ++_progress.dir_count; break;
    case Operation::Kind::CreateSymlink: ++_progress.link_count; break;
    case Operation::Kind::DiscoveryFailure: ++_progress.error_count; break;
    default: break;
    }
    _progress.current_file = op.source.native();
    _plan.steps.push_back(std::move(op));
  };
  auto               error = [&](const Filepath& source, const Filepath& target, const std::string& message) { append({Operation::Kind::DiscoveryFailure, source, target, {}, message}); };
  TraversalCallbacks cb;
  cb.cancelled = [this] { return !_running.load(); };
  cb.error     = [&](const Filepath& p, const std::string& message) { error(p, _request.destination / p.filename(), message); };
  cb.enter     = [&](const TraversalEntry& e) {
    auto                      target = _request.destination / e.relative;
    DirItem item = e.bytes ? DirItem(e.path, e.path.filename().native(), e.status.type(),
                                     e.status.permissions(), *e.modified, *e.bytes)
                           : DirItem(e.path);
    boost::system::error_code ec;
    if ((is_remote(e.path) || is_remote(target))
            ? e.path == target
            : (boost::filesystem::equivalent(e.path, target, ec) && !ec)) {
      error(e.path, target, "Copy to self");
      return false;
    }
    Operation op{Operation::Kind::CopyFile, e.path, target, {}, {}, item.size(), item.write_time(), item.perms()};
    if (e.duplicate_of) {
      op.kind = Operation::Kind::CreateSymlink;
      op.source.clear();
      op.link_text = (_request.destination / *e.duplicate_of).lexically_relative(target.parent_path());
      append(std::move(op));
      return false;
    }
    if (e.link_text && !_request.follow_links) {
      auto text = *e.link_text;
      if (!is_remote(e.path) && !(_request.preserve_relative_links && text.is_relative())) {
        text = resolve_link(e.path);
        if (text.empty()) {
          error(e.path, target, "Cyclic symlink");
          return false;
        }
        auto canonical = boost::filesystem::canonical(text, e.path.parent_path(), ec);
        if (!ec) text = canonical;
      }
      op.kind = Operation::Kind::CreateSymlink;
      op.source.clear();
      op.link_text = text;
      append(std::move(op));
      return false;
    }
    if (e.link_text && _request.follow_links && is_remote(e.path))
      op.source = RemoteFS::canonical(e.path);
    if (boost::filesystem::is_directory(e.status)) {
      if (is_remote(e.path) || is_remote(target)) {
        if (e.path == target || path_is_under(e.path, target)) {
          error(e.path, target, "Copy dir into itself");
          return false;
        }
        op.kind = Operation::Kind::CreateDirectory;
        append(std::move(op));
        return true;
      }
      auto source   = boost::filesystem::canonical(e.path, ec);
      auto resolved = boost::filesystem::weakly_canonical(target, ec);
      if (!ec && path_is_under(source, resolved)) {
        error(e.path, target, "Copy dir into itself");
        return false;
      }
      op.kind = Operation::Kind::CreateDirectory;
    }
    append(std::move(op));
    return true;
  };
  try {
    traverse(_request.sources, TraversalPolicy{_request.follow_links}, cb);
  } catch (const std::exception& e) { error({}, _request.destination, e.what()); }
  bool completed = _running.exchange(false);
  _emit(completed ? "discovery_completed" : "discovery_cancelled", std::to_string(_sequence_id), _sequence_id);
  _notify();
}
