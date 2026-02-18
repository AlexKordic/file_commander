#include "editor_manager.hpp"
#include "runtime_paths.hpp"

#include <boost/filesystem.hpp>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <sstream>
#include <string>
#include <vector>

#if defined(__unix__) || defined(__APPLE__)
#include <sys/wait.h>
#endif

#ifndef FC_FRESH_DEFAULT_BIN
#define FC_FRESH_DEFAULT_BIN "fresh"
#endif

namespace {

double now_seconds() {
  using clock = std::chrono::steady_clock;
  static const auto t0 = clock::now();
  const auto        dt = clock::now() - t0;
  return std::chrono::duration<double>(dt).count();
}

std::string shell_escape(const std::string& input) {
  std::string out;
  out.reserve(input.size() + 8);
  out.push_back('\'');
  for (char c : input) {
    if (c == '\'') out += "'\\''";
    else out.push_back(c);
  }
  out.push_back('\'');
  return out;
}

int decode_exit_code(int system_result) {
  if (system_result == -1) return -1;
#if defined(__unix__) || defined(__APPLE__)
  if (WIFEXITED(system_result)) return WEXITSTATUS(system_result);
  if (WIFSIGNALED(system_result)) return 128 + WTERMSIG(system_result);
#endif
  return system_result;
}

}  // namespace

EditorManager::EditorManager(RunForeground run_foreground, StatusSink status_sink)
    : _run_foreground(std::move(run_foreground)), _status_sink(std::move(status_sink)) {}

void EditorManager::set_run_foreground(RunForeground run_foreground) {
  _run_foreground = std::move(run_foreground);
}

void EditorManager::set_status_sink(StatusSink status_sink) {
  _status_sink = std::move(status_sink);
}

void EditorManager::set_binary_override(std::string path) {
  _binary_override = std::move(path);
}

const std::string& EditorManager::binary_override() const {
  return _binary_override;
}

std::string EditorManager::resolved_binary() const {
  if (!_binary_override.empty()) return normalize_tool_reference(_binary_override);

  if (const char* env_bin = std::getenv("FC_FRESH_BIN")) {
    if (*env_bin) return normalize_tool_reference(env_bin);
  }

  return normalize_tool_reference(FC_FRESH_DEFAULT_BIN);
}

void EditorManager::set_last_session_id(std::string id) {
  _last_session_id = std::move(id);
}

const std::string& EditorManager::last_session_id() const {
  return _last_session_id;
}

std::vector<EditorSessionInfo> EditorManager::sessions() const {
  return _sessions;
}

void EditorManager::report_status(const std::string& text) const {
  if (_status_sink) _status_sink(text);
}

EditorSessionInfo* EditorManager::find_session(const std::string& id) {
  auto it = std::find_if(_sessions.begin(), _sessions.end(), [&id](const EditorSessionInfo& s) { return s.id == id; });
  return it == _sessions.end() ? nullptr : &(*it);
}

const EditorSessionInfo* EditorManager::find_session(const std::string& id) const {
  auto it = std::find_if(_sessions.begin(), _sessions.end(), [&id](const EditorSessionInfo& s) { return s.id == id; });
  return it == _sessions.end() ? nullptr : &(*it);
}

std::string EditorManager::pretty_name_for_dir(const Filepath& directory) const {
  std::string name = directory.filename().native();
  if (name.empty()) name = directory.native();
  if (name.empty()) name = "session";
  return name;
}

std::string EditorManager::create_session_id(const Filepath& directory) {
  ++_session_counter;
  const auto now_ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
  std::ostringstream ss;
  ss << "fc-" << pretty_name_for_dir(directory) << "-" << now_ms << "-" << _session_counter;
  std::string out = ss.str();
  for (char& c : out) {
    const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_';
    if (!ok) c = '-';
  }
  return out;
}

int EditorManager::run_command(const Filepath& cwd, const std::vector<std::string>& args, bool interactive) const {
  if (args.empty()) return -1;

  std::ostringstream cmd;
  if (!cwd.empty()) {
    cmd << "cd " << shell_escape(cwd.native()) << " && ";
  }
  for (size_t i = 0; i < args.size(); ++i) {
    if (i > 0) cmd << " ";
    cmd << shell_escape(args[i]);
  }

  const auto runner = [&]() -> int { return decode_exit_code(std::system(cmd.str().c_str())); };
  if (interactive && _run_foreground) {
    return _run_foreground(runner);
  }
  return runner();
}

void EditorManager::touch_session(const std::string& id, bool alive) {
  if (auto* session = find_session(id)) {
    session->last_used_ts = now_seconds();
    session->alive        = alive;
    _last_session_id      = id;
  }
}

bool EditorManager::attach_session(const std::string& id, std::string& error) {
  EditorSessionInfo* session = find_session(id);
  if (!session) {
    error = "Unknown editor session: " + id;
    return false;
  }

  const int rc = run_command(session->cwd, {resolved_binary(), "-a", session->id}, true);
  if (rc != 0) {
    session->alive = false;
    error          = "Failed to attach session '" + session->id + "' (exit " + std::to_string(rc) + ")";
    report_status(error);
    return false;
  }

  touch_session(session->id, true);
  return true;
}

