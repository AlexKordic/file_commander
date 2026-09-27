#include "traversal.hpp"
#include <unordered_map>

TraversalResult traverse(const std::vector<Filepath>& roots, const TraversalPolicy& policy, const TraversalCallbacks& cb) {
  namespace fs = boost::filesystem;
  struct Frame { TraversalEntry entry; fs::directory_iterator next, end; };
  std::vector<Frame> stack;
  std::unordered_map<std::string,Filepath> visited;
  TraversalResult result;
  auto error = [&](const Filepath& p, const std::string& message) { ++result.errors; cb.error(p,message); };
  auto enter = [&](const Filepath& path, const Filepath& relative) {
    if (result.entries >= policy.max_entries || stack.size() >= policy.max_depth) {
      result.truncated=true; error(path,"Traversal budget exceeded"); return;
    }
    ++result.entries;
    boost::system::error_code ec;
    TraversalEntry e{path,relative,fs::symlink_status(path,ec),{}, {}};
    if (ec) { error(path,ec.message()); return; }
    if (fs::is_symlink(e.status)) {
      e.link_text=fs::read_symlink(path,ec);
      if (!ec && policy.follow_links) e.status=fs::status(path,ec);
      if (ec) { error(path,ec.message()); return; }
    }
    if (fs::is_directory(e.status)) {
      auto identity=fs::canonical(path,ec);
      if (ec) { error(path,ec.message()); return; }
      auto [at,inserted]=visited.emplace(identity.native(),relative);
      if (!inserted) e.duplicate_of=at->second;
    }
    bool descend=cb.enter(e) && fs::is_directory(e.status) && !e.duplicate_of;
    if (descend && !cb.cancelled()) {
      fs::directory_iterator it(path,ec);
      if (ec) { error(path,ec.message()); cb.leave(e); }
      else stack.push_back({std::move(e),it,{}});
    } else cb.leave(e);
  };
  for (const auto& root:roots) {
    if (cb.cancelled() || result.truncated) break;
    enter(root,root.filename());
    while (!stack.empty() && !result.truncated && !cb.cancelled()) {
      auto& frame=stack.back();
      if (frame.next==frame.end) { cb.leave(frame.entry); stack.pop_back(); continue; }
      auto child=frame.next->path(); auto relative=frame.entry.relative/child.filename();
      boost::system::error_code ec; frame.next.increment(ec);
      if (ec) { error(frame.entry.path,ec.message()); frame.next=frame.end; }
      enter(child,relative);
    }
  }
  result.cancelled=cb.cancelled();
  return result;
}
