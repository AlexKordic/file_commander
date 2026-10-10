#include "dialog_models.hpp"

#include "location.hpp"
#include "pane_model.hpp"

#include <algorithm>
#include <cctype>

std::vector<DirItem> CopySession::preview(size_t from, size_t count) {
  std::lock_guard      lock(_m);
  std::vector<DirItem> out;
  for (size_t i = from; i < _plan.steps.size() && out.size() < count; ++i) out.push_back(Perun::operation_display(_plan.steps[i]));
  return out;
}

size_t CopySession::step_count() {
  std::lock_guard lock(_m);
  return _plan.steps.size();
}

namespace {
std::atomic<uint64_t> g_find_sequence{1};
}

FindSession::FindSession(Notify notify, Emit emit) : _notify(std::move(notify)), _emit(std::move(emit)) {}

FindSession::~FindSession() { stop(); }

void FindSession::stop() {
  _running.store(false);
  if (_worker.joinable()) _worker.join();
}

std::string FindSession::start(const Filepath& root, std::string pattern) {
  stop();
  if (root.empty()) return "Enter a folder to search";
  boost::system::error_code ec;
  const bool exists = is_remote(root) || boost::filesystem::exists(root, ec);
  const bool is_dir = exists && !ec.failed() && (is_remote(root) || boost::filesystem::is_directory(root, ec));
  if (ec.failed() || !exists || !is_dir) return "The search folder must be an existing directory";
  if (pattern.empty()) pattern = "*";
  {
    std::lock_guard lock(_mutex);
    _results.clear();
  }
  _dirs = _files = _errors = 0;
  _truncated = false;
  _sequence  = g_find_sequence.fetch_add(1);
  _running   = true;
  _worker    = std::thread([this, root, pattern, sequence = _sequence] {
    TraversalCallbacks cb;
    cb.cancelled = [this] { return !_running.load(); };
    cb.enter     = [&](const TraversalEntry& e) {
      if (boost::filesystem::is_directory(e.status)) ++_dirs;
      else ++_files;
      if (e.path != root && glob_match_casefold(pattern, e.path.filename().native())) {
        std::lock_guard lock(_mutex);
        _results.push_back(e.path);
      }
      return true;
    };
    cb.leave     = [this](const auto&) { _notify(); };
    cb.error     = [this](const auto&, const auto&) { ++_errors; };
    auto result  = traverse({root}, TraversalPolicy{false, 100000, 1024}, cb);
    _truncated   = result.truncated;
    _running     = false;
    _emit(result.cancelled ? "find_cancelled" : "find_completed", std::to_string(sequence), sequence);
    _notify();
  });
  return {};
}

size_t FindSession::result_count() {
  std::lock_guard lock(_mutex);
  return _results.size();
}

std::vector<Filepath> FindSession::results(size_t from, size_t count) {
  std::lock_guard       lock(_mutex);
  std::vector<Filepath> out;
  for (size_t i = from; i < _results.size() && out.size() < count; ++i) out.push_back(_results[i]);
  return out;
}

std::string lower_ascii(std::string text) {
  for (char& c : text) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  return text;
}

int palette_score(const std::string& query_lower, const std::string& text_lower) {
  if (query_lower.empty()) return 0;
  int  score = 0, qpos = 0, last_match = -2;
  bool has_prefix = false;
  for (int i = 0; i < int(text_lower.size()) && qpos < int(query_lower.size()); ++i) {
    if (text_lower[i] != query_lower[qpos]) continue;
    if (qpos == 0 && i == 0) {
      has_prefix = true;
      score += 20;
    }
    score += i == last_match + 1 ? 10 : 3;
    const bool word_start = i == 0 || text_lower[i - 1] == ' ' || text_lower[i - 1] == '_' || text_lower[i - 1] == '-';
    if (word_start) score += 4;
    last_match = i;
    qpos++;
  }
  if (qpos != int(query_lower.size())) return -1;
  if (has_prefix) score += 10;
  // Letters scattered across words must not outrank the query typed as a whole.
  int literal = 0;
  for (size_t at = text_lower.find(query_lower); at != std::string::npos; at = text_lower.find(query_lower, at + 1)) {
    const bool word_start = at == 0 || text_lower[at - 1] == ' ' || text_lower[at - 1] == '_' || text_lower[at - 1] == '-';
    literal               = std::max(literal, word_start ? 150 : 100);
    if (word_start) break;
  }
  return score + literal;
}