std::vector<std::string> EditorManager::session_order() const {
  std::vector<EditorSessionInfo> ordered = _sessions;
  std::sort(ordered.begin(), ordered.end(), [](const EditorSessionInfo& a, const EditorSessionInfo& b) {
    if (a.last_used_ts != b.last_used_ts) return a.last_used_ts > b.last_used_ts;
    return a.id < b.id;
  });

  std::vector<std::string> ids;
  ids.reserve(ordered.size());
  for (const auto& s : ordered) ids.push_back(s.id);
  return ids;
}

std::string EditorManager::first_existing_session_id() const {
  if (_sessions.empty()) return "";
  const auto ordered = session_order();
  if (ordered.empty()) return "";
  return ordered.front();
}

bool EditorManager::open_directory_new_session(const Filepath& directory, std::string& error) {
  boost::system::error_code ec;
  const bool is_dir = boost::filesystem::is_directory(directory, ec);
  if (ec.failed() || !is_dir) {
    error = "Not a directory: " + directory.native();
    return false;
  }

  EditorSessionInfo session;
  session.id          = create_session_id(directory);
  session.display_name = pretty_name_for_dir(directory);
  session.cwd         = directory;
  session.last_used_ts = now_seconds();
  session.alive       = true;
  _sessions.push_back(session);
  _last_session_id = session.id;

  return attach_session(session.id, error);
}

bool EditorManager::open_files_in_last_session(const std::vector<Filepath>& files, std::string& error) {
  std::vector<Filepath> normalized;
  normalized.reserve(files.size());

  for (const auto& f : files) {
    if (f.empty()) continue;
    Filepath p = f;
    if (p.is_relative()) {
      boost::system::error_code cwd_ec;
      const auto cwd = boost::filesystem::current_path(cwd_ec);
      if (!cwd_ec.failed()) p = cwd / p;
    }
    boost::system::error_code can_ec;
    const Filepath canonical = boost::filesystem::canonical(p, can_ec);
    normalized.push_back(can_ec.failed() ? p : canonical);
  }

  if (normalized.empty()) {
    error = "No file selected for editor open";
    return false;
  }

  std::string session_id = _last_session_id;
  if (session_id.empty() || !find_session(session_id)) {
    const Filepath first_parent = normalized.front().parent_path();
    EditorSessionInfo session;
    session.id           = create_session_id(first_parent);
    session.display_name = pretty_name_for_dir(first_parent);
    session.cwd          = first_parent.empty() ? Filepath(".") : first_parent;
    session.last_used_ts = now_seconds();
    session.alive        = true;
    _sessions.push_back(session);
    session_id = session.id;
    _last_session_id = session_id;
  }

  EditorSessionInfo* session = find_session(session_id);
  if (!session) {
    error = "Failed to resolve editor session";
    return false;
  }

  std::vector<std::string> args;
  args.reserve(5 + normalized.size());
  args.push_back(resolved_binary());
  args.push_back("--cmd");
  args.push_back("session");
  args.push_back("open-file");
  args.push_back(session->id);
  for (const auto& f : normalized) args.push_back(f.native());

  const int open_rc = run_command(session->cwd, args, false);
  // Fresh uses exit code 2 for "open-file started a new session".
  if (open_rc != 0 && open_rc != 2) {
    session->alive = false;
    error = "Failed to open files in editor session '" + session->id + "' (exit " + std::to_string(open_rc) + ")";
    report_status(error);
    return false;
  }

  return attach_session(session->id, error);
}

bool EditorManager::switch_next(std::string& error) {
  if (_sessions.empty()) {
    error = "No editor sessions available";
    return false;
  }
  auto ordered = session_order();
  if (ordered.empty()) {
    error = "No editor sessions available";
    return false;
  }

  if (_last_session_id.empty()) _last_session_id = ordered.front();
  auto it = std::find(ordered.begin(), ordered.end(), _last_session_id);
  if (it == ordered.end()) {
    _last_session_id = ordered.front();
    return attach_session(_last_session_id, error);
  }

  size_t index = static_cast<size_t>(std::distance(ordered.begin(), it));
  index        = (index + 1) % ordered.size();
  return attach_session(ordered[index], error);
}

bool EditorManager::switch_prev(std::string& error) {
  if (_sessions.empty()) {
    error = "No editor sessions available";
    return false;
  }
  auto ordered = session_order();
  if (ordered.empty()) {
    error = "No editor sessions available";
    return false;
  }

  if (_last_session_id.empty()) _last_session_id = ordered.front();
  auto it = std::find(ordered.begin(), ordered.end(), _last_session_id);
  if (it == ordered.end()) {
    _last_session_id = ordered.front();
    return attach_session(_last_session_id, error);
  }

  int index = static_cast<int>(std::distance(ordered.begin(), it));
  index--;
  if (index < 0) index = static_cast<int>(ordered.size()) - 1;
  return attach_session(ordered[static_cast<size_t>(index)], error);
}
