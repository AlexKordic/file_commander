#include "archive.hpp"
#include "traversal.hpp"
#include "runtime_paths.hpp"

#include <boost/filesystem.hpp>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#if defined(__unix__) || defined(__APPLE__)
#include <sys/wait.h>
#include <sys/stat.h>
#include <unistd.h>
#include <signal.h>
#include <thread>
#include <cerrno>
#endif

#ifndef FC_ARCHIVE_TOOL_DEFAULT
#define FC_ARCHIVE_TOOL_DEFAULT "7zr"
#endif

namespace {

std::string to_lower_ascii(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
    if (c >= 'A' && c <= 'Z') return static_cast<char>(c - 'A' + 'a');
    return static_cast<char>(c);
  });
  return value;
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

int run_command(const Filepath& cwd, const std::vector<std::string>& args, std::atomic<bool>* cancelled = nullptr) {
  if (args.empty()) return -1;
#if defined(__unix__) || defined(__APPLE__)
  if (cancelled && cancelled->load()) return 130;
  std::vector<char*> argv;
  for (const auto& arg : args) argv.push_back(const_cast<char*>(arg.c_str()));
  argv.push_back(nullptr);
  const pid_t pid = fork();
  if (pid < 0) return -1;
  if (pid == 0) {
    setpgid(0, 0);
    if (!cwd.empty() && chdir(cwd.c_str()) != 0) _exit(126);
    execvp(argv[0], argv.data());
    _exit(127);
  }
  setpgid(pid, pid);
  bool terminating = false;
  auto deadline = std::chrono::steady_clock::now();
  int status = 0;
  for (;;) {
    const auto result = waitpid(pid, &status, WNOHANG);
    if (result == pid) {
      if (terminating) kill(-pid, SIGKILL); // Reap the leader and stop any surviving helpers.
      return terminating ? 130 : decode_exit_code(status);
    }
    if (result < 0 && errno != EINTR) return -1;
    if (cancelled && cancelled->load() && !terminating) {
      kill(-pid, SIGTERM);
      terminating = true;
      deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(500);
    }
    if (terminating && std::chrono::steady_clock::now() >= deadline) kill(-pid, SIGKILL);
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
#else
  std::ostringstream cmd;
  if (!cwd.empty()) cmd << "cd " << shell_escape(cwd.native()) << " && ";
  for (const auto& arg : args) cmd << shell_escape(arg) << " ";
  return decode_exit_code(std::system(cmd.str().c_str()));
#endif
}

std::string sanitize_token(const std::string& input) {
  std::string out = input;
  if (out.empty()) out = "archive";
  for (char& c : out) {
    const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_';
    if (!ok) c = '_';
  }
  return out;
}

Filepath absolute_path_safe(const Filepath& path) {
  if (path.is_absolute()) return path.lexically_normal();
  boost::system::error_code ec;
  const Filepath cwd = boost::filesystem::current_path(ec);
  if (!ec.failed()) return (cwd / path).lexically_normal();
  return path.lexically_normal();
}

Filepath common_prefix_path(const std::vector<Filepath>& paths) {
  if (paths.empty()) return Filepath();

  std::vector<std::vector<Filepath>> components;
  components.reserve(paths.size());
  for (const auto& p : paths) {
    std::vector<Filepath> c;
    for (const auto& part : p) c.push_back(part);
    components.push_back(std::move(c));
  }

  size_t max_prefix = components.front().size();
  for (size_t i = 1; i < components.size(); ++i) {
    max_prefix = std::min(max_prefix, components[i].size());
  }

  size_t prefix = 0;
  for (; prefix < max_prefix; ++prefix) {
    const auto& ref = components.front()[prefix];
    bool all_match = true;
    for (size_t i = 1; i < components.size(); ++i) {
      if (components[i][prefix] != ref) {
        all_match = false;
        break;
      }
    }
    if (!all_match) break;
  }

  Filepath out;
  for (size_t i = 0; i < prefix; ++i) out /= components.front()[i];
  return out;
}

bool dir_exists(const Filepath& path) {
  boost::system::error_code ec;
  return boost::filesystem::is_directory(path, ec) && !ec.failed();
}

}  // namespace

