#include "editor_manager.hpp"
#include "runtime_paths.hpp"
#include "settings.hpp"
#include <boost/json.hpp>
#include <fstream>

#include <boost/filesystem.hpp>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <sstream>
#include <string>
#include <vector>

#if defined(__unix__) || defined(__APPLE__)
#include <sys/wait.h>
#include <sys/file.h>
#include <fcntl.h>
#include <spawn.h>
#include <signal.h>
#include <unistd.h>
#include <thread>
extern char** environ;
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

  return bundled_tool_reference(FC_FRESH_DEFAULT_BIN);
}

void EditorManager::set_last_session_id(std::string id) {
  _last_session_id = std::move(id);
  if (!_last_session_id.empty() && !find_session(_last_session_id)) {
    _sessions.push_back({_last_session_id, "Editor", boost::filesystem::current_path(), now_seconds(), true});
  }
}

void EditorManager::set_session_store(Filepath path) {
  _session_store = std::move(path);
  _session_store_error.clear();
  try {
    if (!boost::filesystem::exists(_session_store)) return;
    std::ifstream in(_session_store.string());
    if (!in || boost::filesystem::file_size(_session_store) > 65536) throw std::runtime_error("Cannot read editor session record");
    auto record = boost::json::parse(std::string(std::istreambuf_iterator<char>(in), {})).as_object();
    if (record.at("version").as_int64() != 1) throw std::runtime_error("Unsupported editor session record");
    auto id = std::string(record.at("id").as_string());
    if (id.empty() || id.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_") != std::string::npos)
      throw std::runtime_error("Invalid editor session identity");
    set_last_session_id(id);
    auto cwd = Filepath(std::string(record.at("cwd").as_string()));
    if (!cwd.is_absolute()) throw std::runtime_error("Invalid editor working directory");
    find_session(id)->cwd = cwd;
  } catch (const std::exception& e) {
    _session_store_error = e.what();
    report_status(_session_store_error + "; editor session record retained");
  }
}

bool EditorManager::persist_session(std::string& error) const {
  if (!_session_store_error.empty()) { error = _session_store_error; return false; }
  if (_session_store.empty()) return true;
  const auto* session = find_session(_last_session_id);
  if (!session) { error = "No editor session to checkpoint"; return false; }
  try {
    SettingsStore::atomic_write(_session_store, boost::json::serialize(boost::json::object{
      {"version",1}, {"id",session->id}, {"cwd",boost::filesystem::absolute(session->cwd).native()}}) + "\n");
    return true;
  } catch (const std::exception& e) { error = "Editor checkpoint failed: " + std::string(e.what()); return false; }
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
  std::ostringstream ss;
  ss << "fc-" << boost::filesystem::unique_path("%%%%%%%%-%%%%%%%%-%%%%%%%%").native();
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
  boost::system::error_code ec;
  const auto working = boost::filesystem::is_directory(cwd, ec) && !ec ? cwd : boost::filesystem::current_path();
  cmd << "cd " << shell_escape(working.native()) << " && ";
  cmd << "exec ";
  for (size_t i = 0; i < args.size(); ++i) {
    if (i > 0) cmd << " ";
    cmd << shell_escape(args[i]);
  }

  const auto runner = [&]() -> int {
#if defined(__unix__) || defined(__APPLE__)
    auto command = cmd.str();
    char* argv[] = {const_cast<char*>("/bin/sh"), const_cast<char*>("-c"), command.data(), nullptr};
    posix_spawnattr_t attrs;
    posix_spawnattr_init(&attrs);
    if (!interactive) {
      posix_spawnattr_setpgroup(&attrs, 0);
      posix_spawnattr_setflags(&attrs, POSIX_SPAWN_SETPGROUP);
    }
    pid_t child;
    int rc = posix_spawn(&child, "/bin/sh", nullptr, &attrs, argv, environ);
    posix_spawnattr_destroy(&attrs);
    if (rc) return rc;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(25);
    int status = 0;
    for (;;) {
      auto done = waitpid(child, &status, WNOHANG);
      if (done == child) return decode_exit_code(status);
      if (done < 0 && errno != EINTR) return -1;
      if (!interactive && std::chrono::steady_clock::now() >= deadline) {
        kill(-child, SIGKILL);
        while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
        return 124;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
#else
    return decode_exit_code(std::system(cmd.str().c_str()));
#endif
  };
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

  _last_session_id = id;
  if (!persist_session(error)) return false;
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

bool EditorManager::ensure_session(const Filepath& initial_directory, std::string& error) {
  struct Lock { int fd = -1; ~Lock() { if (fd >= 0) ::close(fd); } } lock;
  try {
    if (!_session_store_error.empty()) { error = _session_store_error; return false; }
    if (!_session_store.empty()) {
      boost::filesystem::create_directories(_session_store.parent_path());
      auto path = _session_store.native() + ".lock";
      lock.fd = ::open(path.c_str(), O_RDWR | O_CREAT | O_CLOEXEC, 0600);
      if (lock.fd < 0) throw std::runtime_error("Cannot lock editor identity");
      auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
      while (::flock(lock.fd, LOCK_EX | LOCK_NB) != 0) {
        if ((errno != EWOULDBLOCK && errno != EINTR) || std::chrono::steady_clock::now() >= deadline)
          throw std::runtime_error("Editor identity is busy; try again");
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
      }
      // Another FC launch may have established the shared identity since startup.
      set_session_store(_session_store);
      if (!_session_store_error.empty()) { error = _session_store_error; return false; }
    }
    if (_last_session_id.empty()) {
      boost::system::error_code ec;
      auto cwd = boost::filesystem::is_directory(initial_directory, ec) && !ec
        ? boost::filesystem::absolute(initial_directory) : boost::filesystem::current_path();
      auto id = create_session_id(cwd);
      _sessions.clear();
      _sessions.push_back({id, pretty_name_for_dir(cwd), cwd, now_seconds(), true});
      _last_session_id = id;
    }
    return persist_session(error);
  } catch (const std::exception& e) { error = e.what(); return false; }
}

bool EditorManager::open_directory(const Filepath& directory, std::string& error) {
  boost::system::error_code ec;
  if (!boost::filesystem::is_directory(directory, ec) || ec) {
    error = "Not a directory: " + directory.native();
    return false;
  }
  return switch_to_editor(directory, error);
}

bool EditorManager::switch_to_editor(const Filepath& initial_directory, std::string& error) {
  if (!ensure_session(initial_directory, error)) return false;
  return attach_session(_last_session_id, error);
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

  if (!ensure_session(normalized.front().parent_path(), error)) return false;
  const auto session_id = _last_session_id;

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

  if (!persist_session(error)) return false;
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
  if (_last_session_id.empty()) { error = "No editor session available"; return false; }
  return switch_to_editor({}, error);
}

bool EditorManager::switch_prev(std::string& error) { return switch_next(error); }
