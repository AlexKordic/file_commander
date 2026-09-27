#include "archive.hpp"
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

int run_command(const Filepath& cwd, const std::vector<std::string>& args) {
  if (args.empty()) return -1;
  std::ostringstream cmd;
  if (!cwd.empty()) {
    cmd << "cd " << shell_escape(cwd.native()) << " && ";
  }
  for (size_t i = 0; i < args.size(); ++i) {
    if (i > 0) cmd << " ";
    cmd << shell_escape(args[i]);
  }
  return decode_exit_code(std::system(cmd.str().c_str()));
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

std::time_t file_mtime_safe(const Filepath& path) {
  boost::system::error_code ec;
  auto t = boost::filesystem::last_write_time(path, ec);
  if (ec.failed()) return 0;
  return t;
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

void ArchiveService::set_tool_path(std::string tool_path) {
  std::lock_guard lock(_mutex);
  _tool_path = std::move(tool_path);
}

std::string ArchiveService::tool_path() const {
  std::lock_guard lock(_mutex);
  if (_tool_path.empty()) return normalize_tool_reference(FC_ARCHIVE_TOOL_DEFAULT);
  return normalize_tool_reference(_tool_path);
}

Err ArchiveService::extract_to_cache(const Filepath& archive_path, Filepath& extracted_root) {
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

  const uintmax_t size = boost::filesystem::file_size(canonical_archive, ec);
  if (ec.failed()) return Err("cannot read archive size: " + canonical_archive.native());
  const std::time_t mtime = file_mtime_safe(canonical_archive);

  {
    std::lock_guard lock(_mutex);
    for (const auto& entry : _cache) {
      if (entry.canonical_archive == canonical_archive && entry.size == size && entry.mtime == mtime && dir_exists(entry.root)) {
        extracted_root = entry.root;
        return Err();
      }
    }
  }

  boost::system::error_code tmp_ec;
  Filepath cache_base = boost::filesystem::temp_directory_path(tmp_ec);
  if (tmp_ec.failed()) cache_base = Filepath("/tmp");
  cache_base /= "file_commander_archive_cache";
  boost::filesystem::create_directories(cache_base, tmp_ec);
  if (tmp_ec.failed()) return Err("cannot create archive cache dir: " + cache_base.native());

  std::string key = canonical_archive.native() + "|" + std::to_string(size) + "|" + std::to_string(static_cast<long long>(mtime));
  const size_t key_hash = std::hash<std::string>{}(key);
  const std::string leaf = sanitize_token(canonical_archive.filename().native()) + "-" + std::to_string(static_cast<unsigned long long>(key_hash));
  const Filepath extract_root = cache_base / leaf;

  boost::filesystem::remove_all(extract_root, ec);
  ec.clear();
  boost::filesystem::create_directories(extract_root, ec);
  if (ec.failed()) return Err("cannot create archive extract dir: " + extract_root.native());

  const std::vector<std::string> args = {
    tool_path(),
    "x",
    "-y",
    "-bb0",
    "-o" + extract_root.native(),
    canonical_archive.native(),
  };
  const int rc = run_command(canonical_archive.parent_path(), args);
  if (rc != 0) {
    boost::filesystem::remove_all(extract_root, ec);
    return Err("archive extract failed (exit " + std::to_string(rc) + "): " + canonical_archive.native());
  }

  {
    std::lock_guard lock(_mutex);
    _cache.push_back(CacheEntry{
      .root = extract_root,
      .canonical_archive = canonical_archive,
      .size = size,
      .mtime = mtime,
    });
  }
  extracted_root = extract_root;
  return Err();
}

Err ArchiveService::create_archive(const Filepath& archive_path, const std::vector<Filepath>& sources, const Filepath& preferred_cwd, ArchiveConflict conflict) {
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
    if (conflict == ArchiveConflict::Skip) return Err();
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
  args.push_back(staged_archive.native());

  for (const auto& src : source_abs) {
    boost::system::error_code rel_ec;
    Filepath rel = boost::filesystem::relative(src, working_dir, rel_ec);
    if (rel_ec.failed() || rel.empty()) rel = src;
    args.push_back(rel.native());
  }

  const int rc = run_command(working_dir, args);
  if (rc != 0) return Err("archive create failed (exit " + std::to_string(rc) + "): " + archive_abs.native());

  if (!boost::filesystem::is_regular_file(staged_archive, ec) || ec.failed())
    return Err("archive create reported success but output file is missing: " + archive_abs.native());
  if (conflict == ArchiveConflict::Replace) {
    boost::filesystem::rename(staged_archive, archive_abs, ec);
  } else {
    boost::filesystem::create_hard_link(staged_archive, archive_abs, ec);
    if (conflict == ArchiveConflict::Skip && ec == boost::system::errc::file_exists) return Err();
  }
  if (ec.failed()) return Err("cannot commit archive: " + ec.message());
  return Err();
}

ArchiveService& archive_service() {
  static ArchiveService service;
  return service;
}