bool is_archive_file_path(const Filepath& path) {
  const std::string ext = to_lower_ascii(path.extension().native());
  return ext == ".7z";
}

bool path_is_under(const Filepath& parent, const Filepath& child) {
  const Filepath parent_norm = parent.lexically_normal();
  const Filepath child_norm  = child.lexically_normal();
  const std::string parent_text = parent_norm.native();
  const std::string child_text  = child_norm.native();
  if (parent_text.empty()) return false;
  if (child_text == parent_text) return true;
  std::string prefix = parent_text;
  if (prefix.back() != boost::filesystem::path::preferred_separator) {
    prefix.push_back(boost::filesystem::path::preferred_separator);
  }
  return child_text.rfind(prefix, 0) == 0;
}

ArchiveRoot::~ArchiveRoot() {
  boost::system::error_code ec; boost::filesystem::remove_all(root,ec);
}
ArchiveService::~ArchiveService() = default;

ArchiveLease ArchiveService::lease_for_path(const Filepath& path) const {
  std::lock_guard lock(_mutex);
  for (const auto& entry:_cache) if (path_is_under(entry.root,path)) return entry.lease;
  return {};
}
Location ArchiveService::logical_location(const Filepath& path) const {
  Filepath archive, internal;
  {
    std::lock_guard lock(_mutex);
    for (const auto& entry:_cache) if (path_is_under(entry.root,path)) {
      archive=entry.canonical_archive; internal=path.lexically_relative(entry.root); break;
    }
  }
  if (archive.empty()) return Location{path.lexically_normal(),{}, {}};
  auto location=logical_location(archive);
  location.archives.push_back(location.read_only()?location.internal:location.local);
  location.local.clear(); location.internal=internal; return location;
}
Err ArchiveService::resolve(const Location& location, ResolvedLocation& result, std::atomic<bool>* cancelled) {
  if (!location.read_only()) { result.path=location.local; return {}; }
  Filepath root;
  for (const auto& part:location.archives) {
    auto archive=root.empty()?part:root/part;
    if (!root.empty()) {
      boost::system::error_code ec;
      auto actual=boost::filesystem::canonical(archive,ec);
      if (ec || !path_is_under(root,actual)) return Err("Nested archive is missing or escapes its root");
    }
    ArchiveLease lease;
    auto error=extract_to_cache(archive,root,cancelled,&lease); if (!error.ok()) return error;
    result.archives.push_back({archive,root,std::move(lease)});
  }
  result.path=(root/location.internal).lexically_normal();
  boost::system::error_code ec;
  auto actual=boost::filesystem::canonical(result.path,ec);
  if (ec || !path_is_under(root,actual)) return Err("Archive location is missing or escapes the extraction root");
  return {};
}

void ArchiveService::set_cache_limits(size_t roots,uintmax_t bytes) {
  { std::lock_guard lock(_mutex); _max_roots=roots; _max_bytes=bytes; }
  trim_cache();
}
size_t ArchiveService::cached_roots() const { std::lock_guard lock(_mutex); return _cache.size(); }
void ArchiveService::trim_cache() {
  std::lock_guard lock(_mutex);
  uintmax_t bytes=0; for(const auto& entry:_cache) bytes+=entry.bytes;
  for(auto it=_cache.begin();it!=_cache.end() && (_cache.size()>_max_roots || bytes>_max_bytes);) {
    if(it->lease.use_count()==1) {bytes-=it->bytes; it=_cache.erase(it);} else ++it;
  }
}

void ArchiveService::set_tool_path(std::string tool_path) {
  std::lock_guard lock(_mutex);
  _tool_path = std::move(tool_path);
}

std::string ArchiveService::tool_path() const {
  std::lock_guard lock(_mutex);
  if (_tool_path.empty()) return bundled_tool_reference(FC_ARCHIVE_TOOL_DEFAULT);
  return normalize_tool_reference(_tool_path);
}

bool ArchiveService::is_cached_path(const Filepath& path) const {
  boost::system::error_code ec;
  auto normalized = boost::filesystem::weakly_canonical(path, ec);
  if (ec) normalized = absolute_path_safe(path);
  std::lock_guard lock(_mutex);
  for (const auto& entry : _cache) {
    auto root = boost::filesystem::weakly_canonical(entry.root, ec);
    if (ec) root = entry.root.lexically_normal();
    if (path_is_under(root, normalized)) return true;
  }
  return false;
}

std::string archive_mutation_error(const Filepath& path) {
  if (archive_service().is_cached_path(path))
    return "Archive contents are read-only; copy files out before editing: " + path.native();
  return {};
}

Err ArchiveService::read_source_identity(const Filepath& path, SourceIdentity& identity) {
#if defined(__unix__) || defined(__APPLE__)
  struct stat info {};
  if (::stat(path.c_str(), &info) != 0)
    return Err("cannot inspect archive: " + path.native() + ": " + boost::system::error_code(errno, boost::system::generic_category()).message());
  if (!S_ISREG(info.st_mode)) return Err("archive must be a file: " + path.native());
  identity.device = info.st_dev;
  identity.inode = info.st_ino;
  identity.size = info.st_size;
#if defined(__APPLE__)
  identity.modified_seconds = info.st_mtimespec.tv_sec;
  identity.modified_nanoseconds = info.st_mtimespec.tv_nsec;
  identity.changed_seconds = info.st_ctimespec.tv_sec;
  identity.changed_nanoseconds = info.st_ctimespec.tv_nsec;
#else
  identity.modified_seconds = info.st_mtim.tv_sec;
  identity.modified_nanoseconds = info.st_mtim.tv_nsec;
  identity.changed_seconds = info.st_ctim.tv_sec;
  identity.changed_nanoseconds = info.st_ctim.tv_nsec;
#endif
  identity.reusable = true;
#else
  // Retain ownership of extracted roots, but do not reuse them without a
  // sufficiently precise source identity on this platform.
  boost::system::error_code ec;
  identity.size = boost::filesystem::file_size(path, ec);
  if (ec) return Err("cannot read archive size: " + ec.message());
  identity.modified_seconds = boost::filesystem::last_write_time(path, ec);
  if (ec) return Err("cannot read archive modification time: " + ec.message());
#endif
  return Err();
}

Err ArchiveService::extract_to_cache(const Filepath& archive_path, Filepath& extracted_root, std::atomic<bool>* cancelled, ArchiveLease* lease) {
  if (!is_archive_file_path(archive_path)) return Err("unsupported archive type: " + archive_path.native());

  const Filepath archive_abs = absolute_path_safe(archive_path);
  boost::system::error_code ec;
  if (!boost::filesystem::exists(archive_abs, ec) || ec.failed()) {
    return Err("archive not found: " + archive_abs.native());
  }
  if (!boost::filesystem::is_regular_file(archive_abs, ec) || ec.failed()) {
    return Err("archive must be a file: " + archive_abs.native());
  }

  Filepath canonical_archive = archive_abs;
  Filepath canonical_candidate = boost::filesystem::canonical(archive_abs, ec);
  if (!ec.failed()) canonical_archive = canonical_candidate;

  SourceIdentity identity;
  auto inspected = read_source_identity(canonical_archive, identity);
  if (!inspected.ok()) return inspected;

  {
    std::lock_guard lock(_mutex);
    for (const auto& entry : _cache) {
      if (identity.reusable && entry.canonical_archive == canonical_archive && entry.source == identity && dir_exists(entry.root)) {
        extracted_root = entry.root;
        if (lease) *lease = entry.lease;
        return Err();
      }
    }
  }

  boost::system::error_code tmp_ec;
  Filepath cache_base = boost::filesystem::temp_directory_path(tmp_ec);
  if (tmp_ec.failed()) cache_base = Filepath("/tmp");
  cache_base = boost::filesystem::weakly_canonical(cache_base, tmp_ec);
  if (tmp_ec) return Err("cannot resolve temporary directory");
  cache_base /= "file_commander_archive_cache";
  boost::filesystem::create_directories(cache_base, tmp_ec);
  if (tmp_ec.failed()) return Err("cannot create archive cache dir: " + cache_base.native());

  const Filepath extract_root = cache_base / boost::filesystem::unique_path("extract-%%%%-%%%%-%%%%-%%%%-%%%%-%%%%");
  // Exclusive creation: a collision is an error, never permission to remove or
  // reuse a directory belonging to another service/application instance.
  if (!boost::filesystem::create_directory(extract_root, ec) || ec)
    return Err("cannot create private archive extract dir: " + extract_root.native());
  boost::filesystem::permissions(extract_root, boost::filesystem::owner_all, ec);
  struct Cleanup {
    Filepath root;
    bool committed = false;
    ~Cleanup() { if (!committed) { boost::system::error_code ignored; boost::filesystem::remove_all(root, ignored); } }
  } cleanup{extract_root};
  if (ec) return Err("cannot protect archive extract dir: " + ec.message());

  const std::vector<std::string> args = {
    tool_path(),
    "x",
    "-y",
    "-bb0",
    "-o" + extract_root.native(),
    canonical_archive.native(),
  };
  const int rc = run_command(canonical_archive.parent_path(), args, cancelled);
  if (rc != 0 || (cancelled && cancelled->load())) {
    return Err("archive extract failed (exit " + std::to_string(rc) + "): " + canonical_archive.native());
  }

  uintmax_t extracted_bytes=0;
  TraversalCallbacks measure;
  measure.cancelled=[&] { return cancelled && cancelled->load(); };
  measure.enter=[&](const TraversalEntry& e) { if(boost::filesystem::is_regular_file(e.status)) { boost::system::error_code ec; auto n=boost::filesystem::file_size(e.path,ec); if(!ec) extracted_bytes+=n; } return true; };
  auto measured=traverse({extract_root},{},measure);
  if(measured.cancelled || measured.truncated || measured.errors) return Err("cannot account for extracted archive within traversal budget");
  SourceIdentity after;
  inspected = read_source_identity(canonical_archive, after);
  if (!inspected.ok()) return inspected;
  if (after != identity) return Err("archive changed during extraction: " + canonical_archive.native());
  auto ownership=std::make_shared<ArchiveRoot>(extract_root);
  {
    std::lock_guard lock(_mutex);
    _cache.push_back(CacheEntry{
      .lease = ownership,
      .root = extract_root,
      .canonical_archive = canonical_archive,
      .bytes = extracted_bytes,
      .source = identity,
    });
  }
  cleanup.committed = true;
  extracted_root = extract_root;
  if (lease) *lease = ownership;
  trim_cache(); // ownership pins the root being returned, including legacy path-only callers.
  return Err();
}

Err ArchiveService::create_archive(const Filepath& archive_path, const std::vector<Filepath>& sources, const Filepath& preferred_cwd, ArchiveConflict conflict, std::atomic<bool>* cancelled, bool* skipped) {
  if (skipped) *skipped = false;
  if (!is_archive_file_path(archive_path)) return Err("unsupported archive destination: " + archive_path.native());
  if (sources.empty()) return Err("no input files selected for archive creation");

  const Filepath archive_abs = absolute_path_safe(archive_path);
  const Filepath archive_parent = archive_abs.parent_path();

  boost::system::error_code ec;
  if (!archive_parent.empty()) {
    boost::filesystem::create_directories(archive_parent, ec);
    if (ec.failed()) return Err("cannot create destination dir: " + archive_parent.native());
  }

  std::vector<Filepath> source_abs;
  source_abs.reserve(sources.size());
  for (const auto& p : sources) {
    const auto input = absolute_path_safe(p);
    const auto canonical_input = boost::filesystem::canonical(input, ec);
    if (ec.failed()) return Err("cannot read archive input: " + input.native());
    const bool same = input == archive_abs || boost::filesystem::equivalent(input, archive_abs, ec);
    ec.clear();
    if (same || (dir_exists(input) && path_is_under(canonical_input, archive_abs)))
      return Err("archive output must be outside its selected inputs");
    source_abs.push_back(input);
  }
  const auto destination_status = boost::filesystem::symlink_status(archive_abs, ec);
  if (ec.failed() && ec != boost::system::errc::no_such_file_or_directory)
    return Err("cannot inspect archive destination: " + ec.message());
  ec.clear();
  if (boost::filesystem::exists(destination_status)) {
    if (conflict == ArchiveConflict::Skip) { if (skipped) *skipped = true; return Err(); }
    if (conflict == ArchiveConflict::Update)
      return Err("Update if newer is unavailable for archives; choose Replace or Skip");
  }
  const Filepath staging_dir = archive_parent / boost::filesystem::unique_path(".fc-archive-%%%%-%%%%-%%%%");
  if (!boost::filesystem::create_directory(staging_dir, ec) || ec.failed())
    return Err("cannot create private archive staging directory: " + ec.message());
  struct Cleanup {
    Filepath root;
    ~Cleanup() { boost::system::error_code ignored; boost::filesystem::remove_all(root, ignored); }
  } cleanup{staging_dir};
  const Filepath staged_archive = staging_dir / "output.7z";

  Filepath working_dir;
  if (!preferred_cwd.empty()) {
    const Filepath preferred_abs = absolute_path_safe(preferred_cwd);
    bool all_inside = true;
    for (const auto& src : source_abs) {
      if (!path_is_under(preferred_abs, src)) {
        all_inside = false;
        break;
      }
    }
    if (all_inside && dir_exists(preferred_abs)) {
      working_dir = preferred_abs;
    }
  }
  if (working_dir.empty()) {
    working_dir = common_prefix_path(source_abs);
    if (working_dir.empty()) {
      boost::system::error_code cwd_ec;
      working_dir = boost::filesystem::current_path(cwd_ec);
    }
    if (!dir_exists(working_dir)) {
      working_dir = working_dir.parent_path();
    }
  }
  if (!dir_exists(working_dir)) {
    boost::system::error_code cwd_ec;
    working_dir = boost::filesystem::current_path(cwd_ec);
  }

  std::vector<std::string> args;
  args.reserve(4 + source_abs.size());
  args.push_back(tool_path());
  args.push_back("a");
  args.push_back("-y");
  args.push_back("-spd"); // Selected names are literal, including '*' and '?'.
  args.push_back(staged_archive.native());
  args.push_back("--");

  for (const auto& src : source_abs) {
    boost::system::error_code rel_ec;
    Filepath rel = boost::filesystem::relative(src, working_dir, rel_ec);
    if (rel_ec.failed() || rel.empty()) rel = src;
    // Prefix relative names so '@name' cannot become a 7-Zip list file.
    args.push_back((rel.is_relative() ? Filepath(".") / rel : rel).native());
  }

  const int rc = run_command(working_dir, args, cancelled);
  if (rc != 0) return Err("archive create failed (exit " + std::to_string(rc) + "): " + archive_abs.native());

  if (!boost::filesystem::is_regular_file(staged_archive, ec) || ec.failed())
    return Err("archive create reported success but output file is missing: " + archive_abs.native());
  if (cancelled && cancelled->load()) return Err("archive creation cancelled");
  if (conflict == ArchiveConflict::Replace) {
    boost::filesystem::rename(staged_archive, archive_abs, ec);
  } else {
    boost::filesystem::create_hard_link(staged_archive, archive_abs, ec);
    if (conflict == ArchiveConflict::Skip && ec == boost::system::errc::file_exists) { if (skipped) *skipped = true; return Err(); }
  }
  if (ec.failed()) return Err("cannot commit archive: " + ec.message());
  return Err();
}

ArchiveService& archive_service() {
  static ArchiveService service;
  return service;
}
